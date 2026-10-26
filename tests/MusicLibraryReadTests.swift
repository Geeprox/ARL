import Foundation
@testable import ARLCredentialOnboarding
@main enum MusicLibraryReadTests {
    static func main() throws {
        let fixture=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [String:Any]
        for row in fixture["cases"] as! [[String:Any]] {
            let arguments=try JSONSerialization.data(withJSONObject:row["arguments"]!)
            let request=try MusicLibraryReadRequest(toolName:row["tool"] as! String,argumentsJSON:arguments)
            let result=try MusicReadProtocol.decode(row["result"] as! [String:Any],for:.library(request),correlationID:UUID(uuidString:row["correlation_id"] as! String)!)
            if result.state == .authorizedRead {
                precondition(result.payload?.library?.operation == request.operation && result.payload?.complete == false)
                let encoded=try JSONEncoder().encode(result)
                precondition(String(decoding:encoded,as:UTF8.self).contains("9007199254740993"))
            }
        }
        let invalid:[(String,[String:Any])]=[
            ("search_all",["keyword":"x","action":"comment"]),
            ("search_album",["keyword":"x","limit":true]),
            ("search_playlist",["keyword":"x","offset":-1]),
            ("album_get",["album_id":"123"]),
            ("album_get",["album_id":String(repeating:"a",count:32),"desc_flag":"true"]),
            ("album_collected",["limit":1]),
            ("artist_songs",["artist_id":String(repeating:"a",count:32),"limit":1,"offset":0,"start_time":5,"end_time":4]),
            ("song_lyric",["song_id":String(repeating:"a",count:32),"url":"https://example.com"]),
            ("playlist_collected",["limit":true]), ("playlist_collected",["limit":0]),
            ("playlist_collected",["limit":501]), ("playlist_collected",["offset":-1]),
            ("playlist_collected",["offset":9_007_199_254_740_992]),
            ("playlist_get_tags",["limit":1]), ("playlist_get_tags",["action":"updateTags"]) ]
        for (op,args) in invalid {
            do {_ = try MusicLibraryReadRequest(toolName:"mio_netease_"+op,argumentsJSON:JSONSerialization.data(withJSONObject:args));preconditionFailure("invalid_input_accepted")}
            catch is CredentialError {}
        }
        for args: [String: Any] in [[:], ["limit":500,"offset":100000]] {
            _ = try MusicLibraryReadRequest(toolName:"mio_netease_playlist_collected",argumentsJSON:JSONSerialization.data(withJSONObject:args))
        }
        _ = try MusicLibraryReadRequest(toolName:"mio_netease_playlist_get_tags",argumentsJSON:Data("{}".utf8))
        print("PASS: actual bridge/CLI fixtures decoded; \(invalid.count) invalid native inputs rejected, collection defaults/max/large offset and parameterless tags accepted; no real credentials/network")
    }
}

