import Foundation
private enum Failure:Error {case assertion}
@main enum NativeProjectionFixture {
 static func check(_ value:Bool)throws {if !value {throw Failure.assertion}}
 static func main()throws {
  let id=UUID(),epoch=UUID(),reference=UUID()
  let frame:[String:Any]=["schema":1,"event":"diagnostic","call_id":id.uuidString,"sequence":1,"phase":"effect","kind":"provider_rejected","http_status":200,"code":400,"sub_code":NSNull(),"provider_status":NSNull(),"elapsed_ms":1]
  let legacy=try MusicDiagnostic.decode(frame,callID:id.uuidString,expectedSequence:1)
  try check(legacy.code==400 && legacy.providerMessage==nil && legacy.providerCode==nil)
  var finite=frame;finite["provider_code"]="UNEXPECTED_COLLECTION_TYPE";finite["provider_message"]="songIdList: expected JSON array";finite["provider_msg"]="歌曲权限校验失败"
  let item=try MusicDiagnostic.decode(finite,callID:id.uuidString,expectedSequence:1)
  try check(item.providerCode == "UNEXPECTED_COLLECTION_TYPE" && item.providerMessage == "songIdList: expected JSON array" && item.providerMsg == "歌曲权限校验失败")
  let text=String(decoding:try JSONEncoder().encode(item),as:UTF8.self)
  try check(text.contains("expected JSON array") && !text.contains("SYNTHETIC"))
  for (key,value) in [("provider_code",String(repeating:"X",count:65)),("provider_message","https://private.invalid"),("provider_msg","account=private"),("phase","qr_poll"),("kind","succeeded")] {
   var bad=finite;bad[key]=value;var rejected=false
   do {_=try MusicDiagnostic.decode(bad,callID:id.uuidString,expectedSequence:1)} catch {rejected=true}
   try check(rejected)
  }
  try item.validateProviderFields()
  var unsafe=item;unsafe.providerMessage="Authorization: private"
  var logRejected=false
  do {try unsafe.validateProviderFields()}catch {logRejected=true}
  try check(logRejected)
  let request=try MusicWriteRequest(requestID:id,intent:.appendSong,name:"Synthetic playlist",playlistID:String(repeating:"1",count:32),songID:String(repeating:"2",count:32))
  let original=MusicWriteRecord(request:request,reference:reference,epoch:epoch,baseline:[],effectDisposition:.notDispatched)
  let originalBytes=try JSONEncoder().encode(original)
  var recovery=MusicWriteRecoveryRecord(request:request,reference:reference,epoch:epoch,reason:.notDispatched,decidedAt:Date())
  let empty=MusicReconciliationResult(requestID:id,record:original,result:.init(.notDispatched,request:request),recovery:.init(recovery))
  try check(empty.effectDisposition == .notDispatched)
  let dispositions:[MusicEffectDisposition?]=[.outcomeUnknown,nil,.submitted,.notDispatched]
  for disposition in dispositions {
   recovery.attempts=[MusicWriteRecord(request:request,reference:reference,epoch:epoch,baseline:[],effectDisposition:disposition)]
   try recovery.validate(original:original)
   let projected=MusicReconciliationResult(requestID:id,record:original,result:.init(.outcomeUnknown,request:request),recovery:.init(recovery))
   try check(projected.effectDisposition == (disposition ?? .outcomeUnknown))
   try check(!projected.automaticReplay && !projected.newSubmissionAllowed)
   try check(recovery.mayReserve == (disposition == .notDispatched))
   try check(projected.recovery?.reason=="notDispatched")
   let wire=try JSONSerialization.jsonObject(with:JSONEncoder().encode(projected)) as! [String:Any]
   try check(wire["effect_disposition"] as? String == (disposition ?? .outcomeUnknown).rawValue)
  }
  try check(try JSONDecoder().decode(MusicWriteRecord.self,from:originalBytes)==original)
  print("{\"status\":\"PASS\",\"groups\":[\"legacy_diagnostic\",\"finite_provider_decoder\",\"unknown_and_wrong_phase_rejected\",\"latest_recovery_projection_and_gate\"],\"real_provider\":0,\"real_keychain\":0,\"journal_io\":0}")
 }
}
