import SwiftUI

struct ParameterEditorView: View {
    @EnvironmentObject var appModel: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sheet Metal Parameters").font(.headline)
            numberRow("Thickness (mm)", $appModel.thickness)
            numberRow("Bend radius (mm)", $appModel.bendRadius)
            numberRow("K-factor", $appModel.kFactor)
            numberRow("Leg 1 (mm)", $appModel.legOneLength)
            numberRow("Leg 2 (mm)", $appModel.legTwoLength)

            HStack(spacing: 12) {
                resultCard("BA", appModel.sheetMetalResult.bendAllowance)
                resultCard("BD", appModel.sheetMetalResult.bendDeduction)
                resultCard("Flat length", appModel.sheetMetalResult.flatLength)
            }

            Text("BA = θ × (R + K·t)   BD = 2×(R+t)×tan(θ/2) − BA")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Demo model; confirm tooling and material data before fabrication.")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }

    private func numberRow(_ label: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(label).font(.caption)
            Spacer()
            TextField("", value: value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func resultCard(_ label: String, _ value: Double) -> some View {
        VStack {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(String(format: "%.2f", value)).font(.caption.monospacedDigit().bold())
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
