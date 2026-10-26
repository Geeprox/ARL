import Foundation

enum MusicBusinessLogFailure:Error {case unavailable}
final class MusicBusinessJournal:@unchecked Sendable {
    init(directory:URL) {}
    func append(_ row:[String:Any],requestID:UUID?,callID:UUID)throws {}
}
@main struct JournalShapeTests {
 static func main()throws {
    let journal=AppleBusinessJournal(directory:URL(fileURLWithPath:CommandLine.arguments[1]));var checks=0
    func check(_ tool:String,_ args:[String:Any],_ shouldPass:Bool)throws {let raw=try JSONSerialization.data(withJSONObject:args);var accepted=false;do{try journal.recordProduct(tool:tool,callID:UUID(),argumentsJSON:raw,responseJSON:nil);accepted=true}catch{};precondition(accepted==shouldPass);checks+=1}
    try check("mio_reminders_query",[:],true)
    try check("mio_reminders_query",["list_id":"exact"],true)
    try check("mio_reminders_query",["default_list_id":"hidden"],false)
    let task=UUID().uuidString.lowercased()
    try check("mio_reminders_create_item",["task_id":task,"title":"Synthetic"],true)
    try check("mio_reminders_create_item",["task_id":task,"title":"Synthetic","list_id":"exact"],true)
    try check("mio_reminders_create_item",["title":"Synthetic"],false)
    try check("mio_reminders_create_item",["task_id":task,"title":"Synthetic","default_list_id":"hidden"],false)
    try check("mio_reminders_get",["reminder_id":"item"],false)
    try check("mio_reminders_delete_item",["task_id":task,"reminder_id":"item","expected_revision":String(repeating:"a",count:64)],false)
    print("PASS \(checks) real AppleBusinessJournal shape checks; sink=capture-only, durability not exercised")
 }
}
