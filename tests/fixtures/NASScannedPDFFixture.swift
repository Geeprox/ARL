import Foundation
import CoreGraphics
import CoreText

// An image-only PDF: the PDF content stream has no text operators or text layer.
@main enum NASScannedPDFFixture {
    static func main() throws {
        let color = CGColorSpaceCreateDeviceRGB()
        let bitmap = CGContext(data: nil, width: 1600, height: 400, bitsPerComponent: 8,
            bytesPerRow: 6400, space: color, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: 1600, height: 400))
        let font = CTFontCreateWithName("Helvetica" as CFString, 62, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "ARL SCANNED DOCUMENT 7429",
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                         NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)]))
        bitmap.textPosition = CGPoint(x: 80, y: 180); CTLineDraw(line, bitmap)
        let bytes = NSMutableData(), consumer = CGDataConsumer(data: bytes)!
        var rect = CGRect(x: 0, y: 0, width: 800, height: 200)
        let pdf = CGContext(consumer: consumer, mediaBox: &rect, nil)!
        pdf.beginPDFPage(nil); pdf.draw(bitmap.makeImage()!, in: rect); pdf.endPDFPage(); pdf.closePDF()
        FileHandle.standardOutput.write(bytes as Data)
    }
}
