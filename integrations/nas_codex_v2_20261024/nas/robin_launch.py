"""One owned container: Tor, private model adapter, and Streamlit UI."""
from pathlib import Path
import fcntl,importlib.metadata,json,os,signal,socket,struct,subprocess,sys,threading,time,traceback
home=Path('/robin-state');home.mkdir(exist_ok=True)
report={'started_at':time.time(),'status':'starting'}
def save():
 p=home/'runtime.json';t=p.with_suffix('.tmp');t.write_text(json.dumps(report,indent=2)+'\n');os.replace(t,p)
children=[]
def stop(*_):
 for child in reversed(children):
  if child.poll() is None:child.terminate()
 for child in children:
  try:child.wait(10)
  except subprocess.TimeoutExpired:child.kill();child.wait()
 raise SystemExit(0)
signal.signal(signal.SIGTERM,stop);signal.signal(signal.SIGINT,stop)
try:
 sys.path.insert(0,'/robin-bridge');sys.path.insert(0,'/robin-source')
 from local_api import server
 token=Path('/robin-secret/token').read_text().strip()
 adapter=server('robin',Path('/friday-queue'),token)
 threading.Thread(target=adapter.serve_forever,daemon=True).start()
 os.environ.update(CUSTOM_API_KEY=token,CUSTOM_API_BASE_URL='http://127.0.0.1:19421/v1',CUSTOM_API_MODEL='arl/package/medium')
 # Remove only the previous deployment's compact sampling overrides. UI
 # sliders remain editable; config.py supplies the upstream starting values.
 for key in ('ROBIN_DEFAULT_MAX_RESULTS','ROBIN_DEFAULT_MAX_SCRAPE','ROBIN_DEFAULT_CONTENT_CHARS','ROBIN_DEFAULT_THREADS'):os.environ.pop(key,None)
 report['packages']={name:importlib.metadata.version(name) for name in ('streamlit','langchain-core','langchain-openai','openai')}
 report['arl_client']={'configuration_scope':'streamlit_child','receipt':'client-transport.json'}
 from llm import get_llm
 from health import check_tor_proxy
 report['dependencies_imported']=True
 addresses=[]
 for _,interface in socket.if_nameindex():
  if interface=='lo':continue
  try:
   with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as sock:
    addresses.append(socket.inet_ntoa(fcntl.ioctl(sock.fileno(),0x8915,struct.pack('256s',interface.encode()))[20:24]))
  except OSError:pass
 report['addresses']=addresses
 torlog=home/'tor-runtime.log';torlog.write_text('')
 os.environ['ROBIN_TOR_LOG']=str(torlog)
 tor=subprocess.Popen(['tor','--SocksPort','127.0.0.1:9050','--DataDirectory',str(home/'tor-data'),'--HTTPSProxy','127.0.0.1:17890','--Log','notice file '+str(torlog)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 children.append(tor)
 ui=subprocess.Popen([sys.executable,'/robin-bridge/robin_ui.py','--server.address=0.0.0.0','--server.port=19141','--server.baseUrlPath=apps/robin','--browser.gatherUsageStats=false','--server.headless=true'],cwd='/robin-source')
 children.append(ui)
 report['status']='started';save()
 while True:
  if any(child.poll() is not None for child in children):raise RuntimeError('owned_child_exited')
  report['tor']=check_tor_proxy();report['checked_at']=time.time();save();time.sleep(10)
except BaseException as error:
 if not isinstance(error,SystemExit):
  report['error']=type(error).__name__;report['diagnostic']=traceback.format_exc();report['status']='failed';save()
 for child in reversed(children):
  if child.poll() is None:child.terminate()
 raise
