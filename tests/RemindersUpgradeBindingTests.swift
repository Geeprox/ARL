import Foundation

@main enum RemindersUpgradeBindingTests {
    static func main() throws {
        let old=String(repeating:"a",count:64), new=String(repeating:"b",count:64)
        let closure:[String:String] = ["Contents/Info.plist":"info","Contents/MacOS/ARLRemindersBridge":old,"Contents/_CodeSignature/CodeResources":"resources"]
        let closureRaw=try JSONSerialization.data(withJSONObject:closure)
        let control:[String:Any] = ["schema_version":1,"helper_bundle_path":"/same/app/ARLRemindersBridge.app","host_home":"/same/home","control_requirement":"control","helper_requirement":"helper","helper_executable_sha256":old,"helper_designated_requirement_sha256":"stable","closure_sha256":RemindersNativeIO.hash(closureRaw),"policy_sha256":"policy"]
        let controlRaw=try JSONSerialization.data(withJSONObject:control)
        let updated=try RemindersNativeDeployment.codeBindingReplacement(controlRaw:controlRaw,closureRaw:closureRaw,actualExecutableSHA:new)
        let candidate=try RemindersNativeIO.flatObject(updated.control)
        let differences=Set(control.keys.filter { String(describing:control[$0]!) != String(describing:candidate[$0]!) })
        precondition(differences==["helper_executable_sha256","closure_sha256"])
        let actual=try JSONSerialization.jsonObject(with:updated.closure) as! [String:String]
        precondition(actual["Contents/Info.plist"]=="info" && actual["Contents/_CodeSignature/CodeResources"]=="resources")
        precondition(actual["Contents/MacOS/ARLRemindersBridge"]==new)
        precondition(candidate["closure_sha256"] as? String==RemindersNativeIO.hash(updated.closure))
        for (badControl,badClosure,badHash) in [(controlRaw,closureRaw,"bad"),(controlRaw,Data("{}".utf8),new)] {
            do { _=try RemindersNativeDeployment.codeBindingReplacement(controlRaw:badControl,closureRaw:badClosure,actualExecutableSHA:badHash);fatalError("accepted changed binding") }
            catch { }
        }
        print("PASS reminders upgrade binding: policy and resource preservation; malformed closure/hash rejection")
    }
}
