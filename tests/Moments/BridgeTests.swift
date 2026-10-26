import Foundation
@main struct BridgeTests {
 static func main() throws {
  let fm = FileManager.default
  let root = fm.temporaryDirectory.appendingPathComponent("bridge-tests-" + UUID().uuidString)
  try MomentsFiles.privateDirectory(root)
  defer { try? fm.removeItem(at: root) }
  let home = root.appendingPathComponent("owner"), nas = root.appendingPathComponent("nas")
  try MomentsFiles.privateDirectory(home);try MomentsFiles.privateDirectory(nas)
  assert((try? MomentsBridge.poll(root: nas, home: home).isEmpty) == true)
  let id = UUID().uuidString.lowercased(), box = nas.appendingPathComponent("Friday/apps/moments/.bridge")
  let request: [String: Any] = ["schema":1,"id":id,"created_at":ISO8601DateFormatter().string(from:Date()),"kind":"refresh"]
  try MomentsFiles.writeJSON(request,box.appendingPathComponent("requests/"+id+".json"))
  let pending = try MomentsBridge.poll(root:nas,home:home);assert(pending.count==1)
  assert(!fm.fileExists(atPath:home.appendingPathComponent("requests/"+id+".json").path))
  try MomentsBridge.captured(pending,home:home)
  assert(fm.fileExists(atPath:home.appendingPathComponent("requests/"+id+".json").path))
  assert((try? MomentsBridge.poll(root:nas,home:home).isEmpty) == true)
  try fm.removeItem(at:home.appendingPathComponent("requests/"+id+".json"))
  try MomentsFiles.writeJSON(["id":id,"status":"refreshed"],home.appendingPathComponent("responses/"+id+".json"))
  assert((try? MomentsBridge.poll(root:nas,home:home).isEmpty) == true)
  assert(!fm.fileExists(atPath:box.appendingPathComponent("requests/"+id+".json").path))
  assert(MomentsFiles.json(box.appendingPathComponent("responses/"+id+".json"))["status"] as? String == "refreshed")
  let evil = UUID().uuidString.lowercased()
  try MomentsFiles.writeJSON(["schema":1,"id":evil,"created_at":ISO8601DateFormatter().string(from:Date()),"kind":"images","asset_ids":["https://bad.test/"]],box.appendingPathComponent("requests/"+evil+".json"))
  assert((try? MomentsBridge.poll(root:nas,home:home).isEmpty) == true)
  assert(!fm.fileExists(atPath:home.appendingPathComponent("requests/"+evil+".json").path))
  print("PASS: refresh waits for native capture, idempotent mailbox, completion relay, URL rejection")
 }
}
