import Foundation
import CoreFoundation
@testable import ARLCredentialOnboarding

@MainActor @main enum NASDownloadIntegrationTests {
    enum Failure:Error {case assertion(String)}
    static var checks=0
    static let source="synthetic",epoch=String(repeating:"e",count:32),ref=String(repeating:"a",count:64),revision=String(repeating:"b",count:64)
    static func expect(_ value:Bool,_ label:String)throws {guard value else{throw Failure.assertion(label)};checks+=1}
    static func bytes(_ v:[String:Any])throws->Data {try OwnerReadWire.encode(v,limit:OwnerReadWire.responseLimit)}
    static func object(_ d:Data)throws->[String:Any] {try OwnerReadJSON.object(d,limit:196608,maximumDepth:32)}
    static func args(size:Int)->[String:Any] { ["operation_id":UUID().uuidString.lowercased(),"source_ref":source,"config_generation":1,"connection_epoch":epoch,"object_ref":ref,"revision":revision,"name":"中文原始文件.txt","size":size] }
    @MainActor final class Fixture {
        var allowed=true,valid=true,wait=false,wrongEOF=false,wrongSize=false
        var now=100.0,calls=0,connections=0,contexts=0
        var currentEpoch=epoch
        var budgetError=false
        var rows:[(String,Data?)]=[]
        let payload:Data
        var executor:NASFileExecutor!
        init(_ payload:Data) {
            self.payload=payload
            var port=NASFileExecutor.Port(allowed:{self.allowed},connectSavedScope:{self.connections+=1},consume:{tool,input in
                self.calls+=1
                while self.wait {try await Task.sleep(for:.milliseconds(5))}
                if self.budgetError {throw NASRuntimeFailure.budgetExceeded}
                let args=try object(input)
                guard tool=="mio_nas_read" else {throw OwnerReadFault.unsupported}
                let offset=NASCapability.integer(args["offset"])!,length=NASCapability.integer(args["length"])!
                let end=min(self.payload.count,offset+length),data=self.payload.subdata(in:offset..<end)
                let page:[String:Any]=["schema_version":1,"operation":"read","source_ref":source,"config_generation":1,"connection_epoch":self.currentEpoch,
                    "location":["host":"nas.invalid","port":445,"share":"share","root":"资料"],"snapshot_consistent":false,
                    "entry":["object_ref":ref,"revision":revision,"path":"资料/中文原始文件.txt","size":self.payload.count+(self.wrongSize ? 1:0),
                        "modified_ns":123,"kind":"file","media_kind":"other","closed":NSNull(),"revision_basis":"metadata"],
                    "offset":offset,"length":length,"bytes_read":data.count,"data_base64":data.base64EncodedString(),
                    "eof":self.wrongEOF ? end != self.payload.count:end==self.payload.count,"next_offset":end==self.payload.count ? NSNull():end as Any]
                let result=try bytes(page)
                let native=try NASFileRequest(tool:tool,argumentsJSON:input)
                let config=try NASConnectionConfiguration(sourceRef:source,host:"nas.invalid",port:445,share:"share",root:"资料",timeoutSeconds:8,generation:1)
                try native.validateResult(result,configuration:config,epoch:self.currentEpoch)
                return result
            },record:{tool,_,_,output in self.rows.append((tool,output))})
            port.validateContext={s,g,e in
                self.contexts+=1
                guard self.valid,s==source,g==1,e==self.currentEpoch else{throw NASRuntimeFailure.sourceChanged}
            }
            executor=NASFileExecutor(port:port,now:{self.now})
        }
        func call(_ tool:String,_ args:[String:Any])async throws->[String:Any] {try object(await executor.execute(tool:tool,argumentsJSON:bytes(args),callID:UUID()))}
    }
    static func chunkArgs(_ manifest:[String:Any],offset:Int,length:Int=32768)->[String:Any] {
        var args:[String:Any]=[:]
        for key in ["operation_id","source_ref","config_generation","connection_epoch","size","transfer_ref","sha256"] {args[key]=manifest[key]}
        args["offset"]=offset;args["length"]=length;return args
    }
    static func error(_ v:[String:Any])->String? {(v["error"] as? [String:Any])?["code"] as? String}
    static func main()async throws {
        let all=Data((0..<(3*1048576+17)).map{UInt8($0%251)}),f=Fixture(all),input=args(size:all.count)
        let manifest=try await f.call("mio_nas_download",input)
        try expect(f.calls==97 && f.connections==0,"97 original native ranges, never reconnect")
        try expect(manifest["name"] as? String=="中文原始文件.txt" && manifest["sha256"] as? String==NASDownloadCapability.hash(all),"Unicode output basename and whole SHA")
        try expect(manifest["object_ref"] as? String==ref && manifest["revision"] as? String==revision,"manifest binds exact source object/revision")
        try expect(OwnerReadWire.falseBoolean(manifest["downloadable_artifact"]),"never invent downloadable artifact")
        let duplicate=try await f.call("mio_nas_download",input)
        try expect(f.calls==97 && duplicate["transfer_ref"] as? String==manifest["transfer_ref"] as? String,"same request reads cached manifest without NAS replay")
        var collected=Data()
        for offset in stride(from:0,to:all.count,by:32768) {
            let args=chunkArgs(manifest,offset:offset),reply=try await f.call("mio_nas_transfer_read",args)
            try expect(try NASDownloadCapability.admit(reply,tool:"mio_nas_transfer_read",args:args),"strict chunk SHA/EOF/reference admission")
            collected.append(Data(base64Encoded:reply["data_base64"] as! String)!)
            let id=UUID(),request=OwnerReadRequest(generation:UUID().uuidString,callID:id.uuidString,tool:"mio_nas_transfer_read",argumentsJSON:try bytes(args))
            let envelope=try OwnerReadWire.response(request,payload:bytes(reply),error:nil),restored=try OwnerReadWire.payload(envelope,request:request)
            let mcp=try MioReadOwnerAdapter.respond(["jsonrpc":"2.0","id":1,"method":"tools/call","params":["name":"mio_nas_transfer_read","arguments":args]],ownerCall:{tool,original in
                try expect(tool==request.tool && original==request.argumentsJSON,"actual MCP-to-owner dispatch keeps exact request")
                return restored
            })
            let result=mcp["result"] as! [String:Any],content=result["content"] as! [[String:Any]]
            try expect(result["isError"] as? Bool==false && content[0]["text"] as? String==String(decoding:restored,as:UTF8.self),"owner framed payload survives MCP dual representation")
            try expect(envelope.count<196608 && (try JSONSerialization.data(withJSONObject:mcp)).count<196608,"32KiB block fits both final representations")
        }
        try expect(collected==all && f.calls==97 && f.contexts>64,"complete three-MiB transfer SHA and live context revalidation, no additional SMB reads")
        var rebound=chunkArgs(manifest,offset:0);rebound["connection_epoch"]=String(repeating:"f",count:32)
        try expect(error(await f.call("mio_nas_transfer_read",rebound)) != nil,"epoch change rejects cached bytes")
        rebound=chunkArgs(manifest,offset:0);rebound["transfer_ref"]=String(repeating:"0",count:64)
        try expect(error(await f.call("mio_nas_transfer_read",rebound)) != nil,"reference substitution rejected")
        f.valid=false
        try expect(error(await f.call("mio_nas_transfer_read",chunkArgs(manifest,offset:0))) != nil,"native scope revocation prevents cached output")
        f.valid=true;f.now=221
        try expect(error(await f.call("mio_nas_transfer_read",chunkArgs(manifest,offset:0)))==NASRuntimeFailure.expired.rawValue,"expiry produces no bytes or rebind")
        try expect(f.calls==97 && f.connections==0,"errors do not replay or reconnect")
        let empty=Fixture(Data()),zero=try await empty.call("mio_nas_download",args(size:0))
        try expect(empty.calls==1 && zero["sha256"] as? String==NASDownloadCapability.hash(Data()),"empty file still receives checked EOF")
        let emptyChunk=try await empty.call("mio_nas_transfer_read",chunkArgs(zero,offset:0))
        try expect(emptyChunk["data_base64"] as? String=="" && emptyChunk["eof"] as? Bool==true,"empty output chunk is exact")
        let budget=Fixture(Data([1,2]));budget.budgetError=true
        try expect(error(await budget.call("mio_nas_download",args(size:2)))==NASRuntimeFailure.budgetExceeded.rawValue && budget.connections==0,"prior epoch budget failure is preserved, never reconnect")
        let malformed=Fixture(Data([1,2]));malformed.wrongEOF=true
        try expect(error(await malformed.call("mio_nas_download",args(size:2))) != nil,"native SDK rejects wrong EOF before aggregation")
        let busy=Fixture(Data([1]));busy.wait=true
        let pending=Task{_ = try await busy.call("mio_nas_download",args(size:1))}
        while busy.calls==0 {await Task.yield()}
        let blocked=try await busy.call("mio_nas_download",args(size:1))
        try expect(error(blocked)=="nas_busy" && busy.calls==1,"serial admission rejects concurrent work")
        busy.executor.suspendForExit();_ = try await pending.value
        try expect(!busy.executor.busy,"exit cancellation drains tracked download")
        let denied=Fixture(Data([1]));denied.valid=false
        try expect(error(await denied.call("mio_nas_download",args(size:1))) != nil && denied.calls==0 && denied.connections==0,"missing/changed saved scope prevents any NAS IO")
        let transition=Fixture(Data([7])),oldArgs=args(size:1)
        let oldManifest=try await transition.call("mio_nas_download",oldArgs)
        transition.valid=false
        try expect(error(await transition.call("mio_nas_transfer_read",chunkArgs(oldManifest,offset:0))) != nil,"revocation blocks original cached bytes")
        transition.valid=true;transition.currentEpoch=String(repeating:"d",count:32)
        var reboundID=oldArgs;reboundID["connection_epoch"]=transition.currentEpoch
        try expect(error(await transition.call("mio_nas_download",reboundID))==NASRuntimeFailure.sourceChanged.rawValue && transition.calls==1,"old operation ID cannot rebind to new valid epoch")
        var fresh=args(size:1);fresh["connection_epoch"]=transition.currentEpoch
        let freshManifest=try await transition.call("mio_nas_download",fresh)
        try expect(transition.calls==2 && freshManifest["connection_epoch"] as? String==transition.currentEpoch,"new legitimate epoch retires obsolete slot without waiting TTL")
        let catalog=try MioReadOwnerAdapter.respond(["jsonrpc":"2.0","id":7,"method":"tools/list"],ownerCall:{_,_ in throw OwnerReadFault.unavailable})
        let descriptors=(catalog["result"] as! [String:Any])["tools"] as! [[String:Any]]
        try validateMioPublishedDescriptors(descriptors)
        let names=descriptors.compactMap { $0["name"] as? String }
        let expectedNAS:Set<String>=["mio_nas_list","mio_nas_search","mio_nas_read","mio_nas_download","mio_nas_transfer_read","mio_nas_search_recursive","mio_nas_read_text","mio_nas_read_document"]
        try expect(Set(names).count==names.count && expectedNAS.isSubset(of:Set(names)) && NASCapability.descriptors.count==8,"actual catalog contains each NAS read tool once and retains checked published anchors")
        try expect(NASDownloadCapability.descriptors.allSatisfy{($0["annotations"] as? [String:Any])?["readOnlyHint"] as? Bool==true},"no write permission is advertised")
        try expect(NASCapability.names.allSatisfy { OwnerReadWire.seconds(for:$0)==110 && OwnerReadWire.seconds(for:$0)<120 },"composed NAS read deadlines remain bounded by native120 second lease")
        try expect(OwnerReadWire.seconds(for:"mio_calendar_create")==210 && OwnerReadWire.seconds(for:"mio_notes_read")==210 && OwnerReadWire.seconds(for:"mio_reminders_create")==210,"Apple execution budgets unchanged")
        try expect(OwnerReadWire.seconds(for:"mio_maps_text_search")==20 && OwnerReadWire.seconds(for:"mio_flyai_ai_search")==75 && OwnerReadWire.seconds(for:"mio_netease_playlist_create")==180,"travel and music execution budgets unchanged")
        if CommandLine.arguments.count==2 {
            let root=URL(fileURLWithPath:CommandLine.arguments[1]);try expect(!FileManager.default.fileExists(atPath:root.path),"new isolated journal")
            let journal=NASBusinessJournal(directory:root),id=UUID()
            try journal.recordTransfer(tool:"mio_nas_download",callID:id,argumentsJSON:bytes(input),responseJSON:nil)
            try journal.recordTransfer(tool:"mio_nas_download",callID:id,argumentsJSON:bytes(input),responseJSON:bytes(manifest))
            try expect(FileManager.default.fileExists(atPath:root.path),"actual SDK log accepts strict new-tool boundary")
        }
        print("PASS NAS native/Mio download integration \(checks) checks; actual SDK admission and synthetic bytes; real SMB/keychain/permissions/install=0")
    }
}
