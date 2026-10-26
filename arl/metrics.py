"""Lazy bounded macOS sampling. Process targets are host-owned, never RPC input."""
from __future__ import annotations

import ctypes
import json
import os
import re
import subprocess
import sys
import threading
import time

from .contracts import Fault
from .identity import process_identity

class RUsageV0(ctypes.Structure):
    _fields_ = [('uuid', ctypes.c_uint8*16)] + [(key, ctypes.c_uint64) for key in
        ('user_time','system_time','pkg_idle_wkups','interrupt_wkups','pageins',
         'wired_size','resident_size','phys_footprint','proc_start_abstime','proc_exit_abstime')]

def mac_system():
    if sys.platform != 'darwin':
        raise Fault('metrics_platform_unsupported')
    libc = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
    libc.mach_host_self.restype = ctypes.c_uint32
    libc.host_statistics.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
    ticks, count = (ctypes.c_uint32*4)(), ctypes.c_uint32(4)
    tick_value = None
    host = libc.mach_host_self()
    try:
        if libc.host_statistics(host, 3, ctypes.byref(ticks), ctypes.byref(count)) == 0 and count.value == 4:
            tick_value = list(ticks)
    finally:
        libc.mach_port_deallocate.argtypes = [ctypes.c_uint32,ctypes.c_uint32]
        libc.mach_port_deallocate(ctypes.c_uint32.in_dll(libc,'mach_task_self_').value,host)
    values = {}
    # Each fixed sysctl call has a wall-clock deadline; no shell/argv/env user input.
    deadline = time.monotonic()+1.0
    for key in ('hw.ncpu','hw.memsize','kern.memorystatus_vm_pressure_level','vm.swapusage'):
        remaining = deadline-time.monotonic()
        if remaining <= 0:
            break
        try:
            output = subprocess.run(['/usr/sbin/sysctl','-n',key], capture_output=True,
                text=True, timeout=remaining, env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin'})
            if output.returncode == 0 and len(output.stdout) < 1024:
                values[key] = output.stdout.strip()
        except (OSError, subprocess.TimeoutExpired):
            break
    def integer(key):
        raw = values.get(key, '')
        return int(raw) if re.fullmatch(r'\d{1,20}', raw) else None
    swap = re.search(r'used = ([0-9.]+)([MGK])', values.get('vm.swapusage',''))
    used = int(float(swap.group(1))*{'K':1024,'M':1024**2,'G':1024**3}[swap.group(2)]) if swap else None
    return {'ticks':tick_value, 'cpu_logical_count':integer('hw.ncpu'),
        'memory_total_bytes':integer('hw.memsize'), 'swap_used_bytes':used,
        'memory_pressure':{1:'normal',2:'warning',4:'critical'}.get(integer('kern.memorystatus_vm_pressure_level'),'unknown')}

def mac_process(pid):
    library = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    library.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    info = RUsageV0()
    if library.proc_pid_rusage(pid, 0, ctypes.byref(info)) != 0:
        raise Fault('process_metrics_unavailable')
    return {'cpu_ns':info.user_time+info.system_time, 'rss_bytes':info.resident_size}

class ResourceSampler:
    def __init__(self, *, system_reader=mac_system, process_reader=mac_process,
                 identity_reader=process_identity, clock=time.monotonic, wall_clock=None, include_runtime=True):
        self.system_reader, self.process_reader, self.identity_reader = system_reader, process_reader, identity_reader
        self.clock, self.wall_clock = clock, wall_clock or (lambda:int(time.time()*1000))
        self.lock = threading.RLock()
        self.process_set = {}  # PID -> trusted birth, controlled label and apps
        self.previous = None
        self.cached = None
        self.last_at = None
        self.include_runtime = include_runtime

    def register(self, label, pid, app_ids):
        # Host API; UID + process birth pins avoid attributing PID reuse.
        if type(pid) is not int or pid <= 0 or not re.fullmatch(r'[A-Za-z0-9_.-]{1,64}',label):
            raise Fault('invalid_process_registration')
        apps = frozenset(app_ids)
        if len(apps) > 100 or any(type(app) is not str or not re.fullmatch(r'[A-Za-z0-9_.-]{1,64}',app) for app in apps):
            raise Fault('invalid_process_registration')
        identity = self.identity_reader(pid)
        if identity['uid'] != os.geteuid():
            raise Fault('process_not_owned')
        with self.lock:
            if pid not in self.process_set and len(self.process_set) >= 32:
                raise Fault('process_registration_limit')
            old = self.process_set.get(pid)
            if old and old['identity'] == identity:
                if len(old['app_ids'] | apps) > 100: raise Fault('invalid_process_registration')
                old['app_ids'].update(apps)  # shared interpreter/process counted once
            else:
                self.process_set[pid] = {'identity':identity,'id':label,'app_ids':set(apps)}
            self.cached = None

    def unregister(self, pid):
        with self.lock:
            self.process_set.pop(pid, None)
            self.cached = None

    def sample(self):
        with self.lock:
            now = self.clock()
            if self.cached is not None and self.last_at is not None and now-self.last_at < 5:
                return json.loads(json.dumps(self.cached))
            if self.include_runtime and os.getpid() not in self.process_set:
                try: self.register('runtime', os.getpid(), ['settings'])
                except (OSError, Fault, KeyError): pass
            result = {'state':'unknown', 'sampled_at_ms':self.wall_clock(), 'minimum_interval_ms':5000,
                'cpu_logical_count':None, 'system_cpu_percent':None, 'memory_total_bytes':None,
                'memory_pressure':'unknown','swap_used_bytes':None,'processes':[],
                'attribution':'controlled_process_set_shared_counted_once','gpu_allocation':'unavailable'}
            try: system = self.system_reader()
            except Exception: system = {}
            for key in ('cpu_logical_count','memory_total_bytes','swap_used_bytes'):
                value = system.get(key)
                if type(value) is int and 0 <= value <= 2**64:
                    result[key] = value
            if system.get('memory_pressure') in {'normal','warning','critical'}:
                result['memory_pressure'] = system['memory_pressure']
            ticks = system.get('ticks')
            if not (type(ticks) is list and len(ticks) == 4 and all(type(t) is int and t >= 0 for t in ticks)):
                ticks = None
            previous = self.previous
            elapsed = now-previous['at'] if previous else 0
            if ticks and previous and previous['ticks'] and elapsed > 0:
                delta = [new-old for new,old in zip(ticks,previous['ticks'])]
                if min(delta) >= 0 and sum(delta) > 0:
                    result['system_cpu_percent'] = 100*(sum(delta)-delta[2])/sum(delta)
            processes = {}
            for pid, entry in list(self.process_set.items())[:32]:
                row = {'id':entry['id'],'app_ids':sorted(entry['app_ids']),
                       'rss_bytes':None,'cpu_percent':None,'state':'unavailable'}
                try:
                    if self.identity_reader(pid) != entry['identity']:
                        self.process_set.pop(pid,None)
                        raise Fault('process_identity_changed')
                    data = self.process_reader(pid)
                    # Recheck identity after reading resource data as well.
                    if self.identity_reader(pid) != entry['identity']:
                        self.process_set.pop(pid,None)
                        raise Fault('process_identity_changed')
                    cpu, rss = data['cpu_ns'], data['rss_bytes']
                    if type(cpu) is not int or type(rss) is not int or min(cpu,rss) < 0:
                        raise Fault('invalid_process_metrics')
                    row.update(rss_bytes=rss,state='warming_up')
                    old = previous['processes'].get(pid) if previous else None
                    if old and old['identity'] == entry['identity'] and elapsed > 0 and cpu >= old['cpu_ns']:
                        row.update(cpu_percent=(cpu-old['cpu_ns'])/1e9/elapsed*100,state='available')
                    processes[pid] = {'cpu_ns':cpu,'identity':entry['identity']}
                except Exception: pass
                result['processes'].append(row)
            known = [result[k] is not None for k in ('cpu_logical_count','memory_total_bytes','swap_used_bytes','system_cpu_percent')]
            process_ok = bool(result['processes']) and all(p['state'] == 'available' for p in result['processes'])
            result['state'] = 'available' if all(known) and process_ok and result['memory_pressure'] != 'unknown' else 'partial' if any(known) or any(p['rss_bytes'] is not None for p in result['processes']) else 'unavailable'
            self.previous = {'at':now,'ticks':ticks,'processes':processes}
            self.cached, self.last_at = result, now
            return json.loads(json.dumps(result))
