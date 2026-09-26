import Foundation
import UIKit
import simd

/// A small, bounded vector sketch. Its points are independent of display size and can be sent as
/// geometric context alongside a PNG rendering.
struct SketchDrawing: Equatable {
    private(set) var polylines: [[SIMD2<Float>]] = []

    mutating func addStroke(_ points: [CGPoint], in size: CGSize) {
        guard size.width > 0, size.height > 0, !points.isEmpty, polylines.count < 32 else { return }
        let strideLength = max(1, Int(ceil(Double(points.count) / 256)))
        let sampled = Swift.stride(from: 0, to: points.count, by: strideLength).map { point in
            SIMD2<Float>(
                Float(min(max(points[point].x / size.width, 0), 1)),
                Float(min(max(points[point].y / size.height, 0), 1))
            )
        }
        polylines.append(sampled)
    }

    /// Accessible alternative to freehand input, useful as a simple profile guide.
    mutating func addGuideRectangle() {
        guard polylines.count < 32 else { return }
        polylines.append([[0.2, 0.2], [0.8, 0.2], [0.8, 0.8], [0.2, 0.8], [0.2, 0.2]])
    }

    mutating func clear() { polylines.removeAll() }

    func pngData(size: CGSize = CGSize(width: 512, height: 512)) -> Data? {
        guard size.width > 0, size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            cg.setFillColor(UIColor.white.cgColor)
            cg.fill(CGRect(origin: .zero, size: size))
            cg.setStrokeColor(UIColor.black.cgColor)
            cg.setLineWidth(4)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            for line in polylines where !line.isEmpty {
                cg.beginPath()
                cg.move(to: CGPoint(x: CGFloat(line[0].x) * size.width, y: CGFloat(line[0].y) * size.height))
                for point in line.dropFirst() {
                    cg.addLine(to: CGPoint(x: CGFloat(point.x) * size.width, y: CGFloat(point.y) * size.height))
                }
                cg.strokePath()
            }
        }
        return image.pngData()
    }
}
