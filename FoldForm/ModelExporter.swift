import Foundation
import simd

/// 3D file formats the model can be shared as.
enum ExportFormat: String, CaseIterable, Identifiable {
    case stl = "STL", threeMF = "3MF", glb = "GLB", obj = "OBJ"
    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .stl: "stl"
        case .threeMF: "3mf"
        case .glb: "glb"
        case .obj: "obj"
        }
    }

    var detail: String {
        switch self {
        case .stl: "3D printing"
        case .threeMF: "Slicers"
        case .glb: "Web & AR"
        case .obj: "Any 3D app"
        }
    }
}

/// Writes a mesh out as a standalone file. The mesh is in metres with Y up (the app's world).
/// STL, 3MF and OBJ are written in millimetres with Z up, the convention printers and CAD tools
/// expect; GLB stays in metres with Y up, as the glTF specification requires.
enum ModelExporter {
    static func data(for mesh: RenderMesh, as format: ExportFormat) -> Data {
        switch format {
        case .stl: return stl(mesh)
        case .threeMF: return threeMF(mesh)
        case .glb: return glb(mesh)
        case .obj: return obj(mesh)
        }
    }

    /// Metres, Y up → millimetres, Z up (a rotation, so handedness and winding are kept).
    static func printerSpace(_ p: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(p.x, -p.z, p.y) * 1000
    }

    // MARK: Shared geometry

    /// The mesh's triangles, skipping any with no area.
    private static func triangles(_ mesh: RenderMesh) -> [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] {
        var result: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
        for start in stride(from: 0, through: mesh.indices.count - 3, by: 3) {
            let i0 = Int(mesh.indices[start]), i1 = Int(mesh.indices[start + 1]), i2 = Int(mesh.indices[start + 2])
            guard i0 < mesh.positions.count, i1 < mesh.positions.count, i2 < mesh.positions.count else { continue }
            let a = mesh.positions[i0], b = mesh.positions[i1], c = mesh.positions[i2]
            if simd_length(simd_cross(b - a, c - a)) > 1e-14 { result.append((a, b, c)) }
        }
        return result
    }

    private struct Key: Hashable { var x: Int, y: Int, z: Int }

    /// Vertices shared between triangles once points that coincide (to a micrometre) are merged.
    static func welded(_ mesh: RenderMesh) -> (positions: [SIMD3<Float>], indices: [UInt32]) {
        var lookup: [Key: UInt32] = [:]
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        func index(for p: SIMD3<Float>) -> UInt32 {
            let key = Key(x: Int((p.x * 1e6).rounded()), y: Int((p.y * 1e6).rounded()), z: Int((p.z * 1e6).rounded()))
            if let existing = lookup[key] { return existing }
            let created = UInt32(positions.count)
            lookup[key] = created
            positions.append(p)
            return created
        }
        for (a, b, c) in triangles(mesh) {
            let ia = index(for: a), ib = index(for: b), ic = index(for: c)
            if ia != ib, ib != ic, ia != ic { indices += [ia, ib, ic] }
        }
        return (positions, indices)
    }

    // MARK: STL (binary)

    static func stl(_ mesh: RenderMesh) -> Data {
        let tris = triangles(mesh)
        var data = Data(count: 80)
        data.append(le: UInt32(tris.count))
        for (a, b, c) in tris {
            let p = [printerSpace(a), printerSpace(b), printerSpace(c)]
            let cross = simd_cross(p[1] - p[0], p[2] - p[0])
            let normal = simd_length(cross) > 0 ? simd_normalize(cross) : .zero
            for v in [normal, p[0], p[1], p[2]] {
                data.append(le: v.x.bitPattern); data.append(le: v.y.bitPattern); data.append(le: v.z.bitPattern)
            }
            data.append(le: UInt16(0))
        }
        return data
    }

    // MARK: OBJ

    static func obj(_ mesh: RenderMesh) -> Data {
        var lines = ["# FoldForm model (millimetres, Z up)", "o FoldForm"]
        func number(_ v: Float) -> String { String(format: "%.5f", Double(v)) }
        var positions: [String] = [], normals: [String] = [], faces: [String] = []
        for start in stride(from: 0, through: mesh.indices.count - 3, by: 3) {
            let ids = (0..<3).map { Int(mesh.indices[start + $0]) }
            guard ids.allSatisfy({ $0 < mesh.positions.count && $0 < mesh.normals.count }) else { continue }
            let base = positions.count
            for id in ids {
                let p = printerSpace(mesh.positions[id])
                positions.append("v \(number(p.x)) \(number(p.y)) \(number(p.z))")
                let n = printerSpace(mesh.normals[id]) / 1000
                normals.append("vn \(number(n.x)) \(number(n.y)) \(number(n.z))")
            }
            faces.append("f \(base + 1)//\(base + 1) \(base + 2)//\(base + 2) \(base + 3)//\(base + 3)")
        }
        lines += positions + normals + faces
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    // MARK: 3MF

    static func threeMF(_ mesh: RenderMesh) -> Data {
        let (positions, indices) = welded(mesh)
        func number(_ v: Float) -> String { String(format: "%.5f", Double(v)) }
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
         <metadata name="Title">FoldForm model</metadata>
         <resources>
          <object id="1" type="model">
           <mesh>
            <vertices>

        """
        for p in positions {
            let q = printerSpace(p)
            xml += "     <vertex x=\"\(number(q.x))\" y=\"\(number(q.y))\" z=\"\(number(q.z))\"/>\n"
        }
        xml += "    </vertices>\n    <triangles>\n"
        for start in stride(from: 0, to: indices.count, by: 3) {
            xml += "     <triangle v1=\"\(indices[start])\" v2=\"\(indices[start + 1])\" v3=\"\(indices[start + 2])\"/>\n"
        }
        xml += """
            </triangles>
           </mesh>
          </object>
         </resources>
         <build>
          <item objectid="1"/>
         </build>
        </model>

        """
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/></Types>
        """
        let rels = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/></Relationships>
        """
        return ZipArchive.stored([
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rels.utf8)),
            ("3D/3dmodel.model", Data(xml.utf8))
        ])
    }

    // MARK: GLB (binary glTF 2.0)

    static func glb(_ mesh: RenderMesh) -> Data {
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], indices: [UInt32] = []
        for start in stride(from: 0, through: mesh.indices.count - 3, by: 3) {
            let ids = (0..<3).map { Int(mesh.indices[start + $0]) }
            guard ids.allSatisfy({ $0 < mesh.positions.count && $0 < mesh.normals.count }) else { continue }
            for id in ids {
                indices.append(UInt32(positions.count))
                positions.append(mesh.positions[id])
                normals.append(mesh.normals[id])
            }
        }
        let count = positions.count
        let lo = positions.reduce(positions.first ?? .zero) { simd_min($0, $1) }
        let hi = positions.reduce(positions.first ?? .zero) { simd_max($0, $1) }

        var bin = Data()
        for p in positions { bin.append(le: p.x.bitPattern); bin.append(le: p.y.bitPattern); bin.append(le: p.z.bitPattern) }
        for n in normals { bin.append(le: n.x.bitPattern); bin.append(le: n.y.bitPattern); bin.append(le: n.z.bitPattern) }
        for i in indices { bin.append(le: i) }

        let json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "FoldForm"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0, "name": "FoldForm model"]],
            "materials": [[
                "name": "Blue",
                "doubleSided": true,
                "pbrMetallicRoughness": ["baseColorFactor": [0.16, 0.42, 0.95, 1.0], "metallicFactor": 0.0, "roughnessFactor": 1.0]
            ]],
            "meshes": [["name": "FoldForm model", "primitives": [["attributes": ["POSITION": 0, "NORMAL": 1], "indices": 2, "material": 0, "mode": 4]]]],
            "accessors": [
                ["bufferView": 0, "componentType": 5126, "count": count, "type": "VEC3",
                 "min": [lo.x, lo.y, lo.z].map { Double($0) }, "max": [hi.x, hi.y, hi.z].map { Double($0) }],
                ["bufferView": 1, "componentType": 5126, "count": count, "type": "VEC3"],
                ["bufferView": 2, "componentType": 5125, "count": indices.count, "type": "SCALAR"]
            ],
            "bufferViews": [
                ["buffer": 0, "byteOffset": 0, "byteLength": count * 12, "target": 34962],
                ["buffer": 0, "byteOffset": count * 12, "byteLength": count * 12, "target": 34962],
                ["buffer": 0, "byteOffset": count * 24, "byteLength": indices.count * 4, "target": 34963]
            ],
            "buffers": [["byteLength": bin.count]]
        ]
        var jsonData = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data("{}".utf8)
        while jsonData.count % 4 != 0 { jsonData.append(0x20) }
        while bin.count % 4 != 0 { bin.append(0) }

        var out = Data()
        out.append(le: UInt32(0x46546C67))          // "glTF"
        out.append(le: UInt32(2))
        out.append(le: UInt32(12 + 8 + jsonData.count + 8 + bin.count))
        out.append(le: UInt32(jsonData.count)); out.append(le: UInt32(0x4E4F534A)); out.append(jsonData)
        out.append(le: UInt32(bin.count)); out.append(le: UInt32(0x004E4942)); out.append(bin)
        return out
    }
}

/// A minimal ZIP writer (files stored uncompressed), enough for 3MF packages.
enum ZipArchive {
    static func stored(_ files: [(name: String, data: Data)]) -> Data {
        var out = Data()
        var central = Data()
        for file in files {
            let name = Data(file.name.utf8)
            let crc = crc32(file.data)
            let offset = UInt32(out.count)

            out.append(le: UInt32(0x04034B50)); out.append(le: UInt16(20)); out.append(le: UInt16(0)); out.append(le: UInt16(0))
            out.append(le: UInt16(0)); out.append(le: UInt16(0x0021))
            out.append(le: crc); out.append(le: UInt32(file.data.count)); out.append(le: UInt32(file.data.count))
            out.append(le: UInt16(name.count)); out.append(le: UInt16(0))
            out.append(name); out.append(file.data)

            central.append(le: UInt32(0x02014B50)); central.append(le: UInt16(20)); central.append(le: UInt16(20))
            central.append(le: UInt16(0)); central.append(le: UInt16(0))
            central.append(le: UInt16(0)); central.append(le: UInt16(0x0021))
            central.append(le: crc); central.append(le: UInt32(file.data.count)); central.append(le: UInt32(file.data.count))
            central.append(le: UInt16(name.count)); central.append(le: UInt16(0)); central.append(le: UInt16(0))
            central.append(le: UInt16(0)); central.append(le: UInt16(0)); central.append(le: UInt32(0))
            central.append(le: offset)
            central.append(name)
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        out.append(le: UInt32(0x06054B50)); out.append(le: UInt16(0)); out.append(le: UInt16(0))
        out.append(le: UInt16(files.count)); out.append(le: UInt16(files.count))
        out.append(le: UInt32(central.count)); out.append(le: centralOffset); out.append(le: UInt16(0))
        return out
    }

    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(le value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
