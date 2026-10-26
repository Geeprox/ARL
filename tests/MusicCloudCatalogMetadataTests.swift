import Foundation
@main struct MusicCloudCatalogMetadataTests {
 static func main() throws {
  let id="00000000-0000-0000-0000-000000000001"
  let field:[String:Any]=["name":"offset","type":"integer","location":"query","required":"true"]
  let entry:[String:Any]=["operation":["assets","privateSongs"],"endpoint":"/openapi/music/basic/cloud/song/list/v2",
   "http_method":"GET","auth_required":"true","parameter_count":1,"schema_complete":true,"parameters":[field]]
  let base:[String:Any]=["schema_version":1,"coverage":"complete","scanned_methods":1,"matched_methods":1,
   "omitted_candidates":0,"skipped_groups":0,"uninspectable_methods":0,"entries":[entry]]
  func frame(_ value:Any,phase:String="provider")->[String:Any] {
   ["schema":1,"call_id":id,"event":"diagnostic","sequence":1,"phase":phase,"kind":"ignored",
    "http_status":NSNull(),"code":NSNull(),"sub_code":NSNull(),"provider_status":NSNull(),"elapsed_ms":0,"cloud_metadata":value]
  }
  var count=0
  func accepts(_ value:Any) throws {
   let v=try MusicDiagnostic.decode(frame(value),callID:id,expectedSequence:1)
   try v.validateProviderFields();_ = try JSONEncoder().encode(v);count += 1
  }
  func rejects(_ value:Any,phase:String="provider") throws {
   do {_ = try MusicDiagnostic.decode(frame(value,phase:phase),callID:id,expectedSequence:1)}
   catch {count += 1;return}
   throw NSError(domain:"cloud_metadata_expected_rejection",code:1)
  }
  func withEntry(_ e:[String:Any])->[String:Any] {var b=base;b["entries"]=[e];return b}
  try accepts(base)
  var b=base;b["entries"]=[];b["matched_methods"]=0;try accepts(b)
  b=base;b["coverage"]="partial";b["matched_methods"]=2;b["omitted_candidates"]=1;b["scanned_methods"]=2;try accepts(b)
  b=base;b["privatePayload"]="PRIVATE_VALUE";try rejects(b)
  var e=entry;e["description"]="PRIVATE_DESCRIPTION";try rejects(withEntry(e))
  var f=field;f["default"]="PRIVATE_DEFAULT";e=entry;e["parameters"]=[f];try rejects(withEntry(e))
  e=entry;e["endpoint"]="/openapi/cloud/list?token=PRIVATE";try rejects(withEntry(e))
  e=entry;e["operation"]=["cloud","list\n"];try rejects(withEntry(e))
  e=entry;e["parameter_count"]=2;try rejects(withEntry(e))
  b=base;b["matched_methods"]=2;try rejects(b)
  b=base;b["coverage"]="complete";b["skipped_groups"]=1;try rejects(b)
  b=base;b["scanned_methods"]=true;try rejects(b)
  try rejects(base,phase:"effect")
  e=entry;e["schema_complete"]=false;f=field;f["required"]="unknown";e["parameters"]=[f];b=withEntry(e);b["coverage"]="partial";try accepts(b)
  e=entry;e["parameter_count"] = -1;e["parameters"] = [];e["schema_complete"] = false;b=withEntry(e);b["coverage"]="partial";try accepts(b)
  let diagnostic=try MusicDiagnostic.decode(frame(base),callID:id,expectedSequence:1)
  guard diagnostic.cloudMetadata?.entries.first?.operation==["assets","privateSongs"] else {throw NSError(domain:"metadata_lost",code:1)}
  print("{\"status\":\"PASS\",\"tests\":\(count),\"provider_calls\":0,\"credential_access\":0}")
 }
}
