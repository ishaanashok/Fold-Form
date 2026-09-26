import XCTest
@testable import FoldForm

@MainActor
final class DesignModelsTests: XCTestCase {
    private func capture() -> DesignCapture {
        let box = GeometryBuilder.box(width: 0.1, height: 0.02, depth: 0.05)
        return DesignCapture(
            bodies: [DesignBody(mesh: box, style: Palette.style("oak")), DesignBody(mesh: box.translated(by: [0, 0.05, 0]), style: nil)],
            corner: .sharp,
            camera: CameraRig(target: [0.1, 0.2, 0.3], yaw: 0.5, pitch: 0.4, distance: 0.7, roll: 0.1)
        )
    }

    func testContentRoundTripsThroughJSON() throws {
        let (content, _) = DesignContent.make(capture())
        let decoded = try JSONDecoder().decode(DesignContent.self, from: JSONEncoder().encode(content))
        XCTAssertEqual(decoded, content)
        XCTAssertEqual(decoded.bodies.map(\.style), ["oak", nil])
        XCTAssertEqual(decoded.corner, "sharp")
        XCTAssertEqual(decoded.camera?.rig, capture().camera)
    }

    func testIdenticalMeshesShareOneBlob() {
        let box = GeometryBuilder.box(width: 1, height: 1, depth: 1)
        let (content, blobs) = DesignContent.make(DesignCapture(
            bodies: [DesignBody(mesh: box, style: nil), DesignBody(mesh: box, style: nil)], corner: .fillet, camera: nil))
        XCTAssertEqual(content.bodies.count, 2)
        XCTAssertEqual(blobs.count, 1)
        XCTAssertEqual(content.meshHashes, Set(blobs.keys))
    }

    func testUnknownCornerAndStyleFallBackGracefully() {
        var content = DesignContent.make(capture()).content
        content.corner = "bevelled"
        content.bodies[0].style = "no-such-colour"
        let loaded = content.loaded(meshes: [.empty, .empty])
        XCTAssertEqual(loaded.corner, .fillet)
        XCTAssertNil(loaded.styles[0])
    }

    func testEveryTemplateHasBodies() {
        for kind in PartProfileKind.allCases {
            let template = DesignContent.template(kind)
            XCTAssertFalse(template.bodies.isEmpty, kind.rawValue)
            XCTAssertFalse(template.bodies[0].mesh.positions.isEmpty, kind.rawValue)
        }
    }
}
