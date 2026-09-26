import XCTest
@testable import FoldForm

final class MeshBlobTests: XCTestCase {
    func testRoundTripPreservesEveryValue() throws {
        let mesh = GeometryBuilder.box(width: 0.1, height: 0.02, depth: 0.05)
        let decoded = try MeshBlob.decode(MeshBlob.encode(mesh))
        XCTAssertEqual(decoded, mesh)
    }

    func testEmptyMeshRoundTrips() throws {
        XCTAssertEqual(try MeshBlob.decode(MeshBlob.encode(.empty)), .empty)
    }

    func testEqualMeshesHashTheSameAndDifferentOnesDoNot() {
        let a = MeshBlob.encode(GeometryBuilder.box(width: 1, height: 1, depth: 1))
        let b = MeshBlob.encode(GeometryBuilder.box(width: 1, height: 1, depth: 1))
        let c = MeshBlob.encode(GeometryBuilder.box(width: 1, height: 1, depth: 2))
        XCTAssertEqual(MeshBlob.hash(of: a), MeshBlob.hash(of: b))
        XCTAssertNotEqual(MeshBlob.hash(of: a), MeshBlob.hash(of: c))
        XCTAssertEqual(MeshBlob.hash(of: a).count, 64)
    }

    func testTruncatedAndForeignDataThrow() {
        let data = MeshBlob.encode(GeometryBuilder.box(width: 1, height: 1, depth: 1))
        XCTAssertThrowsError(try MeshBlob.decode(data.prefix(data.count - 3)))
        XCTAssertThrowsError(try MeshBlob.decode(Data("nonsense-not-a-mesh".utf8)))
        XCTAssertThrowsError(try MeshBlob.decode(Data()))
    }
}
