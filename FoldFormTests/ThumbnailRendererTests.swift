import XCTest
import UIKit
@testable import FoldForm

final class ThumbnailRendererTests: XCTestCase {
    private func opaqueFraction(_ image: UIImage) -> Double {
        guard let cg = image.cgImage else { return 0 }
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let drawn = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 0 }.count
        return Double(drawn) / Double(w * h)
    }

    func testBoxRendersSomethingThatDoesNotFillTheCanvas() throws {
        let body = ThumbnailRenderer.Body(mesh: GeometryBuilder.box(width: 0.1, height: 0.02, depth: 0.05), rgb: ThumbnailRenderer.defaultRGB)
        let image = try XCTUnwrap(ThumbnailRenderer.render([body]))
        XCTAssertEqual(image.size, CGSize(width: 480, height: 360))
        let fraction = opaqueFraction(image)
        XCTAssertGreaterThan(fraction, 0.05)
        XCTAssertLessThan(fraction, 0.9)
    }

    func testColourShowsInThePixels() throws {
        let red = ThumbnailRenderer.Body(mesh: GeometryBuilder.box(width: 0.1, height: 0.1, depth: 0.1), rgb: [0.9, 0.1, 0.1])
        let image = try XCTUnwrap(ThumbnailRenderer.render([red], size: CGSize(width: 100, height: 100), scale: 1))
        let cg = try XCTUnwrap(image.cgImage)
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: -50, y: -50, width: 100, height: 100))
        XCTAssertGreaterThan(px[0], px[2], "a red body reads red at the centre")
    }

    func testNothingToDrawGivesNil() {
        XCTAssertNil(ThumbnailRenderer.render([]))
        XCTAssertNil(ThumbnailRenderer.render([.init(mesh: .empty, rgb: [1, 1, 1])]))
    }

    func testHugeMeshIsDecimatedAndStillRenders() throws {
        var big = RenderMesh.empty
        for i in 0..<300 { big = RenderMesh.merged([big, GeometryBuilder.cylinder(radius: 0.01, height: 0.01, segments: 64).translated(by: [Float(i) * 0.002, 0, 0])]) }
        XCTAssertGreaterThan(big.indices.count / 3, ThumbnailRenderer.triangleBudget)
        XCTAssertNotNil(ThumbnailRenderer.render([.init(mesh: big, rgb: ThumbnailRenderer.defaultRGB)]))
    }
}
