import Foundation
import CryptoKit
@main struct AuditReuseTests {
 static func main() throws {
  let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent("nas-audit-reuse-"+UUID().uuidString)
  try MomentsFiles.privateDirectory(root);defer{try? fm.removeItem(at:root)}
  let data=root.appendingPathComponent("data"),nas=root.appendingPathComponent("nas")
  try MomentsFiles.privateDirectory(data.appendingPathComponent("media"));try MomentsFiles.privateDirectory(data.appendingPathComponent("private"));try MomentsFiles.privateDirectory(nas)
  let bytes=Data("immutable fixture".utf8),sha=SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined(),ref="media/"+sha+".jpg"
  let local=data.appendingPathComponent(ref);try bytes.write(to:local)
  try MomentsFiles.writeJSON(["posts":[]],data.appendingPathComponent("moments.json"))
  let first=try MomentsNAS.sync(archive:root,destination:nas,template:"__INITIAL_DATA__",reclaim:true)
  let app=nas.appendingPathComponent("Friday/apps/moments"),remote=app.appendingPathComponent("data/"+ref)
  try MomentsFiles.writeJSON(["source_moments_sha256":first,"checked_at":"2026-10-22T00:00:00Z","verification_failures":[],"files":[ref:["sha256":sha,"bytes":bytes.count]]],app.appendingPathComponent(".integrity.json"))
  _=try MomentsNAS.sync(archive:root,destination:nas,template:"__INITIAL_DATA__",reclaim:true)
  assert(MomentsFiles.json(data.appendingPathComponent("private/nas-storage.json"))["reused_NAS_audited_blobs"] as? Int == 1)
  // Even with a prior valid audit, deleting a new local duplicate always checks
  // current NAS bytes again. A corrupt NAS file cannot cause source deletion.
  try bytes.write(to:local);try Data("corrupt after prior audit".utf8).write(to:remote)
  do{_=try MomentsNAS.sync(archive:root,destination:nas,template:"__INITIAL_DATA__",reclaim:true);fatalError("corrupt readback reclaimed source")}
  catch{assert((error as? MomentsFault)?.code == "reclaim_verification_failed")}
  assert(fm.fileExists(atPath:local.path))
  print("PASS: prior committed NAS full-hash proof reused; current readback still required before reclamation")
 }
}
