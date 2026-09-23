import Foundation
import Combine

enum LengthUnit: String, CaseIterable, Identifiable, Codable {
    case millimeters = "mm"
    case inches = "in"
    var id: String { rawValue }
}

/// Owns document-level metadata, the active Part Studio, and undo/redo. A thin document/workspace
/// layer above `PartStudio` so the app can later support multiple Part Studios without reworking
/// the modeling foundation.
final class CADDocument: ObservableObject {
    @Published var units: LengthUnit = .millimeters
    @Published var partStudio: PartStudio
    let undoRedo = UndoRedoManager()

    init() {
        self.partStudio = PartStudio()
    }

    func loadQuickStartProfile(_ profile: PartProfileKind) {
        partStudio = Self.makePartStudio(for: profile)
    }

    /// Builds the default demo document: a sheet-metal plate with one through-hole, matching the
    /// plan's "make sheetPlate the default demo profile" guidance so Sheet Metal and the hinge bend
    /// are demoable immediately without the user hand-authoring a sketch first.
    static func demoSheetPlateDocument() -> CADDocument {
        let doc = CADDocument()
        doc.partStudio = makePartStudio(for: .sheetPlate)
        return doc
    }

    private static func makePartStudio(for profile: PartProfileKind) -> PartStudio {
        let studio = PartStudio()
        guard let topPlane = studio.featureTree.referencePlanes.first(where: { $0.plane == .front }) else { return studio }

        var sketch = Sketch(name: "Plate Sketch", planeID: topPlane.id)
        let (width, height): (Double, Double) = {
            switch profile {
            case .beam: return (0.04, 0.04)
            case .iBeam: return (0.05, 0.025)
            // A real sheet plate is thin relative to its width, but 3mm on a 16cm span rendered as
            // a barely-visible hairline. Keep it clearly thinner than it is wide/long (still reads
            // as sheet metal) while being an unmistakable rectangular prism at launch.
            case .sheetPlate: return (0.12, 0.016)
            case .box: return (0.07, 0.05)
            case .cylinder: return (0.04, 0.04)
            }
        }()
        if profile == .cylinder {
            sketch.entities.append(.circle(id: UUID(), center: .zero, radius: width / 2, construction: false))
        } else {
            sketch.entities.append(.rectangle(id: UUID(), origin: .zero, width: width, height: height, construction: false))
        }
        studio.featureTree.addSketch(sketch)
        studio.featureTree.append(SketchTreeFeature(name: "Sketch1", sketchID: sketch.id))

        let extrude = ExtrudeFeature(
            name: "Extrude1",
            sketchID: sketch.id,
            parameters: ExtrudeParameters(termination: .blind(distance: profile == .sheetPlate ? 0.05 : 0.12), resultType: .new)
        )
        studio.featureTree.append(extrude)
        studio.regenerate()

        if profile == .sheetPlate, let bodyID = extrude.resultBodyID {
            let hole = HoleFeature(
                name: "Hole1",
                targetBodyID: bodyID,
                // Keep the demonstration hole comfortably inside the plate's thickness/profile.
                definition: HoleDefinition(center: .init(0, 0), diameter: 0.008, type: .simple, throughAll: true)
            )
            studio.featureTree.append(hole)
        }
        studio.regenerate()
        return studio
    }
}
