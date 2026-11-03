import Foundation

// This fixture calls only the real product status adapter. Catalog enumeration
// is not part of its proof and must fail closed if reached unexpectedly.
func validateMioBaseDescriptors(_ tools: [[String: Any]]) throws { throw OwnerReadFault.unsupported }

enum MioAttachmentInspection {
    struct Failure: Error { let code: String }
    static let name = "mio_attachment_inspect"
    static var descriptor: [String: Any] { [:] }
    static func respond(id: Any, arguments: [String: Any], cancelled: () -> Bool,
                        execute: (Data) throws -> Data) throws -> [String: Any] {
        throw OwnerReadFault.unsupported
    }
}
