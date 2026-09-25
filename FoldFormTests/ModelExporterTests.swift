import XCTest
import simd
@testable import FoldForm

final class ModelExporterTests: XCTestCase {
    private let box = GeometryBuilder.box(width: 0.12, height: 0.016, depth: 0.05)
    private var boxTriangles: Int { 12 }

    private func u32(_ d: Data, _ o: Int) -> UInt32 { d.subdata(in: o..<o + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian }
    private func u16(_ d: Data, _ o: Int) -> UInt16 { d.subdata(in: o..<o + 2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian }
    private func f32(_ d: Data, _ o: Int) -> Float { Float(bitPattern: u32(d, o)) }

    func testEveryFormatHasAnExtensionAndProducesData() {
        XCTAssertEqual(ExportFormat.allCases.map(\.fileExtension), ["stl", "3mf", "glb", "obj"])
        for format in ExportFormat.allCases {
            XCTAssertFalse(ModelExporter.data(for: box, as: format).isEmpty, format.rawValue)
        }
    }

    func testSTLLayoutAndMillimetreZUpScale() {
        let d = ModelExporter.data(for: box, as: .stl)
        let count = Int(u32(d, 80))
        XCTAssertEqual(count, boxTriangles)
        XCTAssertEqual(d.count, 84 + 50 * count)
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for t in 0..<count {
            let base = 84 + 50 * t
            for v in 1...3 {
                let p = SIMD3(f32(d, base + v * 12), f32(d, base + v * 12 + 4), f32(d, base + v * 12 + 8))
                lo = simd_min(lo, p); hi = simd_max(hi, p)
            }
            let n = SIMD3(f32(d, base), f32(d, base + 4), f32(d, base + 8))
            XCTAssertEqual(simd_length(n), 1, accuracy: 1e-4, "unit normals")
        }
        // 0.12 wide (X), 0.016 tall (becomes Z), 0.05 deep (becomes Y), in millimetres.
        XCTAssertEqual(hi.x - lo.x, 120, accuracy: 1e-2)
        XCTAssertEqual(hi.y - lo.y, 50, accuracy: 1e-2)
        XCTAssertEqual(hi.z - lo.z, 16, accuracy: 1e-2)
    }

    func testSTLNormalsPointOutward() {
        let d = ModelExporter.data(for: box, as: .stl)
        let centre = SIMD3<Float>(0, 0, 0)
        for t in 0..<boxTriangles {
            let base = 84 + 50 * t
            let n = SIMD3(f32(d, base), f32(d, base + 4), f32(d, base + 8))
            let a = SIMD3(f32(d, base + 12), f32(d, base + 16), f32(d, base + 20))
            XCTAssertGreaterThan(simd_dot(n, a - centre), 0, "triangle \(t) faces outward")
        }
    }

    func testWeldingSharesCornersAndClosesTheSolid() {
        let (positions, indices) = ModelExporter.welded(box)
        XCTAssertEqual(positions.count, 8)
        XCTAssertEqual(indices.count, 36)
        var edges: [[UInt32]: Int] = [:]
        for s in stride(from: 0, to: indices.count, by: 3) {
            for e in 0..<3 { edges[[indices[s + e], indices[s + (e + 1) % 3]].sorted(), default: 0] += 1 }
        }
        XCTAssertTrue(edges.values.allSatisfy { $0 == 2 }, "every edge belongs to exactly two triangles")
    }

    /// Reads the archive back the way an unzip tool would, checking every CRC.
    private func unzip(_ d: Data) -> [String: Data] {
        var files: [String: Data] = [:]
        let eocd = d.count - 22
        XCTAssertEqual(u32(d, eocd), 0x06054B50)
        let entries = Int(u16(d, eocd + 10))
        var offset = Int(u32(d, eocd + 16))
        for _ in 0..<entries {
            XCTAssertEqual(u32(d, offset), 0x02014B50)
            let crc = u32(d, offset + 16), size = Int(u32(d, offset + 24))
            let nameLength = Int(u16(d, offset + 28))
            let local = Int(u32(d, offset + 42))
            let name = String(decoding: d.subdata(in: offset + 46..<offset + 46 + nameLength), as: UTF8.self)
            XCTAssertEqual(u32(d, local), 0x04034B50)
            let start = local + 30 + Int(u16(d, local + 26)) + Int(u16(d, local + 28))
            let content = d.subdata(in: start..<start + size)
            XCTAssertEqual(ZipArchive.crc32(content), crc, "crc of \(name)")
            files[name] = content
            offset += 46 + nameLength
        }
        return files
    }

    func testCRC32MatchesTheKnownCheckValue() {
        XCTAssertEqual(ZipArchive.crc32(Data("123456789".utf8)), 0xCBF43926)
    }

    func test3MFIsAValidPackageWithAClosedMesh() throws {
        let files = unzip(ModelExporter.data(for: box, as: .threeMF))
        XCTAssertEqual(Set(files.keys), ["[Content_Types].xml", "_rels/.rels", "3D/3dmodel.model"])

        final class Counter: NSObject, XMLParserDelegate {
            var vertices = 0, triangles = 0, unit = ""
            func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
                if name == "vertex" { vertices += 1 }
                if name == "triangle" { triangles += 1 }
                if name == "model" { unit = a["unit"] ?? "" }
            }
        }
        let counter = Counter()
        let parser = XMLParser(data: try XCTUnwrap(files["3D/3dmodel.model"]))
        parser.delegate = counter
        XCTAssertTrue(parser.parse(), "the model part is well-formed XML")
        XCTAssertEqual(counter.vertices, 8)
        XCTAssertEqual(counter.triangles, boxTriangles)
        XCTAssertEqual(counter.unit, "millimeter")
    }

    func testGLBHeaderChunksAndAccessors() throws {
        let d = ModelExporter.data(for: box, as: .glb)
        XCTAssertEqual(u32(d, 0), 0x46546C67)
        XCTAssertEqual(u32(d, 4), 2)
        XCTAssertEqual(Int(u32(d, 8)), d.count)
        let jsonLength = Int(u32(d, 12))
        XCTAssertEqual(u32(d, 16), 0x4E4F534A)
        XCTAssertEqual(jsonLength % 4, 0)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: d.subdata(in: 20..<20 + jsonLength)) as? [String: Any])
        XCTAssertEqual((json["asset"] as? [String: Any])?["version"] as? String, "2.0")
        let binStart = 20 + jsonLength
        XCTAssertEqual(u32(d, binStart + 4), 0x004E4942)
        let binLength = Int(u32(d, binStart))
        XCTAssertEqual(d.count, binStart + 8 + binLength)
        let accessors = try XCTUnwrap(json["accessors"] as? [[String: Any]])
        XCTAssertEqual(accessors.count, 3)
        XCTAssertEqual(accessors[0]["count"] as? Int, boxTriangles * 3)
        XCTAssertEqual(accessors[2]["count"] as? Int, boxTriangles * 3)
        let bufferLength = ((json["buffers"] as? [[String: Any]])?.first?["byteLength"] as? Int) ?? 0
        XCTAssertEqual(bufferLength, binLength)
        // The position bounds are in metres (glTF), not millimetres.
        let max = try XCTUnwrap(accessors[0]["max"] as? [Double])
        XCTAssertEqual(max[0], 0.06, accuracy: 1e-5)
        // Indices reference real vertices.
        let indexStart = binStart + 8 + boxTriangles * 3 * 24
        for i in 0..<boxTriangles * 3 { XCTAssertLessThan(Int(u32(d, indexStart + i * 4)), boxTriangles * 3) }
    }

    func testOBJFacesReferenceDeclaredVertices() throws {
        let text = String(decoding: ModelExporter.data(for: box, as: .obj), as: UTF8.self)
        let lines = text.split(separator: "\n")
        let vertices = lines.filter { $0.hasPrefix("v ") }.count
        let faces = lines.filter { $0.hasPrefix("f ") }
        XCTAssertEqual(faces.count, boxTriangles)
        for face in faces {
            for corner in face.dropFirst(2).split(separator: " ") {
                let index = try XCTUnwrap(Int(corner.split(separator: "/").first ?? ""))
                XCTAssertTrue((1...vertices).contains(index))
            }
        }
    }

    func testFoldedAndMultiPartMeshesExportToo() {
        let rig = CameraRig(target: .zero, yaw: 0, pitch: 0, distance: 0.3)
        let bent = BendDeformer.deform(box, bendAngleRadians: 1.2, frame: rig.foldFrame(crease: .centeredVertical, aspect: 1.4))
        let both = RenderMesh.merged([bent, GeometryBuilder.cylinder(radius: 0.01, height: 0.01).translated(by: SIMD3(0, 0.05, 0))])
        for format in ExportFormat.allCases {
            XCTAssertGreaterThan(ModelExporter.data(for: both, as: format).count, 1000, format.rawValue)
        }
        let files = unzip(ModelExporter.data(for: both, as: .threeMF))
        XCTAssertNotNil(files["3D/3dmodel.model"])
    }
}
