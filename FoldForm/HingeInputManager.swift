import Foundation
import SwiftUI
import Combine

/// Bridges the real iPhone Duo hinge API (`View.onHingeChange`, `DeviceHingeContext`, `DeviceHinge`
/// — confirmed against the installed Xcode 27.1 SDK's SwiftUICore.swiftinterface, not guessed) into
/// a plain published *bend angle* the rest of the app consumes, with a simulator-slider fallback
/// when no hinge context is available.
///
/// Keep every beta-API touch point inside this file (plan section 13, "Beta API mismatch") so a
/// future SDK signature change only requires editing `handle(context:)`.
@MainActor
final class HingeInputManager: ObservableObject {
    /// How far the part is folded away from flat, radians. 0 = flat (device fully open); the value
    /// grows 1:1 as the hinge closes, so a hinge 5° short of fully open is a 5° bend.
    @Published private(set) var bendAngleRadians: Double = 0
    /// The device's own hinge angle (π when fully open), if a hinge is reporting.
    @Published private(set) var rawHingeRadians: Double?
    @Published private(set) var hingeStatus: String = "unknown"
    @Published private(set) var hingeAvailable: Bool = false
    @Published var isUsingSimulatorFallback: Bool = true
    @Published var simulatorBendRadians: Double = 0 {
        didSet {
            if isUsingSimulatorFallback { bendAngleRadians = Self.snappedBend(Self.clampedBend(simulatorBendRadians)) }
        }
    }

    var bendAngleDegrees: Double { bendAngleRadians * 180 / .pi }

    /// True when a debug launch argument is pinning the bend and the real hinge is being ignored.
    var isDebugOverridden: Bool {
        #if DEBUG
        return debugForcedBend != nil
        #else
        return false
        #endif
    }

    #if DEBUG
    /// Launch-argument override (`-FoldFormDebugBendDegrees 5`) so a specific bend can be checked
    /// without physically driving the hinge.
    private let debugForcedBend: Double? = HingeInputManager.debugDouble("FoldFormDebugBendDegrees")

    /// Command-line defaults (`-key 5`) arrive as strings, so `as? Double` would always fail.
    nonisolated static func debugDouble(_ key: String) -> Double? {
        guard UserDefaults.standard.object(forKey: key) != nil else { return nil }
        return UserDefaults.standard.double(forKey: key)
    }

    /// While the override is active, the bend can also be changed live by writing degrees to this
    /// file. Lets an automated run fold, open, and re-fold the "device" the way a real hinge would,
    /// which nothing else can do to a simulator from the command line.
    nonisolated static let debugBendFile = "/tmp/foldform_debug_bend.txt"

    private func startDebugFilePolling() {
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      let text = try? String(contentsOfFile: Self.debugBendFile, encoding: .utf8),
                      let degrees = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
                let bend = Self.clampedBend(degrees * .pi / 180)
                if abs(bend - self.bendAngleRadians) > 1e-9 { self.simulatorBendRadians = bend }
            }
        }
    }
    #endif

    init() {
        #if DEBUG
        if let forced = debugForcedBend {
            bendAngleRadians = Self.snappedBend(Self.clampedBend(forced * .pi / 180))
            simulatorBendRadians = bendAngleRadians
            startDebugFilePolling()
        }
        #endif
    }

    /// The hinge reports π (180°) when fully open/flat and decreases as it closes. The bend is the
    /// distance from flat. (Treating the raw angle as the bend, as an earlier version did, made a
    /// flat device read as a 90° fold.)
    nonisolated static func bend(fromHingeRadians raw: Double) -> Double {
        guard raw.isFinite else { return 0 }
        return snappedBend(clampedBend(.pi - raw))
    }

    /// Bend angles the fold locks onto, degrees: flat, the common corners, and fully closed.
    nonisolated static let snapAnglesDegrees: [Double] = [0, 45, 90, 135, 180]
    /// Within this many degrees of a snap angle the bend reads as exactly that angle, so 89.4° and
    /// 90.7° both give a clean 90° fold instead of one that is hard to hit by hand.
    nonisolated static let snapWindowDegrees = 1.0

    nonisolated static func snappedBend(_ radians: Double) -> Double {
        let degrees = radians * 180 / .pi
        guard let target = snapAnglesDegrees.first(where: { abs(degrees - $0) < snapWindowDegrees }) else { return radians }
        return target * .pi / 180
    }

    nonisolated static func clampedBend(_ radians: Double) -> Double {
        guard radians.isFinite else { return 0 }
        return min(max(radians, 0), .pi)
    }

    func handle(context: DeviceHingeContext) {
        #if DEBUG
        if debugForcedBend != nil { return }
        #endif
        guard let hinge = context.hinge else {
            // No hinge reading: hand control to the slider, seeded with the current bend so the
            // model doesn't snap flat just because a reading went missing.
            hingeAvailable = false
            isUsingSimulatorFallback = true
            rawHingeRadians = nil
            simulatorBendRadians = bendAngleRadians
            hingeStatus = "unavailable"
            return
        }
        hingeAvailable = true
        isUsingSimulatorFallback = false
        // No smoothing: the OS only calls back on change, so a low-pass filter never converges and
        // leaves the model bent by a fraction of the real angle.
        let raw = Double(hinge.angle.radians)
        rawHingeRadians = raw
        bendAngleRadians = Self.bend(fromHingeRadians: raw)

        switch hinge.status {
        case .closed: hingeStatus = "closed"
        case .partiallyOpen: hingeStatus = "partiallyOpen"
        case .fullyOpen: hingeStatus = "fullyOpen"
        default: hingeStatus = "unknown"
        }
    }

    func reset() {
        simulatorBendRadians = 0
        bendAngleRadians = 0
    }
}

/// Attaches the real hinge-change handler to the view hierarchy. Isolated into its own modifier so
/// call sites (FoldFormApp.swift) don't need to know the SDK's exact closure signature.
struct HingeInputBinding: ViewModifier {
    @ObservedObject var manager: HingeInputManager

    func body(content: Content) -> some View {
        content.onHingeChange { _, newContext in
            manager.handle(context: newContext)
        }
    }
}

extension View {
    func bindHingeInput(_ manager: HingeInputManager) -> some View {
        modifier(HingeInputBinding(manager: manager))
    }
}
