import Foundation
import PDFKit

// Offline worker: raw PDF on stdin, bounded JSON on stdout. No file path,
// password, networking, GUI, OCR, permission request or authority issuance.
@main enum NASPDFTextExtractor {
    static func emit(_ value: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) {
            FileHandle.standardOutput.write(data)
        }
    }
    static func main() {
        do {
            let args = CommandLine.arguments
            guard args.count == 1 || args.count == 3,
                  let start = Int(args.count == 3 ? args[1] : "1"), start >= 1,
                  let textOffset = Int(args.count == 3 ? args[2] : "0"), textOffset >= 0
            else { emit(["ok": false, "code": "invalid_document_cursor"]); return }
            let memoryBudget = 32 * 1024 * 1024
            var data = Data()
            while let chunk = try FileHandle.standardInput.read(upToCount: min(65536, memoryBudget + 1 - data.count)), !chunk.isEmpty {
                data.append(chunk)
                guard data.count <= memoryBudget else { emit(["ok": false, "code": "input_budget"]); return }
            }
            guard let document = PDFDocument(data: data) else { emit(["ok": false, "code": "invalid_pdf"]); return }
            guard !document.isEncrypted && !document.isLocked else { emit(["ok": false, "code": "encrypted_pdf"]); return }
            var pages: [[String: Any]] = []
            var remaining = 65536
            var next: [Int]?
            for index in min(start - 1, document.pageCount)..<document.pageCount {
                if pages.count == 128 { next = [index + 1, 0]; break }
                let text = document.page(at: index)?.string ?? ""
                let bytes = Data(text.utf8)
                let offset = index == start - 1 ? textOffset : 0
                guard offset <= bytes.count, String(data: bytes.dropFirst(offset), encoding: .utf8) != nil
                else { emit(["ok": false, "code": "invalid_document_cursor"]); return }
                let separator = pages.isEmpty ? 0 : 1
                if remaining <= separator && offset < bytes.count { next = [index + 1, offset]; break }
                remaining -= separator
                var accepted = min(bytes.count - offset, remaining)
                var prefix = String(data: bytes.dropFirst(offset).prefix(accepted), encoding: .utf8)
                while prefix == nil && accepted > 0 {
                    accepted -= 1
                    prefix = String(data: bytes.dropFirst(offset).prefix(accepted), encoding: .utf8)
                }
                pages.append(["index": index + 1, "text_offset": offset, "text": prefix ?? ""])
                remaining -= accepted
                if offset + accepted < bytes.count { next = [index + 1, offset + accepted]; break }
            }
            emit(["ok": true, "page_count": document.pageCount, "pages": pages, "truncated": next != nil, "next": next as Any? ?? NSNull()])
        } catch { emit(["ok": false, "code": "invalid_pdf"]) }
    }
}
