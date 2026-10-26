import Foundation

// Native composition only: no JSON/RPC imports an interaction or grant.
enum MioSetupObservation:String {case unlocked,locked,unknown}
enum MioSetupDecision {case confirmed(Double),cancelled,expired}
struct MioSetupTarget:Equatable {let identifier:String;let name:String}
struct MioSetupResult {let target:MioSetupTarget;let expiresAtMs:Int64}
@MainActor struct MioSetupServices {
    let observation:()->MioSetupObservation
    let validate:()throws->Void
    let consumed:()->Bool
    let phase:(String)->Void
    let review:(_ title:String,_ text:String,_ button:String)throws->MioSetupDecision
    let permission:()->String
    let requestWriteOnly:()async throws->Bool
    let target:()throws->MioSetupTarget
    let monotonic:()->Double
    let wallMs:()->Int64
}
@MainActor enum MioCalendarSetupFlow {
    static func prepare(_ s:MioSetupServices)async throws->MioSetupResult {
        let began=s.monotonic()
        func current()throws {
            guard !Task.isCancelled else{throw ReviewFault("user_cancelled")}
            try s.validate()
            guard !s.consumed() else{throw ReviewFault("session_already_consumed")}
            guard s.monotonic()>=began,s.monotonic()-began<165 else{throw ReviewFault("native_setup_deadline")}
            // This is permission/setup admission, not an awake observation.
            // Unknown may display UI; it never becomes unlocked or write-ready.
            guard s.observation() != .locked else{throw ReviewFault("needs_unlock")}
        }
        func accepted(_ decision:MioSetupDecision)throws->Double {
            switch decision {
            case .cancelled:throw ReviewFault("user_cancelled")
            case .expired:throw ReviewFault("user_cancelled_or_expired")
            case .confirmed(let at):
                let now=s.monotonic()
                guard at.isFinite,now>=at,now-at<20,at>=began else{throw ReviewFault("native_interaction_expired")}
                return at
            }
        }
        s.phase("setup_lock");try current()
        s.phase("setup_disclosure")
        let access=try accepted(s.review("为 Mio 启用日历创建","向当前 Personal 组织的隧道调用者开放一小时、最多三次创建。仅使用默认新建日程日历。","继续"))
        try current()
        guard s.monotonic()-access<20 else{throw ReviewFault("native_interaction_expired")}
        s.phase("setup_permission")
        let beforePermission=s.permission();try current()
        guard s.monotonic()-access<20 else{throw ReviewFault("native_interaction_expired")}
        if beforePermission=="not_determined" {
            guard try await s.requestWriteOnly() else{throw ReviewFault("needs_permission")}
        }
        try current()
        let authorization=s.permission();try current()
        guard ["write_only","full_access"].contains(authorization) else{throw ReviewFault("needs_permission")}
        s.phase("setup_target");let selected=try s.target();try current()
        s.phase("setup_confirmation")
        let approved=try accepted(s.review("允许 Mio 在此日历创建？",selected.name,"启用一小时"))
        // Parent/caller/profile/cancel/expiry/target must remain current AFTER
        // the final potentially blocking operation, immediately before grant.
        try current()
        let finalAuthorization=s.permission();try current()
        guard ["write_only","full_access"].contains(finalAuthorization) else{throw ReviewFault("needs_permission")}
        let final=try s.target();try current()
        guard final==selected else{throw ReviewFault("target_changed")}
        guard s.monotonic()-approved<20 else{throw ReviewFault("native_interaction_expired")}
        return MioSetupResult(target:selected,expiresAtMs:s.wallMs()+3600000)
    }
}
