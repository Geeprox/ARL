import Foundation
import PDFKit

// Test-only: produces a password-protected synthetic PDF in memory.
@main enum NASPDFProtectionFixture {
    static func main() {
        let raw = FileHandle.standardInput.readDataToEndOfFile()
        guard let document = PDFDocument(data: raw),
              let encrypted = document.dataRepresentation(options: [
                PDFDocumentWriteOption.ownerPasswordOption: "SYNTHETIC-OWNER",
                PDFDocumentWriteOption.userPasswordOption: "SYNTHETIC-USER"
              ]) else { exit(1) }
        FileHandle.standardOutput.write(encrypted)
    }
}
