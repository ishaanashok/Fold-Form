import Foundation
import CryptoKit

enum MeshBlobError: Error { case badMagic, truncated }

/// A mesh as bytes: "FFM1", then three little-endian UInt32 counts (positions, normals, indices),
/// then the position floats, normal floats and index integers. Named on disk by its SHA-256.
enum MeshBlob {
    private static let magic = Array("FFM1".utf8)
    private static let headerSize = 16

    static func encode(_ mesh: RenderMesh) -> Data {
        var data = Data(magic)
        data.reserveCapacity(headerSize + (mesh.positions.count * 3 + mesh.normals.count * 3 + mesh.indices.count) * 4)
        func put(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func put(_ value: Float) { put(value.bitPattern) }
        put(UInt32(mesh.positions.count))
        put(UInt32(mesh.normals.count))
        put(UInt32(mesh.indices.count))
        for p in mesh.positions { put(p.x); put(p.y); put(p.z) }
        for n in mesh.normals { put(n.x); put(n.y); put(n.z) }
        for i in mesh.indices { put(i) }
        return data
    }

    static func decode(_ data: Data) throws -> RenderMesh {
        guard data.count >= headerSize else { throw data.count >= 4 && Array(data.prefix(4)) != magic ? MeshBlobError.badMagic : MeshBlobError.truncated }
        guard Array(data.prefix(4)) == magic else { throw MeshBlobError.badMagic }
        func word(at offset: Int) -> UInt32 {
            data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + 4))
                .withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        }
        let positionCount = Int(word(at: 4)), normalCount = Int(word(at: 8)), indexCount = Int(word(at: 12))
        // Checked up front so a corrupt count can never drive a huge allocation.
        guard data.count == headerSize + (positionCount * 3 + normalCount * 3 + indexCount) * 4 else { throw MeshBlobError.truncated }
        var offset = headerSize
        func float() -> Float { defer { offset += 4 }; return Float(bitPattern: word(at: offset)) }
        var positions: [SIMD3<Float>] = []; positions.reserveCapacity(positionCount)
        for _ in 0..<positionCount { positions.append(SIMD3(float(), float(), float())) }
        var normals: [SIMD3<Float>] = []; normals.reserveCapacity(normalCount)
        for _ in 0..<normalCount { normals.append(SIMD3(float(), float(), float())) }
        var indices: [UInt32] = []; indices.reserveCapacity(indexCount)
        for _ in 0..<indexCount { indices.append(word(at: offset)); offset += 4 }
        return RenderMesh(positions: positions, normals: normals, indices: indices)
    }

    static func hash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
