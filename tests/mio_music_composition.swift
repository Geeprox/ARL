// Isolated APPLE_REVIEW_FIXTURE executable. Production consumer/engine sources;
// descriptor-only calls, injected caller/effects, no EventKit or live service.
import Foundation
import Darwin

final class NoCompositionEffects:AppleEffects {
    var calls=0
    func authorization(_ operation:AppleOperation)->String{calls+=1;return "unknown"}
    func lockState()->String{calls+=1;return "unknown"}
    func resolve(_ binding:TargetBinding)throws->ResolvedTarget{calls+=1;throw ReviewFault("unexpected_effect")}
    func save(_ proposal:AppleProposal,target:ResolvedTarget)throws->String{calls+=1;throw ReviewFault("unexpected_effect")}
}
@main struct MusicCompositionFixture {
    static func main()throws {
        let data=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
        guard data.count<1048576,let cases=try JSONSerialization.jsonObject(with:data) as? [[String:Any]],cases.count<=40 else{throw ReviewFault("fixture_shape")}
        let home=CommandLine.arguments[2]
        let journal=try ConsumptionJournal(home:home)
        var results=[[String:Any]]()
        for item in cases {
            let mode=item["mode"] as! String
            let binding=TargetBinding(alias:"synthetic_calendar",operation:.calendar,identifier:"synthetic-only")
            let policy:()->ReviewPolicy?={
                if mode=="disabled"{return nil}
                return ReviewPolicy(epoch:1,callers:[mioSubject:CallerGrant(operations:[.calendar],targets:[binding.alias],nativeReview:false,workflowIssuers:[],maxEffects:3,delegatedTunnel:mode=="enabled")],targets:[binding.alias:binding],issuerPublicKeys:[:],lockedQualified:[])
            }
            let effects=NoCompositionEffects()
            let consumer=MioCalendarConsumer(engine:AppleApprovalEngine(journal:journal,policy:policy),effects:effects,policy:policy)
            var result:[String:Any]=["name":item["name"]!,"mode":mode]
            do {
                let response=try consumer.respond(["jsonrpc":"2.0","id":1,"method":"tools/list"],caller:.fixture(mioSubject),legacy:{_ in item["response"] as! [String:Any]})
                result["response"]=response
            }catch let fault as ReviewFault{result["code"]=fault.code}
            result["effect_calls"]=effects.calls
            results.append(result)
        }
        let value:[String:Any]=["results":results,"journal_entries":try FileManager.default.contentsOfDirectory(atPath:home).count,
                                "real_native_consumer":true,"real_kernel_IPC":false,"EventKit_linked":false]
        FileHandle.standardOutput.write(try jsonBytes(value))
    }
}
