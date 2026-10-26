import Foundation
import Darwin

/// Durable claims are mandatory; optional business logs cannot replace them.
final class CalendarBusinessTaskStore {
    let home:URL
    private var root:URL {home.appendingPathComponent("calendar-business-once-v1")}
    private var anchor:URL {home.appendingPathComponent("calendar-business-once-v1.anchor")}
    private struct ClaimRecord:Codable {let claim:CalendarBusinessClaim;let claim_sha256:String}
    init(home:URL) {self.home=home}
    private func verify(create:Bool)throws->Bool {
        try RemindersNativeIO.privateDirectory(home.path)
        var dir=stat(),marker=stat()
        let hasDir=lstat(root.path,&dir)==0,dirError=errno
        let hasMarker=lstat(anchor.path,&marker)==0,markerError=errno
        guard hasDir || dirError==ENOENT,hasMarker || markerError==ENOENT,hasDir==hasMarker else{throw CalendarBusinessFault("journal_missing_or_replaced")}
        if !hasDir {
            guard create else{return false}
            guard mkdir(root.path,0o700)==0,lstat(root.path,&dir)==0 else{throw CalendarBusinessFault("journal_unavailable")}
            try RemindersNativeIO.writeNew(Data(("v1\n"+String(dir.st_dev)+"\n"+String(dir.st_ino)+"\n").utf8),to:anchor.path)
        }
        try RemindersNativeIO.privateDirectory(root.path)
        guard lstat(root.path,&dir)==0,try RemindersNativeIO.privateFile(anchor.path)==Data(("v1\n"+String(dir.st_dev)+"\n"+String(dir.st_ino)+"\n").utf8) else{throw CalendarBusinessFault("journal_missing_or_replaced")}
        return true
    }
    private func file(_ id:String,_ suffix:String)throws->String {
        guard RemindersTaskContract.uuid(id) else{throw CalendarBusinessFault("invalid_task_id")}
        return root.appendingPathComponent(id+suffix+".json").path
    }
    private func readClaim(_ id:String)throws->ClaimRecord? {
        guard try verify(create:false) else{return nil}
        let path=try file(id,".claim")
        guard access(path,F_OK)==0 else{return nil}
        let value=try JSONDecoder().decode(ClaimRecord.self,from:RemindersNativeIO.privateFile(path,limit:131072))
        try value.claim.request.validate()
        guard value.claim.request.task_id==id,value.claim.digest==value.claim_sha256 else{throw CalendarBusinessFault("journal_changed")}
        return value
    }
    func lookup(_ id:String)throws->CalendarBusinessOperation? {
        guard let record=try readClaim(id) else{return nil}
        let path=try file(id,".terminal")
        guard access(path,F_OK)==0 else{return .init(task_id:id,digest:record.claim.request.digest,action:record.claim.request.action,state:.attempting,code:"outcome_unknown",event:nil)}
        let op=try JSONDecoder().decode(CalendarBusinessOperation.self,from:RemindersNativeIO.privateFile(path,limit:131072))
        guard op.task_id==id,op.digest==record.claim.request.digest,op.action==record.claim.request.action,op.state != .attempting,!op.automatic_replay else{throw CalendarBusinessFault("journal_changed")}
        return op
    }
    func claim(_ claim:CalendarBusinessClaim)throws {
        try claim.request.validate()
        guard claim.request.action.writes else{throw CalendarBusinessFault("invalid_arguments")}
        _=try verify(create:true)
        try RemindersNativeIO.writeNew(try CalendarBusinessContract.encode(ClaimRecord(claim:claim,claim_sha256:claim.digest)),to:file(claim.request.task_id,".claim"))
        _=try verify(create:false)
    }
    func finish(_ op:CalendarBusinessOperation)throws {
        guard let record=try readClaim(op.task_id),record.claim.request.digest==op.digest,record.claim.request.action==op.action,op.state != .attempting,!op.automatic_replay else{throw CalendarBusinessFault("journal_changed")}
        let path=try file(op.task_id,".terminal"),bytes=try CalendarBusinessContract.encode(op)
        if access(path,F_OK)==0 {
            guard try RemindersNativeIO.privateFile(path,limit:131072)==bytes else{throw CalendarBusinessFault("journal_changed")};return
        }
        try RemindersNativeIO.writeNew(bytes,to:path);_=try verify(create:false)
    }
}

// Confirmation uses the same backend's revision-bound original occurrence.
enum CalendarBusinessConfirmation {
    static func details(_ claim:CalendarBusinessClaim,current:CalendarBusinessEvent?)throws->String {
        if let target=claim.request.target {
            guard current?.target==target else{throw CalendarBusinessFault("revision_changed")}
        } else {guard current==nil else{throw CalendarBusinessFault("target_changed")}}
        func describe(_ draft:CalendarBusinessDraft)->String {
            var text=draft.title+"\n"+draft.start+" → "+draft.end+"\n时区："+draft.time_zone+"\n全天："+(draft.all_day ? "是":"否")
            text+="\n提醒："+(draft.alarm_seconds.isEmpty ? "无":draft.alarm_seconds.map{"提前 "+String($0)+" 秒"}.joined(separator:"、"))
            if let rule=draft.recurrence {
                text+="\n重复："+rule.frequency.title+"，间隔 "+String(rule.interval)
                if let count=rule.count{text+="，共 "+String(count)+" 次"}
                if let until=rule.until{text+="，截止 "+until}
            } else {text+="\n重复：无"}
            return text
        }
        var parts=[claim.calendar.source+" / "+claim.calendar.title]
        if let current {parts.append("原日程：\n"+describe(current.draft))}
        if let draft=claim.request.draft {parts.append((current==nil ? "新日程：\n":"修改为：\n")+describe(draft))}
        if claim.request.action == .delete {parts.append("仅删除上述本次实例。")}
        return parts.joined(separator:"\n\n")
    }
}
