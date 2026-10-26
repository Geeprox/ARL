import Foundation
import Darwin
import Security

enum InstallManagement { static func validateDynamicAndStatic(_ code: SecCode, requirement: SecRequirement?) -> Bool { true } }

struct ARLError: Error { let code: String }
enum RemindersNativeIO {
 static func privateFile(_ path: String) throws -> Data { throw ARLError(code:"fixture_only") }
 static func flatObject(_ raw: Data) throws -> [String:Any] { [:] }
 static func integer(_ value: Any?) -> Int? { value as? Int }
 static func hash(_ raw: Data) -> String { "fixture" }
}
@MainActor final class Suspension {
 var continuation: CheckedContinuation<Void,Never>?
 var entered = false
 func hold() async { entered=true;await withCheckedContinuation { continuation=$0 } }
 func release() { continuation?.resume();continuation=nil }
}
@main struct BundledOwnerLifecycleTests {
 @MainActor static func main() async throws {
  let owner=BundledRuntimeOwner.fixture(), gate=Suspension()
  var starts=0
  owner.afterDrainTestHook={ await gate.hold() }
  owner.activationTestHook={
   starts += 1
   let process=Process();process.executableURL=URL(fileURLWithPath:"/bin/sleep");process.arguments=["30"]
   try process.run();owner.addTestChild(process)
  }
  let recover=Task { @MainActor in await owner.recover(home:URL(fileURLWithPath:"/fixture")) }
  while !gate.entered { await Task.yield() }
  let exiting=Task { @MainActor in await owner.stopAndDrain(forExit:true) }
  await Task.yield();gate.release()
  let recovered=await recover.value, stopped=await exiting.value
  precondition(!recovered && stopped && starts==0 && owner.testChildCount==0,"exit overlap restarted a child")
  owner.cancelExit();owner.afterDrainTestHook=nil
  let second = await owner.recover(home:URL(fileURLWithPath:"/fixture"))
  precondition(second)
  precondition(starts==1 && owner.testChildCount==1,"cancelled exit lost new child ownership")
  let final=await owner.stopAndDrain(forExit:true)
  precondition(final && owner.testChildCount==0,"owned child did not drain")
  print("PASS: overlapping recovery/exit; cancelled exit; exact owned-child drain")
 }
}
