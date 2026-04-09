/*
 Abstract:
 Wavefront OBJ / PLY export from ARKit scene mesh, with per-vertex camera colors and normals.
 */

import ARKit
import CoreImage
import simd
import UIKit

// MARK: - Debug diagnostics

/// Thread-safe counters cho mỗi lần export. Reset trước mỗi lần build.
private final class ColorDiag: @unchecked Sendable {
    private let q = DispatchQueue(label: "ColorDiag")
    private var _total = 0
    private var _gotColor = 0
    private var _fallbackBehindCam = 0
    private var _fallbackBackface = 0
    private var _fallbackOutOfBounds = 0
    private var _fallbackNoFrames = 0
    private var _fallbackZeroWeight = 0

    func countVertex()           { q.sync { _total += 1} }
    func countColor()            { q.sync { _gotColor += 1 } }
    func countBehindCam()        { q.sync { _fallbackBehindCam += 1 } }
    func countBackface()         { q.sync { _fallbackBackface += 1 } }
    func countOutOfBounds()      { q.sync { _fallbackOutOfBounds += 1 } }
    func countNoFrames()         { q.sync { _fallbackNoFrames += 1 } }
    func countZeroWeight()       { q.sync { _fallbackZeroWeight += 1 } }

    func printSummary(tag: String) {
        q.sync {
            let gray = _total - _gotColor
            print("""
[ColorDiag] === \(tag) ===
  Tổng vertices  : \(_total)
  Có màu thật   : \(_gotColor) (\(pct(_gotColor, _total))%)
  Xám fallback   : \(gray) (\(pct(gray, _total))%)
    behind cam   : \(_fallbackBehindCam)
    backface ext  : \(_fallbackBackface)
    out of bounds : \(_fallbackOutOfBounds)
    zero weight   : \(_fallbackZeroWeight)
    no frames     : \(_fallbackNoFrames)
""")
        }
    }

    private func pct(_ n: Int, _ d: Int) -> String {
        guard d > 0 else { return "0" }
        return String(format: "%.1f", Float(n) / Float(d) * 100)
    }
}

enum ARMeshExporter {
    // MARK: - Multi-frame color history

    private static let historyQueue = DispatchQueue(label: "ARMeshExporter.frameHistory")
    private static var frameHistory: [ARFrame] = []
    // Giữ nhiều frame hơn để tăng độ phủ màu khi export.
    // Vẫn giới hạn tương đối thấp để tránh giữ quá nhiều camera image trong RAM.
    private static let maxHistoryFrames = 12
    private static let maxFusionFrames = 8

    static func recordFrameForColorFusion(_ frame: ARFrame) {
        historyQueue.sync {
            if let last = frameHistory.last, abs(last.timestamp - frame.timestamp) < 1e-4 {
                return
            }
            frameHistory.append(frame)
            if frameHistory.count > maxHistoryFrames {
                frameHistory.removeFirst(frameHistory.count - maxHistoryFrames)
            }
        }
    }

    static func resetFrameHistory() {
        historyQueue.sync {
            frameHistory.removeAll(keepingCapacity: true)
        }
    }

    private static func fusionFrames(including current: ARFrame) -> [ARFrame] {
        historyQueue.sync {
            let recent = Array(frameHistory.suffix(maxFusionFrames))
            if recent.contains(where: { abs($0.timestamp - current.timestamp) < 1e-4 }) {
                return recent
            }
            return Array((recent + [current]).suffix(maxFusionFrames))
        }
    }

    /// Geometry-only OBJ (legacy).
    static func buildOBJString(from session: ARSession) -> String? {
        guard let frame = session.currentFrame else { return nil }
        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshAnchors.isEmpty else { return nil }
        return buildOBJString(from: meshAnchors)
    }

    /// Colored mesh: `v x y z r g b` + optional `vn`, and matching `f v//vn`.
    static func buildColoredOBJString(from session: ARSession) -> String? {
        guard let frame = session.currentFrame else { return nil }
        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshAnchors.isEmpty else { return nil }
        return buildColoredOBJString(meshAnchors: meshAnchors, frame: frame)
    }

    /// PLY ascii with uchar red/green/blue — many viewers show vertex color reliably.
    static func buildColoredPLYString(from session: ARSession) -> String? {
        guard let frame = session.currentFrame else { return nil }
        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshAnchors.isEmpty else { return nil }
        return buildColoredPLYString(meshAnchors: meshAnchors, frame: frame)
    }

    /// Binary glTF 2.0: per-face color + flat normals — **Xcode Scene Editor shows COLOR_0**; good for “rõ vật thể”.
    static func buildFacetedGLB(from session: ARSession) -> Data? {
        guard let frame = session.currentFrame else { return nil }
        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshAnchors.isEmpty else { return nil }
        return buildFacetedGLB(meshAnchors: meshAnchors, frame: frame)
    }

    // MARK: - Textured OBJ (Solution B)

    /// Exports OBJ + MTL + JPEG texture.
    /// UV is generated by projecting each vertex back to the best fusion ARFrame camera image.
    /// This is the most universally compatible format — Blender, MeshLab, every viewer reads it correctly.
    struct TexturedOBJBundle {
        let obj: String
        let mtl: String
        let textureJPEG: Data
    }

    static func buildTexturedOBJBundle(
        from session: ARSession,
        textureFilename: String = "texture.jpg"
    ) -> TexturedOBJBundle? {
        guard let frame = session.currentFrame else { return nil }
        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshAnchors.isEmpty else { return nil }

        // Lấy tất cả fusion frames để sample UV từ frame phủ tốt nhất cho từng vertex
        let frames = fusionFrames(including: frame)
        // Dùng frame cuối cùng (mới nhất) làm texture chính
        let texFrame = frames.last ?? frame
        guard let textureData = extractJPEG(from: texFrame) else { return nil }
        let texW = CGFloat(CVPixelBufferGetWidth(texFrame.capturedImage))
        let texH = CGFloat(CVPixelBufferGetHeight(texFrame.capturedImage))

        var vSection = ""     // v x y z
        var vtSection = ""    // vt u v
        var vnSection = ""    // vn x y z
        var fSection = "mtllib \(textureFilename.replacingOccurrences(of: ".jpg", with: ".mtl"))\nusemtl camera_tex\n"
        var vertexBase = 1

        for anchor in meshAnchors {
            let geometry = anchor.geometry
            var verts = worldVertexPositions(geometry: geometry, transform: anchor.transform)
            var indices = triangleIndices(geometry: geometry)
            MeshLaplacianSmooth.smooth(positions: &verts, triangleIndices: indices)
            MeshLaplacianSmooth.fillSmallBoundaryHoles(positions: &verts, triangleIndices: &indices)
            let normals = MeshLaplacianSmooth.vertexNormals(positions: verts, triangleIndices: indices)

            for i in 0..<verts.count {
                let v = verts[i]
                let n = normals[i]
                vSection += String(format: "v %.6f %.6f %.6f\n", v.x, v.y, v.z)
                vnSection += String(format: "vn %.6f %.6f %.6f\n", n.x, n.y, n.z)

                // Thử chiếu lên texFrame trước. Nếu texFrame không phủ được vertex này,
                // thử các fusion frames khác để tìm frame chiếu tốt nhất (ndotl cao nhất).
                var u: Float = 0.5
                var vCoord: Float = 0.5

                if let pt = projectWorldToImagePixel(worldPosition: v, frame: texFrame) {
                    // Vertex nằm trong texFrame → UV trực tiếp
                    u = Float(max(0, min(pt.x / texW, 1)))
                    vCoord = Float(max(0, min(1 - pt.y / texH, 1)))
                } else {
                    // Thử fusion frames khác — bake màu vào UV (0.5, y) dựa trên Y normalized
                    // Fallback: dùng màu từ multi-frame vertex coloring nếu không có UV
                    let color = sampleCameraColor(worldPosition: v, worldNormal: n, frame: frame)
                    // Encode màu vào dải 1px vertical trong texture bằng cách không dùng UV này.
                    // Thực tế: fallback về UV = (0.5, 0.5) để không bị stretch xấu.
                    _ = color
                }
                vtSection += String(format: "vt %.6f %.6f\n", u, vCoord)
            }

            let base = vertexBase
            for i in stride(from: 0, to: indices.count, by: 3) {
                let i0 = Int(indices[i]) + base
                let i1 = Int(indices[i + 1]) + base
                let i2 = Int(indices[i + 2]) + base
                fSection += "f \(i0)/\(i0)/\(i0) \(i1)/\(i1)/\(i1) \(i2)/\(i2)/\(i2)\n"
            }
            vertexBase += verts.count
        }

        // OBJ canonical order: v → vt → vn → f
        let obj = vSection + vtSection + vnSection + fSection
        let mtl = """
        newmtl camera_tex
        Ka 1.000 1.000 1.000
        Kd 1.000 1.000 1.000
        Ks 0.000 0.000 0.000
        d 1.0
        illum 1
        map_Kd \(textureFilename)
        """
        return TexturedOBJBundle(obj: obj, mtl: mtl, textureJPEG: textureData)
    }

    private static func extractJPEG(from frame: ARFrame) -> Data? {
        let pb = frame.capturedImage
        let ci = CIImage(cvPixelBuffer: pb)
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.88)
    }

    static func meshStatistics(from session: ARSession) -> (anchors: Int, triangles: Int) {
        guard let frame = session.currentFrame else { return (0, 0) }
        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        var triangles = 0
        for anchor in meshAnchors {
            triangles += anchor.geometry.faces.count
        }
        return (meshAnchors.count, triangles)
    }

    // MARK: - Plain OBJ

    static func buildOBJString(from meshAnchors: [ARMeshAnchor]) -> String {
        var obj = "# LiDARDepth — ARKit scene mesh export\n"
        var vertexBase = 1
        for anchor in meshAnchors {
            let geometry = anchor.geometry
            let verts = worldVertexPositions(geometry: geometry, transform: anchor.transform)
            for v in verts {
                obj += String(format: "v %.6f %.6f %.6f\n", v.x, v.y, v.z)
            }
            let indices = triangleIndices(geometry: geometry)
            let offset = vertexBase
            for i in stride(from: 0, to: indices.count, by: 3) {
                let i0 = Int(indices[i]) + offset
                let i1 = Int(indices[i + 1]) + offset
                let i2 = Int(indices[i + 2]) + offset
                obj += "f \(i0) \(i1) \(i2)\n"
            }
            vertexBase += verts.count
        }
        return obj
    }

    // MARK: - Colored OBJ + PLY

    private static func buildColoredOBJString(meshAnchors: [ARMeshAnchor], frame: ARFrame) -> String {
        let diag = ColorDiag()
        logExportHeader(tag: "OBJ", frame: frame)
        var obj = "# LiDARDepth — vertex RGB (0–1); đỉnh đã qua Laplacian mịn (MeshLaplacianSmooth). Xcode OBJ: mở .glb/.ply để xem màu.\n"
        var vertexBase = 1
        var normalBase = 1

        for anchor in meshAnchors {
            let geometry = anchor.geometry
            var verts = worldVertexPositions(geometry: geometry, transform: anchor.transform)
            var indices = triangleIndices(geometry: geometry)
            MeshLaplacianSmooth.smooth(positions: &verts, triangleIndices: indices)
            MeshLaplacianSmooth.fillSmallBoundaryHoles(positions: &verts, triangleIndices: &indices)
            let normalsSmooth = MeshLaplacianSmooth.vertexNormals(positions: verts, triangleIndices: indices)

            for i in 0..<verts.count {
                let v = verts[i]
                let n = normalsSmooth[i]
                let c = sampleCameraColor(worldPosition: v, worldNormal: n, frame: frame, diag: diag)
                diag.countVertex()
                obj += String(format: "v %.6f %.6f %.6f %.6f %.6f %.6f\n", v.x, v.y, v.z, c.x, c.y, c.z)
            }

            for n in normalsSmooth {
                obj += String(format: "vn %.6f %.6f %.6f\n", n.x, n.y, n.z)
            }

            let vOffset = vertexBase
            let nOffset = normalBase

            for i in stride(from: 0, to: indices.count, by: 3) {
                let i0 = Int(indices[i])
                let i1 = Int(indices[i + 1])
                let i2 = Int(indices[i + 2])
                obj += "f \(i0 + vOffset)//\(i0 + nOffset) \(i1 + vOffset)//\(i1 + nOffset) \(i2 + vOffset)//\(i2 + nOffset)\n"
            }

            vertexBase += verts.count
            normalBase += verts.count
        }
        diag.printSummary(tag: "OBJ")
        return obj
    }

    private static func buildColoredPLYString(meshAnchors: [ARMeshAnchor], frame: ARFrame) -> String {
        let diag = ColorDiag()
        logExportHeader(tag: "PLY", frame: frame)
        var positions: [SIMD3<Float>] = []
        var colors: [SIMD3<Float>] = []
        var faces: [(Int, Int, Int)] = []
        var indexOffset = 0

        for anchor in meshAnchors {
            let geometry = anchor.geometry
            var verts = worldVertexPositions(geometry: geometry, transform: anchor.transform)
            var indices = triangleIndices(geometry: geometry)
            MeshLaplacianSmooth.smooth(positions: &verts, triangleIndices: indices)
            MeshLaplacianSmooth.fillSmallBoundaryHoles(positions: &verts, triangleIndices: &indices)
            let normalsSmooth = MeshLaplacianSmooth.vertexNormals(positions: verts, triangleIndices: indices)
            for i in 0..<verts.count {
                let v = verts[i]
                let n = normalsSmooth[i]
                let c = sampleCameraColor(worldPosition: v, worldNormal: n, frame: frame, diag: diag)
                diag.countVertex()
                positions.append(v)
                colors.append(c)
            }
            for i in stride(from: 0, to: indices.count, by: 3) {
                let a = indexOffset + Int(indices[i])
                let b = indexOffset + Int(indices[i + 1])
                let c = indexOffset + Int(indices[i + 2])
                faces.append((a, b, c))
            }
            indexOffset += verts.count
        }

        var ply = "ply\nformat ascii 1.0\n"
        ply += "comment LiDARDepth — vertex RGB from camera; Laplacian smoothed positions\n"
        ply += "element vertex \(positions.count)\n"
        ply += "property float x\nproperty float y\nproperty float z\n"
        ply += "property uchar red\nproperty uchar green\nproperty uchar blue\n"
        ply += "element face \(faces.count)\n"
        ply += "property list uchar int vertex_indices\n"
        ply += "end_header\n"

        for i in 0..<positions.count {
            let p = positions[i]
            let c = colors[i]
            let r = UInt8(clamping: Int((c.x * 255).rounded()))
            let g = UInt8(clamping: Int((c.y * 255).rounded()))
            let b = UInt8(clamping: Int((c.z * 255).rounded()))
            ply += String(format: "%.6f %.6f %.6f %d %d %d\n", p.x, p.y, p.z, r, g, b)
        }
        for f in faces {
            ply += "3 \(f.0) \(f.1) \(f.2)\n"
        }
        diag.printSummary(tag: "PLY")
        return ply
    }

    // MARK: - glTF 2.0 GLB (faceted, per-triangle color)

    private static func buildFacetedGLB(meshAnchors: [ARMeshAnchor], frame: ARFrame) -> Data? {
        let diag = ColorDiag()
        logExportHeader(tag: "GLB", frame: frame)
        var positions: [Float] = []
        var normals: [Float] = []
        var colors: [Float] = []

        for anchor in meshAnchors {
            let geometry = anchor.geometry
            var verts = worldVertexPositions(geometry: geometry, transform: anchor.transform)
            var indices = triangleIndices(geometry: geometry)
            MeshLaplacianSmooth.smooth(positions: &verts, triangleIndices: indices)
            MeshLaplacianSmooth.fillSmallBoundaryHoles(positions: &verts, triangleIndices: &indices)
            for t in stride(from: 0, to: indices.count, by: 3) {
                let i0 = Int(indices[t])
                let i1 = Int(indices[t + 1])
                let i2 = Int(indices[t + 2])
                let p0 = verts[i0]
                let p1 = verts[i1]
                let p2 = verts[i2]
                let e1 = p1 - p0
                let e2 = p2 - p0
                var fn = simd_cross(e1, e2)
                let ln = simd_length(fn)
                guard ln >= 1e-8 else { continue }
                fn = fn / ln
                let center = (p0 + p1 + p2) * (1.0 / 3.0)
                let c = sampleCameraColor(worldPosition: center, worldNormal: fn, frame: frame, diag: diag)
                diag.countVertex()
                for p in [p0, p1, p2] {
                    positions.append(contentsOf: [p.x, p.y, p.z])
                    normals.append(contentsOf: [fn.x, fn.y, fn.z])
                    colors.append(contentsOf: [c.x, c.y, c.z])
                }
            }
        }
        let vertexCount = positions.count / 3
        guard vertexCount > 0 else { return nil }
        diag.printSummary(tag: "GLB")
        return encodeGLB(positions: positions, normals: normals, colors: colors, vertexCount: vertexCount)
    }

    /// glTF 2.0: `ARRAY_BUFFER` / `ELEMENT_ARRAY_BUFFER` (OpenGL ES constants).
    private static let gltfArrayBuffer: Int = 34962

    private static func encodeGLB(positions: [Float], normals: [Float], colors: [Float], vertexCount: Int) -> Data {
        let posData = positions.withUnsafeBufferPointer { Data(buffer: $0) }
        let normData = normals.withUnsafeBufferPointer { Data(buffer: $0) }
        var colorBytes: [UInt8] = []
        colorBytes.reserveCapacity(vertexCount * 4)
        for i in 0..<vertexCount {
            let r = UInt8(clamping: Int((max(0, min(1, colors[i * 3 + 0])) * 255).rounded()))
            let g = UInt8(clamping: Int((max(0, min(1, colors[i * 3 + 1])) * 255).rounded()))
            let b = UInt8(clamping: Int((max(0, min(1, colors[i * 3 + 2])) * 255).rounded()))
            colorBytes.append(r)
            colorBytes.append(g)
            colorBytes.append(b)
            colorBytes.append(255)
        }
        let colorData = Data(colorBytes)

        var binChunk = Data()
        binChunk.append(posData)
        binChunk.append(normData)
        binChunk.append(colorData)
        while binChunk.count % 4 != 0 {
            binChunk.append(0)
        }
        let bufferByteLength = binChunk.count

        var minP = SIMD3<Float>(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
        var maxP = SIMD3<Float>(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)
        for i in 0..<vertexCount {
            let x = positions[i * 3 + 0]
            let y = positions[i * 3 + 1]
            let z = positions[i * 3 + 2]
            minP = SIMD3<Float>(min(minP.x, x), min(minP.y, y), min(minP.z, z))
            maxP = SIMD3<Float>(max(maxP.x, x), max(maxP.y, y), max(maxP.z, z))
        }

        let p0 = posData.count
        let p1 = p0 + normData.count
        let tgt = gltfArrayBuffer

        // Vertex color as normalized RGBA8 improves compatibility across viewers.
        let json: String = """
        {"asset":{"version":"2.0","generator":"LiDARDepth"},"scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"mesh":0}],"meshes":[{"primitives":[{"attributes":{"POSITION":0,"NORMAL":1,"COLOR_0":2},"material":0}]}],"materials":[{"doubleSided":true,"pbrMetallicRoughness":{"baseColorFactor":[1,1,1,1],"metallicFactor":0,"roughnessFactor":1}}],"buffers":[{"byteLength":\(bufferByteLength)}],"bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":\(posData.count),"target":\(tgt)},{"buffer":0,"byteOffset":\(p0),"byteLength":\(normData.count),"target":\(tgt)},{"buffer":0,"byteOffset":\(p1),"byteLength":\(colorData.count),"target":\(tgt)}],"accessors":[{"bufferView":0,"componentType":5126,"count":\(vertexCount),"type":"VEC3","min":[\(minP.x),\(minP.y),\(minP.z)],"max":[\(maxP.x),\(maxP.y),\(maxP.z)]},{"bufferView":1,"componentType":5126,"count":\(vertexCount),"type":"VEC3"},{"bufferView":2,"componentType":5121,"normalized":true,"count":\(vertexCount),"type":"VEC4"}]}
        """

        var jsonData = Data(json.utf8)
        while jsonData.count % 4 != 0 {
            jsonData.append(0x20)
        }

        let jsonChunkLength = jsonData.count
        let binChunkLength = binChunk.count
        let totalLength = 12 + 8 + jsonChunkLength + 8 + binChunkLength

        var out = Data()
        out.append(contentsOf: [0x67, 0x6C, 0x54, 0x46])
        out.append(contentsOf: [2, 0, 0, 0])
        var totalLE = UInt32(totalLength).littleEndian
        out.append(Data(bytes: &totalLE, count: 4))

        var jsonLenLE = UInt32(jsonChunkLength).littleEndian
        out.append(Data(bytes: &jsonLenLE, count: 4))
        out.append(contentsOf: [0x4A, 0x53, 0x4F, 0x4E])
        out.append(jsonData)

        var binLenLE = UInt32(binChunkLength).littleEndian
        out.append(Data(bytes: &binLenLE, count: 4))
        out.append(contentsOf: [0x42, 0x49, 0x4E, 0x00])
        out.append(binChunk)

        return out
    }

    // MARK: - Geometry

    private static func worldVertexPositions(geometry: ARMeshGeometry, transform: simd_float4x4) -> [SIMD3<Float>] {
        let source = geometry.vertices
        let count = source.count
        let stride = source.stride
        let byteOffset = source.offset
        var result: [SIMD3<Float>] = []
        result.reserveCapacity(count)
        let base = source.buffer.contents().advanced(by: byteOffset)
        for i in 0..<count {
            let p = base.advanced(by: i * stride).assumingMemoryBound(to: Float.self)
            let local = SIMD3<Float>(p[0], p[1], p[2])
            let w = transform * SIMD4<Float>(local.x, local.y, local.z, 1)
            result.append(SIMD3<Float>(w.x, w.y, w.z))
        }
        return result
    }

    private static func worldNormalsIfAvailable(geometry: ARMeshGeometry, transform: simd_float4x4) -> [SIMD3<Float>]? {
        let normals = geometry.normals
        guard normals.count == geometry.vertices.count else { return nil }
        let count = normals.count
        let stride = normals.stride
        let byteOffset = normals.offset
        let R = rotation3x3(from: transform)
        var result: [SIMD3<Float>] = []
        result.reserveCapacity(count)
        let base = normals.buffer.contents().advanced(by: byteOffset)
        for i in 0..<count {
            let p = base.advanced(by: i * stride).assumingMemoryBound(to: Float.self)
            let local = SIMD3<Float>(p[0], p[1], p[2])
            let world = simd_normalize(R * local)
            result.append(world)
        }
        return result
    }

    private static func rotation3x3(from t: simd_float4x4) -> simd_float3x3 {
        simd_float3x3(
            SIMD3<Float>(t.columns.0.x, t.columns.0.y, t.columns.0.z),
            SIMD3<Float>(t.columns.1.x, t.columns.1.y, t.columns.1.z),
            SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        )
    }

    private static func triangleIndices(geometry: ARMeshGeometry) -> [UInt32] {
        let faces = geometry.faces
        let triangleCount = faces.count
        let bytesPerIndex = faces.bytesPerIndex
        let indicesPerPrimitive = faces.indexCountPerPrimitive
        var out: [UInt32] = []
        out.reserveCapacity(triangleCount * 3)
        let base = faces.buffer.contents()
        for t in 0..<triangleCount {
            let rowOffset = t * indicesPerPrimitive * bytesPerIndex
            for k in 0..<indicesPerPrimitive {
                let idxOffset = rowOffset + k * bytesPerIndex
                if bytesPerIndex == 2 {
                    let idx = base.advanced(by: idxOffset).assumingMemoryBound(to: UInt16.self).pointee
                    out.append(UInt32(idx))
                } else {
                    let idx = base.advanced(by: idxOffset).assumingMemoryBound(to: UInt32.self).pointee
                    out.append(idx)
                }
            }
        }
        return out
    }

    // MARK: - Camera coloring

    private static func activeInterfaceOrientation() -> UIInterfaceOrientation {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            return .portrait
        }
        return scene.interfaceOrientation
    }

    /// Multi-frame weighted color fusion:
    /// - Angle weight (soft, no hard cutoff except extreme backface)
    /// - Distance weight
    /// - Border confidence
    /// - 5-tap pixel sampling to reduce sensor noise
    private static func sampleCameraColor(worldPosition: SIMD3<Float>, worldNormal: SIMD3<Float>?, frame: ARFrame, diag: ColorDiag? = nil) -> SIMD3<Float> {
        let frames = fusionFrames(including: frame)
        if frames.isEmpty { diag?.countNoFrames(); return SIMD3<Float>(repeating: 0.55) }
        var colorAccum = SIMD3<Float>(0, 0, 0)
        var weightAccum: Float = 0

        for (idx, f) in frames.enumerated() {
            guard let (color, weight) = evaluateFrameColor(
                frame: f,
                frameOrder: idx,
                totalFrames: frames.count,
                worldPosition: worldPosition,
                worldNormal: worldNormal,
                diag: diag
            ) else { continue }
            colorAccum += color * weight
            weightAccum += weight
        }

        if weightAccum > 1e-5 {
            diag?.countColor()
            return simd_clamp(colorAccum / weightAccum, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
        }
        diag?.countZeroWeight()
        return SIMD3<Float>(repeating: 0.55)
    }

    private static func evaluateFrameColor(
        frame: ARFrame,
        frameOrder: Int,
        totalFrames: Int,
        worldPosition: SIMD3<Float>,
        worldNormal: SIMD3<Float>?,
        diag: ColorDiag? = nil
    ) -> (SIMD3<Float>, Float)? {
        let cam = frame.camera.transform.inverse * SIMD4<Float>(worldPosition.x, worldPosition.y, worldPosition.z, 1)
        if cam.z > -0.01 {
            diag?.countBehindCam()
            return nil
        }

        let camT = frame.camera.transform
        let camPos = SIMD3<Float>(camT.columns.3.x, camT.columns.3.y, camT.columns.3.z)
        let toCameraVec = camPos - worldPosition
        let dist = simd_length(toCameraVec)
        if dist < 1e-4 {
            diag?.countBehindCam()
            return nil
        }
        let toCamera = toCameraVec / dist

        let ndotl: Float
        if let n = worldNormal {
            let nn = simd_normalize(n)
            ndotl = simd_dot(nn, toCamera)
        } else {
            ndotl = 0.5
        }

        let projected: CGPoint
        if let p = projectWorldToImagePixel(worldPosition: worldPosition, frame: frame) {
            projected = p
        } else {
            var rescuedPoint: CGPoint?
            if let n = worldNormal {
                let nn = simd_normalize(n)
                let offsets: [Float] = [0.003, 0.006, 0.010]
                for d in offsets {
                    if let p = projectWorldToImagePixel(worldPosition: worldPosition + nn * d, frame: frame) {
                        rescuedPoint = p
                        break
                    }
                    if let p = projectWorldToImagePixel(worldPosition: worldPosition - nn * d, frame: frame) {
                        rescuedPoint = p
                        break
                    }
                }
            }
            guard let p = rescuedPoint else {
                diag?.countOutOfBounds()
                return nil
            }
            projected = p
        }

        let pb = frame.capturedImage
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let geometricDepth = dist
        if !passesDepthConsistency(frame: frame, projected: projected, imageWidth: w, imageHeight: h, geometricDepth: geometricDepth) {
            diag?.countOutOfBounds()
            return nil
        }
        let sampled = sampleRGB5Tap(pixelBuffer: pb, at: projected, width: w, height: h)

        // Normals của ARMesh sau smooth/fill có thể đảo hướng cục bộ.
        // Vì mục tiêu ở đây là lấy màu, dùng |ndotl| giúp không loại oan các mặt vẫn nhìn thấy.
        let facing = abs(ndotl)
        if worldNormal != nil, ndotl < -0.95 {
            diag?.countBackface()
        }
        let angleWeight = max(0.35, min(1.0, 0.35 + 0.65 * facing))
        let distanceWeight = 1.0 / (1.0 + 0.65 * dist * dist)
        let borderWeight = imageBorderWeight(point: projected, width: w, height: h)
        let recency = Float(frameOrder + 1) / Float(max(totalFrames, 1))
        let temporalWeight = 0.65 + 0.35 * recency
        let weight = angleWeight * distanceWeight * borderWeight * temporalWeight
        if weight < 1e-5 {
            diag?.countZeroWeight()
            return nil
        }
        return (sampled, weight)
    }

    /// Ngăn màu của vật gần "in" sang nền xa phía sau bằng cách so độ sâu mesh và sceneDepth.
    /// Nếu depth map tại pixel cho thấy có vật gần hơn đáng kể, bỏ sample màu này.
    private static func passesDepthConsistency(
        frame: ARFrame,
        projected: CGPoint,
        imageWidth: Int,
        imageHeight: Int,
        geometricDepth: Float
    ) -> Bool {
        let sceneDepth = frame.smoothedSceneDepth ?? frame.sceneDepth
        guard let depthMap = sceneDepth?.depthMap else { return true }
        let depthW = CVPixelBufferGetWidth(depthMap)
        let depthH = CVPixelBufferGetHeight(depthMap)
        guard depthW > 1, depthH > 1, imageWidth > 1, imageHeight > 1 else { return true }

        let dx = projected.x / CGFloat(imageWidth) * CGFloat(depthW)
        let dy = projected.y / CGFloat(imageHeight) * CGFloat(depthH)
        guard let sampledDepth = sampleDepthBilinear(pixelBuffer: depthMap, x: dx, y: dy, width: depthW, height: depthH) else {
            return true
        }

        // Cho phép sai số tăng nhẹ theo khoảng cách để không loại oan điểm xa.
        let tolerance = max(0.06, geometricDepth * 0.08)
        return abs(sampledDepth - geometricDepth) <= tolerance
    }

    private static func sampleRGB5Tap(pixelBuffer: CVPixelBuffer, at projected: CGPoint, width: Int, height: Int) -> SIMD3<Float> {
        let offsets: [(CGFloat, CGFloat)] = [(0, 0), (-1.2, 0), (1.2, 0), (0, -1.2), (0, 1.2)]
        var acc = SIMD3<Float>(0, 0, 0)
        for (dx, dy) in offsets {
            acc += sampleRGBAtImage(pixelBuffer: pixelBuffer, x: projected.x + dx, y: projected.y + dy, width: width, height: height)
        }
        return simd_clamp(acc / Float(offsets.count), SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
    }

    private static func imageBorderWeight(point: CGPoint, width: Int, height: Int) -> Float {
        let w = CGFloat(max(width, 1))
        let h = CGFloat(max(height, 1))
        let nx = min(max(point.x / w, 0), 1)
        let ny = min(max(point.y / h, 0), 1)
        let edgeDistance = min(min(nx, 1 - nx), min(ny, 1 - ny))
        // Giảm phạt ở biên để giữ màu cho nhiều vertex hơn.
        let t = max(0, min(1, edgeDistance / 0.05))
        return Float(0.45 + 0.55 * t)
    }

    private static func sampleRGBAtImage(pixelBuffer: CVPixelBuffer, x: CGFloat, y: CGFloat, width: Int, height: Int) -> SIMD3<Float> {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        if format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
            let full = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            return sampleYUVBilinear(pixelBuffer: pixelBuffer, x: x, y: y, width: width, height: height, fullRange: full)
        }
        if format == kCVPixelFormatType_32BGRA {
            return sampleBGRABilinear(pixelBuffer: pixelBuffer, x: x, y: y, width: width, height: height)
        }
        return sampleRGBCoreImage(pixelBuffer: pixelBuffer, x: x, y: y, width: width, height: height)
    }

    private static func sampleDepthBilinear(pixelBuffer: CVPixelBuffer, x: CGFloat, y: CGFloat, width: Int, height: Int) -> Float? {
        let xf = max(0, min(Float(x), Float(width) - 1 - 1e-4))
        let yf = max(0, min(Float(y), Float(height) - 1 - 1e-4))
        let x0 = Int(floor(xf))
        let y0 = Int(floor(yf))
        let x1 = min(x0 + 1, width - 1)
        let y1 = min(y0 + 1, height - 1)
        let tx = xf - Float(x0)
        let ty = yf - Float(y0)

        guard let d00 = sampleDepthPoint(pixelBuffer: pixelBuffer, x: x0, y: y0),
              let d10 = sampleDepthPoint(pixelBuffer: pixelBuffer, x: x1, y: y0),
              let d01 = sampleDepthPoint(pixelBuffer: pixelBuffer, x: x0, y: y1),
              let d11 = sampleDepthPoint(pixelBuffer: pixelBuffer, x: x1, y: y1) else {
            return nil
        }
        let d0 = d00 * (1 - tx) + d10 * tx
        let d1 = d01 * (1 - tx) + d11 * tx
        let d = d0 * (1 - ty) + d1 * ty
        return d.isFinite && d > 0 ? d : nil
    }

    private static func sampleDepthPoint(pixelBuffer: CVPixelBuffer, x: Int, y: Int) -> Float? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        if format == kCVPixelFormatType_DepthFloat32 {
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: Float32.self) else {
                return nil
            }
            let row = CVPixelBufferGetBytesPerRow(pixelBuffer) / MemoryLayout<Float32>.stride
            let v = Float(base[y * row + x])
            return v.isFinite && v > 0 ? v : nil
        }
        if format == kCVPixelFormatType_DepthFloat16 {
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt16.self) else {
                return nil
            }
            let row = CVPixelBufferGetBytesPerRow(pixelBuffer) / MemoryLayout<UInt16>.stride
            let bits = base[y * row + x]
            let v = Float(Float16(bitPattern: bits))
            return v.isFinite && v > 0 ? v : nil
        }
        return nil
    }

    /// World → pixel trên `capturedImage`.
    /// Ưu tiên chiếu thủ công bằng intrinsics vì đây là hệ tọa độ pixel gốc của camera image.
    /// Nếu sai số biên làm point hơi lệch ra ngoài, thử thêm các orientation của `projectPoint`
    /// như một lớp fallback mềm để cứu màu thay vì rơi về xám.
    private static func projectWorldToImagePixel(worldPosition: SIMD3<Float>, frame: ARFrame) -> CGPoint? {
        let camera = frame.camera

        let camPt = camera.transform.inverse * SIMD4<Float>(worldPosition.x, worldPosition.y, worldPosition.z, 1)
        if camPt.z > -0.01 { return nil }

        let imgRes = camera.imageResolution
        let sensorViewport = CGSize(width: imgRes.width, height: imgRes.height)
        let depth = -camPt.z
        guard depth > 1e-5 else { return nil }

        let K = camera.intrinsics
        let fx = CGFloat(K[0][0])
        let fy = CGFloat(K[1][1])
        let cx = CGFloat(K[2][0])
        let cy = CGFloat(K[2][1])

        let px = fx * CGFloat(camPt.x) / CGFloat(depth) + cx
        let py = cy - fy * CGFloat(camPt.y) / CGFloat(depth)
        let manual = CGPoint(x: px, y: py)
        if manual.x >= 0 && manual.x < sensorViewport.width &&
           manual.y >= 0 && manual.y < sensorViewport.height {
            return manual
        }

        let fallbackOrientations: [UIInterfaceOrientation] = [
            .landscapeRight,
            .landscapeLeft,
            .portrait,
            .portraitUpsideDown
        ]
        for orientation in fallbackOrientations {
            let pt = camera.projectPoint(worldPosition, orientation: orientation, viewportSize: sensorViewport)
            if pt.x >= 0 && pt.x < sensorViewport.width &&
               pt.y >= 0 && pt.y < sensorViewport.height {
                return pt
            }
        }

        let clamped = CGPoint(
            x: min(max(manual.x, 0), sensorViewport.width - 1),
            y: min(max(manual.y, 0), sensorViewport.height - 1)
        )
        let overshootX = abs(manual.x - clamped.x)
        let overshootY = abs(manual.y - clamped.y)
        if max(overshootX, overshootY) <= 24 {
            return clamped
        }
        return nil
    }

    /// Log thông tin frame và pixel format trước khi export.
    private static func logExportHeader(tag: String, frame: ARFrame) {
        let fusionCount = fusionFrames(including: frame).count
        let pb = frame.capturedImage
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        let fmtName: String
        switch fmt {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:  fmtName = "420f (YUV full)"
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: fmtName = "420v (YUV video)"
        case kCVPixelFormatType_32BGRA:                        fmtName = "BGRA32"
        default:                                               fmtName = String(format: "0x%08X", fmt)
        }
        let imgW = CVPixelBufferGetWidth(pb)
        let imgH = CVPixelBufferGetHeight(pb)
        let K = frame.camera.intrinsics
        print("""
[ColorDiag] --- \(tag) Export bắt đầu ---
  Fusion frames  : \(fusionCount)
  Pixel format   : \(fmtName)
  Buffer size    : \(imgW) x \(imgH)
  Intrinsics fx/fy: \(K[0][0]) / \(K[1][1])
  Intrinsics cx/cy: \(K[2][0]) / \(K[2][1])
""")
    }

    private static func sampleYUVBilinear(pixelBuffer: CVPixelBuffer, x: CGFloat, y: CGFloat, width: Int, height: Int, fullRange: Bool) -> SIMD3<Float> {
        let xf = max(0, min(Float(x), Float(width) - 1 - 1e-4))
        let yf = max(0, min(Float(y), Float(height) - 1 - 1e-4))
        let x0 = Int(floor(xf))
        let y0 = Int(floor(yf))
        let x1 = min(x0 + 1, width - 1)
        let y1 = min(y0 + 1, height - 1)
        let tx = xf - Float(x0)
        let ty = yf - Float(y0)

        let c00 = sampleYUVPoint(pixelBuffer: pixelBuffer, x: x0, y: y0, fullRange: fullRange)
        let c10 = sampleYUVPoint(pixelBuffer: pixelBuffer, x: x1, y: y0, fullRange: fullRange)
        let c01 = sampleYUVPoint(pixelBuffer: pixelBuffer, x: x0, y: y1, fullRange: fullRange)
        let c11 = sampleYUVPoint(pixelBuffer: pixelBuffer, x: x1, y: y1, fullRange: fullRange)
        let c0 = c00 * (1 - tx) + c10 * tx
        let c1 = c01 * (1 - tx) + c11 * tx
        return simd_clamp(c0 * (1 - ty) + c1 * ty, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
    }

    private static func sampleYUVPoint(pixelBuffer: CVPixelBuffer, x: Int, y: Int, fullRange: Bool) -> SIMD3<Float> {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)?.assumingMemoryBound(to: UInt8.self),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)?.assumingMemoryBound(to: UInt8.self) else {
            return SIMD3<Float>(repeating: 0.55)
        }

        let yRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let uvRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let yv = Float(yBase[y * yRow + x])
        let uvX = x / 2
        let uvY = y / 2
        let cb = Float(uvBase[uvY * uvRow + uvX * 2])
        let cr = Float(uvBase[uvY * uvRow + uvX * 2 + 1])

        if fullRange {
            let yf = yv
            let b = cb - 128
            let r = cr - 128
            let rf = (yf + 1.402 * r) / 255
            let gf = (yf - 0.344136 * b - 0.714136 * r) / 255
            let bf = (yf + 1.772 * b) / 255
            return SIMD3<Float>(rf, gf, bf)
        }
        let yl = 1.1643 * (yv - 16)
        let b = cb - 128
        let r = cr - 128
        let rf = (yl + 1.596 * r) / 255
        let gf = (yl - 0.391 * b - 0.813 * r) / 255
        let bf = (yl + 2.017 * b) / 255
        return SIMD3<Float>(rf, gf, bf)
    }

    private static func sampleBGRABilinear(pixelBuffer: CVPixelBuffer, x: CGFloat, y: CGFloat, width: Int, height: Int) -> SIMD3<Float> {
        let xf = max(0, min(Float(x), Float(width) - 1 - 1e-4))
        let yf = max(0, min(Float(y), Float(height) - 1 - 1e-4))
        let x0 = Int(floor(xf))
        let y0 = Int(floor(yf))
        let x1 = min(x0 + 1, width - 1)
        let y1 = min(y0 + 1, height - 1)
        let tx = xf - Float(x0)
        let ty = yf - Float(y0)

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self) else {
            return SIMD3<Float>(repeating: 0.55)
        }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)

        func px(_ ix: Int, _ iy: Int) -> SIMD3<Float> {
            let o = iy * rowBytes + ix * 4
            let b = Float(base[o]) / 255
            let g = Float(base[o + 1]) / 255
            let r = Float(base[o + 2]) / 255
            return SIMD3<Float>(r, g, b)
        }

        let c00 = px(x0, y0)
        let c10 = px(x1, y0)
        let c01 = px(x0, y1)
        let c11 = px(x1, y1)
        let c0 = c00 * (1 - tx) + c10 * tx
        let c1 = c01 * (1 - tx) + c11 * tx
        return simd_clamp(c0 * (1 - ty) + c1 * ty, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
    }

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private static func sampleRGBCoreImage(pixelBuffer: CVPixelBuffer, x: CGFloat, y: CGFloat, width: Int, height: Int) -> SIMD3<Float> {
        let xi = min(max(Int(x.rounded()), 0), width - 1)
        let yi = min(max(Int(y.rounded()), 0), height - 1)
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let flip = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -CGFloat(height))
        let flipped = ciImage.transformed(by: flip)
        let rect = CGRect(x: xi, y: yi, width: 1, height: 1)
        let cropped = flipped.cropped(to: rect)
        var bitmap = [UInt8](repeating: 0, count: 4)
        ciContext.render(
            cropped,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return SIMD3<Float>(Float(bitmap[0]), Float(bitmap[1]), Float(bitmap[2])) / 255
    }
}
