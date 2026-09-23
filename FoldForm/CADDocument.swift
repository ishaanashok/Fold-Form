import Foundation

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

    /// Builds the default demo document: a sheet-metal plate with one through-hole, matching the
    /// plan's "make sheetPlate the default demo profile" guidance so Sheet Metal and the hinge bend
    /// are demoable immediately without the user hand-authoring a sketch first.
    static func demoSheetPlateDocument() -> CADDocument {
        let doc = CADDocument()
        let studio = doc.partStudio
        guard let topPlane = studio.featureTree.referencePlanes.first(where: { $0.plane == .front }) else { return doc }

        var sketch = Sketch(name: "Plate Sketch", planeID: topPlane.id)
        let plateWidth = 0.16   // meters across the fold (X)
        let plateHeight = 0.003 // meters thick (Y)
        sketch.entities.append(.rectangle(id: UUID(), origin: .zero, width: plateWidth, height: plateHeight, construction: false))
        studio.featureTree.addSketch(sketch)
        studio.featureTree.append(SketchTreeFeature(name: "Sketch1", sketchID: sketch.id))

        let extrude = ExtrudeFeature(
            name: "Extrude1",
            sketchID: sketch.id,
            parameters: ExtrudeParameters(termination: .blind(distance: 0.05), resultType: .new)
        )
        studio.featureTree.append(extrude)
        studio.regenerate()

        if let bodyID = extrude.resultBodyID {
            let hole = HoleFeature(
                name: "Hole1",
                targetBodyID: bodyID,
                definition: HoleDefinition(center: .init(0, 0), diameter: 0.02, type: .simple, throughAll: true)
            )
            studio.featureTree.append(hole)
        }
        studio.regenerate()
        return doc
    }
}
