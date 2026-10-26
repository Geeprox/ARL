import Foundation
@main struct MusicCloudCatalogObservationTests {
 static func main() throws {
  let id="00000000-0000-0000-0000-000000000001"
  let observed:[String:String]=["state":"observed","group":"cloudAsset","command":"songs","http_method":"GET",
    "auth_required":"true","parameter_count":"2","extra_required_parameters":"0",
    "offset_type":"integer","offset_required":"true","offset_location":"query",
    "limit_type":"integer","limit_required":"true","limit_location":"query"]
  func frame(_ c:Any,phase:String="provider")->[String:Any] {
   ["schema":1,"call_id":id,"event":"diagnostic","sequence":1,"phase":phase,"kind":"ignored",
    "http_status":NSNull(),"code":NSNull(),"sub_code":NSNull(),"provider_status":NSNull(),"elapsed_ms":0,"cloud_catalog":c]
  }
  var count=0
  func accepts(_ c:Any) throws {
   let value=try MusicDiagnostic.decode(frame(c),callID:id,expectedSequence:1)
   try value.validateProviderFields()
   _=try JSONEncoder().encode(value);count += 1
  }
  func rejects(_ c:Any,phase:String="provider") throws {
   do {_=try MusicDiagnostic.decode(frame(c,phase:phase),callID:id,expectedSequence:1)}
   catch {count += 1;return}
   throw NSError(domain:"catalog_fixture_expected_rejection",code:1)
  }
  try accepts(observed)
  for state in ["missing","ambiguous","invalid"] {try accepts(["state":state])}
  var changed=observed;changed["extra"]="PRIVATE_VALUE";try rejects(changed)
  changed=observed;changed["command"]="https://private.invalid";try rejects(changed)
  changed=observed;changed["command"]="songs\n";try rejects(changed)
  changed=observed;changed["parameter_count"]="129";try rejects(changed)
  changed=observed;changed["parameter_count"]="02";try rejects(changed)
  changed=observed;changed["offset_location"]="header";try rejects(changed)
  try rejects(observed,phase:"effect")
  try rejects(["state":"missing","command":"unexpected"])
  let decoded=try MusicDiagnostic.decode(frame(observed),callID:id,expectedSequence:1)
  guard decoded.cloudCatalog==observed else {throw NSError(domain:"catalog_fixture_lost_fields",code:1)}
  print("{\"status\":\"PASS\",\"tests\":\(count),\"provider_calls\":0,\"credential_access\":0}")
 }
}
