import Foundation
import Observation

@MainActor @Observable final class NotesPermissionController {
    let home:URL
    let demo:Bool
    let sourceHeld:Bool
    private(set) var deployment:NotesPermissionDeployment?
    private(set) var configuredState="not_deployed"
    private(set) var records:[NotesPermissionStatus]=[]
    private(set) var busy=false
    private(set) var message:String?
    private var cancellation:NotesControlCancellation?
    init(home:URL,demo:Bool,sourceHeld:Bool=false){self.home=home;self.demo=demo;self.sourceHeld=sourceHeld;refreshConfiguration()}
    func refreshConfiguration() {
        guard !busy else{return}
        deployment=nil
        guard !sourceHeld else{configuredState="source_held";records=[];return}
        guard !demo else{configuredState="preview_disabled";return}
        guard FileManager.default.fileExists(atPath:home.appendingPathComponent("notes-v2/control.json").path) else{configuredState="not_deployed";return}
        do{let value=try NotesPermissionDeployment.load(home:home);try value.verify();deployment=value;configuredState=value.enabled==0 ? "verified_disabled":value.current ? "admitted":"expired"}
        catch{configuredState="identity_unverified";records=[]}
    }
    func canRequest(_ capability:String)->Bool {
        guard !sourceHeld,!demo,!busy,let value=deployment,value.current,value.capability_id==capability else{return false}
        return !FileManager.default.fileExists(atPath:home.appendingPathComponent("notes-v2/control-admissions/"+value.request_id).path)
    }
    var canCheckStatus:Bool { !sourceHeld && !demo && !busy && deployment?.current == true }
    func checkStatus() async {
        guard let value=deployment,canCheckStatus else{message="权限状态入口未获配置与身份核验。";return}
        busy=true
        defer{busy=false}
        do {
            records=try await NotesNativePermissionClient(home:home).snapshot(value)
            message="已向已核验的备忘录服务读取系统 Automation 状态；未请求权限或访问备忘录内容。"
        } catch {
            records=[]
            message="权限状态未核验：\((error as? NotesControlFault)?.code ?? "probe_unavailable")。"
        }
    }
    func request() async {
        guard let value=deployment,canRequest(value.capability_id) else{message="请求未获配置与身份核验，未调用系统授权。";return}
        let stop=NotesControlCancellation();cancellation=stop;busy=true
        defer{busy=false;cancellation=nil}
        do{let reply=try await NotesNativePermissionClient(home:home).request(value,cancel:stop);records=reply.records
            message=reply.synthetic ? "合成授权回调已完成；实际系统权限仍未知，未创建执行授权。":"原生权限流程结果：\(reply.outcome)。没有创建、读取备忘录或授予执行范围。"
        }catch{records=[];message="权限流程未完成：\((error as? NotesControlFault)?.code ?? "permission_needs_review")。核查原请求，勿重新发送或重置 journal。"}
    }
    func cancel(){cancellation?.cancel();message="已请求停止；OS 调用实际返回前仍保持占用，已有系统授权不会撤销。"}
    func permissionTitle(_ capability:String)->String {
        guard let value=records.first(where:{$0.capabilityID==capability}),value.fresh else{return "系统权限未知"}
        return switch value.state {case "authorized_automation":"系统 Automation 已授权";case "denied":"系统未授权";case "not_determined":"尚未请求";default:"系统权限未知"}
    }
}
