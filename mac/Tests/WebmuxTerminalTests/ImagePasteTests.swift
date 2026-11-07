import XCTest
import AppKit
@testable import WebmuxTerminal

/// Pasteboard images for paste-image and clipboard-sync (PARITY C-06, C-07, C-09,
/// C-10, ruling A-11), on private pasteboards so the user's clipboard is untouched.
final class ImagePasteTests: XCTestCase {
    private var pasteboards: [NSPasteboard] = []

    private func pasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("me.puntium.webmux.mac.tests.\(UUID().uuidString)"))
        pasteboards.append(pb)
        return pb
    }

    override func tearDown() {
        pasteboards.forEach { $0.releaseGlobally() }
        pasteboards = []
        super.tearDown()
    }

    /// A 2×2 image as TIFF and PNG bytes.
    private func sample() -> (tiff: Data, png: Data) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<2 { for y in 0..<2 { rep.setColor(x == y ? .red : .blue, atX: x, y: y) } }
        return (rep.tiffRepresentation!, rep.representation(using: .png, properties: [:])!)
    }

    private static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    func testTextOnlyIsNotAnImage() {
        let pb = pasteboard()
        pb.clearContents()
        pb.setString("hello", forType: .string)
        XCTAssertFalse(ImagePaste.hasImage(pb))
        XCTAssertNil(ImagePaste.encode(pb))
    }

    func testTiffIsConvertedToPNG() {
        let pb = pasteboard()
        pb.clearContents()
        pb.setData(sample().tiff, forType: .tiff)
        XCTAssertTrue(ImagePaste.hasImage(pb))
        let encoded = ImagePaste.encode(pb)
        XCTAssertEqual(encoded?.mime, "image/png", "A-11: a type the host does not take becomes PNG")
        let bytes = encoded.flatMap { Data(base64Encoded: $0.base64) }
        XCTAssertEqual(bytes?.prefix(8), Self.pngSignature)
        XCTAssertEqual(NSBitmapImageRep(data: bytes ?? Data())?.pixelsWide, 2)
    }

    func testPNGPassesThroughUnchanged() {
        let pb = pasteboard()
        pb.clearContents()
        let s = sample()
        pb.setData(s.tiff, forType: .tiff)
        pb.setData(s.png, forType: .png)
        let encoded = ImagePaste.encode(pb)
        XCTAssertEqual(encoded?.mime, "image/png")
        XCTAssertEqual(encoded?.base64, s.png.base64EncodedString(), "the host's own type is sent as is")
    }

    func testImageAndTextIsAnImagePaste() {
        // C-06: any paste event that carries an image is diverted.
        let pb = pasteboard()
        pb.clearContents()
        pb.setData(sample().tiff, forType: .tiff)
        pb.setString("caption", forType: .string)
        XCTAssertTrue(ImagePaste.hasImage(pb))
    }

    @MainActor
    func testSyncStateThrottlesAndDedupes() {
        var now = Date(timeIntervalSince1970: 1000)
        let state = ClipboardSyncState(now: { now })
        XCTAssertTrue(state.shouldLook(host: "/h.sock"))
        XCTAssertFalse(state.shouldLook(host: "/h.sock"), "once per second")
        XCTAssertTrue(state.shouldLook(host: "/other.sock"), "per host")
        now = now.addingTimeInterval(1.1)
        XCTAssertTrue(state.shouldLook(host: "/h.sock"))

        let a = ImagePaste.Encoded(mime: "image/png", base64: "AAAA")
        let b = ImagePaste.Encoded(mime: "image/png", base64: "BBBB")
        XCTAssertTrue(state.isNew(a, host: "/h.sock"))
        state.recordSent(a, host: "/h.sock")
        XCTAssertFalse(state.isNew(a, host: "/h.sock"), "the same image is not synced twice")
        XCTAssertTrue(state.isNew(b, host: "/h.sock"))
        XCTAssertTrue(state.isNew(a, host: "/other.sock"))
        state.reset(host: "/h.sock")
        XCTAssertTrue(state.isNew(a, host: "/h.sock"))
    }
}
