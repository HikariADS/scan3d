/*
 Abstract:
 Wavefront OBJ / PLY export from ARKit scene mesh, with per-vertex camera colors and normals.
 */

import ARKit
import CoreImage
import simd
import UIKit

enum ARMeshExporter {

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
        let orientation = activeInterfaceOrientation()
        var obj = "# LiDARDepth — vertex RGB (0–1); đỉnh đã qua Laplacian mịn (MeshLaplacianSmooth). Xcode OBJ: mở .glb/.ply để xem màu.\n"
        var vertexBase = 1
        var normalBase = 1

        for anchor in meshAnchors {
            let geometry = anchor.geometry
            var verts = worldVertexPositions(geometry: geometry, transform: anchor.transform)
            let indices = triangleIndices(geometry: geometry)
            MeshLaplacianSmooth.smoothUniform(positions: &verts, triangleIndices: indices)
            let normalsSmooth = MeshLaplacianSmooth.vertexNormals(positions: verts, triangleIndices: indices)

            for i in 0..<verts.count {
                let v = verts[i]
                let n = normalsSmooth[i]
                let c = sampleCameraColor(worldPosition: v, worldNormal: n, frame: frame, orientation: orientation)
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
        return obj
    }

    private static func buildColoredPLYString(meshAnchors: [ARMeshAnchor], frame: ARFrame) -> String {
        let orientation = activeInterfaceOrientation()
        var positions: [SIMD3<Float>] = []
        var colors: [SIMD3<Float>] = []
        var faces: [(Int, Int, Int)] = []
        var indexOffset = 0

        for anchor in meshAnchors {
            let geometry = anchor.geometry
            var verts = worldVertexPositions(geometry: geometry, transform: anchor.transform)
            let indices = triangleIndices(geometry: geometry)
            MeshLaplacianSmooth.smoothUniform(positions: &verts, triangleIndices: indices)
            let normalsSmooth = MeshLaplacianSmooth.vertexNormals(positions: verts, triangleIndices: indices)
            for i in 0..<verts.count {
                let v = verts[i]
                let n = normalsSmooth[i]
                let c = sampleCameraColor(worldPosition: v, worldNormal: n, frame: frame, orientation: orientation)
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
        return ply
    }

    // MARK: - glTF 2.0 GLB (faceted, per-triangle color)

    private static func buildFacetedGLB(meshAnchors: [ARMeshAnchor], frame: ARFrame) -> Data? {
        let orientation = activeInterfaceOrientation()
        var positions: [Float] = []
        var normals: [Float] = []
        var colors: [Float] = []

        for anchor in meshAnchors {
            let geometry = anchor.geometry
            var verts = worldVertexPositions(geometry: geometry, transform: anchor.transform)
            let indices = triangleIndices(geometry: geometry)
            MeshLaplacianSmooth.smoothUniform(positions: &verts, triangleIndices: indices)
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
                let c = sampleCameraColor(worldPosition: center, worldNormal: fn, frame: frame, orientation: orientation)
                for p in [p0, p1, p2] {
                    positions.append(contentsOf: [p.x, p.y, p.z])
                    normals.append(contentsOf: [fn.x, fn.y, fn.z])
                    colors.append(contentsOf: [c.x, c.y, c.z])
                }
            }
        }
        let vertexCount = positions.count / 3
        guard vertexCount > 0 else { return nil }
        return encodeGLB(positions: positions, normals: normals, colors: colors, vertexCount: vertexCount)
    }

    /// glTF 2.0: `ARRAY_BUFFER` / `ELEMENT_ARRAY_BUFFER` (OpenGL ES constants).
    private static let gltfArrayBuffer: Int = 34962

    private static func encodeGLB(positions: [Float], normals: [Float], colors: [Float], vertexCount: Int) -> Data {
        let posData = positions.withUnsafeBufferPointer { Data(buffer: $0) }
        let normData = normals.withUnsafeBufferPointer { Data(buffer: $0) }
        let colorData = colors.withUnsafeBufferPointer { Data(buffer: $0) }

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

        // Root `extensionsUsed` (not under `asset`). Buffer views for vertex attributes need `target` 34962.
        let json: String = """
        {"asset":{"version":"2.0","generator":"LiDARDepth"},"extensionsUsed":["KHR_materials_unlit"],"scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"mesh":0}],"meshes":[{"primitives":[{"attributes":{"POSITION":0,"NORMAL":1,"COLOR_0":2},"material":0}]}],"materials":[{"doubleSided":true,"pbrMetallicRoughness":{"baseColorFactor":[1,1,1,1],"metallicFactor":0,"roughnessFactor":1},"extensions":{"KHR_materials_unlit":{}}}],"buffers":[{"byteLength":\(bufferByteLength)}],"bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":\(posData.count),"target":\(tgt)},{"buffer":0,"byteOffset":\(p0),"byteLength":\(normData.count),"target":\(tgt)},{"buffer":0,"byteOffset":\(p1),"byteLength":\(colorData.count),"target":\(tgt)}],"accessors":[{"bufferView":0,"componentType":5126,"count":\(vertexCount),"type":"VEC3","min":[\(minP.x),\(minP.y),\(minP.z)],"max":[\(maxP.x),\(maxP.y),\(maxP.z)]},{"bufferView":1,"componentType":5126,"count":\(vertexCount),"type":"VEC3"},{"bufferView":2,"componentType":5126,"count":\(vertexCount),"type":"VEC3"}]}
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

    /// Samples vertex color: facing check + 5-tap cross filter (reduces speckle). True texture needs UV / multi-view fusion.
    private static func sampleCameraColor(worldPosition: SIMD3<Float>, worldNormal: SIMD3<Float>?, frame: ARFrame, orientation: UIInterfaceOrientation) -> SIMD3<Float> {
        let cam = frame.camera.transform.inverse * SIMD4<Float>(worldPosition.x, worldPosition.y, worldPosition.z, 1)
        if cam.z > -0.01 {
            return SIMD3<Float>(repeating: 0.55)
        }

        // Chỉ bỏ mặt sau thật (normal ngược hướng camera). Ngưỡng 0.06 trước đây khiến gần hết đỉnh thành xám.
        if let n = worldNormal {
            let camT = frame.camera.transform
            let camPos = SIMD3<Float>(camT.columns.3.x, camT.columns.3.y, camT.columns.3.z)
            let toCamera = simd_normalize(camPos - worldPosition)
            let ndotl = simd_dot(simd_normalize(n), toCamera)
            if ndotl < 0 {
                return SIMD3<Float>(repeating: 0.5)
            }
        }

        guard let projected = projectWorldToImagePixel(worldPosition: worldPosition, frame: frame, orientation: orientation) else {
            return SIMD3<Float>(repeating: 0.55)
        }

        let pb = frame.capturedImage
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)

        let offsets: [(CGFloat, CGFloat)] = [(0, 0), (-1.5, 0), (1.5, 0), (0, -1.5), (0, 1.5)]
        var acc = SIMD3<Float>(0, 0, 0)
        for (dx, dy) in offsets {
            acc += sampleRGBAtImage(pixelBuffer: pb, x: projected.x + dx, y: projected.y + dy, width: w, height: h)
        }
        return simd_clamp(acc / 5, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
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

    /// World → điểm trên `capturedImage` để lấy mẫu YUV/BGRA.
    /// `projectPoint` cho tọa độ viewport (đúng orientation); `displayTransform` nối viewport → buffer pixel (sensor thường “ngang” so với cầm dọc).
    private static func projectWorldToImagePixel(worldPosition: SIMD3<Float>, frame: ARFrame, orientation: UIInterfaceOrientation) -> CGPoint? {
        let camera = frame.camera
        let p = camera.transform.inverse * SIMD4<Float>(worldPosition.x, worldPosition.y, worldPosition.z, 1)
        if p.z > -0.01 { return nil }

        let resolution = camera.imageResolution
        let viewport = CGSize(width: resolution.width, height: resolution.height)
        let viewPoint = camera.projectPoint(worldPosition, orientation: orientation, viewportSize: viewport)
        let displayTransform = frame.displayTransform(for: orientation, viewportSize: viewport)
        return viewPoint.applying(displayTransform.inverted())
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
