import Foundation

// These tests exercise launch policy and bounded focus intents only. They never
// load a launch agent or touch the installed app/state.
enum RemindersNativeIO {
    static func privateFile(_ path:String,limit:Int=65536)throws->Data {throw CocoaError(.fileNoSuchFile)}
    static func privateDirectory(_ path:String)throws {throw CocoaError(.fileNoSuchFile)}
}
@main enum ManagedLaunchTests {
    static func main() throws {
        func check(_ value:Bool) {precondition(value)}
        let executable="/synthetic/Applications/ARL.app/Contents/MacOS/ARL"
        var agent:[String:Any] = ["Label":"local.arl.runtime","ProgramArguments":[executable,"--background"],"RunAtLoad":true,"KeepAlive":["SuccessfulExit":false],"ThrottleInterval":10]
        func bytes()throws->Data {try PropertyListSerialization.data(fromPropertyList:agent,format:.xml,options:0)}
        check(ManagedLaunch.validAgent(try bytes(),executable:executable))
        agent["ProgramArguments"]=[executable,"--unreviewed"]
        check(!ManagedLaunch.validAgent(try bytes(),executable:executable))
        agent["ProgramArguments"]=[executable,"--background"];agent["KeepAlive"]=true
        check(!ManagedLaunch.validAgent(try bytes(),executable:executable))
        let status="state = running\nprogram = \(executable)\npid = 12345\n"
        check(ManagedLaunch.managedPID(status,executable:executable)==12345)
        check(ManagedLaunch.managedPID(status,executable:"/other")==nil)
        check(ManagedLaunch.managedPID("program = \(executable)\nstate = not running",executable:executable)==nil)
        let now=Date(timeIntervalSince1970:1000)
        func intent(_ created:Any,extra:Bool=false)throws->Data {
            var p:[String:Any] = ["nonce":UUID().uuidString,"created_at":created]
            if extra {p["action"]="execute"}
            return try JSONSerialization.data(withJSONObject:p)
        }
        check(ManagedLaunch.validIntent(try intent(999),now:now))
        for stale in [980,1001] {check(!ManagedLaunch.validIntent(try intent(stale),now:now))}
        check(!ManagedLaunch.validIntent(try intent(true),now:now))
        check(!ManagedLaunch.validIntent(try intent(999,extra:true),now:now))
        print("managed launch policy, current PID and expiring window intent checks passed")
    }
}
