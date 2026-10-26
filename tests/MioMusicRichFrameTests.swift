import Foundation
@main enum MioMusicRichFrameTests {
 static func main() throws {
  let base=try MioReadCatalog.descriptors();precondition(base.count==20);try validateMioBaseDescriptors(base)
  var bad=base;bad[14]["description"]="tampered"
  do {try validateMioBaseDescriptors(bad);preconditionFailure("modified_catalog_accepted")}catch let error as ReviewFault {precondition(error.code=="legacy_schema_changed")}
  let list=try MioReadOwnerAdapter.respond(["jsonrpc":"2.0","id":0,"method":"tools/list"],ownerCall:{_,_ in throw OwnerReadFault.unavailable})
  let published=(list["result"] as! [String:Any])["tools"] as! [[String:Any]];try validateMioPublishedDescriptors(published)
  precondition(published.contains{$0["name"] as? String == "mio_netease_song_search"})
  let fixture=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [String:Any]
  let pages=fixture["pages"] as! [[String:Any]];var ids:[String]=[],wireSizes:[Int]=[],offset=0
  for raw in pages {
   let typed=try MusicReadProtocol.decode(raw,for:.search(keyword:"Synthetic query",offset:offset))
   let songs=typed.payload!.songs!;precondition(songs.allSatisfy{$0.metadata.businessInfo!.artists!.count==20})
   let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
   let payload=try encoder.encode(typed)
   let request=OwnerReadRequest(generation:"00000000-0000-4000-8000-000000000001",callID:"00000000-0000-4000-8000-000000000002",tool:"mio_netease_song_search",argumentsJSON:Data("{}".utf8))
   let wire=try OwnerReadWire.response(request,payload:payload,error:nil);precondition(wire.count<=OwnerReadWire.responseLimit);wireSizes.append(wire.count)
   let restored=try OwnerReadWire.payload(wire,request:request)
   let reply=try MioReadOwnerAdapter.respond(["jsonrpc":"2.0","id":1,"method":"tools/call","params":["name":request.tool,"arguments":["keyword":"Synthetic query","offset":offset]]],ownerCall:{_,_ in restored})
   let result=reply["result"] as! [String:Any],structured=result["structuredContent"] as! [String:Any]
   let text=(result["content"] as! [[String:Any]])[0]["text"] as! String
   let parsed=try OwnerReadJSON.object(Data(text.utf8),limit:OwnerReadWire.responseLimit)
   precondition(NSDictionary(dictionary:parsed).isEqual(to:structured));precondition(result["isError"] as? Bool == false)
   let outputSongs=(structured["payload"] as! [String:Any])["songs"] as! [[String:Any]]
   let inputSongs=(raw["payload"] as! [String:Any])["songs"] as! [[String:Any]]
   for (input,output) in zip(inputSongs,outputSongs) {
    let expected=(input["metadata"] as! [String:Any])["business_info"] as! [String:Any]
    let actual=(output["metadata"] as! [String:Any])["business_info"] as! [String:Any]
    precondition(NSDictionary(dictionary:expected).isEqual(to:actual));precondition(NSDictionary(dictionary: input["provider_record"] as! [String:Any]).isEqual(to:output["provider_record"] as! [String:Any]));ids.append(output["song_id"] as! String)
   }
   offset=typed.payload!.searchPage!.nextOffset ?? offset+songs.count
  }
  precondition(ids.count==20 && Set(ids).count==20)
  print(String(decoding:try JSONSerialization.data(withJSONObject:["status":"PASS","real_catalog_and_consumer":true,"real_tools_list_count":published.count,"native_dto_owner_wire_mio_adapter":true,"pages":pages.count,"owner_wire_bytes":wireSizes,"all_20_song_fields_preserved":true]),as:UTF8.self))
 }
}
