import Foundation
// Non-exercised transport/catalog dependencies. respond() and wire codec are real.
struct OwnerReadClient {func call(tool:String,argumentsJSON:Data,cancelled:()->Bool)throws ->Data {throw OwnerReadFault.unavailable}}
enum MioReadCatalog {static func descriptors()throws ->[[String:Any]] {[]}}
enum TaobaoTools {
    static let catalog="taobao_capability_catalog",status="taobao_connection_status"
    static let publicNames:Set<String>=[]
    static var statusAction:CapabilityAction {CapabilityAction(capability:"taobao",action:"connection_status",description:"fixture",inputSchema:[:],outputSchema:[:],readOnly:true,risk:"low",requiresConfirmation:false)}
    static func validPublished(_ value:[String:Any])->Bool {false}
    static func cartIntentID(_ args:[String:Any])throws ->String {throw OwnerReadFault.invalid}
}
