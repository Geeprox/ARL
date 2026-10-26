import Foundation
@testable import ARLCredentialOnboarding
@main enum MioPlaylistCoverReadContractTests {
    static func check(_ ok: Bool, line: Int = #line) { precondition(ok, "assertion \(line)") }
    static func main() throws {
        let id=String(repeating:"1",count:32)
        let fields: [String:Any]=["coverImgUrl":"http://p2.music.126.net/matched/109951165474121408.jpg",
            "coverImgId":NSNumber(value:UInt64(1099511650000000123)),"nullCover":NSNull(),"extra":["kept":true]]
        var playlist: [String:Any]=["playlist_id":id,"name":"Synthetic album","track_count":0,
            "provider_record":["fields":fields,"omitted_authentication_fields":[]]]
        func decode(_ row:[String:Any]) throws -> MusicReadPlaylist {
            let raw:[String:Any]=["state":"authorized_read","session":"present","payload":["playlist":row,"songs":[],"complete":true,
                "pagination":["state":"stable_observed","pages":2,"items":0,"total":0]]]
            return try MusicReadProtocol.decode(raw,for:.playlistDetail(playlistID:id)).payload!.playlist!
        }
        let result=try decode(playlist)
        check(MusicPlaylistCoverVerification.coverURL(result) == fields["coverImgUrl"] as? String)
        check(result.providerRecord?.fields["nullCover"] == .null)
        check(String(decoding:try JSONEncoder().encode(result),as:UTF8.self).contains("1099511650000000123"))
        playlist.removeValue(forKey:"provider_record");check(try decode(playlist).providerRecord == nil)
        playlist["provider_record"]=["fields":["coverImgUrl":NSNull()],"omitted_authentication_fields":[]]
        check(try decode(playlist).providerRecord?.fields["coverImgUrl"] == .null)
        playlist["provider_record"]=["fields":["accessToken":"DENY"],"omitted_authentication_fields":[]]
        do {_=try decode(playlist);preconditionFailure("authentication accepted")} catch {}
        let request=try MusicPlaylistCoverRequest(requestID:UUID(),playlistID:id,imageURL:"https://example.test/cover.jpg")
        check(request.imageURL?.scheme == "https")
        check(try MusicPlaylistCoverRequest(requestID:UUID(),playlistID:id,imageURL:"http://p2.music.126.net/cover.jpg").imageURL?.scheme == "https")
        check(try MusicPlaylistCoverRequest(requestID:UUID(),playlistID:id,imageReference:String(repeating:"2",count:32)).imageURL == nil)
        for value in ["file:///tmp/cover.jpg","http://example.test/a","https://user:password@example.test/a"] {
            do {_=try MusicPlaylistCoverRequest(requestID:UUID(),playlistID:id,imageURL:value);preconditionFailure("bad URL")} catch {}
        }
        check(try JSONDecoder().decode(MusicPlaylistCoverRequest.self,from:JSONEncoder().encode(request)) == request)
        print("{\"status\":\"PASS\",\"read_raw_cover\":true,\"lossless_integer\":true,\"simple_url_or_ref\":true,\"authentication_rejected\":true}")
    }
}
