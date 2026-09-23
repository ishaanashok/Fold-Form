import Foundation
import SwiftUI
import Combine

/// Bridges the real iPhone Duo hinge API (`View.onHingeChange`, `DeviceHingeContext`, `DeviceHinge`
/// — confirmed against the installed Xcode 27.1 SDK's SwiftUICore.swiftinterface, not guessed) into
/// a plain published angle the rest of the app consumes, with a simulator-slider fallback when no
/// hinge context is available.
///
/// Keep every beta-API touch point inside this file (plan section 13, "Beta API mismatch") so a
/// future SDK signature change only requires editing `bind(to:)` and `handle(context:)`.
@MainActor
final class HingeInputManager: ObservableObject {
    @Published private(set) var hingeAngleRadians: Double = 0
    @Published private(set) var hingeStatus: String = "unknown"
    @Published private(set) var hingeAvailable: Bool = false
    @Published var isUsingSimulatorFallback: Bool = true
    @Published var simulatorAngleRadians: Double = 0 {
        didSet {
            if isUsingSimulatorFallback { hingeAngleRadians = simulatorAngleRadians }
        }
    }

    var hingeAngleDegrees: Double { hingeAngleRadians * 180 / .pi }

    /// Short low-pass filter so small sensor/simulator noise doesn't jitter the deformer, without
    /// adding perceptible latency (plan requirement).
    private let smoothing = 0.35
    private var filteredAngle: Double = 0

    func handle(context: DeviceHingeContext) {
        guard let hinge = context.hinge else {
            hingeAvailable = false
            isUsingSimulatorFallback = true
            hingeAngleRadians = simulatorAngleRadians
            hingeStatus = "unavailable"
            filteredAngle = 0
            return
        }
        hingeAvailable = true
        isUsingSimulatorFallback = false
        let rawAngle = max(0, min(.pi / 2, Double(hinge.angle.radians)))
        filteredAngle = filteredAngle + smoothing * (rawAngle - filteredAngle)
        hingeAngleRadians = filteredAngle

        switch hinge.status {
        case .closed: hingeStatus = "closed"
        case .partiallyOpen: hingeStatus = "partiallyOpen"
        case .fullyOpen: hingeStatus = "fullyOpen"
        default: hingeStatus = "unknown"
        }
    }

    func reset() {
        simulatorAngleRadians = 0
        filteredAngle = 0
        hingeAngleRadians = 0
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
