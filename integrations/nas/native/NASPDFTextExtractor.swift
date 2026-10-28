import Foundation
import PDFKit
import Vision
import AppKit

// Offline worker: raw PDF on stdin, bounded JSON on stdout. No file path,
// password, networking, GUI, permission request or authority issuance.
// Image-only pages use local Vision OCR. Render size and request time are bounded.
@main enum NASPDFTextExtractor {
    static func emit(_ value: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) {
            FileHandle.standardOutput.write(data)
        }
    }
    static func pageText(_ page: PDFPage) throws -> String {
        let embedded = page.string ?? ""
        if !embedded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return embedded }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return "" }
        let scale = min(2, 2048 / max(bounds.width, bounds.height))
        let image = page.thumbnail(of: NSSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale)), for: .mediaBox)
        guard let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw OCRFailure.render }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US", "zh-Hans"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: pixels).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
    enum OCRFailure: Error { case render }
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
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            var pages: [[String: Any]] = []
            var remaining = 65536
            var next: [Int]?
            for index in min(start - 1, document.pageCount)..<document.pageCount {
                if pages.count == 128 || ProcessInfo.processInfo.systemUptime >= deadline { next = [index + 1, 0]; break }
                guard let page = document.page(at: index) else { emit(["ok": false, "code": "invalid_pdf"]); return }
                let text: String
                do { text = try pageText(page) }
                catch { emit(["ok": false, "code": "pdf_ocr_failed"]); return }
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
