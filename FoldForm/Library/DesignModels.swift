import Foundation

struct DesignManifest: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var createdAt: Date
    var modifiedAt: Date
    var isFavourite: Bool = false
    var folderID: UUID?
    var partCount: Int
    /// The `PartProfileKind` the design was started from, for display only.
    var template: String
}

struct DesignFolder: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var createdAt: Date
}

struct DesignBody {
    var mesh: RenderMesh
    var style: PartStyle?
}

/// Everything read from the live workbench that a save needs.
struct DesignCapture {
    var bodies: [DesignBody]
    var corner: CornerStyle
    var camera: CameraRig?
}

/// A design read back from disk, ready to build an editor from.
struct LoadedDesign {
    var meshes: [RenderMesh]
    /// Colour per body, by position (body ids are regenerated on load).
    var styles: [PartStyle?]
    var corner: CornerStyle
    var camera: CameraRig?
}

struct DesignContent: Codable, Equatable {
    struct Body: Codable, Equatable {
        var meshHash: String
        /// A `Palette` colour name, or nil for the default blue.
        var style: String?
    }
    struct Camera: Codable, Equatable {
        var target: [Float]
        var yaw: Float
        var pitch: Float
        var distance: Float
        var roll: Float

        init(_ rig: CameraRig) {
            target = [rig.target.x, rig.target.y, rig.target.z]
            yaw = rig.yaw; pitch = rig.pitch; distance = rig.distance; roll = rig.roll
        }

        var rig: CameraRig {
            let t = target.count == 3 ? SIMD3<Float>(target[0], target[1], target[2]) : .zero
            return CameraRig(target: t, yaw: yaw, pitch: pitch, distance: distance, roll: roll)
        }
    }

    var bodies: [Body]
    var corner: String
    var camera: Camera?

    var meshHashes: Set<String> { Set(bodies.map(\.meshHash)) }

    static func make(_ capture: DesignCapture) -> (content: DesignContent, blobs: [String: Data]) {
        var blobs: [String: Data] = [:]
        let bodies = capture.bodies.map { body -> Body in
            let data = MeshBlob.encode(body.mesh)
            let hash = MeshBlob.hash(of: data)
            blobs[hash] = data
            return Body(meshHash: hash, style: body.style?.name)
        }
        return (DesignContent(bodies: bodies, corner: capture.corner.rawValue, camera: capture.camera.map(Camera.init)), blobs)
    }

    func loaded(meshes: [RenderMesh]) -> LoadedDesign {
        LoadedDesign(
            meshes: meshes,
            styles: bodies.map { $0.style.flatMap(Palette.style) },
            corner: CornerStyle(rawValue: corner) ?? .fillet,
            camera: camera?.rig
        )
    }

    /// The starting shapes of a new design: the app's own quick-start geometry for the profile.
    @MainActor
    static func template(_ kind: PartProfileKind) -> DesignCapture {
        let document = CADDocument()
        document.loadQuickStartProfile(kind)
        let studio = document.partStudio
        let bodies = studio.orderedBodyIDs.compactMap { studio.body($0) }.map { DesignBody(mesh: $0.mesh, style: nil) }
        return DesignCapture(bodies: bodies, corner: .fillet, camera: nil)
    }
}

struct DesignVersion: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var note: String
    var createdAt: Date
    var isAutomatic: Bool
    var partCount: Int
    var content: DesignContent
}
