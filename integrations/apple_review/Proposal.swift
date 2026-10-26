import Foundation
import CryptoKit
import CoreFoundation

struct ReviewFault: Error { let code:String;init(_ code:String){self.code=code} }
func digest(_ data:Data)->String{SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
func identifier(_ text:String)->Bool{text.utf8.count<=64 && text.range(of:#"^[A-Za-z0-9_.-]+$"#,options:.regularExpression) != nil}
func uuid(_ text:String)->Bool{UUID(uuidString:text)?.uuidString.lowercased()==text}
func safeText(_ text:String,limit:Int)->Bool{!text.isEmpty && text.unicodeScalars.count<=limit && !text.unicodeScalars.contains(where:{$0.value<32 || (127...159).contains($0.value)})}
func integer(_ value:Any?)->Int64? {
    guard let number=value as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite,number.doubleValue.rounded()==number.doubleValue,
          abs(number.doubleValue)<=9_007_199_254_740_991 else{return nil}
    return number.int64Value
}

// These bounded wire objects are flat. Foundation checks JSON syntax; this
// lexical pass additionally rejects duplicate keys including escaped aliases.
func flatObject(_ data:Data,limit:Int=16384)throws->[String:Any] {
    guard !data.isEmpty,data.count<=limit,let object=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else{throw ReviewFault("invalid_arguments")}
    let bytes=[UInt8](data);var index=0;var keys=Set<String>()
    func spaces(){while index<bytes.count,[9,10,13,32].contains(bytes[index]){index+=1}}
    func quoted()throws->String {
        guard index<bytes.count,bytes[index]==34 else{throw ReviewFault("invalid_arguments")}
        let start=index;index+=1;var escape=false
        while index<bytes.count {
            let byte=bytes[index];index+=1
            if escape{escape=false;continue};if byte==92{escape=true;continue}
            if byte==34 {
                guard let text=(try? JSONSerialization.jsonObject(with:Data(bytes[start..<index]),options:.fragmentsAllowed)) as? String else{throw ReviewFault("invalid_arguments")}
                return text
            }
        }
        throw ReviewFault("invalid_arguments")
    }
    spaces();guard index<bytes.count,bytes[index]==123 else{throw ReviewFault("invalid_arguments")};index+=1;spaces()
    if index<bytes.count,bytes[index]==125{index+=1}
    else {
        while true {
            let key=try quoted();guard keys.insert(key).inserted else{throw ReviewFault("duplicate_key")}
            spaces();guard index<bytes.count,bytes[index]==58 else{throw ReviewFault("invalid_arguments")};index+=1;spaces()
            if index<bytes.count,bytes[index]==34{_=try quoted()}
            else {
                let start=index
                while index<bytes.count,![44,125,9,10,13,32].contains(bytes[index]){index+=1}
                guard index>start else{throw ReviewFault("invalid_arguments")}
                let token=String(decoding:bytes[start..<index],as:UTF8.self)
                guard token=="null" || token.range(of:#"^-?[0-9]+$"#,options:.regularExpression) != nil else{throw ReviewFault("invalid_arguments")}
            }
            spaces();guard index<bytes.count else{throw ReviewFault("invalid_arguments")}
            if bytes[index]==125{index+=1;break}
            guard bytes[index]==44 else{throw ReviewFault("invalid_arguments")};index+=1;spaces()
        }
    }
    spaces();guard index==bytes.count,keys==Set(object.keys) else{throw ReviewFault("invalid_arguments")}
    return object
}

enum AppleOperation:String {case calendar="apple.calendar.create.v2",reminder="apple.reminders.create.v2"}
struct AppleProposal {
    let operation:AppleOperation;let operationID:String;let callerID:String;let targetAlias:String
    let title:String;let timeZone:String;let start:Date?;let end:Date?;let due:Date?
    let rawHash:String;let raw:Data;let object:[String:Any]
    init(_ data:Data)throws {
        let value=try flatObject(data)
        guard integer(value["schema_version"])==1,let tool=value["tool"] as? String,let operation=AppleOperation(rawValue:tool),
              let op=value["operation_id"] as? String,uuid(op),let caller=value["caller_id"] as? String,identifier(caller),
              let alias=value["target_alias"] as? String,identifier(alias),let title=value["title"] as? String,
              safeText(title,limit:300),!title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              let zone=value["time_zone"] as? String,zone.utf8.count<=80,let timezone=TimeZone(identifier:zone) else{throw ReviewFault("invalid_arguments")}
        let common=Set(["schema_version","tool","operation_id","caller_id","target_alias","title","time_zone"])
        func date(_ field:String)throws->Date {
            guard let text=value[field] as? String,text.utf8.count<=40,
                  text.range(of:#"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:Z|[+-][0-9]{2}:[0-9]{2})$"#,options:.regularExpression) != nil else{throw ReviewFault("invalid_time")}
            let formatter=ISO8601DateFormatter();formatter.formatOptions=[.withInternetDateTime]
            guard let date=formatter.date(from:text) else{throw ReviewFault("invalid_time")}
            let suffix=String(text.suffix(6));let offset:Int
            if text.hasSuffix("Z"){offset=0}
            else {
                guard let hour=Int(suffix.dropFirst().prefix(2)),let minute=Int(suffix.suffix(2)),hour<=23,minute<=59 else{throw ReviewFault("invalid_time")}
                offset=(suffix.first=="-" ? -1:1)*(hour*3600+minute*60)
            }
            guard timezone.secondsFromGMT(for:date)==offset else{throw ReviewFault("time_zone_offset_mismatch")}
            var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(secondsFromGMT:offset)!
            let parts=calendar.dateComponents([.year,.month,.day,.hour,.minute,.second],from:date)
            let digits=Array(text.prefix(19));let widths=[(0,4),(5,2),(8,2),(11,2),(14,2),(17,2)]
            let expected=widths.map{Int(String(digits[$0.0..<($0.0+$0.1)]))}
            guard expected[0] != 0,[parts.year,parts.month,parts.day,parts.hour,parts.minute,parts.second]==expected else{throw ReviewFault("invalid_time")}
            return date
        }
        var start:Date?=nil;var end:Date?=nil;var due:Date?=nil
        if operation == .calendar {
            guard Set(value.keys)==common.union(["start","end"]) else{throw ReviewFault("invalid_arguments")}
            start=try date("start");end=try date("end")
            guard end!>start!,end!.timeIntervalSince(start!)<=86400 else{throw ReviewFault("invalid_time")}
        } else {
            guard Set(value.keys)==common.union(["due"]) else{throw ReviewFault("invalid_arguments")}
            if !(value["due"] is NSNull){due=try date("due")}
        }
        self.operation=operation;operationID=op;callerID=caller;targetAlias=alias;self.title=title;timeZone=zone
        self.start=start;self.end=end;self.due=due;rawHash=digest(data);raw=data;object=value
    }
}
struct TargetBinding {
    let alias:String;let operation:AppleOperation;let identifier:String
    var hash:String{digest(Data((operation.rawValue+"\u{0}"+alias+"\u{0}"+identifier).utf8))}
}
struct ResolvedTarget {let identifier:String;let name:String}
struct ReviewDisplay {
    let proposal:AppleProposal;let target:ResolvedTarget
    var text:String {
        let times=proposal.operation == .calendar ? "开始：\(proposal.object["start"]!)\n结束：\(proposal.object["end"]!)":"到期：\(proposal.object["due"] is NSNull ? "无":String(describing:proposal.object["due"]!))"
        return "目标：\(target.name)\n标题：\(proposal.title)\n\(times)\n时区：\(proposal.timeZone)"
    }
}
