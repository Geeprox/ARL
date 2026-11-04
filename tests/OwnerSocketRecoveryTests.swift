import Foundation
import Darwin

@main enum OwnerSocketRecoveryTests {
    static func main() throws {
        let recoverable=OwnerReadLifecycle.Snapshot(phase:.failed,failure:.transport,workerJoined:true,operationPending:false,listenerCleanupProven:true)
        precondition(recoverable.canAutomaticallyRecover)
        for failure in [OwnerReadLifecycle.Failure.identity,.cleanupPending] {
            precondition(!OwnerReadLifecycle.Snapshot(phase:.failed,failure:failure,workerJoined:true,operationPending:false,listenerCleanupProven:true).canAutomaticallyRecover)
        }
        precondition(!OwnerReadLifecycle.Snapshot(phase:.failed,failure:.transport,workerJoined:true,operationPending:true,listenerCleanupProven:true).canAutomaticallyRecover)
        precondition(!OwnerReadLifecycle.Snapshot(phase:.failed,failure:.transport,workerJoined:true,operationPending:false,listenerCleanupProven:false).canAutomaticallyRecover)
        guard CommandLine.arguments.count==3 else {exit(2)}
        let mode=CommandLine.arguments[1],path=CommandLine.arguments[2]+"/read.sock"
        if mode=="expect-busy" {
            do {_ = try OwnerReadSocket.fixtureLeasedListener(path:path);exit(3)}
            catch OwnerReadFault.unavailable {print("PASS endpoint preserved");return}
        }
        let listener=try OwnerReadSocket.fixtureLeasedListener(path:path)
        if mode=="hold" {
            try Data("ready".utf8).write(to:URL(fileURLWithPath:CommandLine.arguments[2]+"/ready"))
            while true {usleep(10000)}
        }
        guard mode=="recover",close(listener.fd)==0,
              OwnerReadSocket.fixtureRemove(path:path,device:listener.device,inode:listener.inode) else {exit(4)}
        flock(listener.leaseFD,LOCK_UN);close(listener.leaseFD)
        print("PASS exact stale endpoint recovered")
    }
}
