import Foundation

/// Same owner-only fsynced eight-day implementation; NAS content is local only.
public final class NASBusinessJournal:@unchecked Sendable {
    private let journal:MusicBusinessJournal
    public init(directory:URL){journal=MusicBusinessJournal(directory:directory)}
    public func record(tool:String,callID:UUID,argumentsJSON:Data,responseJSON:Data?)throws {
        _=try NASFileRequest(tool:tool,argumentsJSON:argumentsJSON)
        try append(tool:tool,callID:callID,argumentsJSON:argumentsJSON,responseJSON:responseJSON)
    }
    /// Called after the shared strict transfer schema has been admitted. This
    /// records bytes only; it does not grant read scope or issue an operation.
    public func recordTransfer(tool:String,callID:UUID,argumentsJSON:Data,responseJSON:Data?)throws {
        guard ["mio_nas_download","mio_nas_transfer_read"].contains(tool) else {throw NASRuntimeFailure.invalidRequest}
        _=try MusicStrictJSON.object(argumentsJSON,limit:65536,maximumDepth:32)
        try append(tool:tool,callID:callID,argumentsJSON:argumentsJSON,responseJSON:responseJSON)
    }
    private func append(tool:String,callID:UUID,argumentsJSON:Data,responseJSON:Data?)throws {
        if let responseJSON {_=try MusicStrictJSON.object(responseJSON,limit:196608,maximumDepth:32)}
        var row:[String:Any]=["event":responseJSON==nil ? "nas_request":"nas_response","tool":tool,
            "arguments_text":String(decoding:argumentsJSON,as:UTF8.self)]
        if let responseJSON {row["response_text"]=String(decoding:responseJSON,as:UTF8.self)}
        try? journal.append(row,requestID:nil,callID:callID)
    }
}
