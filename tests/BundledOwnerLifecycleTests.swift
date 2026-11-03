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
 @MainActor static func waitUntil(_ condition: () -> Bool) async throws {
  let deadline=ProcessInfo.processInfo.systemUptime+5
  while !condition() && ProcessInfo.processInfo.systemUptime<deadline { try await Task.sleep(for:.milliseconds(10)) }
  precondition(condition(),"watchdog transition timed out")
 }
 @MainActor static func child(_ executable: String = "/bin/sleep") throws -> Process {
  let process=Process();process.executableURL=URL(fileURLWithPath:executable)
  process.arguments=executable=="/bin/sleep" ? ["30"] : []
  process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
  try process.run();return process
 }
 @MainActor static func checkAutomaticRecovery(home: URL) async throws {
  let owner=BundledRuntimeOwner.fixture(automatic:true)
  var starts=0
  owner.activationTestHook={
   starts += 1
   for key in ["core","mio"] {
    try owner.ensureFixtureChild(key:key, executable:URL(fileURLWithPath:CommandLine.arguments[1]), arguments:["30"])
   }
  }
  let started=await owner.recover(home:home);precondition(started)
  let original=owner.testChild("core")!, sibling=owner.testChild("mio")!
  let lateCallback=original.terminationHandler
  precondition(kill(original.processIdentifier,SIGKILL)==0)
  try await waitUntil { starts==2 && owner.testChild("core")?.isRunning==true }
  precondition(!original.isRunning && owner.testChild("core") !== original)
  precondition(owner.testChild("mio") === sibling && sibling.isRunning,"healthy sibling was restarted")
  lateCallback?(original)
  try await Task.sleep(for:.milliseconds(30))
  precondition(owner.failure==nil && owner.activated,"stale child callback revoked replacement")
  for marker in ["install-maintenance.json","disabled"] {
   let path=home.appendingPathComponent(marker);try Data().write(to:path)
   let before=starts, core=owner.testChild("core")!
   precondition(kill(core.processIdentifier,SIGKILL)==0)
   try await Task.sleep(for:.milliseconds(250))
   precondition(starts==before,"maintenance/disabled marker did not hold recovery")
   try FileManager.default.removeItem(at:path)
   try await waitUntil { starts==before+1 && owner.testChild("core")?.isRunning==true }
  }
  owner.requestExit()
  let before=starts
  precondition(kill(owner.testChild("core")!.processIdentifier,SIGKILL)==0)
  try await Task.sleep(for:.milliseconds(250))
  precondition(starts==before,"exit request restarted a child")
  owner.cancelExit()
  try await waitUntil { starts==before+1 && owner.testChild("core")?.isRunning==true }
  let stopped=await owner.stopAndDrain()
  let finalStarts=starts
  try await Task.sleep(for:.milliseconds(250))
  precondition(stopped && owner.testChildCount==0 && starts==finalStarts,"manual stop restarted service")
  owner.activationTestHook=nil
  print("PASS: real SIGKILL recovery; unchanged healthy sibling; stale callbacks; maintenance/disabled/exit holds; cancelled exit; manual stop")
 }
 @MainActor static func checkLaunchFailureAndBackoff(home: URL) async throws {
  let owner=BundledRuntimeOwner.fixture(automatic:true)
  var times:[TimeInterval]=[]
  owner.activationTestHook={
   times.append(ProcessInfo.processInfo.systemUptime)
   if times.count<4 { throw ARLError(code:"synthetic_start_failed") }
   try owner.ensureFixtureChild(key:"core", executable:URL(fileURLWithPath:CommandLine.arguments[1]), arguments:["30"])
  }
  let first=await owner.recover(home:home);precondition(!first)
  try await waitUntil { times.count==4 && owner.activated }
  precondition(times[1]-times[0]>=0.03 && times[2]-times[1]>=0.06 && times[3]-times[2]>=0.12,"crash retries did not back off")
  precondition(owner.testRecoveryAttempt==3)
  try await waitUntil { owner.testRecoveryAttempt==0 }
  precondition(times.count==4,"healthy service was retried")
  let stopped=await owner.stopAndDrain(forExit:true);precondition(stopped)
  owner.activationTestHook=nil
  let zero=BundledRuntimeOwner.fixture(automatic:true)
  var starts=0
  zero.activationTestHook={
   starts += 1
   try zero.ensureFixtureChild(key:"core", executable:URL(fileURLWithPath:CommandLine.arguments[starts==1 ? 2 : 1]), arguments:starts==1 ? [] : ["30"])
  }
  let running=await zero.recover(home:home);precondition(running)
  try await waitUntil { starts==2 && zero.testChild("core")?.isRunning==true }
  let ended=await zero.stopAndDrain(forExit:true);precondition(ended)
  zero.activationTestHook=nil
  print("PASS: startup failures retry with exponential capped backoff; stable uptime resets attempts; unexpected zero exit restarts")
 }
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
  owner.activationTestHook=nil
  let home=FileManager.default.temporaryDirectory.appendingPathComponent("arl-watchdog-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:home,withIntermediateDirectories:true)
  defer { try? FileManager.default.removeItem(at:home) }
  try await checkAutomaticRecovery(home:home)
  try await checkLaunchFailureAndBackoff(home:home)
 }
}
