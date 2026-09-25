import SwiftUI
import UIKit

/// Transparent gesture surface laid over the 3D viewport.
///
/// - one finger, or primary mouse button drag → rotate
/// - two fingers, Shift-drag, right-mouse-button drag, or trackpad two-finger scroll → pan (move
///   the object without rotating it)
/// - Move mode (`oneFingerPans`): a one-finger drag pans instead of rotating
/// - pinch, or mouse wheel → zoom
///
/// RealityKit's built-in `.orbit` camera control only orbits/zooms — it has no pan — so these are
/// implemented directly and drive `CameraRig`.
struct ViewportGestureView: UIViewRepresentable {
    var oneFingerPans = false
    /// Sketching: a one-finger drag draws instead of rotating; two fingers still pan and pinch.
    var drawMode = false
    var onRotate: (CGSize) -> Void
    var onPan: (CGSize) -> Void
    var onZoom: (CGFloat) -> Void
    var onTap: (CGPoint) -> Void = { _ in }
    var onDoubleTap: (CGPoint) -> Void = { _ in }
    var onLongPress: (CGPoint) -> Void = { _ in }
    var onDrawBegan: (CGPoint) -> Void = { _ in }
    var onDrawChanged: (CGPoint) -> Void = { _ in }
    var onDrawEnded: () -> Void = {}
    var onDrawCancelled: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// The touch surface. Secondary-button (right-click) drags aren't recognized by
    /// `UIPanGestureRecognizer`, so those are read from the raw touches and reported as a pan.
    final class SurfaceView: UIView {
        var onPan: ((CGSize) -> Void)?

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesMoved(touches, with: event)
            guard let event, event.buttonMask.contains(.secondary),
                  let touch = touches.first(where: { $0.type == .indirectPointer }) else { return }
            let now = touch.location(in: self)
            let before = touch.previousLocation(in: self)
            onPan?(CGSize(width: now.x - before.x, height: now.y - before.y))
        }
    }

    func makeUIView(context: Context) -> UIView {
        let view = SurfaceView()
        let coordinator = context.coordinator
        view.onPan = { delta in coordinator.parent?.onPan(delta) }
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "viewport"
        view.accessibilityLabel = "3D viewport"
        view.accessibilityHint = "Drag to rotate, two-finger drag to pan, pinch to zoom"
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        let c = context.coordinator

        let direct = NSNumber(value: UITouch.TouchType.direct.rawValue)
        let pointer = NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)

        // One recognizer for both rotate and pan. Separate one-finger and two-finger recognizers
        // compete: if the first finger has already started a rotate when the second lands, the
        // two-finger pan never gets to begin. Here the finger count is read live instead, so a
        // second finger simply switches the same drag from rotating to panning.
        let drag = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.handleDrag(_:)))
        drag.minimumNumberOfTouches = 1
        drag.maximumNumberOfTouches = 2
        drag.allowedTouchTypes = [direct, pointer]

        // Trackpad two-finger scroll: pan. (Scroll-only: no touch types.)
        let trackpadPan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.handleTrackpadScroll(_:)))
        trackpadPan.allowedTouchTypes = []
        trackpadPan.allowedScrollTypesMask = .continuous

        // Mouse wheel: zoom.
        let wheelZoom = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.handleWheel(_:)))
        wheelZoom.allowedTouchTypes = []
        wheelZoom.allowedScrollTypesMask = .discrete

        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.handlePinch(_:)))

        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleTap(_:)))
        tap.allowedTouchTypes = [direct, pointer]
        let doubleTap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.allowedTouchTypes = [direct, pointer]
        // A single tap waits a moment to be sure it isn't the first half of a double tap.
        tap.require(toFail: doubleTap)
        let hold = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.handleLongPress(_:)))
        hold.minimumPressDuration = 0.55
        hold.allowableMovement = 10
        hold.allowedTouchTypes = [direct, pointer]

        for recognizer in [drag, trackpadPan, wheelZoom, pinch, tap, doubleTap, hold] as [UIGestureRecognizer] {
            recognizer.delegate = c
            view.addGestureRecognizer(recognizer)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: ViewportGestureView?

        private var lastTouchCount = 0
        private var isDrawing = false

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard g.state == .ended else { return }
            parent?.onTap(g.location(in: g.view))
        }

        @objc func handleDoubleTap(_ g: UITapGestureRecognizer) {
            guard g.state == .ended else { return }
            parent?.onDoubleTap(g.location(in: g.view))
        }

        @objc func handleLongPress(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began else { return }
            parent?.onLongPress(g.location(in: g.view))
        }

        @objc func handleDrag(_ g: UIPanGestureRecognizer) {
            let drawing = parent?.drawMode == true
            switch g.state {
            case .began:
                lastTouchCount = g.numberOfTouches
                if drawing, g.numberOfTouches == 1, !g.modifierFlags.contains(.shift), !g.buttonMask.contains(.secondary) {
                    isDrawing = true
                    // The pan only starts after it has moved a little; start from where the finger landed.
                    let start = g.location(in: g.view)
                    let t = g.translation(in: g.view)
                    parent?.onDrawBegan(CGPoint(x: start.x - t.x, y: start.y - t.y))
                    parent?.onDrawChanged(start)
                }
            case .changed:
                if isDrawing {
                    // A second finger turns the drag into a pan/pinch: drop the half-drawn shape.
                    if g.numberOfTouches != 1 {
                        isDrawing = false
                        parent?.onDrawCancelled()
                        lastTouchCount = g.numberOfTouches
                        g.setTranslation(.zero, in: g.view)
                    } else {
                        parent?.onDrawChanged(g.location(in: g.view))
                    }
                    return
                }
                // A finger landing or lifting mid-drag moves the centroid; restart the baseline
                // so the object doesn't jump.
                if g.numberOfTouches != lastTouchCount {
                    lastTouchCount = g.numberOfTouches
                    g.setTranslation(.zero, in: g.view)
                    return
                }
                // Right-button drags are handled from raw touches in SurfaceView.
                guard !g.buttonMask.contains(.secondary), let d = takeTranslation(g) else { return }
                let pans = g.numberOfTouches >= 2 || g.modifierFlags.contains(.shift) || parent?.oneFingerPans == true
                if pans { parent?.onPan(d) } else if !drawing { parent?.onRotate(d) }
            case .ended:
                if isDrawing { parent?.onDrawEnded() }
                isDrawing = false
            case .cancelled, .failed:
                if isDrawing { parent?.onDrawCancelled() }
                isDrawing = false
            default:
                break
            }
        }

        @objc func handleTrackpadScroll(_ g: UIPanGestureRecognizer) {
            guard let d = takeTranslation(g) else { return }
            parent?.onPan(d)
        }

        @objc func handleWheel(_ g: UIPanGestureRecognizer) {
            guard let d = takeTranslation(g) else { return }
            // Scrolling up (negative y) zooms in, gently: about 0.25% per point of wheel travel.
            parent?.onZoom(CGFloat(exp(-d.height * Self.wheelZoomPerPoint)))
        }

        /// Two fingers dragging always wobble their spacing a little, which used to read as zoom and
        /// made panning feel like it drifted. A pinch only starts zooming once the spacing has really
        /// changed, and then follows from that point.
        private var pinchEngaged = false
        private static let pinchDeadZone: CGFloat = 0.06
        /// 1 would zoom exactly as far as the fingers spread; lower is less sensitive.
        private static let pinchZoomGain: CGFloat = 0.3
        private static let wheelZoomPerPoint: CGFloat = 0.0025

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            switch g.state {
            case .began:
                pinchEngaged = false
            case .changed:
                if !pinchEngaged {
                    guard abs(g.scale - 1) > Self.pinchDeadZone else { return }
                    pinchEngaged = true
                    g.scale = 1
                    return
                }
                // Only part of the finger spacing change becomes zoom, so it is easy to nudge.
                parent?.onZoom(pow(g.scale, Self.pinchZoomGain))
                g.scale = 1
            default:
                break
            }
        }

        /// Incremental translation since the previous callback, or nil when the gesture isn't mid-drag.
        private func takeTranslation(_ g: UIPanGestureRecognizer) -> CGSize? {
            guard g.state == .changed else { return nil }
            let t = g.translation(in: g.view)
            g.setTranslation(.zero, in: g.view)
            return CGSize(width: t.x, height: t.y)
        }

        // Pinch and two-finger pan should run together (zoom while dragging).
        func gestureRecognizer(_ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool {
            (a is UIPinchGestureRecognizer) != (b is UIPinchGestureRecognizer)
        }
    }
}
