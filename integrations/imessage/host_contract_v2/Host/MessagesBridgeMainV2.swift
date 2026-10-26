import Foundation
import AppKit
import Darwin

@MainActor final class MessagesServerLifecycleV2 {
    let host:MessagesResponsibleHostV2
    let socket:Int32
    let path:String
    let lock:Int32
    private var sources:[DispatchSourceSignal] = []
    private var stopping = false
    init(host:MessagesResponsibleHostV2,socket:Int32,path:String,lock:Int32) {
        self.host = host; self.socket = socket; self.path = path; self.lock = lock
    }
    func install(seconds:Double) {
        for sig in [SIGTERM,SIGINT] {
            signal(sig,SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal:sig,queue:.main)
            source.setEventHandler { [weak self] in Task { @MainActor in await self?.stop() } }
            source.resume(); sources.append(source)
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+seconds) { [weak self] in Task { @MainActor in await self?.stop() } }
    }
    func stop() async {
        guard !stopping else { return }; stopping = true
        _ = shutdown(socket,SHUT_RDWR); close(socket)
        await host.lifecycleStop()
        _ = unlink(path); _ = flock(lock,LOCK_UN); close(lock)
        exit(0)
    }
}

@main struct ARLMessagesBridgeMainV2 {
    @MainActor static func main() {
        do { try run() }
        catch { failure(error) }
    }
    static func failure(_ error:Error) {
        let code = (error as? MessagesTransportFault)?.code ?? "host_unavailable"
        if let data = try? MessagesJSON(["schema_version":2,"status":code,"effects_started":0]).data {
            try? FileHandle.standardError.write(contentsOf:data+Data([10]))
        }
        exit(1)
    }
    @MainActor static func run() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args == ["--serve"] || args == ["--identity-status"] else {
            print("{\"schema_version\":2,\"status\":\"controlled_host_required\",\"effects_started\":0}")
            return
        }
        let (policy,hash) = try MessagesHostPolicyV2.load()
        if args == ["--identity-status"] {
            let identity = try NativePermissionIdentity.current(expectedBundle:"local.arl.messagesbridge")
            let raw = try JSONEncoder().encode(identity)
            let json = try JSONSerialization.jsonObject(with:raw)
            print(String(decoding:try MessagesJSON(["schema_version":2,"identity":json,"implementation":"native_candidate",
                "policy_enabled":policy.enabled == 1 && policy.mode == "live","prompts_requested":false,"messages_data_read":false]).data,as:UTF8.self))
            return
        }
        guard policy.enabled == 1 else { print("{\"schema_version\":2,\"status\":\"activation_not_approved\",\"effects_started\":0}"); return }
        try MessagesNativeIO.privateDirectory(policy.state_root)
        let lock = open(policy.state_root+"/host.lock",O_CREAT|O_RDWR|O_NOFOLLOW,0o600)
        var info = stat()
        guard lock >= 0, fstat(lock,&info) == 0, info.st_mode&S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode&0o077 == 0, info.st_nlink == 1, flock(lock,LOCK_EX|LOCK_NB) == 0 else { throw MessagesTransportFault("host_unavailable") }
        let path = policy.state_root+"/control.sock"
        if access(path,F_OK) == 0 {
            var old = stat()
            guard lstat(path,&old) == 0, old.st_mode&S_IFMT == S_IFSOCK, old.st_uid == getuid(), unlink(path) == 0 else { throw MessagesTransportFault("unsafe_socket") }
        }
        let socket = try MessagesNativeIO.socketAt(path,listen:true)
        #if !MESSAGES_HOST_FIXTURE
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        #endif
        let host = try MessagesResponsibleHostV2(policy:policy,hash:hash)
        let lifecycle = MessagesServerLifecycleV2(host:host,socket:socket,path:path,lock:lock)
        // Expired restarts permit at most 45s of owned cleanup/status, never a renewed trial.
        lifecycle.install(seconds:host.remainingLifetime > 0 ? host.remainingLifetime : 45)
        Task { @MainActor in
            do {
                try await host.start()
                DispatchQueue.global().async {
                    let slots = DispatchSemaphore(value:8)
                    while true {
                        let client = accept(socket,nil,nil)
                        if client < 0 { if errno == EINTR { continue }; break }
                        guard slots.wait(timeout:.now()) == .success else { close(client); continue }
                        var noSignal:Int32 = 1
                        _ = setsockopt(client,SOL_SOCKET,SO_NOSIGPIPE,&noSignal,socklen_t(MemoryLayout<Int32>.size)); _ = fcntl(client,F_SETFD,FD_CLOEXEC)
                        DispatchQueue.global().async {
                            do {
                                let peer = try MessagesNativeIO.Peer(client,requirement:policy.control_requirement)
                                guard let bytes = try MessagesNativeIO.line(client) else { close(client); slots.signal(); return }
                                Task { @MainActor in
                                    let reply = await host.handle(bytes,peer:peer)
                                    try? MessagesNativeIO.send(reply,client,limit:65536)
                                    close(client); slots.signal()
                                }
                            } catch {
                                try? MessagesNativeIO.send(Data("{\"schema_version\":2,\"ok\":false,\"error\":{\"code\":\"identity_unverified\"}}".utf8),client)
                                close(client); slots.signal()
                            }
                        }
                    }
                }
            } catch {
                let code = (error as? MessagesTransportFault)?.code ?? "host_unavailable"
                if let data = try? MessagesJSON(["schema_version":2,"status":code,"effects_started":0]).data {
                    try? FileHandle.standardError.write(contentsOf:data+Data([10]))
                }
                await lifecycle.stop()
            }
        }
        #if MESSAGES_HOST_FIXTURE
        dispatchMain()
        #else
        NSApp.run()
        #endif
    }
}
