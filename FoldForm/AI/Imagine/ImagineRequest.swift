import Foundation
import simd

/// Everything the person deliberately submits to Imagine. `revision` identifies the document at
/// capture time; a reply for another revision must never be applied.
struct ImagineRequest: Sendable {
    var prompt: String
    var sketchPNG: Data
    var polylines: [[SIMD2<Float>]]
    var designPNG: Data
    var designDescription: String
    var selectedBody: String?
    var units: String
    var revision: Int
    var allowDelete: Bool
}

protocol ImagineGenerating: Sendable {
    func generate(_ request: ImagineRequest) async throws -> ImaginePlan
}
