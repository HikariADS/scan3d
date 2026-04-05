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
        var obj = "# LiDARDepth — vertex RGB từ camera (0–1), vn từ ARKit\n"
        var vertexBase = 1
        var normalBase = 1

        for anchor in meshAnchors {
            let geometry = anchor.geometry
            let verts = worldVertexPositions(geometry: geometry, transform: anchor.transform)
            let normalsOpt = worldNormalsIfAvailable(geometry: geometry, transform: anchor.transform)

            for v in verts {
                let c = sampleCameraColor(worldPosition: v, frame: frame, orientation: orientation)
                obj += String(format: "v %.6f %.6f %.6f %.6f %.6f %.6f\n", v.x, v.y, v.z, c.x, c.y, c.z)
            }

            if let normals = normalsOpt, normals.count == verts.count {
                for n in normals {
                    obj += String(format: "vn %.6f %.6f %.6f\n", n.x, n.y, n.z)
                }
            }

            let indices = triangleIndices(geometry: geometry)
            let vOffset = vertexBase
            let nOffset = normalBase
            let hasNormals = normalsOpt?.count == verts.count

            for i in stride(from: 0, to: indices.count, by: 3) {
                let i0 = Int(indices[i])
                let i1 = Int(indices[i + 1])
                let i2 = Int(indices[i + 2])
                if hasNormals {
                    obj += "f \(i0 + vOffset)//\(i0 + nOffset) \(i1 + vOffset)//\(i1 + nOffset) \(i2 + vOffset)//\(i2 + nOffset)\n"
                } else {
                    obj += "f \(i0 + vOffset) \(i1 + vOffset) \(i2 + vOffset)\n"
                }
            }

            vertexBase += verts.count
            if hasNormals {
                normalBase += verts.count
            }
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
            let verts = worldVertexPositions(geometry: geometry, transform: anchor.transform)
            for v in verts {
                let c = sampleCameraColor(worldPosition: v, frame: frame, orientation: orientation)
                positions.append(v)
                colors.append(c)
            }
            let indices = triangleIndices(geometry: geometry)
            for i in stride(from: 0, to: indices.count, by: 3) {
                let a = indexOffset + Int(indices[i])
                let b = indexOffset + Int(indices[i + 1])
                let c = indexOffset + Int(indices[i + 2])
                faces.append((a, b, c))
            }
            indexOffset += verts.count
        }

        var ply = "ply\nformat ascii 1.0\n"
        ply += "comment LiDARDepth — vertex RGB from camera\n"
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

    /// Projects world point into the current camera image and samples RGB (bilinear).
    private static func sampleCameraColor(worldPosition: SIMD3<Float>, frame: ARFrame, orientation: UIInterfaceOrientation) -> SIMD3<Float> {
        let cam = frame.camera.transform.inverse * SIMD4<Float>(worldPosition.x, worldPosition.y, worldPosition.z, 1)
        // Camera looks along -Z; surfaces in front have negative z.
        if cam.z > -0.02 {
            return SIMD3<Float>(repeating: 0.55)
        }

        let pb = frame.capturedImage
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let format = CVPixelBufferGetPixelFormatType(pb)

        guard let projected = projectWorldToImagePixel(worldPosition: worldPosition, frame: frame, orientation: orientation) else {
            return SIMD3<Float>(repeating: 0.55)
        }
        let x = projected.x
        let yTopLeft = projected.y

        if format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
            let full = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            return sampleYUVBilinear(pixelBuffer: pb, x: x, y: yTopLeft, width: w, height: h, fullRange: full)
        }
        if format == kCVPixelFormatType_32BGRA {
            return sampleBGRABilinear(pixelBuffer: pb, x: x, y: yTopLeft, width: w, height: h)
        }
        return sampleRGBCoreImage(pixelBuffer: pb, x: x, y: yTopLeft, width: w, height: h)
    }

    /// Pinhole projection with intrinsics, then map to pixel-buffer space using `displayTransform` inverse.
    private static func projectWorldToImagePixel(worldPosition: SIMD3<Float>, frame: ARFrame, orientation: UIInterfaceOrientation) -> CGPoint? {
        let camera = frame.camera
        let p = camera.transform.inverse * SIMD4<Float>(worldPosition.x, worldPosition.y, worldPosition.z, 1)
        if p.z > -0.02 { return nil }

        let K = camera.intrinsics
        let fx = K[0][0]
        let fy = K[1][1]
        let cx = K[2][0]
        let cy = K[2][1]
        let invZ = 1.0 / (-p.z)
        let u = fx * p.x * invZ + cx
        let v = fy * p.y * invZ + cy

        let imageResolution = camera.imageResolution
        let viewPoint = CGPoint(x: CGFloat(u), y: CGFloat(v))
        let displayTransform = frame.displayTransform(for: orientation, viewportSize: imageResolution)
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
