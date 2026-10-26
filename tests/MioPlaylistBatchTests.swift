import Foundation
import Darwin
@main enum MioPlaylistBatchTests {
 static func main() throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
  let list=try MioReadOwnerAdapter.respond(["jsonrpc":"2.0","id":1,"method":"tools/list"],ownerCall:{_,_ in throw OwnerReadFault.unavailable})
  let tools=(list["result"] as! [String:Any])["tools"] as! [[String:Any]]
  precondition(tools.count==77);try validateMioPublishedDescriptors(tools)
  try jsonBytes(tools).write(to:root.appendingPathComponent("CATALOG121.json"))
  try jsonBytes(OwnerReadWire.musicBatchDescriptors).write(to:root.appendingPathComponent("FOUR-TOOL-SCHEMAS.json"))
  let original=try JSONSerialization.jsonObject(with:Data(contentsOf:root.deletingLastPathComponent().appendingPathComponent("playlist-reads-20261022.noindex/CATALOG120.json"))) as! [[String:Any]]
  let preserved=try jsonBytes(tools.filter{!OwnerReadWire.musicBatchWrites.contains($0["name"] as! String)}), old=try jsonBytes(original); precondition(preserved==old)
  var count=0,bytes=[Int]()
  for descriptor in OwnerReadWire.musicBatchDescriptors {
   let tool=descriptor["name"] as! String,tags=tool.hasSuffix("update_tags"),intent=tool.hasSuffix("add_songs") ? "add_songs":tool.hasSuffix("reorder") ? "reorder_songs":tags ? "update_playlist_tags":"remove_songs"
   let ids=(1...500).map{String(format:"%032x",$0)},id=UUID().uuidString,field=tags ? "tags":"song_ids"
   let args:[String:Any]=["request_id":id,"intent":intent,"playlist_id":String(repeating:"a",count:32),"playlist_name":"Synthetic playlist",field:tags ? ["流行","摇滚"]:ids]
   let call:([String:Any])->[String:Any] = {["jsonrpc":"2.0","id":2,"method":"tools/call","params":["name":tool,"arguments":$0]]}
   var calls=0
   _=try MioReadOwnerAdapter.respond(call(args),ownerCall:{name,data in
    calls += 1;precondition(name==tool)
    let received=try OwnerReadJSON.object(data,limit:OwnerReadWire.requestLimit)
    precondition(NSDictionary(dictionary:received).isEqual(to:args))
    return try jsonBytes(["state":"verified","request_id":id,"readback_verified":true])
   });precondition(calls==1);count += 1
   let unknown=try MioReadOwnerAdapter.respond(call(args),ownerCall:{_,_ in throw OwnerReadFault.deadline})
   let value=(unknown["result"] as! [String:Any])["structuredContent"] as! [String:Any]
   precondition(value["state"] as? String=="outcome_unknown" && value["request_id"] as? String==id && value["automatic_replay"] as? Bool==false);count += 1
   var invalids=[[String:Any]]();var bad=args;bad[field]=[] as [String];invalids.append(bad)
   bad=args;bad[field]=tags ? ["Same","Same"]:[ids[0],ids[0].uppercased()];invalids.append(bad)
   bad=args;bad["intent"]="create_playlist";invalids.append(bad)
   bad=args;bad["reconcile_only"]=1;invalids.append(bad)
   bad=args;bad["extra"]=true;invalids.append(bad)
   if tool.hasSuffix("remove_songs") {bad=args;bad[field]=ids+[String(repeating:"e",count:32)];invalids.append(bad)}
   for bad in invalids {
    let out=try MioReadOwnerAdapter.respond(call(bad),ownerCall:{_,_ in calls += 1;throw OwnerReadFault.unavailable})
    precondition((out["result"] as? [String:Any])?["isError"] as? Bool==true && calls==1);count += 1
   }
   let arguments=try jsonBytes(args),request=OwnerReadRequest(generation:"synthetic-generation",callID:UUID().uuidString,tool:tool,argumentsJSON:arguments)
   let frame=try request.encoded();bytes.append(frame.count)
   if !tags {precondition(frame.count>16384)}
   var fds=[Int32](repeating:0,count:2);precondition(socketpair(AF_UNIX,SOCK_STREAM,0,&fds)==0)
   try OwnerReadSocket.configure(fds[0]);try OwnerReadSocket.configure(fds[1])
   let writerFD=fds[0], group=DispatchGroup();group.enter()
   DispatchQueue.global().async { defer{group.leave()};do {try OwnerReadSocket.writeFrame(frame,fd:writerFD,limit:OwnerReadWire.requestLimit,deadline:OwnerReadSocket.now+3,cancelled:{false})} catch {fatalError("synthetic socket writer: \(error)")} }
   let roundtrip=try OwnerReadSocket.readFrame(fds[1],limit:OwnerReadWire.requestLimit,deadline:OwnerReadSocket.now+3,cancelled:{false})
   group.wait();close(fds[0]);close(fds[1]);precondition(roundtrip==frame)
   let decoded=try OwnerReadWire.request(roundtrip,generation:"synthetic-generation")
   let parsed=try OwnerReadWire.batchIntent(tool,OwnerReadJSON.object(decoded.argumentsJSON,limit:OwnerReadWire.requestLimit)); precondition(parsed.items == (tags ? ["流行","摇滚"]:ids));count += 1
   let line=try jsonBytes(call(args)),lineBytes=Array(line)+[UInt8(10)];var cursor=0
   let io=LineIO(now:{0},wait:{_,_ in 1},receive:{_ in defer{cursor += 1};return cursor<lineBytes.count ? (1,lineBytes[cursor]):(0,0)})
   let restored=try boundedLine(-1,io:io); precondition(restored==line);count += 1
  }
  do {_=try OwnerReadWire.encode(["oversized":String(repeating:"x",count:65536)],limit:OwnerReadWire.requestLimit);preconditionFailure("oversize admitted")} catch OwnerReadFault.limit {count += 1}
  var bad=tools;let i=bad.firstIndex{$0["name"] as? String=="mio_netease_playlist_reorder"}!;bad[i]["description"]="tampered"
  do {try validateMioPublishedDescriptors(bad);preconditionFailure("modified catalog accepted")} catch is ReviewFault {count += 1}
  print(String(decoding:try jsonBytes(["status":"PASS","cases":count,"catalog_count":77,"unchanged_prior_descriptors":73,"request_frame_bytes":bytes,"no_truncation":true,"real_network":false,"real_writes":0]),as:UTF8.self))
 }
}
