import Foundation
@main enum CoverTokenRecoveryArgumentsTests {
 static func main() throws {
  precondition(!MusicPlaylistCoverCapability.requestsRecovery([:]))
  precondition(!MusicPlaylistCoverCapability.requestsRecovery(["reconcile_only":true]))
  precondition(!MusicPlaylistCoverCapability.requestsRecovery(["reconcile_only":0]))
  precondition(!MusicPlaylistCoverCapability.requestsRecovery(["reconcile_only":"false"]))
  precondition(MusicPlaylistCoverCapability.requestsRecovery(["reconcile_only":false]))
  let args: [String:Any] = ["request_id":UUID().uuidString,"playlist_id":String(repeating:"a",count:32),"image_url":"https://example.test/a.png","reconcile_only":false]
  _ = try MusicPlaylistCoverCapability.validate(args)
  let schema = MusicPlaylistCoverCapability.descriptor["inputSchema"] as! [String:Any]
  let props = schema["properties"] as! [String:Any]
  precondition((props["reconcile_only"] as! [String:Any])["default"] as? Bool == false)
  print("{\"state\":\"PASS\",\"checks\":7,\"missing_means_recovery\":false}")
 }
}
