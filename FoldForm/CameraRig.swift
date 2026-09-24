import Foundation
import simd

/// Where the physical crease appears on screen, as a fraction across the viewport.
struct ScreenCrease: Equatable {
    enum Axis: Equatable { case vertical, horizontal }
    var axis: Axis
    /// 0...1 across the viewport (left→right for vertical, top→bottom for horizontal).
    var fraction: Float

    static let centeredVertical = ScreenCrease(axis: .vertical, fraction: 0.5)
}

/// Orbit/pan/zoom camera around a movable target, independent of RealityKit so it can be unit
/// tested. The model itself never moves: "dragging the model" means moving the camera's target, so
/// the point of the block that sits under the (fixed-on-screen) crease changes as you pan.
struct CameraRig: Equatable {
    var target: SIMD3<Float>
    /// Rotation about world Y, radians. 0 puts the camera on +Z looking toward -Z.
    var yaw: Float
    /// Elevation above the XZ plane, radians. Unlimited: past ±90° the camera goes over the top and
    /// keeps turning, upside down.
    var pitch: Float
    var distance: Float
    var fovYRadians: Float = 60 * .pi / 180

    static let distanceRange: ClosedRange<Float> = 0.03...3
    /// Radians of orbit per point dragged.
    static let rotateSensitivity: Float = 0.008

    /// Unit vector from the target toward the camera.
    var offsetDirection: SIMD3<Float> {
        SIMD3<Float>(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
    }
    var position: SIMD3<Float> { target + offsetDirection * distance }
    var forward: SIMD3<Float> { -offsetDirection }
    /// Independent of pitch, so it stays smooth when the camera passes over the poles.
    var right: SIMD3<Float> { SIMD3<Float>(cos(yaw), 0, -sin(yaw)) }
    var up: SIMD3<Float> { simd_cross(right, forward) }

    /// One-finger / primary-drag: dragging right turns the model to the right, dragging down tips
    /// its top toward the viewer.
    mutating func rotate(dx: Float, dy: Float) {
        // Upside down, the screen's left/right maps to the opposite yaw direction.
        let flip: Float = cos(pitch) < 0 ? -1 : 1
        yaw -= flip * dx * Self.rotateSensitivity
        pitch += dy * Self.rotateSensitivity
        yaw = wrap(yaw)
        pitch = wrap(pitch)
    }

    /// Two-finger drag: the model follows the fingers 1:1 on screen (the camera target moves the
    /// opposite way).
    mutating func pan(dx: Float, dy: Float, viewportHeight: Float) {
        guard viewportHeight > 0 else { return }
        let worldPerPoint = 2 * distance * tan(fovYRadians / 2) / viewportHeight
        target -= right * (dx * worldPerPoint)
        target += up * (dy * worldPerPoint)
    }

    private func wrap(_ angle: Float) -> Float {
        let turn = 2 * Float.pi
        return angle - turn * (angle / turn).rounded()
    }

    mutating func zoom(scale: Float) {
        guard scale.isFinite, scale > 0 else { return }
        distance = min(max(distance / scale, Self.distanceRange.lowerBound), Self.distanceRange.upperBound)
    }

    /// The world-space ray through a point of the viewport (points, origin top-left).
    func ray(at point: CGPoint, in size: CGSize) -> (origin: SIMD3<Float>, direction: SIMD3<Float>) {
        let aspect = Float(size.width / max(size.height, 1))
        let tanHalf = tan(fovYRadians / 2)
        let ndcX = Float(point.x / max(size.width, 1)) * 2 - 1
        let ndcY = 1 - Float(point.y / max(size.height, 1)) * 2
        let direction = simd_normalize(forward + right * (ndcX * tanHalf * aspect) + up * (ndcY * tanHalf))
        return (position, direction)
    }

    /// Where a world point lands in the viewport, or nil if it is behind the camera.
    func project(_ world: SIMD3<Float>, in size: CGSize) -> CGPoint? {
        let d = world - position
        let z = simd_dot(d, forward)
        guard z > 1e-6 else { return nil }
        let aspect = Float(size.width / max(size.height, 1))
        let tanHalf = tan(fovYRadians / 2)
        let x = simd_dot(d, right) / (z * tanHalf * aspect)
        let y = simd_dot(d, up) / (z * tanHalf)
        return CGPoint(x: CGFloat((x + 1) / 2) * size.width, y: CGFloat((1 - y) / 2) * size.height)
    }

    /// The face of the block the camera is closest to looking straight at.
    var nearestFace: ViewFace {
        ViewFace.allCases.max { simd_dot($0.normal, offsetDirection) < simd_dot($1.normal, offsetDirection) } ?? .front
    }

    /// The fold, expressed in camera space so it always matches what the phone's crease looks like
    /// on screen.
    ///
    /// The crease is a fixed line on screen, which is a plane through the camera. That plane is where
    /// the block is cut, whatever way it is oriented, and the halves swing about the crease's
    /// on-screen direction (vertical for a vertical crease) — toward the viewer, like closing a book.
    /// The hinge sits at the target's depth (the point being looked at), so panning the block
    /// changes which part of it is under the crease.
    func foldFrame(crease: ScreenCrease, aspect: Float) -> FoldFrame {
        let f = forward, r = right, u = up
        let tanHalf = tan(fovYRadians / 2)
        let ndc = crease.fraction * 2 - 1
        let ray: SIMD3<Float>
        let axis: SIMD3<Float>
        let normal: SIMD3<Float>
        switch crease.axis {
        case .vertical:
            // Plane spanned by the up vector and the ray through the crease's x position. Its normal
            // points to the right of the crease; the right half swings toward the camera.
            ray = f + r * (ndc * tanHalf * max(aspect, 0.01))
            axis = u
            normal = simd_normalize(simd_cross(ray, u))
        case .horizontal:
            // Screen y grows downward, NDC y grows upward. The normal points below the crease.
            ray = f + u * (-ndc * tanHalf)
            axis = r
            normal = simd_normalize(simd_cross(ray, r))
        }
        // `ray` has unit length along `forward`, so this lands at the target's depth.
        let pivot = position + ray * distance
        return FoldFrame(pivot: pivot, axis: axis, normal: normal)
    }
}

/// The six faces of the view cube. The block's front is +Z, its top +Y and its right +X.
enum ViewFace: CaseIterable {
    case front, back, right, left, top, bottom

    var title: String {
        switch self {
        case .front: "FRONT"
        case .back: "BACK"
        case .right: "RIGHT"
        case .left: "LEFT"
        case .top: "TOP"
        case .bottom: "BOTTOM"
        }
    }

    /// Outward direction of the face, which is where the camera sits when looking straight at it.
    var normal: SIMD3<Float> {
        switch self {
        case .front: SIMD3(0, 0, 1)
        case .back: SIMD3(0, 0, -1)
        case .right: SIMD3(1, 0, 0)
        case .left: SIMD3(-1, 0, 0)
        case .top: SIMD3(0, 1, 0)
        case .bottom: SIMD3(0, -1, 0)
        }
    }

    /// Two in-face directions used to draw the face's corners.
    var tangents: (u: SIMD3<Float>, v: SIMD3<Float>) {
        switch self {
        case .front: (SIMD3(1, 0, 0), SIMD3(0, 1, 0))
        case .back: (SIMD3(-1, 0, 0), SIMD3(0, 1, 0))
        case .right: (SIMD3(0, 0, -1), SIMD3(0, 1, 0))
        case .left: (SIMD3(0, 0, 1), SIMD3(0, 1, 0))
        case .top: (SIMD3(1, 0, 0), SIMD3(0, 0, -1))
        case .bottom: (SIMD3(1, 0, 0), SIMD3(0, 0, 1))
        }
    }
}

extension CameraRig {
    /// The exact yaw/pitch that looks straight at `face`, reached by the shortest turn from where
    /// the camera is now (so snapping never spins the long way round).
    func snapAngles(to face: ViewFace) -> (yaw: Float, pitch: Float) {
        let turn = 2 * Float.pi
        func nearest(_ target: Float, to current: Float) -> Float {
            target + turn * ((current - target) / turn).rounded()
        }
        switch face {
        case .front: return (nearest(0, to: yaw), nearest(0, to: pitch))
        case .right: return (nearest(.pi / 2, to: yaw), nearest(0, to: pitch))
        case .back: return (nearest(.pi, to: yaw), nearest(0, to: pitch))
        case .left: return (nearest(-.pi / 2, to: yaw), nearest(0, to: pitch))
        case .top, .bottom:
            // Keep whichever side of the block is already toward the bottom of the screen.
            let quarter = Float.pi / 2
            let alignedYaw = (yaw / quarter).rounded() * quarter
            return (alignedYaw, nearest(face == .top ? quarter : -quarter, to: pitch))
        }
    }
}
