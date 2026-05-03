/*
 Abstract:
 Wavefront OBJ / PLY export from ARKit scene mesh, with per-vertex camera colors and normals.
 */

import ARKit
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import simd
import UIKit
import UniformTypeIdentifiers

// MARK: - Fusion colour pipeline (do NOT store ARFrame in arrays — ARSession retains ≤~4 camera buffers)

/// HEIC (10-bit friendly, fewer block artefacts than JPEG) or JPEG fallback for snapshot blobs.
private enum FusionSnapshotImageCodec: UInt8 {
    case heic = 0
    case jpeg = 1
}

/// Downsampled depth stored with each snapshot so historical frames can run the same median occlusion
/// without holding full `CVPixelBuffer` history. ~96×72×2 B ≈ 14 KiB per frame (memory-safe vs full maps).
private struct FusionPackedMiniDepth: Equatable {
    let gridW: Int
    let gridH: Int
    /// Row-major UInt16 depth in millimetres (LE). `0` = invalid / unknown.
    let millimetresLE: Data

    private static let maxGridW = 96
    private static let maxGridH = 72

    /// Pack from ARKit depth map (float metres). Coordinates align to `imageWidth`×`imageHeight` pixel grid.
    static func encode(depthMap: CVPixelBuffer, imageWidth: Int, imageHeight: Int) -> FusionPackedMiniDepth? {
        let dw = CVPixelBufferGetWidth(depthMap)
        let dh = CVPixelBufferGetHeight(depthMap)
        guard dw > 1, dh > 1, imageWidth > 1, imageHeight > 1 else { return nil }

        let gw = min(maxGridW, max(8, dw / 4))
        let gh = min(maxGridH, max(6, dh / 4))

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        var raw = Data(count: gw * gh * MemoryLayout<UInt16>.size)
        raw.withUnsafeMutableBytes { dst in
            guard let base = dst.baseAddress else { return }
            let out = base.assumingMemoryBound(to: UInt16.self)
            for gy in 0..<gh {
                for gx in 0..<gw {
                    let xDepth = Int((Float(gx) + 0.5) / Float(gw) * Float(dw - 1))
                    let yDepth = Int((Float(gy) + 0.5) / Float(gh) * Float(dh - 1))
                    let d = sampleDepthFloatMetres(depthMap: depthMap, x: xDepth, y: yDepth)
                    let mm: UInt16
                    if let d, d.isFinite, d > 0.02, d < 80 {
                        mm = UInt16(min(65535, max(1, d * 1000)))
                    } else {
                        mm = 0
                    }
                    out[gy * gw + gx] = mm.littleEndian
                }
            }
        }
        return FusionPackedMiniDepth(gridW: gw, gridH: gh, millimetresLE: raw)
    }

    func asBinaryPayload() -> Data {
        var h = Data()
        var w16 = UInt16(gridW).littleEndian
        var h16 = UInt16(gridH).littleEndian
        withUnsafeBytes(of: &w16) { h.append(contentsOf: $0) }
        withUnsafeBytes(of: &h16) { h.append(contentsOf: $0) }
        h.append(millimetresLE)
        return h
    }

    static func fromBinaryPayload(_ data: Data) -> FusionPackedMiniDepth? {
        guard data.count >= 4 else { return nil }
        let gw = Int(UInt16(littleEndian: data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt16.self) }))
        let gh = Int(UInt16(littleEndian: data.withUnsafeBytes { $0.load(fromByteOffset: 2, as: UInt16.self) }))
        guard gw >= 4, gh >= 4, gw <= maxGridW, gh <= maxGridH else { return nil }
        let expect = 4 + gw * gh * 2
        guard data.count == expect else { return nil }
        let body = data.subdata(in: 4..<expect)
        return FusionPackedMiniDepth(gridW: gw, gridH: gh, millimetresLE: body)
    }

    private static func sampleDepthFloatMetres(depthMap: CVPixelBuffer, x: Int, y: Int) -> Float? {
        let format = CVPixelBufferGetPixelFormatType(depthMap)
        if format == kCVPixelFormatType_DepthFloat32 {
            guard let base = CVPixelBufferGetBaseAddress(depthMap)?.assumingMemoryBound(to: Float32.self) else { return nil }
            let row = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.stride
            let v = Float(base[y * row + x])
            return v.isFinite && v > 0 ? v : nil
        }
        if format == kCVPixelFormatType_DepthFloat16 {
            guard let base = CVPixelBufferGetBaseAddress(depthMap)?.assumingMemoryBound(to: UInt16.self) else { return nil }
            let row = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<UInt16>.stride
            let v = Float(Float16(bitPattern: base[y * row + x]))
            return v.isFinite && v > 0 ? v : nil
        }
        return nil
    }
}

/// 16-bin luma histogram → 17-point CDF for cheap per-pixel tone matching (reference = first live frame in fusion).
private enum FusionLumaHistogram {
    private static let binCount = 16

    static func linearIdentityCDF() -> ContiguousArray<Float> {
        var c = ContiguousArray<Float>()
        c.reserveCapacity(17)
        for i in 0...binCount {
            c.append(Float(i) / Float(binCount))
        }
        return c
    }

    static func cdf17(from pixelBuffer: CVPixelBuffer) -> ContiguousArray<Float> {
        var bins = [Float](repeating: 0, count: binCount)
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        var total: Float = 0
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            if let baseY = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)?.assumingMemoryBound(to: UInt8.self) {
                let pw = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
                let ph = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
                let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
                let step = max(6, min(pw, ph) / 48)
                for y in stride(from: 0, to: ph, by: step) {
                    for x in stride(from: 0, to: pw, by: step) {
                        let yv = Float(baseY[y * rowBytes + x]) / 255.0
                        addSample(yv, into: &bins, total: &total)
                    }
                }
            }
        case kCVPixelFormatType_32BGRA:
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self) {
                let pw = CVPixelBufferGetWidth(pixelBuffer)
                let ph = CVPixelBufferGetHeight(pixelBuffer)
                let bpp = CVPixelBufferGetBytesPerRow(pixelBuffer)
                let step = max(6, min(pw, ph) / 48)
                for y in stride(from: 0, to: ph, by: step) {
                    for x in stride(from: 0, to: pw, by: step) {
                        let o = y * bpp + x * 4
                        let b = Float(base[o]), g = Float(base[o + 1]), r = Float(base[o + 2])
                        let yv = simd_clamp(0.0722 * b + 0.7152 * g + 0.2126 * r, 0, 255) / 255.0
                        addSample(yv, into: &bins, total: &total)
                    }
                }
            }
        default:
            break
        }
        if total < 1 {
            return linearIdentityCDF()
        }
        var cdf = ContiguousArray<Float>()
        cdf.reserveCapacity(17)
        cdf.append(0)
        var acc: Float = 0
        for i in 0..<binCount {
            acc += bins[i] / total
            cdf.append(min(1, acc))
        }
        if cdf[binCount] < 0.999 {
            cdf[binCount] = 1
        }
        return cdf
    }

    private static func addSample(_ yv: Float, into bins: inout [Float], total: inout Float) {
        let b = min(binCount - 1, Int(yv * Float(binCount)))
        bins[b] += 1
        total += 1
    }

    /// Map scalar luma through source CDF into reference CDF (histogram match, O(bin) inverse).
    static func matchLuma(_ y: Float, cdfSource: ContiguousArray<Float>, cdfRef: ContiguousArray<Float>) -> Float {
        guard cdfSource.count == 17, cdfRef.count == 17 else { return y }
        let yy = simd_clamp(y, 0, 1)
        let f = yy * Float(binCount)
        let i0 = min(binCount - 1, max(0, Int(floor(f))))
        let i1 = min(binCount, i0 + 1)
        let t = f - Float(i0)
        let u = cdfSource[i0] * (1 - t) + cdfSource[i1] * t
        // Invert ref CDF
        var k = 0
        while k < binCount, cdfRef[k + 1] < u {
            k += 1
        }
        let u0 = cdfRef[k]
        let u1 = cdfRef[k + 1]
        let span = max(u1 - u0, 1e-6)
        let tf = simd_clamp((u - u0) / span, 0, 1)
        return (Float(k) + tf) / Float(binCount)
    }
}

/// Live or decoded snapshot — used for projection + RGB sampling without holding `ARFrame` in history.
private protocol ColorFusionFrame: AnyObject {
    var fusionTimestamp: TimeInterval { get }
    var fusionCameraTransform: simd_float4x4 { get }
    var fusionIntrinsics: simd_float3x3 { get }
    var fusionImageResolution: CGSize { get }
    var fusionCapturedImage: CVPixelBuffer { get }
    /// Live LiDAR depth at full resolution when available.
    var fusionDepthMap: CVPixelBuffer? { get }
    /// Coarse depth captured with each snapshot (historical frames); live adapter returns nil (uses `fusionDepthMap`).
    var fusionPackedMiniDepth: FusionPackedMiniDepth? { get }
    /// 17-point cumulative luma distribution (0…1) for histogram matching.
    var fusionLumaCDF: ContiguousArray<Float> { get }
    /// ~0–1 from coarse Laplacian energy; lowers weight when frame is blurry.
    var fusionImageSharpness01: Float { get }
    /// Approx mean scene luminance 0–1 for mild exposure normalization before fusion.
    var fusionMeanLuminance01: Float { get }
}

private final class ARFrameFusionAdapter: ColorFusionFrame {
    let frame: ARFrame
    private let metricsLuma01: Float
    private let metricsSharp01: Float
    private let cdf: ContiguousArray<Float>

    init(_ frame: ARFrame) {
        self.frame = frame
        let m = FrameImageMetrics.compute(frame.capturedImage)
        metricsLuma01 = m.meanLuma01
        metricsSharp01 = m.sharpness01
        cdf = FusionLumaHistogram.cdf17(from: frame.capturedImage)
    }
    var fusionTimestamp: TimeInterval { frame.timestamp }
    var fusionCameraTransform: simd_float4x4 { frame.camera.transform }
    var fusionIntrinsics: simd_float3x3 { frame.camera.intrinsics }
    var fusionImageResolution: CGSize { frame.camera.imageResolution }
    var fusionCapturedImage: CVPixelBuffer { frame.capturedImage }
    var fusionDepthMap: CVPixelBuffer? {
        frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap
    }
    var fusionPackedMiniDepth: FusionPackedMiniDepth? { nil }
    var fusionLumaCDF: ContiguousArray<Float> { cdf }
    var fusionImageSharpness01: Float { metricsSharp01 }
    var fusionMeanLuminance01: Float { metricsLuma01 }
}

private final class DecodedStillFusionAdapter: ColorFusionFrame {
    let fusionTimestamp: TimeInterval
    let fusionCameraTransform: simd_float4x4
    let fusionIntrinsics: simd_float3x3
    let fusionImageResolution: CGSize
    let fusionCapturedImage: CVPixelBuffer
    private let metricsLuma01: Float
    private let metricsSharp01: Float
    private let cdf: ContiguousArray<Float>
    let fusionPackedMiniDepth: FusionPackedMiniDepth?
    var fusionDepthMap: CVPixelBuffer? { nil }

    init?(
        timestamp: TimeInterval,
        transform: simd_float4x4,
        intrinsics: simd_float3x3,
        resolution: CGSize,
        imageBlob: Data,
        codec: FusionSnapshotImageCodec,
        meanLuma01: Float,
        sharpness01: Float,
        lumaCDF: ContiguousArray<Float>,
        miniDepth: FusionPackedMiniDepth?
    ) {
        guard let pb = FusionStillImageDecode.pixelBufferBGRA(from: imageBlob, codec: codec) else { return nil }
        fusionTimestamp = timestamp
        fusionCameraTransform = transform
        fusionIntrinsics = intrinsics
        fusionImageResolution = resolution
        fusionCapturedImage = pb
        metricsLuma01 = meanLuma01
        metricsSharp01 = sharpness01
        cdf = lumaCDF.isEmpty ? FusionLumaHistogram.linearIdentityCDF() : lumaCDF
        fusionPackedMiniDepth = miniDepth
    }
    var fusionImageSharpness01: Float { metricsSharp01 }
    var fusionMeanLuminance01: Float { metricsLuma01 }
    var fusionLumaCDF: ContiguousArray<Float> { cdf }
}

private enum FusionStillImageDecode {
    static func pixelBufferBGRA(from data: Data, codec: FusionSnapshotImageCodec) -> CVPixelBuffer? {
        _ = codec // HEIC and JPEG both decode via UIImage; codec reserved for future fast paths
        guard let image = UIImage(data: data), let cg = image.cgImage else { return nil }
        let w = cg.width
        let h = cg.height
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
              let pb = pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb),
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return pb
    }
}

/// Lấy **trung bình luma + proxy độ nét** (mean |Laplacian| trên grid thưa). Rẻ đủ để gọi mỗi lần record snapshot / fresh cache.
private enum FrameImageMetrics {
    static func compute(_ pixelBuffer: CVPixelBuffer) -> (meanLuma01: Float, sharpness01: Float) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return computeYPlane420(pixelBuffer)
        case kCVPixelFormatType_32BGRA:
            return computeBGRA(pixelBuffer)
        default:
            return (0.42, 0.45)
        }
    }

    private static func clamp01(_ x: Float) -> Float {
        simd_clamp(x, 0, 1)
    }

    /// Trung bình luma grid + coarse Laplacian energy → map qua tanh vào ~0–1.
    private static func computeYPlane420(_ pb: CVPixelBuffer) -> (meanLuma01: Float, sharpness01: Float) {
        guard let baseY = CVPixelBufferGetBaseAddressOfPlane(pb, 0)?.assumingMemoryBound(to: UInt8.self) else {
            return (0.42, 0.45)
        }
        let pw = CVPixelBufferGetWidthOfPlane(pb, 0)
        let ph = CVPixelBufferGetHeightOfPlane(pb, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        guard pw > 4, ph > 4 else { return (0.42, 0.45) }

        let stepMean = max(8, pw / 64)
        let stepL = max(4, pw / 96)
        var lumSum: Float = 0
        var lumCnt: Int = 0
        for y in stride(from: 0, to: ph, by: stepMean) {
            let row = y * rowBytes
            for x in stride(from: 0, to: pw, by: stepMean) {
                lumSum += Float(baseY[row + x]) / 255.0
                lumCnt += 1
            }
        }
        let meanL = lumCnt > 0 ? lumSum / Float(lumCnt) : 0.42

        var lapE: Float = 0
        var lapCnt: Int = 0
        for y in stride(from: stepL, to: ph - stepL, by: stepL) {
            for x in stride(from: stepL, to: pw - stepL, by: stepL) {
                let c = Float(baseY[y * rowBytes + x])
                let l = Float(baseY[y * rowBytes + (x - stepL)])
                let r = Float(baseY[y * rowBytes + (x + stepL)])
                let u = Float(baseY[(y - stepL) * rowBytes + x])
                let d = Float(baseY[(y + stepL) * rowBytes + x])
                lapE += abs(4 * c - l - r - u - d) / max(512, 255 * Float(stepL))
                lapCnt += 1
            }
        }
        let rawSharp = lapCnt > 0 ? lapE / Float(lapCnt) : 0
        let sharp = clamp01(1 - exp(-rawSharp * 3.8))
        return (meanL, sharp)
    }

    private static func computeBGRA(_ pb: CVPixelBuffer) -> (meanLuma01: Float, sharpness01: Float) {
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else {
            return (0.42, 0.45)
        }
        let pw = CVPixelBufferGetWidth(pb)
        let ph = CVPixelBufferGetHeight(pb)
        let bpp = CVPixelBufferGetBytesPerRow(pb)
        guard pw > 2, ph > 2 else { return (0.42, 0.45) }

        func gray(_ x: Int, _ y: Int) -> Float {
            let o = y * bpp + x * 4
            let b = Float(base[o]), g = Float(base[o + 1]), r = Float(base[o + 2])
            return simd_clamp(0.0722 * b + 0.7152 * g + 0.2126 * r, 0, 255) / 255.0
        }

        let stepMean = max(8, pw / 56)
        var lumSum: Float = 0
        var lumCnt = 0
        for y in stride(from: 0, to: ph, by: stepMean) {
            for x in stride(from: 0, to: pw, by: stepMean) {
                lumSum += gray(x, y)
                lumCnt += 1
            }
        }
        let meanL = lumCnt > 0 ? lumSum / Float(lumCnt) : 0.42

        let stepL = max(3, pw / 80)
        var lapE: Float = 0
        var lapCnt = 0
        for y in stride(from: stepL, to: ph - stepL, by: stepL) {
            for x in stride(from: stepL, to: pw - stepL, by: stepL) {
                let cf = gray(x, y) * 255
                let lf = gray(x - stepL, y) * 255
                let rf = gray(x + stepL, y) * 255
                let uf = gray(x, y - stepL) * 255
                let df = gray(x, y + stepL) * 255
                lapE += abs(4 * cf - lf - rf - uf - df) / max(512, 255 * Float(stepL))
                lapCnt += 1
            }
        }
        let rawSharp = lapCnt > 0 ? lapE / Float(lapCnt) : 0
        let sharp = clamp01(1 - exp(-rawSharp * 3.8))
        return (meanL, sharp)
    }
}

// MARK: - Debug diagnostics

/// Thread-safe counters cho mỗi lần export. Reset trước mỗi lần build.
private final class ColorDiag: @unchecked Sendable {
    private let q = DispatchQueue(label: "ColorDiag")
    private var _total = 0
    private var _gotColor = 0
    private var _fallbackBehindCam = 0
    private var _fallbackBackface = 0
    private var _fallbackOutOfBounds = 0
    private var _fallbackDepthMismatch = 0
    private var _fallbackNoFrames = 0
    private var _fallbackZeroWeight = 0
    private var _sumColor = SIMD3<Float>(repeating: 0)
    private var _sumLuma: Float = 0
    private var _sumSaturation: Float = 0
    private var _minLuma: Float = 1
    private var _maxLuma: Float = 0
    private var _sumWeight: Float = 0
    private var _sumBestWeight: Float = 0
    private var _fusionSamples = 0

    func countVertex()           { q.sync { _total += 1} }
    func countColor()            { q.sync { _gotColor += 1 } }
    func countBehindCam()        { q.sync { _fallbackBehindCam += 1 } }
    func countBackface()         { q.sync { _fallbackBackface += 1 } }
    func countOutOfBounds()      { q.sync { _fallbackOutOfBounds += 1 } }
    func countDepthMismatch()    { q.sync { _fallbackDepthMismatch += 1 } }
    func countNoFrames()         { q.sync { _fallbackNoFrames += 1 } }
    func countZeroWeight()       { q.sync { _fallbackZeroWeight += 1 } }
    func recordResolvedColor(_ color: SIMD3<Float>) {
        q.sync {
            _sumColor += color
            let luma = simd_dot(color, SIMD3<Float>(0.2126, 0.7152, 0.0722))
            let maxC = max(color.x, max(color.y, color.z))
            let minC = min(color.x, min(color.y, color.z))
            _sumLuma += luma
            _sumSaturation += maxC - minC
            _minLuma = min(_minLuma, luma)
            _maxLuma = max(_maxLuma, luma)
        }
    }
    func recordFusion(weight: Float, bestWeight: Float) {
        q.sync {
            _sumWeight += weight
            _sumBestWeight += bestWeight
            _fusionSamples += 1
        }
    }

    func printSummary(tag: String) {
        q.sync {
            let gray = _total - _gotColor
            let avgColor = _gotColor > 0 ? _sumColor / Float(_gotColor) : SIMD3<Float>(repeating: 0)
            let avgLuma = _gotColor > 0 ? _sumLuma / Float(_gotColor) : 0
            let avgSaturation = _gotColor > 0 ? _sumSaturation / Float(_gotColor) : 0
            let avgWeight = _fusionSamples > 0 ? _sumWeight / Float(_fusionSamples) : 0
            let avgBestWeight = _fusionSamples > 0 ? _sumBestWeight / Float(_fusionSamples) : 0
            print("""
[ColorDiag] === \(tag) ===
  Tổng vertices  : \(_total)
  Có màu thật   : \(_gotColor) (\(pct(_gotColor, _total))%)
  Xám fallback   : \(gray) (\(pct(gray, _total))%)
  Avg RGB        : \(fmt(avgColor.x)) / \(fmt(avgColor.y)) / \(fmt(avgColor.z))
  Avg luma/sat   : \(fmt(avgLuma)) / \(fmt(avgSaturation))
  Luma min-max   : \(fmt(_minLuma)) ... \(fmt(_maxLuma))
  Avg weight     : \(fmt(avgWeight)) (best \(fmt(avgBestWeight)))
    behind cam   : \(_fallbackBehindCam)
    backface ext  : \(_fallbackBackface)
    out of bounds : \(_fallbackOutOfBounds)
    depth mismatch: \(_fallbackDepthMismatch)
    weight thap   : \(_fallbackZeroWeight)
    no frames     : \(_fallbackNoFrames)
""")
        }
    }

    private func pct(_ n: Int, _ d: Int) -> String {
        guard d > 0 else { return "0" }
        return String(format: "%.1f", Float(n) / Float(d) * 100)
    }

    private func fmt(_ value: Float) -> String {
        String(format: "%.3f", value)
    }
}

private final class TextureDiag {
    private var totalVertices = 0
    private var mappedVertices = 0
    private var relaxedMappedVertices = 0
    private var unmappedVertices = 0
    private var rejectedOutOfBounds = 0
    private var rejectedDepthMismatch = 0
    private var rejectedFacing = 0
    private var scoreSum: Float = 0
    private var scoreMin: Float = .greatestFiniteMagnitude
    private var scoreMax: Float = 0
    private var uvMin = SIMD2<Float>(repeating: 1)
    private var uvMax = SIMD2<Float>(repeating: 0)
    private var frameUsage: [Int: Int] = [:]

    func countVertex() {
        totalVertices += 1
    }

    func countMapped(frameIndex: Int, score: Float, u: Float, v: Float, relaxed: Bool) {
        mappedVertices += 1
        if relaxed {
            relaxedMappedVertices += 1
        }
        scoreSum += score
        scoreMin = min(scoreMin, score)
        scoreMax = max(scoreMax, score)
        uvMin = simd_min(uvMin, SIMD2<Float>(u, v))
        uvMax = simd_max(uvMax, SIMD2<Float>(u, v))
        frameUsage[frameIndex, default: 0] += 1
    }

    func countUnmapped() {
        unmappedVertices += 1
    }

    func countOutOfBounds() {
        rejectedOutOfBounds += 1
    }

    func countDepthMismatch() {
        rejectedDepthMismatch += 1
    }

    func countFacingRejected() {
        rejectedFacing += 1
    }

    func printSummary(tag: String, atlasFrameCount: Int, atlasSize: CGSize, jpegBytes: Int) {
        let avgScore = mappedVertices > 0 ? scoreSum / Float(mappedVertices) : 0
        let scoreMinValue = mappedVertices > 0 ? scoreMin : 0
        let scoreMaxValue = mappedVertices > 0 ? scoreMax : 0
        let usage = frameUsage.keys.sorted().map { "#\($0):\(frameUsage[$0] ?? 0)" }.joined(separator: ", ")
        print("""
[TextureDiag] === \(tag) ===
  Atlas frames    : \(atlasFrameCount)
  Atlas size      : \(Int(atlasSize.width)) x \(Int(atlasSize.height))
  JPEG size       : \(jpegBytes / 1024) KB
  UV mapped       : \(mappedVertices) / \(totalVertices) (\(pct(mappedVertices, totalVertices))%)
  UV relaxed      : \(relaxedMappedVertices)
  UV fallback     : \(unmappedVertices)
  Score avg/min/max: \(fmt(avgScore)) / \(fmt(scoreMinValue)) / \(fmt(scoreMaxValue))
  UV bounds       : u \(fmt(uvMin.x))...\(fmt(uvMax.x)), v \(fmt(uvMin.y))...\(fmt(uvMax.y))
  Rejected OOB    : \(rejectedOutOfBounds)
  Rejected depth  : \(rejectedDepthMismatch)
  Rejected facing : \(rejectedFacing)
  Frame usage     : \(usage.isEmpty ? "none" : usage)
""")
    }

    private func pct(_ n: Int, _ d: Int) -> String {
        guard d > 0 else { return "0" }
        return String(format: "%.1f", Float(n) / Float(d) * 100)
    }

    private func fmt(_ value: Float) -> String {
        String(format: "%.3f", value)
    }
}

enum ARMeshExporter {
    enum ExportSubject: String, CaseIterable, Identifiable {
        case room
        case nearbyObject
        case ultraDetailObject

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .room: return "Không gian"
            case .nearbyObject: return "Vật gần"
            case .ultraDetailObject: return "Siêu chi tiết"
            }
        }
    }

    struct ExportProfile {
        let subject: ExportSubject

        var objectMinDistance: Float { 0.08 }
        var objectMaxDistance: Float {
            switch subject {
            case .room: return 6.0
            case .nearbyObject: return 2.2
            case .ultraDetailObject: return 1.1
            }
        }
        var depthToleranceBase: Float {
            switch subject {
            case .room: return 0.26
            case .nearbyObject: return 0.14
            case .ultraDetailObject: return 0.10
            }
        }
        var depthToleranceScale: Float {
            switch subject {
            case .room: return 0.24
            case .nearbyObject: return 0.14
            case .ultraDetailObject: return 0.11
            }
        }
        /// Median(depth 3×3) phải tương thích mesh; gap lớn → nhiều noisy/hole → bỏ vì hay gây smear texture.
        var maxMedianDepthNeighborSpreadMeters: Float {
            switch subject {
            case .room: return 0.38
            case .nearbyObject: return 0.28
            case .ultraDetailObject: return 0.20
            }
        }
        /// **`exp(-k * distance²)` trong weight fusion** — k lớn = ưu tiên máy ảnh gần. Khi `dist² = 1/k` thì Gaussian ≈ 1/e (~37%).
        /// Gợi ý chỉnh: lia nhanh mà xa → giảm k; chỉ có view xa → giảm k.
        var fusionGaussianDistanceK: Float {
            switch subject {
            case .room: return 0.24
            case .nearbyObject: return 0.38
            case .ultraDetailObject: return 0.55
            }
        }
        /// `weight *= 1 + scale * clipped(gradient)`. Tăng scale = ưu tiên mép/ghi chi tiết; quá cao ↔ nhiễu JPEG.
        var fusionEdgeBoostScale: Float {
            switch subject {
            case .room: return 0.42
            case .nearbyObject: return 0.56
            case .ultraDetailObject: return 0.79
            }
        }
        /// JPEG history không có LiDAR map — chỉ góp nếu bề mặt khá frontal (substitute occlusion).
        var fusionMinFrontalContributionNoLiDAR: Float {
            switch subject {
            case .room: return 0.26
            case .nearbyObject: return 0.34
            case .ultraDetailObject: return 0.42
            }
        }
        var textureJPEGQuality: CGFloat {
            switch subject {
            case .room: return 0.92
            case .nearbyObject: return 0.98
            case .ultraDetailObject: return 1.0
            }
        }
        var atlasFrameCount: Int {
            switch subject {
            case .room: return 6
            case .nearbyObject: return 4
            case .ultraDetailObject: return 16
            }
        }
        var prefersAggressiveOcclusion: Bool {
            subject != .room
        }
        var centerBias: Float {
            switch subject {
            case .room: return 0.0
            case .nearbyObject: return 0.35
            case .ultraDetailObject: return 1.10
            }
        }
        var bestFrameBlend: Float {
            switch subject {
            case .room: return 0.34
            case .nearbyObject: return 0.40
            case .ultraDetailObject: return 0.47
            }
        }
        /// Khi best vượt runner-up theo tỷ lệ này (và đủ `bestFrameMinAbsoluteWeight`) → chỉ best, không fuse.
        var bestFrameDominanceRatio: Float {
            switch subject {
            case .room: return 2.05
            case .nearbyObject: return 2.35
            case .ultraDetailObject: return 2.65
            }
        }
        /// Ngưỡng weight tối thiểu để dominance ratio được xét (đủ “tín hiệu” raster).
        var bestFrameMinAbsoluteWeight: Float {
            switch subject {
            case .room: return 0.11
            case .nearbyObject: return 0.125
            case .ultraDetailObject: return 0.14
            }
        }
        /// Trên ngưỡng này: luôn lấy màu best (pixel confidence cao → tránh làm mềm).
        var bestFrameAbsolutePickWeight: Float {
            switch subject {
            case .room: return 0.38
            case .nearbyObject: return 0.44
            case .ultraDetailObject: return 0.52
            }
        }
        /// Khi weight best rất cao nhưng chưa absolute-pick → thu nhỏ blend xuống.
        var bestFrameHeavyWeightThreshold: Float {
            switch subject {
            case .room: return 0.22
            case .nearbyObject: return 0.26
            case .ultraDetailObject: return 0.31
            }
        }
        var bestFrameHeavyWeightBlendFactor: Float {
            switch subject {
            case .room: return 0.52
            case .nearbyObject: return 0.48
            case .ultraDetailObject: return 0.42
            }
        }
        /// Góc grazing (1−n·v): siết tolerance depth để giảm “ăn nhầm” ở rìa nghiêng.
        var fusionNormalOcclusionTolScaleMin: Float {
            switch subject {
            case .room: return 0.82
            case .nearbyObject: return 0.78
            case .ultraDetailObject: return 0.72
            }
        }
        var fusionNormalOcclusionSpreadScaleMin: Float {
            switch subject {
            case .room: return 0.88
            case .nearbyObject: return 0.84
            case .ultraDetailObject: return 0.78
            }
        }
        /// Bilinear − Gaussian: tăng vi mịn có gate Sobel để không thổi noise đồng nhất.
        var fusionMicroContrastStrength: Float {
            switch subject {
            case .room: return 0.22
            case .nearbyObject: return 0.30
            case .ultraDetailObject: return 0.38
            }
        }
        /// Nhịp thời gian hẹp hơn ↔ ít dao động màu giữa khung trong fuse.
        var fusionTemporalBaseline: Float {
            switch subject {
            case .room: return 0.78
            case .nearbyObject: return 0.82
            case .ultraDetailObject: return 0.86
            }
        }
        var fusionTemporalRecencyMix: Float {
            switch subject {
            case .room: return 0.22
            case .nearbyObject: return 0.18
            case .ultraDetailObject: return 0.14
            }
        }
        /// Khung fusion đầu (thường live) được boost để neo màu theo khung hiện tại.
        var fusionReferenceFrameWeightBoost: Float {
            switch subject {
            case .room: return 1.12
            case .nearbyObject: return 1.18
            case .ultraDetailObject: return 1.24
            }
        }
        var fusionMinSobelMagnitude: Float {
            switch subject {
            case .room: return 0.017
            case .nearbyObject: return 0.021
            case .ultraDetailObject: return 0.026
            }
        }
        var fusionSharpnessBypassSobel: Float {
            switch subject {
            case .room: return 0.34
            case .nearbyObject: return 0.36
            case .ultraDetailObject: return 0.38
            }
        }
        /// Độ mạnh “ripple” quanh luma từng đỉnh — bù wash-out sau fuse multi-frame (không cần patch ảnh lân cận).
        var postFusionLocalContrastRipple: Float {
            switch subject {
            case .room: return 0.050
            case .nearbyObject: return 0.072
            case .ultraDetailObject: return 0.095
            }
        }
        var saturationBoost: Float {
            switch subject {
            case .room: return 2.20   // strong — recover vivid real-world colours
            case .nearbyObject: return 2.40
            case .ultraDetailObject: return 2.60
            }
        }
        /// S-curve contrast strength. Higher = more tonal separation (dark→dark, bright→bright).
        var contrastBoost: Float {
            switch subject {
            case .room: return 1.55   // punchy — keeps whites distinct from mid-tones
            case .nearbyObject: return 1.70
            case .ultraDetailObject: return 1.85
            }
        }
        /// Gamma > 1 darkens the image. Use to counter the over-bright (washed-out) look
        /// produced by ARKit's auto-exposed camera frames.
        var gammaCorrection: Float {
            switch subject {
            case .room: return 1.20   // darken ~20 % — prevents blown-out surfaces
            case .nearbyObject: return 1.12
            case .ultraDetailObject: return 1.05
            }
        }
        /// Laplacian màu đỉnh GLB — ít pass / độ mạnh thấp hơn → giữ sắc nét polycam-lite.
        var glbColorSmoothPasses: Int {
            switch subject {
            case .room: return 1
            case .nearbyObject: return 1
            case .ultraDetailObject: return 2
            }
        }
        var glbColorSmoothStrength: Float {
            switch subject {
            case .room: return 0.13
            case .nearbyObject: return 0.15
            case .ultraDetailObject: return 0.18
            }
        }
    }

    struct DetailPatch: Identifiable {
        let id: UUID
        let center: SIMD3<Float>
        let radius: Float
        let label: String

        init(id: UUID = UUID(), center: SIMD3<Float>, radius: Float = 0.7, label: String = "Vùng chi tiết") {
            self.id = id
            self.center = center
            self.radius = radius
            self.label = label
        }
    }

    // MARK: - Reference Points (for mesh alignment export)

    struct ReferencePoint: Identifiable {
        let id: UUID
        let worldPosition: SIMD3<Float>
        let label: String
        let timestamp: Date

        init(id: UUID = UUID(), worldPosition: SIMD3<Float>, label: String) {
            self.id = id
            self.worldPosition = worldPosition
            self.label = label
            self.timestamp = Date()
        }
    }

    private static let refQueue = DispatchQueue(label: "ARMeshExporter.refPoints")
    private static var _referencePoints: [ReferencePoint] = []

    static var referencePointCount: Int { refQueue.sync { _referencePoints.count } }

    static func addReferencePoint(_ point: ReferencePoint) {
        refQueue.sync { _referencePoints.append(point) }
    }

    static func clearReferencePoints() {
        refQueue.sync { _referencePoints.removeAll() }
    }

    /// Encodes all reference points as pretty-printed JSON ready to ship alongside the OBJ.
    /// Returns nil if no points have been placed.
    static func buildReferencePointsJSON() -> Data? {
        let points = refQueue.sync { _referencePoints }
        guard !points.isEmpty else { return nil }

        struct PointEntry: Encodable {
            let id: String; let label: String
            let x, y, z: Float
        }
        struct Export: Encodable {
            let units: String
            let description: String
            let cloudcompare_tip: String
            let points: [PointEntry]
        }
        let export = Export(
            units: "meters",
            description: "ARKit world-space reference points for mesh alignment.",
            cloudcompare_tip: "CloudCompare: Tools > Registration > Align (Point Pairs Picking). Match each labeled point to the same feature on your reference CAD/mesh.",
            points: points.map { PointEntry(id: $0.id.uuidString, label: $0.label, x: $0.worldPosition.x, y: $0.worldPosition.y, z: $0.worldPosition.z) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(export)
    }

    // MARK: - Frozen mesh blocks (Polycam-style block scanning)

    /// A snapshot of world-space geometry captured when the user presses "Chụp vùng".
    /// Frozen blocks persist regardless of ARKit anchor updates so triangles
    /// from already-scanned areas are never lost when the camera moves away.
    struct FrozenMeshBlock {
        let positions: [SIMD3<Float>]
        let indices: [UInt32]
        let capturedAt: Date
    }

    private static let frozenQueue = DispatchQueue(label: "ARMeshExporter.frozen")
    private static var _frozenBlocks: [FrozenMeshBlock] = []
    /// IDs of ARMeshAnchors whose geometry has been committed to a frozen block.
    /// prepareMeshes skips these from the live session to avoid double-counting.
    private static var _frozenAnchorIDs: Set<UUID> = []

    static var frozenBlockCount: Int {
        frozenQueue.sync { _frozenBlocks.count }
    }

    static var frozenBlocks: [FrozenMeshBlock] {
        frozenQueue.sync { _frozenBlocks }
    }

    /// IDs already snapshotted — used by prepareMeshes to skip live duplicates.
    static var frozenAnchorIDs: Set<UUID> {
        frozenQueue.sync { _frozenAnchorIDs }
    }

    /// Snapshot the given anchors and mark their IDs as frozen.
    /// Subsequent exports will use the snapshot and skip the live anchor data.
    static func freezeCurrentAnchors(_ anchors: [ARMeshAnchor]) {
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        var offset: UInt32 = 0
        var ids: Set<UUID> = []
        for anchor in anchors {
            let verts = worldVertexPositions(geometry: anchor.geometry, transform: anchor.transform)
            let idx   = triangleIndices(geometry: anchor.geometry)
            positions.append(contentsOf: verts)
            indices.append(contentsOf: idx.map { $0 + offset })
            offset += UInt32(verts.count)
            ids.insert(anchor.identifier)
        }
        guard !positions.isEmpty else { return }
        let block = FrozenMeshBlock(positions: positions, indices: indices, capturedAt: Date())
        frozenQueue.sync {
            _frozenBlocks.append(block)
            _frozenAnchorIDs.formUnion(ids)
        }
    }

    /// Remove all frozen blocks and clear the frozen-anchor ID set.
    static func clearFrozenBlocks() {
        frozenQueue.sync {
            _frozenBlocks.removeAll()
            _frozenAnchorIDs.removeAll()
        }
    }

    // MARK: - Multi-frame colour history (HEIC snapshots — never stash ARFrame in arrays)

    /// HEIC HEVC still: ít blocking/mosquito hơn JPEG ở cùng bitrate → giữ high‑frequency cho fusion; fallback JPEG nếu encode thất bại.
    private static let fusionSnapshotHEICQuality: CGFloat = 0.88

    /// Compact camera observation for fusion. ARKit forbids delegates from retaining many `ARFrame`
    /// (camera backs up → few fusion frames → mass grey / UV fallback exactly like your log).
    private struct FusionFrameSnapshot {
        let timestamp: TimeInterval
        let cameraTransform: simd_float4x4
        let intrinsics: simd_float3x3
        let imageResolution: CGSize
        let imageBlob: Data
        let imageCodec: FusionSnapshotImageCodec
        /// Thumbnail depth pack (optional) — cho occlusion lịch sử mà không giữ full depth buffer.
        let miniDepthPayload: Data?
        let lumaCDF: ContiguousArray<Float>
        /// Từ lúc encode — dùng lại cho decode adapters (ảnh nén không giữ metadata độ phơi).
        let meanLuminance01: Float
        let sharpness01: Float

        init?(from frame: ARFrame) {
            let m = FrameImageMetrics.compute(frame.capturedImage)
            guard let packed = ARMeshExporter.extractFusionSnapshotImage(from: frame) else { return nil }
            let dm = frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap
            let mini: Data?
            if let dm {
                let iw = Int(frame.camera.imageResolution.width)
                let ih = Int(frame.camera.imageResolution.height)
                mini = FusionPackedMiniDepth.encode(depthMap: dm, imageWidth: iw, imageHeight: ih)?.asBinaryPayload()
            } else {
                mini = nil
            }
            let cdf = FusionLumaHistogram.cdf17(from: frame.capturedImage)
            self.timestamp = frame.timestamp
            self.cameraTransform = frame.camera.transform
            self.intrinsics = frame.camera.intrinsics
            self.imageResolution = frame.camera.imageResolution
            self.imageBlob = packed.data
            self.imageCodec = packed.codec
            self.miniDepthPayload = mini
            self.lumaCDF = cdf
            meanLuminance01 = m.meanLuma01
            sharpness01 = m.sharpness01
        }

        static func camPosition(_ s: FusionFrameSnapshot) -> SIMD3<Float> {
            let c = s.cameraTransform.columns.3
            return SIMD3<Float>(c.x, c.y, c.z)
        }
    }

    private static let historyQueue = DispatchQueue(label: "ARMeshExporter.frameHistory")
    private static var frameSnapshotHistory: [FusionFrameSnapshot] = []
    private static var patchFrameSnapshotHistory: [UUID: [FusionFrameSnapshot]] = [:]

    /// ~100 snapshots × HEIC+blob nhỏ ≈ manageable RAM vs 12 live ARFrames starving the pipeline.
    private static let maxHistorySnapshots = 100
    /// Ít khung được chọn hơn — giảm decode/mỗi lần materialize và CPU export.
    private static let maxFusionSnapshots = 11
    /// Số ảnh still decode **full‑res BGRA** cho fusion đỉnh (cache 1× / miền patch — không được giải mã × mọi đỉnh).
    private static let maxDecodedBGRAFusion = 8
    /// Atlas texture: vẫn cần nhiều view hơn nhưng không cho phép spike “mọi JPEG cùng lúc”.
    private static let maxDecodedBGRAAtlas = 8
    /// Bỏ khung cực mờ khỏi history (still export snap “fresh” từ frame hiện tại như snapshot mới nhất có thể mờ).
    private static let minSharpnessToRecordHistory: Float = 0.048

    private static let freshSnapshotCacheLock = NSLock()
    private static var freshSnapshotCache: FusionFrameSnapshot?


    static func recordFrameForColorFusion(_ frame: ARFrame) {
        recordFrameForColorFusion(frame, cameraPosition: nil, detailPatches: [], preferPatchHistory: false)
    }

    /// Chấp nhận `initializing` / `insufficientFeatures` nhưng từ chối các trạng thái gây artefact nặng.
    static func shouldRecordFrameForFusion(_ frame: ARFrame) -> Bool {
        switch frame.camera.trackingState {
        case .normal:
            break
        case .limited(let reason):
            switch reason {
            case .excessiveMotion, .relocalizing:
                return false
            case .initializing, .insufficientFeatures:
                break
            @unknown default:
                break
            }
        case .notAvailable:
            return false
        @unknown default:
            break
        }
        return true
    }

    static func recordFrameForColorFusion(
        _ frame: ARFrame,
        cameraPosition: SIMD3<Float>?,
        detailPatches: [DetailPatch],
        preferPatchHistory: Bool
    ) {
        guard shouldRecordFrameForFusion(frame) else { return }
        guard let snap = FusionFrameSnapshot(from: frame), snap.sharpness01 >= minSharpnessToRecordHistory else { return }
        historyQueue.sync {
            if let lastTs = frameSnapshotHistory.last?.timestamp, abs(lastTs - snap.timestamp) < 1e-4 {
                return
            }
            frameSnapshotHistory.append(snap)
            if frameSnapshotHistory.count > maxHistorySnapshots {
                frameSnapshotHistory.removeFirst(frameSnapshotHistory.count - maxHistorySnapshots)
            }

            guard preferPatchHistory,
                  let camPos = cameraPosition,
                  let patch = nearestPatch(to: camPos, detailPatches: detailPatches, expandFactor: 2.2)
            else { return }

            var list = patchFrameSnapshotHistory[patch.id] ?? []
            if let lastTs = list.last?.timestamp, abs(lastTs - snap.timestamp) < 1e-4 {
                patchFrameSnapshotHistory[patch.id] = list
                return
            }
            list.append(snap)
            if list.count > maxHistorySnapshots {
                list.removeFirst(list.count - maxHistorySnapshots)
            }
            patchFrameSnapshotHistory[patch.id] = list
        }
    }

    static func resetFrameHistory() {
        clearVertexFusionMaterialCache()
        freshSnapshotCacheLock.lock()
        freshSnapshotCache = nil
        freshSnapshotCacheLock.unlock()
        historyQueue.sync {
            frameSnapshotHistory.removeAll(keepingCapacity: true)
            patchFrameSnapshotHistory.removeAll(keepingCapacity: true)
        }
    }

    /// Một JPEG + metrics cho frame export — có cache để không encode lặp cho mọi đỉnh GLB/OBJ.
    private static func freshCachedFusionSnapshot(for current: ARFrame) -> FusionFrameSnapshot? {
        freshSnapshotCacheLock.lock()
        defer { freshSnapshotCacheLock.unlock() }
        if let c = freshSnapshotCache, abs(c.timestamp - current.timestamp) < 1e-6 {
            return c
        }
        guard let s = FusionFrameSnapshot(from: current) else { return nil }
        freshSnapshotCache = s
        return s
    }

    /// Khi ≤ maxKeeps khung → sắp lại ƯNT thô; khi có vị trí → ưu gần + sắc nét cao để không over-blend.
    private static func sortFusionSnapshotsPreferSharpness(
        _ snaps: [FusionFrameSnapshot],
        maxKeeps: Int,
        nearVertex maybeV: SIMD3<Float>?,
        currentTs: TimeInterval
    ) -> [FusionFrameSnapshot] {
        guard !snaps.isEmpty else { return [] }
        var s = snaps
        s.sort { a, b in
            let sharpJump = abs(a.sharpness01 - b.sharpness01)
            if sharpJump > 0.016 { return a.sharpness01 > b.sharpness01 }
            if let v = maybeV {
                let da = simd_length(FusionFrameSnapshot.camPosition(a) - v)
                let db = simd_length(FusionFrameSnapshot.camPosition(b) - v)
                let distJump = abs(da - db)
                if distJump > Float(0.048) {
                    return da < db
                }
            }
            let ta = abs(a.timestamp - currentTs)
            let tb = abs(b.timestamp - currentTs)
            if abs(ta - tb) > 0.035 { return ta < tb }
            return a.sharpness01 > b.sharpness01
        }
        return Array(s.prefix(maxKeeps))
    }

    /// Lấy mẫu thời gian rải đều trong phần còn lại (baseline + keyframe không trùng thời).
    private static func spacedTemporalSamples(_ frames: [FusionFrameSnapshot], take: Int) -> [FusionFrameSnapshot] {
        guard take > 0, !frames.isEmpty else { return [] }
        let sorted = frames.sorted { $0.timestamp < $1.timestamp }
        if sorted.count <= take { return sorted }
        let cap = sorted.count - 1
        let step = Swift.max(cap / Swift.max(take - 1, 1), 1)
        var out: [FusionFrameSnapshot] = []
        var i = 0
        while i <= cap, out.count < take {
            out.append(sorted[i])
            i += step
        }
        if let la = sorted.last, out.last?.timestamp != la.timestamp {
            out.append(la)
        }
        return Array(out.prefix(take))
    }

    /// Chọn snapshots cho fusion GPU-side (projection + colour). Không chứa `ARFrame`.
    private static func selectFusionSnapshots(
        nearVertex vertexPosition: SIMD3<Float>?,
        including current: ARFrame,
        preferredPatchID: UUID?
    ) -> [FusionFrameSnapshot] {
        guard let fresh = freshCachedFusionSnapshot(for: current) else { return [] }
        return historyQueue.sync {
            var all = frameSnapshotHistory
            if let preferredPatchID, let patchFrames = patchFrameSnapshotHistory[preferredPatchID] {
                all.append(contentsOf: patchFrames)
            }

            let currentTs = current.timestamp
            if !all.contains(where: { abs($0.timestamp - currentTs) < 1e-4 }) {
                all.append(fresh)
            }

            var seenTs: [TimeInterval] = []
            var unique: [FusionFrameSnapshot] = []
            unique.reserveCapacity(all.count)
            for s in all {
                if seenTs.contains(where: { abs($0 - s.timestamp) < 1e-4 }) { continue }
                seenTs.append(s.timestamp)
                unique.append(s)
            }

            if unique.count <= maxFusionSnapshots { return sortFusionSnapshotsPreferSharpness(unique, maxKeeps: maxFusionSnapshots, nearVertex: vertexPosition, currentTs: currentTs) }

            if let vpos = vertexPosition {
                let sharpPenalty: Float = 0.095
                unique.sort {
                    let da = simd_length(FusionFrameSnapshot.camPosition($0) - vpos) + sharpPenalty * max(0, 1.0 - $0.sharpness01)
                    let db = simd_length(FusionFrameSnapshot.camPosition($1) - vpos) + sharpPenalty * max(0, 1.0 - $1.sharpness01)
                    if abs(da - db) < 0.022 { return $0.sharpness01 > $1.sharpness01 }
                    return da < db
                }
                let proxCount = max(4, min((maxFusionSnapshots * 5) / 7, unique.count))
                let tempCount = max(2, maxFusionSnapshots - proxCount)
                let proxFrames = Array(unique.prefix(proxCount))
                let remaining = Array(unique.dropFirst(proxCount))
                var tempFrames: [FusionFrameSnapshot] = []
                if !remaining.isEmpty {
                    let spaced = spacedTemporalSamples(remaining, take: tempCount)
                    tempFrames.append(contentsOf: spaced)
                }
                return sortFusionSnapshotsPreferSharpness(proxFrames + tempFrames, maxKeeps: maxFusionSnapshots, nearVertex: vpos, currentTs: currentTs)
            }

            let ranked = sortFusionSnapshotsPreferSharpness(unique, maxKeeps: unique.count, nearVertex: nil, currentTs: currentTs)
            let n = ranked.count
            let k = maxFusionSnapshots
            if n <= k { return ranked }
            let step = Swift.max((n - 1) / Swift.max(k - 1, 1), 1)
            return (0..<k).map { ranked[Swift.min($0 * step, n - 1)] }
        }
    }

    private struct VertexFusionMaterialCacheKey: Hashable {
        let frameTimestamp: TimeInterval
        let preferredPatchID: UUID?
        let voxelCell: SIMD3<Int32>
    }

    /// Kích thước ô không gian (world) để tái materialize fusion — không còn 1 bucket cho toàn mesh.
    private static let fusionMaterialVoxelPitchMeters: Float = 0.135

    private static let vertexFusionMaterialLock = NSLock()
    /// LRU nhỏ: tránh spike RAM và map vô hạn.
    private static var vertexFusionMaterialCaches: [VertexFusionMaterialCacheKey: [ColorFusionFrame]] = [:]
    private static var vertexFusionMaterialCacheFifo: [VertexFusionMaterialCacheKey] = []
    private static let maxVertexFusionMaterialCacheEntries = 56

    private static func quantizedFusionVoxel(_ worldPosition: SIMD3<Float>) -> SIMD3<Int32> {
        let s = fusionMaterialVoxelPitchMeters
        return SIMD3(
            Int32(floor(worldPosition.x / s)),
            Int32(floor(worldPosition.y / s)),
            Int32(floor(worldPosition.z / s))
        )
    }

    private static func voxelRegionCenter(for cell: SIMD3<Int32>) -> SIMD3<Float> {
        let s = fusionMaterialVoxelPitchMeters
        return SIMD3(
            Float(cell.x) * s + s * 0.5,
            Float(cell.y) * s + s * 0.5,
            Float(cell.z) * s + s * 0.5
        )
    }

    private static func clearVertexFusionMaterialCache() {
        vertexFusionMaterialLock.lock()
        vertexFusionMaterialCaches.removeAll(keepingCapacity: false)
        vertexFusionMaterialCacheFifo.removeAll(keepingCapacity: false)
        vertexFusionMaterialLock.unlock()
    }

    /// Xóa LRU cho tới khi còn chỗ trước khi thêm key mới.
    private static func prepareFusionCacheSlotForNewKey_locked(_ key: VertexFusionMaterialCacheKey) {
        if vertexFusionMaterialCaches[key] != nil { return }
        while vertexFusionMaterialCaches.count >= maxVertexFusionMaterialCacheEntries,
              let oldest = vertexFusionMaterialCacheFifo.first {
            vertexFusionMaterialCacheFifo.removeFirst()
            vertexFusionMaterialCaches.removeValue(forKey: oldest)
        }
    }
    /// Giới hạn số snapshot cần decode still image → tránh hàng chục IOSurface full‑res cùng lúc (crash `NSMallocException`).
    private static func capSnapshotsForMaterialize(
        currentTs: TimeInterval,
        snapshots: [FusionFrameSnapshot],
        maxStillImageDecode: Int
    ) -> [FusionFrameSnapshot] {
        guard maxStillImageDecode > 0 else {
            return snapshots.filter { abs($0.timestamp - currentTs) < 1e-4 }
        }
        var nonLive = snapshots.filter { abs($0.timestamp - currentTs) >= 1e-4 }
        if nonLive.count > maxStillImageDecode {
            nonLive.sort { $0.sharpness01 > $1.sharpness01 }
            nonLive = Array(nonLive.prefix(maxStillImageDecode))
            nonLive.sort { $0.timestamp < $1.timestamp }
        }
        let liveFirst = snapshots.first(where: { abs($0.timestamp - currentTs) < 1e-4 })
        if let live = liveFirst {
            var out: [FusionFrameSnapshot] = [live]
            for s in nonLive where !out.contains(where: { abs($0.timestamp - s.timestamp) < 1e-6 }) {
                out.append(s)
            }
            return out
        }
        return nonLive
    }

    /// Biến snapshot + frame hiện tại → adapters có `CVPixelBuffer` cho sampling.
    /// `maxStillImageDecode` chặn số buffer BGRA giải mã đồng thời (nguyên nhân crash khi export lớn).
    private static func materializeFusionSnapshots(
        current: ARFrame,
        snapshots: [FusionFrameSnapshot],
        maxStillImageDecode: Int
    ) -> [ColorFusionFrame] {
        let currentTs = current.timestamp
        let capped = capSnapshotsForMaterialize(currentTs: currentTs, snapshots: snapshots, maxStillImageDecode: maxStillImageDecode)
        var out: [ColorFusionFrame] = []
        out.reserveCapacity(capped.count + 1)
        var usedLive = false
        for s in capped {
            if !usedLive && abs(s.timestamp - currentTs) < 1e-4 {
                out.append(ARFrameFusionAdapter(current))
                usedLive = true
            } else {
                let mini = s.miniDepthPayload.flatMap { FusionPackedMiniDepth.fromBinaryPayload($0) }
                if let decoded = DecodedStillFusionAdapter(
                    timestamp: s.timestamp,
                    transform: s.cameraTransform,
                    intrinsics: s.intrinsics,
                    resolution: s.imageResolution,
                    imageBlob: s.imageBlob,
                    codec: s.imageCodec,
                    meanLuma01: s.meanLuminance01,
                    sharpness01: s.sharpness01,
                    lumaCDF: s.lumaCDF,
                    miniDepth: mini
                ) {
                    out.append(decoded)
                }
            }
        }
        if out.isEmpty {
            out.append(ARFrameFusionAdapter(current))
        } else if !usedLive {
            out.insert(ARFrameFusionAdapter(current), at: 0)
        }
        return out
    }

    /// Cache fusion đã materialize — **per voxel × frame × patch**; `nearVertex` = tâm vùng để chọn keyframe như polycam-lite.
    private static func materializedFramesForVertexExport(
        frame: ARFrame,
        preferredPatchID: UUID?,
        anchorWorldPosition: SIMD3<Float>
    ) -> [ColorFusionFrame] {
        let cell = quantizedFusionVoxel(anchorWorldPosition)
        let key = VertexFusionMaterialCacheKey(frameTimestamp: frame.timestamp, preferredPatchID: preferredPatchID, voxelCell: cell)
        vertexFusionMaterialLock.lock()
        if let hit = vertexFusionMaterialCaches[key] {
            vertexFusionMaterialLock.unlock()
            return hit
        }
        vertexFusionMaterialLock.unlock()

        let regionCenter = voxelRegionCenter(for: cell)
        let snaps = selectFusionSnapshots(nearVertex: regionCenter, including: frame, preferredPatchID: preferredPatchID)
        let mats = materializeFusionSnapshots(current: frame, snapshots: snaps, maxStillImageDecode: maxDecodedBGRAFusion)

        vertexFusionMaterialLock.lock()
        if let raced = vertexFusionMaterialCaches[key] {
            vertexFusionMaterialLock.unlock()
            return raced
        }
        prepareFusionCacheSlotForNewKey_locked(key)
        vertexFusionMaterialCaches[key] = mats
        vertexFusionMaterialCacheFifo.append(key)
        vertexFusionMaterialLock.unlock()
        return mats
    }

    private static func selectFusionSnapshots(including current: ARFrame) -> [FusionFrameSnapshot] {
        selectFusionSnapshots(nearVertex: nil, including: current, preferredPatchID: nil)
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
    static func buildFacetedGLB(
        from session: ARSession,
        profile: ExportProfile = ExportProfile(subject: .room),
        detailPatches: [DetailPatch] = []
    ) -> Data? {
        guard let frame = session.currentFrame else { return nil }
        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshAnchors.isEmpty else { return nil }
        return buildFacetedGLB(meshAnchors: meshAnchors, frame: frame, profile: profile, detailPatches: detailPatches)
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
        textureFilename: String = "texture.jpg",
        profile: ExportProfile = ExportProfile(subject: .room),
        detailPatches: [DetailPatch] = []
    ) -> TexturedOBJBundle? {
        defer { clearVertexFusionMaterialCache() }
        guard let frame = session.currentFrame else { return nil }
        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshAnchors.isEmpty else { return nil }
        let textureDiag = TextureDiag()
        logExportHeader(tag: "TexturedOBJ", frame: frame)

        let snapSelection = selectFusionSnapshots(including: frame)
        let preparedMeshes = prepareMeshes(meshAnchors: meshAnchors, frame: frame, profile: profile)
        guard !preparedMeshes.isEmpty else { return nil }

        let atlasFrames = bestTextureFusionFrames(
            snapshots: snapSelection,
            current: frame,
            preparedMeshes: preparedMeshes,
            profile: profile,
            detailPatches: detailPatches
        )
        guard let atlas = buildTextureAtlas(from: atlasFrames, quality: profile.textureJPEGQuality) else { return nil }
        let texW = atlas.size.width
        let texH = atlas.size.height

        var vSection = ""
        var vtSection = ""
        var vnSection = ""
        var fSection = "mtllib \(textureFilename.replacingOccurrences(of: ".jpg", with: ".mtl"))\nusemtl camera_tex\n"
        var vertexBase = 1

        for mesh in preparedMeshes {
            for i in 0..<mesh.positions.count {
                let v = mesh.positions[i]
                let n = mesh.normals[i]
                textureDiag.countVertex()
                vSection += String(format: "v %.6f %.6f %.6f\n", v.x, v.y, v.z)
                vnSection += String(format: "vn %.6f %.6f %.6f\n", n.x, n.y, n.z)

                var u: Float = 0.5
                var vCoord: Float = 0.5
                let localProfile = profileForPosition(v, baseProfile: profile, detailPatches: detailPatches)
                if let bestProjection = bestTextureProjection(
                    worldPosition: v,
                    normal: n,
                    frames: atlasFrames,
                    profile: localProfile,
                    diag: textureDiag
                ) {
                    let tile = atlas.tiles[bestProjection.frameIndex]
                    let atlasX = tile.origin.x + bestProjection.point.x
                    let atlasY = tile.origin.y + bestProjection.point.y
                    u = Float(max(0, min(atlasX / texW, 1)))
                    vCoord = Float(max(0, min(1 - atlasY / texH, 1)))
                    textureDiag.countMapped(
                        frameIndex: bestProjection.frameIndex,
                        score: bestProjection.score,
                        u: u,
                        v: vCoord,
                        relaxed: bestProjection.isRelaxed
                    )
                } else {
                    textureDiag.countUnmapped()
                }
                vtSection += String(format: "vt %.6f %.6f\n", u, vCoord)
            }

            let base = vertexBase
            for i in stride(from: 0, to: mesh.indices.count, by: 3) {
                let i0 = Int(mesh.indices[i]) + base
                let i1 = Int(mesh.indices[i + 1]) + base
                let i2 = Int(mesh.indices[i + 2]) + base
                fSection += "f \(i0)/\(i0)/\(i0) \(i1)/\(i1)/\(i1) \(i2)/\(i2)/\(i2)\n"
            }
            vertexBase += mesh.positions.count
        }

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
        textureDiag.printSummary(
            tag: "TexturedOBJ",
            atlasFrameCount: atlasFrames.count,
            atlasSize: atlas.size,
            jpegBytes: atlas.jpegData.count
        )
        return TexturedOBJBundle(obj: obj, mtl: mtl, textureJPEG: atlas.jpegData)
    }

    private struct FusionSnapshotImagePack {
        let data: Data
        let codec: FusionSnapshotImageCodec
    }

    /// HEIC-first: entropy coding + larger transform blocks ⇒ ít ringing/blocking JPEG trên ridge/texture nhỏ trong fusion đa khung.
    private static func encodeHEICStillData(cgImage: CGImage, quality: CGFloat) -> Data? {
        let mutable = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutable,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else { return nil }
        let opts: NSDictionary = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(dest, cgImage, opts)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutable as Data
    }

    private static func extractFusionSnapshotImage(from frame: ARFrame) -> FusionSnapshotImagePack? {
        let pb = frame.capturedImage
        let ci = CIImage(cvPixelBuffer: pb)
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return nil }
        if let heic = encodeHEICStillData(cgImage: cg, quality: fusionSnapshotHEICQuality) {
            return FusionSnapshotImagePack(data: heic, codec: .heic)
        }
        if let jpg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.98) {
            return FusionSnapshotImagePack(data: jpg, codec: .jpeg)
        }
        return nil
    }

    private static func extractJPEG(from frame: ARFrame, quality: CGFloat) -> Data? {
        let pb = frame.capturedImage
        let ci = CIImage(cvPixelBuffer: pb)
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: quality)
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
        defer { clearVertexFusionMaterialCache() }
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
                autoreleasepool {
                let v = verts[i]
                let n = normalsSmooth[i]
                let c = sampleCameraColor(worldPosition: v, worldNormal: n, frame: frame, diag: diag, profile: ExportProfile(subject: .room), preferredPatchID: nil)
                diag.countVertex()
                obj += String(format: "v %.6f %.6f %.6f %.6f %.6f %.6f\n", v.x, v.y, v.z, c.x, c.y, c.z)
                }
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
        defer { clearVertexFusionMaterialCache() }
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
                autoreleasepool {
                let v = verts[i]
                let n = normalsSmooth[i]
                let c = sampleCameraColor(worldPosition: v, worldNormal: n, frame: frame, diag: diag, profile: ExportProfile(subject: .room), preferredPatchID: nil)
                diag.countVertex()
                positions.append(v)
                colors.append(c)
                }
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

    // MARK: - glTF 2.0 GLB

    private static func buildFacetedGLB(
        meshAnchors: [ARMeshAnchor],
        frame: ARFrame,
        profile: ExportProfile,
        detailPatches: [DetailPatch]
    ) -> Data? {
        let diag = ColorDiag()
        logExportHeader(tag: "GLB", frame: frame)
        defer { clearVertexFusionMaterialCache() }
        var positions: [Float] = []
        var normals: [Float] = []
        var colors: [Float] = []
        var indicesOut: [UInt32] = []
        var vertexOffset: UInt32 = 0

        for mesh in prepareMeshes(meshAnchors: meshAnchors, frame: frame, profile: profile) {
            for i in 0..<mesh.positions.count {
                autoreleasepool {
                let p = mesh.positions[i]
                let n = mesh.normals[i]
                let localProfile = profileForPosition(p, baseProfile: profile, detailPatches: detailPatches)
                let preferredPatchID = nearestPatchID(for: p, detailPatches: detailPatches)
                let c = sampleCameraColor(
                    worldPosition: p,
                    worldNormal: n,
                    frame: frame,
                    diag: diag,
                    profile: localProfile,
                    preferredPatchID: preferredPatchID
                )
                diag.countVertex()
                positions.append(contentsOf: [p.x, p.y, p.z])
                normals.append(contentsOf: [n.x, n.y, n.z])
                colors.append(contentsOf: [c.x, c.y, c.z])
                }
            }
            for idx in mesh.indices {
                indicesOut.append(vertexOffset + idx)
            }
            vertexOffset += UInt32(mesh.positions.count)
        }

        let vertexCount = positions.count / 3
        guard vertexCount > 0, !indicesOut.isEmpty else { return nil }
        diag.printSummary(tag: "GLB")

        // 2 passes of Laplacian colour smoothing at 28% strength.
        // Pass 1 softens the hard colour discontinuity at anchor boundaries.
        // Pass 2 diffuses the remaining gradient so transitions are visually seamless.
        // 28% strength keeps sharp real-world colour edges (e.g. wall-floor junction)
        // intact while dissolving the 1–2 vertex-wide seam bands.
        smoothVertexColors(colors: &colors, indices: indicesOut,
                           vertexCount: vertexCount,
                           passes: profile.glbColorSmoothPasses,
                           strength: profile.glbColorSmoothStrength)

        return encodeIndexedGLB(positions: positions, normals: normals, colors: colors, indices: indicesOut, vertexCount: vertexCount)
    }

    /// Laplacian color smoothing: blends each vertex colour with its mesh neighbours.
    /// One pass with strength ≈ 0.20–0.30 is enough to dissolve the hard colour
    /// discontinuities that appear at ARMeshAnchor boundaries without visibly
    /// blurring sharp real-world colour edges.
    ///
    /// - Parameters:
    ///   - colors:      flat [r,g,b, r,g,b, …] Float array, modified in-place.
    ///   - indices:     triangle index buffer (UInt32 triples).
    ///   - vertexCount: number of vertices.
    ///   - passes:      number of smoothing iterations (1 = light, 2 = strong).
    ///   - strength:    blend factor 0–1 (0 = no change, 1 = full neighbour average).
    private static func smoothVertexColors(
        colors: inout [Float],
        indices: [UInt32],
        vertexCount: Int,
        passes: Int,
        strength: Float
    ) {
        guard vertexCount > 0, passes > 0, strength > 0 else { return }

        // Build neighbour lists from the triangle index buffer.
        // Allowing duplicates is intentional: shared (interior) edges appear twice,
        // giving them a slightly higher weight — which is geometrically correct.
        var neighbors: [[Int]] = Array(repeating: [], count: vertexCount)
        for i in stride(from: 0, to: indices.count, by: 3) {
            let i0 = Int(indices[i]), i1 = Int(indices[i + 1]), i2 = Int(indices[i + 2])
            neighbors[i0].append(i1); neighbors[i0].append(i2)
            neighbors[i1].append(i0); neighbors[i1].append(i2)
            neighbors[i2].append(i0); neighbors[i2].append(i1)
        }

        let inv_s = 1.0 - strength
        for _ in 0..<passes {
            var next = colors
            for i in 0..<vertexCount {
                let ns = neighbors[i]
                guard !ns.isEmpty else { continue }
                var ar: Float = 0, ag: Float = 0, ab: Float = 0
                for n in ns {
                    ar += colors[n * 3]
                    ag += colors[n * 3 + 1]
                    ab += colors[n * 3 + 2]
                }
                let k = Float(ns.count)
                next[i * 3]     = colors[i * 3]     * inv_s + (ar / k) * strength
                next[i * 3 + 1] = colors[i * 3 + 1] * inv_s + (ag / k) * strength
                next[i * 3 + 2] = colors[i * 3 + 2] * inv_s + (ab / k) * strength
            }
            colors = next
        }
    }

    /// glTF 2.0: `ARRAY_BUFFER` / `ELEMENT_ARRAY_BUFFER` (OpenGL ES constants).
    private static let gltfArrayBuffer: Int = 34962
    private static let gltfElementArrayBuffer: Int = 34963

    private static func encodeIndexedGLB(positions: [Float], normals: [Float], colors: [Float], indices: [UInt32], vertexCount: Int) -> Data {
        let posData = positions.withUnsafeBufferPointer { Data(buffer: $0) }
        let normData = normals.withUnsafeBufferPointer { Data(buffer: $0) }
        let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
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
        binChunk.append(indexData)
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
        let p2 = p1 + colorData.count

        // KHR_materials_unlit: display vertex colors directly without PBR lighting.
        // Without this extension, PBR with roughness=1 and no IBL environment makes
        // the mesh appear dark/black in most viewers even when vertex colors are correct.
        let json: String = """
        {"asset":{"version":"2.0","generator":"LiDARDepth"},"extensionsUsed":["KHR_materials_unlit"],"scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"mesh":0}],"meshes":[{"primitives":[{"attributes":{"POSITION":0,"NORMAL":1,"COLOR_0":2},"indices":3,"material":0}]}],"materials":[{"doubleSided":true,"extensions":{"KHR_materials_unlit":{}},"pbrMetallicRoughness":{"baseColorFactor":[1,1,1,1]}}],"buffers":[{"byteLength":\(bufferByteLength)}],"bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":\(posData.count),"target":\(gltfArrayBuffer)},{"buffer":0,"byteOffset":\(p0),"byteLength":\(normData.count),"target":\(gltfArrayBuffer)},{"buffer":0,"byteOffset":\(p1),"byteLength":\(colorData.count),"target":\(gltfArrayBuffer)},{"buffer":0,"byteOffset":\(p2),"byteLength":\(indexData.count),"target":\(gltfElementArrayBuffer)}],"accessors":[{"bufferView":0,"componentType":5126,"count":\(vertexCount),"type":"VEC3","min":[\(minP.x),\(minP.y),\(minP.z)],"max":[\(maxP.x),\(maxP.y),\(maxP.z)]},{"bufferView":1,"componentType":5126,"count":\(vertexCount),"type":"VEC3"},{"bufferView":2,"componentType":5121,"normalized":true,"count":\(vertexCount),"type":"VEC4"},{"bufferView":3,"componentType":5125,"count":\(indices.count),"type":"SCALAR"}]}
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

    private struct PreparedMesh {
        let positions: [SIMD3<Float>]
        let normals: [SIMD3<Float>]
        let indices: [UInt32]
    }

    private struct TextureAtlas {
        struct Tile {
            let origin: CGPoint
            let size: CGSize
        }

        let jpegData: Data
        let size: CGSize
        let tiles: [Tile]
    }

    private struct TextureProjection {
        let frameIndex: Int
        let point: CGPoint
        let score: Float
        let isRelaxed: Bool
    }

    private static func prepareMeshes(meshAnchors: [ARMeshAnchor], frame: ARFrame, profile: ExportProfile) -> [PreparedMesh] {
        // Merge all anchors into one combined mesh before smoothing.
        // This lets bilateral smoothing work across anchor boundaries and
        // vertex welding closes the seam gaps that appear as black lines.
        var allPositions: [SIMD3<Float>] = []
        var allIndices: [UInt32] = []
        var vertexOffset: UInt32 = 0

        // 1. Prepend geometry from all frozen blocks (block-scan mode).
        //    These snapshots are stable — they don't change even if ARKit
        //    removes or updates the corresponding anchors later.
        for block in frozenBlocks {
            allPositions.append(contentsOf: block.positions)
            allIndices.append(contentsOf: block.indices.map { $0 + vertexOffset })
            vertexOffset += UInt32(block.positions.count)
        }

        // 2. Append live ARMeshAnchor data — skip any anchor whose geometry has
        //    already been committed to a frozen block to avoid double-counting.
        let frozenIDs = frozenAnchorIDs
        for anchor in meshAnchors where !frozenIDs.contains(anchor.identifier) {
            let verts   = worldVertexPositions(geometry: anchor.geometry, transform: anchor.transform)
            let indices = triangleIndices(geometry: anchor.geometry)
            allPositions.append(contentsOf: verts)
            allIndices.append(contentsOf: indices.map { $0 + vertexOffset })
            vertexOffset += UInt32(verts.count)
        }

        guard !allPositions.isEmpty else { return [] }

        // Weld vertices within 5 mm to seal anchor-boundary seams.
        MeshLaplacianSmooth.weldVertices(positions: &allPositions, triangleIndices: &allIndices, epsilon: 0.005)

        // Smooth + hole-fill on the unified mesh (cross-boundary neighbours now exist).
        MeshLaplacianSmooth.smooth(positions: &allPositions, triangleIndices: allIndices)
        MeshLaplacianSmooth.fillSmallBoundaryHoles(positions: &allPositions, triangleIndices: &allIndices)

        let normals = MeshLaplacianSmooth.vertexNormals(positions: allPositions, triangleIndices: allIndices)
        let camPos  = cameraPosition(frame: frame)
        let filtered = filterMesh(positions: allPositions, normals: normals, indices: allIndices, cameraPosition: camPos, profile: profile)
        return filtered.indices.isEmpty ? [] : [filtered]
    }

    private static func filterMesh(
        positions: [SIMD3<Float>],
        normals: [SIMD3<Float>],
        indices: [UInt32],
        cameraPosition: SIMD3<Float>,
        profile: ExportProfile
    ) -> PreparedMesh {
        if profile.subject == .room {
            return PreparedMesh(positions: positions, normals: normals, indices: indices)
        }

        var keptVertices = Set<Int>()
        var keptTriangles: [(Int, Int, Int)] = []
        keptTriangles.reserveCapacity(indices.count / 3)

        for i in stride(from: 0, to: indices.count, by: 3) {
            let i0 = Int(indices[i])
            let i1 = Int(indices[i + 1])
            let i2 = Int(indices[i + 2])
            let center = (positions[i0] + positions[i1] + positions[i2]) / 3
            let dist = simd_distance(center, cameraPosition)
            if dist < profile.objectMinDistance || dist > profile.objectMaxDistance {
                continue
            }

            if profile.subject == .ultraDetailObject {
                let area = simd_length(simd_cross(positions[i1] - positions[i0], positions[i2] - positions[i0])) * 0.5
                if area < 1e-6 {
                    continue
                }
            }

            keptVertices.insert(i0)
            keptVertices.insert(i1)
            keptVertices.insert(i2)
            keptTriangles.append((i0, i1, i2))
        }

        guard !keptTriangles.isEmpty else {
            return PreparedMesh(positions: [], normals: [], indices: [])
        }

        var remap: [Int: UInt32] = [:]
        var newPositions: [SIMD3<Float>] = []
        var newNormals: [SIMD3<Float>] = []
        newPositions.reserveCapacity(keptVertices.count)
        newNormals.reserveCapacity(keptVertices.count)
        for oldIndex in keptVertices.sorted() {
            remap[oldIndex] = UInt32(newPositions.count)
            newPositions.append(positions[oldIndex])
            newNormals.append(normals[oldIndex])
        }

        var newIndices: [UInt32] = []
        newIndices.reserveCapacity(keptTriangles.count * 3)
        for tri in keptTriangles {
            guard let a = remap[tri.0], let b = remap[tri.1], let c = remap[tri.2] else { continue }
            newIndices.append(contentsOf: [a, b, c])
        }

        return PreparedMesh(positions: newPositions, normals: newNormals, indices: newIndices)
    }

    private static func cameraPosition(frame: ARFrame) -> SIMD3<Float> {
        let t = frame.camera.transform
        return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
    }

    private static func profileForPosition(
        _ position: SIMD3<Float>,
        baseProfile: ExportProfile,
        detailPatches: [DetailPatch]
    ) -> ExportProfile {
        for patch in detailPatches {
            if simd_distance(position, patch.center) <= patch.radius * 1.35 {
                return ExportProfile(subject: .ultraDetailObject)
            }
        }
        return baseProfile
    }

    private static func nearestPatchID(
        for position: SIMD3<Float>,
        detailPatches: [DetailPatch],
        expandFactor: Float = 1.35
    ) -> UUID? {
        nearestPatch(to: position, detailPatches: detailPatches, expandFactor: expandFactor)?.id
    }

    private static func nearestPatch(
        to position: SIMD3<Float>,
        detailPatches: [DetailPatch],
        expandFactor: Float
    ) -> DetailPatch? {
        var best: DetailPatch?
        var bestDist = Float.greatestFiniteMagnitude
        for patch in detailPatches {
            let d = simd_distance(position, patch.center)
            if d <= patch.radius * expandFactor, d < bestDist {
                best = patch
                bestDist = d
            }
        }
        return best
    }

    private static func mergedCandidateSnapshots(
        baseSnapshots: [FusionFrameSnapshot],
        detailPatches: [DetailPatch]
    ) -> [FusionFrameSnapshot] {
        historyQueue.sync {
            var combined = baseSnapshots
            for patch in detailPatches {
                if let snaps = patchFrameSnapshotHistory[patch.id] {
                    combined.append(contentsOf: snaps.suffix(maxFusionSnapshots))
                }
            }

            var unique: [FusionFrameSnapshot] = []
            var seenTs: [TimeInterval] = []
            unique.reserveCapacity(combined.count)
            for snap in combined {
                if seenTs.contains(where: { abs($0 - snap.timestamp) < 1e-4 }) { continue }
                seenTs.append(snap.timestamp)
                unique.append(snap)
            }
            return unique
        }
    }

    /// Chọn vài fusion frame làm ô trong atlas — chỉ materialize adapters, không `[ARFrame]`.
    private static func bestTextureFusionFrames(
        snapshots: [FusionFrameSnapshot],
        current: ARFrame,
        preparedMeshes: [PreparedMesh],
        profile: ExportProfile,
        detailPatches: [DetailPatch]
    ) -> [ColorFusionFrame] {
        let mergedSnapsUnsorted = mergedCandidateSnapshots(baseSnapshots: snapshots, detailPatches: detailPatches)
        let mergedSnaps = mergedSnapsUnsorted.sorted { $0.timestamp < $1.timestamp }

        let snapsForMaterialize: [FusionFrameSnapshot]
        if mergedSnaps.count > 48 {
            let step = max(1, mergedSnaps.count / 48)
            snapsForMaterialize = stride(from: 0, to: mergedSnaps.count, by: step).map { mergedSnaps[$0] }
        } else {
            snapsForMaterialize = mergedSnaps
        }

        let materialized = materializeFusionSnapshots(
            current: current,
            snapshots: snapsForMaterialize,
            maxStillImageDecode: maxDecodedBGRAAtlas
        )

        let allPoints = preparedMeshes.flatMap { $0.positions }
        let samplePoints = allPoints.enumerated().compactMap { idx, p in
            idx % 18 == 0 ? p : nil
        }
        guard !samplePoints.isEmpty else {
            return materialized.isEmpty ? [ARFrameFusionAdapter(current)] : materialized
        }

        let effectiveAtlasCount = max(profile.atlasFrameCount, detailPatches.isEmpty ? 0 : ExportProfile(subject: .ultraDetailObject).atlasFrameCount)
        let patchCenters = detailPatches.map(\.center)
        let patchRadii = detailPatches.map(\.radius)

        let scored = materialized.enumerated().map { frameOrder, fus -> (ColorFusionFrame, Float) in
            let camPos = cameraPosition(fusion: fus)
            let pb = fus.fusionCapturedImage
            let w = CVPixelBufferGetWidth(pb)
            let h = CVPixelBufferGetHeight(pb)
            var score: Float = 0
            var hits = 0

            for sp in samplePoints {
                let localProfile = profileForPosition(sp, baseProfile: profile, detailPatches: detailPatches)
                let normal = simd_normalize(camPos - sp)
                guard let pt = textureCoordinatePointFusion(
                    worldPosition: sp,
                    normal: normal,
                    fusion: fus,
                    profile: localProfile,
                    allowRelaxedFallback: false,
                    diag: nil
                ) else { continue }
                let depth = simd_distance(camPos, sp)
                let border = imageBorderWeight(point: pt, width: w, height: h)
                let center = centerWeight(point: pt, width: w, height: h, bias: localProfile.centerBias)
                score += border * center * (1.0 / (1.0 + 0.35 * depth * depth))
                hits += 1
            }

            for (idx, centerPos) in patchCenters.enumerated() {
                let d = simd_distance(camPos, centerPos)
                let patchRadius = idx < patchRadii.count ? patchRadii[idx] : 0.7
                let proximity = max(0, 1 - d / max(patchRadius * 2.5, 0.25))
                score += 1.1 * proximity
                score += 0.7 / (1.0 + 0.6 * d * d)
            }

            score += Float(hits) * 0.15
            score += Float(frameOrder) * 0.03
            return (fus, score)
        }

        let sorted = scored.sorted { $0.1 > $1.1 }
        let take = max(1, effectiveAtlasCount)
        return sorted.prefix(take).map { $0.0 }
    }

    private static func buildTextureAtlas(from frames: [ColorFusionFrame], quality: CGFloat) -> TextureAtlas? {
        guard !frames.isEmpty else { return nil }
        let images = frames.compactMap { fus -> UIImage? in
            let ci = CIImage(cvPixelBuffer: fus.fusionCapturedImage)
            let ctx = CIContext(options: [.useSoftwareRenderer: false])
            guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return nil }
            return UIImage(cgImage: cg)
        }
        guard !images.isEmpty else { return nil }

        let tileW = images.map(\.size.width).max() ?? 0
        let tileH = images.map(\.size.height).max() ?? 0
        guard tileW > 0, tileH > 0 else { return nil }

        let columns = images.count == 1 ? 1 : 2
        let rows = Int(ceil(Double(images.count) / Double(columns)))
        let atlasSize = CGSize(width: tileW * CGFloat(columns), height: tileH * CGFloat(rows))
        let renderer = UIGraphicsImageRenderer(size: atlasSize)
        var tiles: [TextureAtlas.Tile] = []
        tiles.reserveCapacity(images.count)

        let atlasImage = renderer.image { _ in
            UIColor.black.setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: atlasSize)).fill()

            for (idx, image) in images.enumerated() {
                let col = idx % columns
                let row = idx / columns
                let origin = CGPoint(x: CGFloat(col) * tileW, y: CGFloat(row) * tileH)
                let rect = CGRect(origin: origin, size: CGSize(width: tileW, height: tileH))
                image.draw(in: rect)
                tiles.append(.init(origin: origin, size: rect.size))
            }
        }

        guard let jpegData = atlasImage.jpegData(compressionQuality: quality) else { return nil }
        return TextureAtlas(jpegData: jpegData, size: atlasSize, tiles: tiles)
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

    // MARK: - Projection (intrinsics / imageResolution → capturedImage pixel coords)

    /// World ↔ buffer bug class: **`ARCamera.projectPoint`/`intrinsics`** live in `imageResolution` space while sampling uses **`CVPixelBufferGetWidth`**; portrait UI often **transpose** WxH vs YUV plane.
    private static func mapCalibrationPointToCaptureBufferPixels(
        pointCalibration: CGPoint,
        calibrationSize ref: CGSize,
        bufferPixelWidth bw: Int,
        bufferPixelHeight bh: Int
    ) -> CGPoint {
        let refW = max(ref.width, 1)
        let refH = max(ref.height, 1)

        func scaleStraight(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x / refW * CGFloat(bw), y: p.y / refH * CGFloat(bh))
        }

        func scaleTransposed(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.y / refH * CGFloat(bw), y: p.x / refW * CGFloat(bh))
        }

        func inPixels(_ p: CGPoint, margin m: CGFloat) -> Bool {
            p.x >= -m && p.y >= -m && p.x < CGFloat(bw) + m && p.y < CGFloat(bh) + m
        }

        let sStraight = scaleStraight(pointCalibration)
        let sTranspose = scaleTransposed(pointCalibration)
        let m: CGFloat = 2

        let matchStraightDims =
            abs(Int(round(ref.width)) - bw) <= 3 && abs(Int(round(ref.height)) - bh) <= 3
        let matchTransposeDims =
            abs(Int(round(ref.width)) - bh) <= 3 && abs(Int(round(ref.height)) - bw) <= 3

        if matchStraightDims { return sStraight }
        if matchTransposeDims { return sTranspose }

        let okStraight = inPixels(sStraight, margin: m)
        let okTranspose = inPixels(sTranspose, margin: m)
        if okStraight && !okTranspose { return sStraight }
        if okTranspose && !okStraight { return sTranspose }

        let arRef = ref.width / ref.height
        let arBuf = CGFloat(bw) / CGFloat(max(bh, 1))
        if okStraight && okTranspose {
            let deltaStraight = abs(arRef - arBuf)
            let deltaTranspose = abs(ref.height / ref.width - arBuf)
            return deltaStraight <= deltaTranspose ? sStraight : sTranspose
        }

        return sStraight
    }

    private static func clampPixelToCaptureBufferForgiving(_ p: CGPoint, bufferPixelWidth bw: Int, bufferPixelHeight bh: Int) -> CGPoint? {
        guard bw >= 2, bh >= 2 else { return nil }
        let maxOs = CGFloat(max(180, max(bw, bh) / 5))
        let cx = CGFloat(bw - 1) / 2
        let cy = CGFloat(bh - 1) / 2
        let bx = min(max(p.x, CGFloat(0)), CGFloat(bw - 1))
        let by = min(max(p.y, CGFloat(0)), CGFloat(bh - 1))
        if hypot(p.x - bx, p.y - by) <= maxOs {
            return CGPoint(x: bx, y: by)
        }
        if hypot(p.x - cx, p.y - cy) <= hypot(CGFloat(bw), CGFloat(bh)) * 0.58 {
            return CGPoint(x: bx, y: by)
        }
        return nil
    }

    /// Multi-frame weighted colour fusion (`ColorFusionFrame` adapters — không giữ ARFrame trong lịch sử).
    private static func sampleCameraColor(worldPosition: SIMD3<Float>, worldNormal: SIMD3<Float>?, frame: ARFrame, diag: ColorDiag? = nil) -> SIMD3<Float> {
        sampleCameraColor(
            worldPosition: worldPosition,
            worldNormal: worldNormal,
            frame: frame,
            diag: diag,
            profile: ExportProfile(subject: .room),
            preferredPatchID: nil
        )
    }

    private static func sampleCameraColor(
        worldPosition: SIMD3<Float>,
        worldNormal: SIMD3<Float>?,
        frame: ARFrame,
        diag: ColorDiag? = nil,
        profile: ExportProfile,
        preferredPatchID: UUID?
    ) -> SIMD3<Float> {
        let frames = materializedFramesForVertexExport(
            frame: frame,
            preferredPatchID: preferredPatchID,
            anchorWorldPosition: worldPosition
        )
        return sampleCameraColorMaterialized(
            worldPosition: worldPosition,
            worldNormal: worldNormal,
            materialized: frames,
            diag: diag,
            profile: profile
        )
    }

    private static func sampleCameraColorMaterialized(
        worldPosition: SIMD3<Float>,
        worldNormal: SIMD3<Float>?,
        materialized: [ColorFusionFrame],
        diag: ColorDiag? = nil,
        profile: ExportProfile
    ) -> SIMD3<Float> {
        if materialized.isEmpty { diag?.countNoFrames(); return SIMD3<Float>(repeating: 0.45) }
        let refCDF = materialized.first?.fusionLumaCDF ?? FusionLumaHistogram.linearIdentityCDF()

        for relaxedPass in [false, true] {
            var colorAccum = SIMD3<Float>(0, 0, 0)
            var weightAccum: Float = 0
            var bestColor = SIMD3<Float>(repeating: 0.45)
            var bestWeight: Float = -.greatestFiniteMagnitude
            var secondBestWeight: Float = -.greatestFiniteMagnitude

            for (idx, f) in materialized.enumerated() {
                guard let (color, weight) = evaluateFrameColor(
                    fusion: f,
                    frameOrder: idx,
                    totalFrames: materialized.count,
                    worldPosition: worldPosition,
                    worldNormal: worldNormal,
                    diag: diag,
                    profile: profile,
                    referenceLumaCDF: refCDF,
                    relaxedCoverageGates: relaxedPass
                ) else { continue }
                colorAccum += color * weight
                weightAccum += weight
                if weight > bestWeight {
                    secondBestWeight = max(secondBestWeight, bestWeight)
                    bestWeight = weight
                    bestColor = color
                } else {
                    secondBestWeight = max(secondBestWeight, weight)
                }
            }

            guard weightAccum > 1e-5 else {
                if relaxedPass { break }
                continue
            }
            diag?.countColor()
            diag?.recordFusion(weight: weightAccum, bestWeight: bestWeight)
            let fused = simd_clamp(colorAccum / weightAccum, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
            let dominanceRatio: Float =
                secondBestWeight > -.greatestFiniteMagnitude / 4
                    ? bestWeight / max(secondBestWeight, 1e-8)
                    : 0
            let dominant =
                !relaxedPass
                && (
                    (bestWeight >= profile.bestFrameAbsolutePickWeight)
                    || (
                        dominanceRatio >= profile.bestFrameDominanceRatio
                        && bestWeight >= profile.bestFrameMinAbsoluteWeight
                    )
                )
            let finalColor: SIMD3<Float>
            if dominant {
                finalColor = simd_clamp(bestColor, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
            } else if profile.bestFrameBlend > 0, bestWeight > 0 {
                var blendAmt = profile.bestFrameBlend
                if bestWeight >= profile.bestFrameHeavyWeightThreshold {
                    blendAmt *= profile.bestFrameHeavyWeightBlendFactor
                }
                blendAmt = min(blendAmt, 0.95)
                if relaxedPass {
                    blendAmt = min(blendAmt, Float(0.38))
                }
                finalColor = simd_mix(fused, bestColor, SIMD3<Float>(repeating: blendAmt))
            } else {
                finalColor = fused
            }
            let enhanced = enhanceSampledColor(finalColor, profile: profile)
            diag?.recordResolvedColor(enhanced)
            return enhanced
        }

        diag?.countZeroWeight()
        return SIMD3<Float>(repeating: 0.45)
    }

    private static func evaluateFrameColor(
        fusion frame: ColorFusionFrame,
        frameOrder: Int,
        totalFrames: Int,
        worldPosition: SIMD3<Float>,
        worldNormal: SIMD3<Float>?,
        diag: ColorDiag? = nil,
        profile: ExportProfile,
        referenceLumaCDF: ContiguousArray<Float>,
        relaxedCoverageGates: Bool = false
    ) -> (SIMD3<Float>, Float)? {
        let invT = frame.fusionCameraTransform.inverse
        let cam = invT * SIMD4<Float>(worldPosition.x, worldPosition.y, worldPosition.z, 1)
        if cam.z > -0.01 {
            diag?.countBehindCam()
            return nil
        }

        let camPos = cameraPosition(fusion: frame)
        let toCameraVec = camPos - worldPosition
        let dist = simd_length(toCameraVec)
        if dist < 1e-4 {
            diag?.countBehindCam()
            return nil
        }
        let toCamera = toCameraVec / dist

        let ndotl: Float
        if let n = worldNormal {
            ndotl = simd_dot(simd_normalize(n), toCamera)
        } else {
            ndotl = 0.5
        }

        let projected: CGPoint
        if let p = projectWorldToImagePixel(worldPosition: worldPosition, fusion: frame) {
            projected = p
        } else {
            var rescuedPoint: CGPoint?
            if let n = worldNormal {
                let nn = simd_normalize(n)
                let offsets: [Float] = profile.subject == .nearbyObject ? [0.003, 0.006, 0.010, 0.016, 0.024] : [0.003, 0.006, 0.010]
                for d in offsets {
                    if let p = projectWorldToImagePixel(worldPosition: worldPosition + nn * d, fusion: frame) {
                        rescuedPoint = p
                        break
                    }
                    if let p = projectWorldToImagePixel(worldPosition: worldPosition - nn * d, fusion: frame) {
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

        let pb = frame.fusionCapturedImage
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let geometricDepth = dist
        let frontalDepth01 = simd_clamp(simd_max(0, ndotl), 0, 1)
        if let dm = frame.fusionDepthMap {
            if !projectionDepthOcclusionPasses(
                depthMap: dm,
                projected: projected,
                imageWidth: w,
                imageHeight: h,
                geometricDepth: geometricDepth,
                surfaceFrontal01: frontalDepth01,
                profile: profile,
                relaxTolerance: relaxedCoverageGates
            ) {
                diag?.countDepthMismatch()
                return nil
            }
        } else if let mini = frame.fusionPackedMiniDepth {
            if !projectionMiniDepthOcclusionPasses(
                mini: mini,
                projected: projected,
                imageWidth: w,
                imageHeight: h,
                geometricDepth: geometricDepth,
                surfaceFrontal01: frontalDepth01,
                profile: profile,
                relaxTolerance: relaxedCoverageGates
            ) {
                diag?.countDepthMismatch()
                return nil
            }
        } else {
            let frontal = simd_max(0, ndotl)
            let frontalMinScale: Float = relaxedCoverageGates ? 0.55 : 1.0
            guard frontal >= profile.fusionMinFrontalContributionNoLiDAR * frontalMinScale else {
                diag?.countDepthMismatch()
                return nil
            }
        }

        let sobelMag = fusionSobelLumaMagnitude(pixelBuffer: pb, at: projected, width: w, height: h)
        let sobelFloor = relaxedCoverageGates
            ? simd_max(Float(0.0045), profile.fusionMinSobelMagnitude * Float(0.26))
            : profile.fusionMinSobelMagnitude
        let sobelOK = sobelMag >= sobelFloor
            || frame.fusionImageSharpness01 >= profile.fusionSharpnessBypassSobel
        guard sobelOK else {
            diag?.countZeroWeight()
            return nil
        }

        var sampled = sampleRGB3x3(pixelBuffer: pb, at: projected, width: w, height: h)
        let y0 = luma01FromRGB(sampled)
        let y1 = FusionLumaHistogram.matchLuma(y0, cdfSource: frame.fusionLumaCDF, cdfRef: referenceLumaCDF)
        let scaleHist = y1 / max(y0, 1e-4)
        sampled = simd_clamp(sampled * scaleHist, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))

        let cx = min(max(projected.x, 0), CGFloat(max(w - 1, 0)))
        let cy = min(max(projected.y, 0), CGFloat(max(h - 1, 0)))
        let centerTap = sampleRGBAtImage(pixelBuffer: pb, x: cx, y: cy, width: w, height: h)
        let edgeGate = simd_clamp(sobelMag * 11.0, 0, 1)
        let kSharpen = profile.fusionMicroContrastStrength * (Float(0.26) + Float(0.74) * edgeGate)
        sampled = simd_clamp(sampled + kSharpen * (centerTap - sampled), SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))

        if worldNormal != nil, ndotl < -0.80 { diag?.countBackface() }

        // Production-weight: sharp * frontal^2 * exp(-k d^2) × edge-aware × heuristic bonuses.
        let frontal = simd_max(0, ndotl)
        let angularW = frontal * frontal
        let sharpW = max(frame.fusionImageSharpness01, Float(1e-4))
        let distGaussian = exp(-profile.fusionGaussianDistanceK * dist * dist)
        let shaped = simd_clamp(sobelMag * 6.5, 0, 14)
        let edgeBoost = 1 + profile.fusionEdgeBoostScale * shaped
        let borderWeight = imageBorderWeight(point: projected, width: w, height: h)
        let recency = Float(frameOrder + 1) / Float(max(totalFrames, 1))
        let temporalWeight = profile.fusionTemporalBaseline + profile.fusionTemporalRecencyMix * recency
        var weight = sharpW * angularW * distGaussian * borderWeight * temporalWeight * edgeBoost
        if frameOrder == 0 {
            weight *= profile.fusionReferenceFrameWeightBoost
        }
        if weight < 1e-5 {
            diag?.countZeroWeight()
            return nil
        }
        return (sampled, weight)
    }

    private static func cameraPosition(fusion: ColorFusionFrame) -> SIMD3<Float> {
        let c = fusion.fusionCameraTransform.columns.3
        return SIMD3<Float>(c.x, c.y, c.z)
    }

    /// Depth/occlusion: median 3×3 trên LiDAR depth so với khoảng cách geometrictheo ray — lọc trọng lực/occlusion sai (nguồn blur chính).
    private static func projectionDepthOcclusionPasses(
        depthMap: CVPixelBuffer,
        projected: CGPoint,
        imageWidth: Int,
        imageHeight: Int,
        geometricDepth: Float,
        surfaceFrontal01: Float,
        profile: ExportProfile,
        relaxTolerance: Bool
    ) -> Bool {

        let depthW = CVPixelBufferGetWidth(depthMap)
        let depthH = CVPixelBufferGetHeight(depthMap)
        guard depthW > 2, depthH > 2, imageWidth > 1, imageHeight > 1 else { return true }

        let frontal = simd_clamp(surfaceFrontal01, Float(0), Float(1))
        let tolScale = simd_mix(profile.fusionNormalOcclusionTolScaleMin, 1.0, frontal * frontal)
        let spreadScale = simd_mix(profile.fusionNormalOcclusionSpreadScaleMin, 1.0, frontal)

        let baseX = (projected.x / CGFloat(imageWidth)) * CGFloat(depthW - 1)
        let baseY = (projected.y / CGFloat(imageHeight)) * CGFloat(depthH - 1)

        var taps: [Float] = []
        taps.reserveCapacity(9)
        for oy in -1...1 {
            for ox in -1...1 {
                let ix = Int(floor(baseX)) + ox
                let iy = Int(floor(baseY)) + oy
                guard ix >= 0, ix < depthW, iy >= 0, iy < depthH else { continue }
                if let d = sampleDepthPoint(pixelBuffer: depthMap, x: ix, y: iy),
                   d.isFinite, d > 1e-4 {
                    taps.append(d)
                }
            }
        }
        guard taps.count >= 5 else {
            return relaxTolerance
        }

        taps.sort()
        let medianDepth = taps[taps.count / 2]
        let spread = taps.last! - taps.first!
        let relax: Float = relaxTolerance ? 1.75 : 1.0
        let tol = max(profile.depthToleranceBase, geometricDepth * profile.depthToleranceScale) * relax * tolScale
        guard abs(medianDepth - geometricDepth) <= tol else { return false }
        guard spread <= profile.maxMedianDepthNeighborSpreadMeters * relax * spreadScale else { return false }

        return true
    }

    /// Cùng logic tolerance nhưng trên coarse depth pack (historical snapshots).
    private static func projectionMiniDepthOcclusionPasses(
        mini: FusionPackedMiniDepth,
        projected: CGPoint,
        imageWidth: Int,
        imageHeight: Int,
        geometricDepth: Float,
        surfaceFrontal01: Float,
        profile: ExportProfile,
        relaxTolerance: Bool
    ) -> Bool {
        guard mini.gridW > 2, mini.gridH > 2, imageWidth > 1, imageHeight > 1 else {
            return relaxTolerance
        }
        let frontal = simd_clamp(surfaceFrontal01, Float(0), Float(1))
        let tolScale = simd_mix(profile.fusionNormalOcclusionTolScaleMin, 1.0, frontal * frontal)
        let spreadScale = simd_mix(profile.fusionNormalOcclusionSpreadScaleMin, 1.0, frontal)

        let nx = (projected.x / CGFloat(imageWidth)) * CGFloat(mini.gridW - 1)
        let ny = (projected.y / CGFloat(imageHeight)) * CGFloat(mini.gridH - 1)
        let cx = Int(floor(nx))
        let cy = Int(floor(ny))

        var taps: [Float] = []
        taps.reserveCapacity(9)
        mini.millimetresLE.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let p = base.assumingMemoryBound(to: UInt16.self)
            for oy in -1...1 {
                for ox in -1...1 {
                    let ix = cx + ox
                    let iy = cy + oy
                    guard ix >= 0, ix < mini.gridW, iy >= 0, iy < mini.gridH else { continue }
                    let mm = UInt16(littleEndian: p[iy * mini.gridW + ix])
                    if mm > 0 {
                        taps.append(Float(mm) / 1000.0)
                    }
                }
            }
        }
        guard taps.count >= 5 else {
            return relaxTolerance
        }
        taps.sort()
        let medianDepth = taps[taps.count / 2]
        let spread = taps.last! - taps.first!
        let relax: Float = relaxTolerance ? 1.75 : 1.0
        let tol = max(profile.depthToleranceBase, geometricDepth * profile.depthToleranceScale) * relax * 1.15 * tolScale
        guard abs(medianDepth - geometricDepth) <= tol else { return false }
        guard spread <= profile.maxMedianDepthNeighborSpreadMeters * relax * 1.35 * spreadScale else { return false }

        return true
    }

    /// 3×3 Gaussian kernel (9 taps, pre-normalised weights sum to 1.0).
    /// More accurate than the old 5-tap uniform average: corners contribute less,
    /// centre dominates → sharper result with better noise suppression.
    private static func sampleRGB3x3(pixelBuffer: CVPixelBuffer, at p: CGPoint, width: Int, height: Int) -> SIMD3<Float> {
        // (dx, dy, weight)  — Gaussian weights: centre=0.25, edge=0.125, corner=0.0625
        let taps: [(CGFloat, CGFloat, Float)] = [
            (-1, -1, 0.0625), (0, -1, 0.125), (1, -1, 0.0625),
            (-1,  0, 0.125),  (0,  0, 0.25),  (1,  0, 0.125),
            (-1,  1, 0.0625), (0,  1, 0.125), (1,  1, 0.0625)
        ]
        var acc = SIMD3<Float>(0, 0, 0)
        for (dx, dy, w) in taps {
            acc += sampleRGBAtImage(pixelBuffer: pixelBuffer,
                                    x: p.x + dx, y: p.y + dy,
                                    width: width, height: height) * w
        }
        return simd_clamp(acc, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
    }

    @inline(__always)
    private static func luma01FromRGB(_ c: SIMD3<Float>) -> Float {
        simd_dot(c, SIMD3<Float>(0.2126, 0.7152, 0.0722))
    }

    /// Luma tại ô ảnh gần nearest (để Sobel không phụ thuộc kernel bilinear của sampleRGB đứng riêng).
    private static func luma01AtLatticePixel(pixelBuffer: CVPixelBuffer, x: Int, y: Int, width: Int, height: Int) -> Float {
        let xi = min(max(x, 0), max(width - 1, 0))
        let yi = min(max(y, 0), max(height - 1, 0))
        let c = sampleRGBAtImage(pixelBuffer: pixelBuffer, x: CGFloat(xi), y: CGFloat(yi), width: width, height: height)
        return simd_clamp(luma01FromRGB(c), 0, 1)
    }

    /// Edge-aware multiplier: Sobel magnitude trên luma — dùng cùng số học như multiplier để không tính Sobel hai lần ở `evaluateFrameColor`.
    private static func fusionSobelLumaMagnitude(
        pixelBuffer: CVPixelBuffer,
        at projected: CGPoint,
        width: Int,
        height: Int
    ) -> Float {
        let x = Int(projected.x.rounded())
        let y = Int(projected.y.rounded())
        let l00 = luma01AtLatticePixel(pixelBuffer: pixelBuffer, x: x - 1, y: y - 1, width: width, height: height)
        let l01 = luma01AtLatticePixel(pixelBuffer: pixelBuffer, x: x - 1, y: y, width: width, height: height)
        let l02 = luma01AtLatticePixel(pixelBuffer: pixelBuffer, x: x - 1, y: y + 1, width: width, height: height)
        let l10 = luma01AtLatticePixel(pixelBuffer: pixelBuffer, x: x, y: y - 1, width: width, height: height)
        let l12 = luma01AtLatticePixel(pixelBuffer: pixelBuffer, x: x, y: y + 1, width: width, height: height)
        let l20 = luma01AtLatticePixel(pixelBuffer: pixelBuffer, x: x + 1, y: y - 1, width: width, height: height)
        let l21 = luma01AtLatticePixel(pixelBuffer: pixelBuffer, x: x + 1, y: y, width: width, height: height)
        let l22 = luma01AtLatticePixel(pixelBuffer: pixelBuffer, x: x + 1, y: y + 1, width: width, height: height)

        let gx = -l00 + l20 + 2 * (-l01 + l21) + (-l02 + l22)
        let gy = (-l00 - 2 * l10 - l20) + (l02 + 2 * l12 + l22)
        return hypot(gx, gy)
    }

    /// Edge-aware multiplier: Sobel magnitude trên luma — tăng weight ở cạnh / texture high‑frequency.
    private static func fusionEdgeBoostMultiplier(
        pixelBuffer: CVPixelBuffer,
        at projected: CGPoint,
        width: Int,
        height: Int,
        profile: ExportProfile
    ) -> Float {
        let mag = fusionSobelLumaMagnitude(pixelBuffer: pixelBuffer, at: projected, width: width, height: height)
        let shaped = simd_clamp(mag * 6.5, 0, 14)
        return 1 + profile.fusionEdgeBoostScale * shaped
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

    private static func bestTextureProjection(
        worldPosition: SIMD3<Float>,
        normal: SIMD3<Float>,
        frames: [ColorFusionFrame],
        profile: ExportProfile,
        diag: TextureDiag? = nil
    ) -> TextureProjection? {
        var best: TextureProjection?
        for (idx, fus) in frames.enumerated() {
            guard let pt = textureCoordinatePointFusion(
                worldPosition: worldPosition,
                normal: normal,
                fusion: fus,
                profile: profile,
                allowRelaxedFallback: false,
                diag: diag
            ) else { continue }
            let camPos = cameraPosition(fusion: fus)
            let depth = simd_distance(camPos, worldPosition)
            let pb = fus.fusionCapturedImage
            let w = CVPixelBufferGetWidth(pb)
            let h = CVPixelBufferGetHeight(pb)
            let border = imageBorderWeight(point: pt, width: w, height: h)
            let center = centerWeight(point: pt, width: w, height: h, bias: profile.centerBias)
            let score = border * center * (1.0 / (1.0 + 0.25 * depth * depth)) + Float(idx) * 0.01
            if best == nil || score > best!.score {
                best = TextureProjection(frameIndex: idx, point: pt, score: score, isRelaxed: false)
            }
        }
        if best != nil {
            return best
        }

        for (idx, fus) in frames.enumerated() {
            guard let pt = textureCoordinatePointFusion(
                worldPosition: worldPosition,
                normal: normal,
                fusion: fus,
                profile: profile,
                allowRelaxedFallback: true,
                diag: nil
            ) else { continue }
            let camPos = cameraPosition(fusion: fus)
            let depth = simd_distance(camPos, worldPosition)
            let pb = fus.fusionCapturedImage
            let w = CVPixelBufferGetWidth(pb)
            let h = CVPixelBufferGetHeight(pb)
            let border = imageBorderWeight(point: pt, width: w, height: h)
            let center = centerWeight(point: pt, width: w, height: h, bias: profile.centerBias)
            let score = 0.55 * border * center * (1.0 / (1.0 + 0.25 * depth * depth)) + Float(idx) * 0.005
            if best == nil || score > best!.score {
                best = TextureProjection(frameIndex: idx, point: pt, score: score, isRelaxed: true)
            }
        }
        return best
    }

    private static func centerWeight(point: CGPoint, width: Int, height: Int, bias: Float) -> Float {
        guard bias > 0 else { return 1 }
        let cx = CGFloat(width) * 0.5
        let cy = CGFloat(height) * 0.5
        let dx = (point.x - cx) / max(CGFloat(width) * 0.5, 1)
        let dy = (point.y - cy) / max(CGFloat(height) * 0.5, 1)
        let d = min(1, sqrt(dx * dx + dy * dy))
        let center = 1 - Float(d)
        return 1 + center * bias
    }

    private static func textureCoordinatePointFusion(
        worldPosition: SIMD3<Float>,
        normal: SIMD3<Float>,
        fusion fus: ColorFusionFrame,
        profile: ExportProfile,
        allowRelaxedFallback: Bool = false,
        diag: TextureDiag? = nil
    ) -> CGPoint? {
        let projected: CGPoint?
        if let point = projectWorldToImagePixel(worldPosition: worldPosition, fusion: fus) {
            projected = point
        } else {
            let nn = simd_normalize(normal)
            let offsets: [Float] = allowRelaxedFallback ? [0.003, 0.006, 0.012, 0.020] : [0.003, 0.006, 0.012]
            var rescued: CGPoint?
            for offset in offsets {
                if let point = projectWorldToImagePixel(worldPosition: worldPosition + nn * offset, fusion: fus) {
                    rescued = point
                    break
                }
                if let point = projectWorldToImagePixel(worldPosition: worldPosition - nn * offset, fusion: fus) {
                    rescued = point
                    break
                }
            }
            projected = rescued
        }
        guard let pt = projected else {
            diag?.countOutOfBounds()
            return nil
        }
        let pb = fus.fusionCapturedImage
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let nv = simd_normalize(normal)
        let camPos = cameraPosition(fusion: fus)
        let viewDir = simd_normalize(camPos - worldPosition)
        let ndotlFacing = abs(simd_dot(nv, viewDir))
        let depth = simd_distance(camPos, worldPosition)

        let facing01 = simd_clamp(ndotlFacing, Float(0), Float(1))

        if let dm = fus.fusionDepthMap {
            guard projectionDepthOcclusionPasses(
                depthMap: dm,
                projected: pt,
                imageWidth: w,
                imageHeight: h,
                geometricDepth: depth,
                surfaceFrontal01: facing01,
                profile: profile,
                relaxTolerance: allowRelaxedFallback
            ) else {
                diag?.countDepthMismatch()
                return nil
            }
        } else if let mini = fus.fusionPackedMiniDepth {
            guard projectionMiniDepthOcclusionPasses(
                mini: mini,
                projected: pt,
                imageWidth: w,
                imageHeight: h,
                geometricDepth: depth,
                surfaceFrontal01: facing01,
                profile: profile,
                relaxTolerance: allowRelaxedFallback
            ) else {
                diag?.countDepthMismatch()
                return nil
            }
        } else {
            let minFrontal = profile.fusionMinFrontalContributionNoLiDAR * (allowRelaxedFallback ? 0.72 : 1.0)
            guard ndotlFacing >= minFrontal else {
                diag?.countDepthMismatch()
                return nil
            }
        }
        let ndotl = ndotlFacing
        let minFacing: Float
        switch profile.subject {
        case .room: minFacing = 0.01
        case .nearbyObject: minFacing = 0.02
        case .ultraDetailObject: minFacing = 0.04
        }
        let facingThreshold = allowRelaxedFallback ? minFacing * 0.4 : minFacing
        guard ndotl >= facingThreshold else {
            diag?.countFacingRejected()
            return nil
        }
        return pt
    }

    /// Sigmoid S-curve: maps [0,1]→[0,1] preserving 0.0 and 1.0 as fixed points.
    /// strength > 1  →  steeper S (more contrast pop).
    /// strength = 1  →  linear pass-through.
    @inline(__always)
    private static func sCurveContrast(_ x: Float, strength: Float) -> Float {
        let v = (x - 0.5) * strength
        return simd_clamp(0.5 + v / (1.0 + abs(v)), 0.0, 1.0)
    }

    private static func enhanceSampledColor(_ color: SIMD3<Float>, profile: ExportProfile) -> SIMD3<Float> {
        // 1. Saturation — simple linear boost around luma, preserving luminance.
        //    No vibrance/vibrancy: it over-pushes near-grey surfaces (walls, ceiling)
        //    into artificially coloured results that don't match reality.
        let luma = simd_dot(color, SIMD3<Float>(0.2126, 0.7152, 0.0722))
        let gray = SIMD3<Float>(repeating: luma)
        let saturated = simd_clamp(gray + (color - gray) * profile.saturationBoost,
                                   SIMD3<Float>(0), SIMD3<Float>(1))

        // 2. Gentle S-curve contrast — mild, just to add a touch of pop.
        let s = profile.contrastBoost
        let curved = SIMD3<Float>(
            sCurveContrast(saturated.x, strength: s),
            sCurveContrast(saturated.y, strength: s),
            sCurveContrast(saturated.z, strength: s)
        )

        let lfMid = simd_dot(curved, SIMD3<Float>(0.2126, 0.7152, 0.0722))
        let midGate = simd_clamp(Float(1.12) - abs(lfMid - Float(0.445)) / Float(0.62), Float(0), Float(1))
        let ripple = profile.postFusionLocalContrastRipple * midGate
        let tonal = SIMD3<Float>(
            simd_clamp(curved.x + (curved.x - lfMid) * ripple, Float(0), Float(1)),
            simd_clamp(curved.y + (curved.y - lfMid) * ripple, Float(0), Float(1)),
            simd_clamp(curved.z + (curved.z - lfMid) * ripple, Float(0), Float(1))
        )

        // 3. Gamma — stay close to 1.0 so light-coloured surfaces stay accurate.
        let gamma = profile.gammaCorrection
        let corrected = SIMD3<Float>(
            pow(tonal.x, gamma),
            pow(tonal.y, gamma),
            pow(tonal.z, gamma)
        )
        return simd_clamp(corrected, SIMD3<Float>(0), SIMD3<Float>(1))
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

    /// World → pixel trong **capture buffer** của `frame.capturedImage` (≠ UI displayTransform).
    /// Bug trước: kiểm biên qua `imageResolution`/`projectPoint(viewport)` rồi sample theo WxH của `CVPixelBuffer` khác transpose/scale ⇒ ~OOB artefact cực lớn.
    private static func projectWorldToImagePixel(worldPosition: SIMD3<Float>, frame: ARFrame) -> CGPoint? {
        let camera = frame.camera

        let camPt = camera.transform.inverse * SIMD4<Float>(worldPosition.x, worldPosition.y, worldPosition.z, 1)
        if camPt.z > -0.01 { return nil }

        let calibrationSize = camera.imageResolution
        let viewport = CGSize(width: calibrationSize.width, height: calibrationSize.height)
        let depth = -camPt.z
        guard depth > 1e-5 else { return nil }

        let pb = frame.capturedImage
        let bw = CVPixelBufferGetWidth(pb)
        let bh = CVPixelBufferGetHeight(pb)

        var oriQueue: [UIInterfaceOrientation] = [
            activeInterfaceOrientation(),
            .portrait,
            .landscapeRight,
            .landscapeLeft,
            .portraitUpsideDown
        ]
        var seenOri = Set<Int>()
        oriQueue.removeAll { ori in !seenOri.insert(ori.rawValue).inserted }

        for ori in oriQueue {
            let ppt = camera.projectPoint(worldPosition, orientation: ori, viewportSize: viewport)
            let mapped = mapCalibrationPointToCaptureBufferPixels(
                pointCalibration: ppt,
                calibrationSize: calibrationSize,
                bufferPixelWidth: bw,
                bufferPixelHeight: bh
            )
            if mapped.x >= 0 && mapped.y >= 0 && mapped.x <= CGFloat(max(bw - 1, 0)) && mapped.y <= CGFloat(max(bh - 1, 0)) {
                return mapped
            }
            if let c = clampPixelToCaptureBufferForgiving(mapped, bufferPixelWidth: bw, bufferPixelHeight: bh) {
                return c
            }
        }

        let K = camera.intrinsics
        let fx = CGFloat(K[0][0])
        let fy = CGFloat(K[1][1])
        let cx = CGFloat(K[2][0])
        let cy = CGFloat(K[2][1])

        let pxRaw = fx * CGFloat(camPt.x) / CGFloat(depth) + cx
        let pyRaw = cy - fy * CGFloat(camPt.y) / CGFloat(depth)
        let manualCal = CGPoint(x: pxRaw, y: pyRaw)

        let mappedManual = mapCalibrationPointToCaptureBufferPixels(
            pointCalibration: manualCal,
            calibrationSize: calibrationSize,
            bufferPixelWidth: bw,
            bufferPixelHeight: bh
        )
        if mappedManual.x >= 0 && mappedManual.y >= 0
            && mappedManual.x <= CGFloat(max(bw - 1, 0)) && mappedManual.y <= CGFloat(max(bh - 1, 0)) {
            return mappedManual
        }
        if let c = clampPixelToCaptureBufferForgiving(mappedManual, bufferPixelWidth: bw, bufferPixelHeight: bh) {
            return c
        }
        return nil
    }

    /// Adapter fusion không có ARCamera → pinhole trong domain intrinsics/`imageResolution` rồi map sang WxH của buffer đích.
    private static func projectWorldToImagePixel(worldPosition: SIMD3<Float>, fusion frame: ColorFusionFrame) -> CGPoint? {
        let camPt = frame.fusionCameraTransform.inverse * SIMD4<Float>(worldPosition.x, worldPosition.y, worldPosition.z, 1)
        if camPt.z > -0.01 { return nil }

        let calibrationSize = frame.fusionImageResolution
        let depth = -camPt.z
        guard depth > 1e-5 else { return nil }

        let K = frame.fusionIntrinsics
        let fx = CGFloat(K[0][0])
        let fy = CGFloat(K[1][1])
        let cx = CGFloat(K[2][0])
        let cy = CGFloat(K[2][1])

        let pxRaw = fx * CGFloat(camPt.x) / CGFloat(depth) + cx
        let pyRaw = cy - fy * CGFloat(camPt.y) / CGFloat(depth)
        let manualCal = CGPoint(x: pxRaw, y: pyRaw)

        let pb = frame.fusionCapturedImage
        let bw = CVPixelBufferGetWidth(pb)
        let bh = CVPixelBufferGetHeight(pb)

        let mapped = mapCalibrationPointToCaptureBufferPixels(
            pointCalibration: manualCal,
            calibrationSize: calibrationSize,
            bufferPixelWidth: bw,
            bufferPixelHeight: bh
        )
        if mapped.x >= 0 && mapped.y >= 0
            && mapped.x <= CGFloat(max(bw - 1, 0)) && mapped.y <= CGFloat(max(bh - 1, 0)) {
            return mapped
        }
        if let c = clampPixelToCaptureBufferForgiving(mapped, bufferPixelWidth: bw, bufferPixelHeight: bh) {
            return c
        }
        return nil
    }

    /// Log thông tin frame và pixel format trước khi export.
    private static func logExportHeader(tag: String, frame: ARFrame) {
        let fusionCount = selectFusionSnapshots(including: frame).count
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
        let cal = frame.camera.imageResolution
        let K = frame.camera.intrinsics
        print("""
[ColorDiag] --- \(tag) Export bắt đầu ---
  Fusion frames  : \(fusionCount)
  Pixel format   : \(fmtName)
  Buffer size    : \(imgW) x \(imgH)
  Calib size     : \(Int(cal.width)) x \(Int(cal.height))  ← phải khớp map vào buffer hoặc transpose
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
            return SIMD3<Float>(repeating: 0.45)
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
            return SIMD3<Float>(repeating: 0.45)
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
