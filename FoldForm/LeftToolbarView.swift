import SwiftUI

/// Content-sized editor controls. The parent closes the dropdown when the viewport is pressed.
struct LeftToolbarView: View {
    var layout: LeftToolbarLayout
    @Binding var isExpanded: Bool
    var buttons: [LeftToolbarTool: AnyView]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 10) {
            ForEach(layout.visible, id: \.self) { tool in
                if tool == .disclosure {
                    disclosureButton
                } else if let button = buttons[tool] {
                    button.simultaneousGesture(TapGesture().onEnded { close() })
                }
            }
            if isExpanded && !layout.showsOnlyLock {
                VStack(spacing: 8) {
                    ForEach(layout.dropdown, id: \.self) { tool in
                        if let button = buttons[tool] {
                            if tool == .share {
                                // Keep the Menu mounted until a format is chosen. EditorView then
                                // closes the dropdown and presents the share sheet from its root.
                                button
                            } else {
                                button.simultaneousGesture(TapGesture().onEnded { close() })
                            }
                        }
                    }
                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(reduceMotion ? nil : .smooth, value: isExpanded)
        .animation(reduceMotion ? nil : .smooth, value: layout.showsOnlyLock)
        .onChange(of: layout.showsOnlyLock) { _, locked in
            if locked { isExpanded = false }
        }
    }

    private var disclosureButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : .smooth) { isExpanded.toggle() }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityIdentifier("moreToolsButton")
        .accessibilityLabel("More tools")
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
    }

    private func close() {
        if isExpanded { withAnimation(reduceMotion ? nil : .smooth) { isExpanded = false } }
    }
}
