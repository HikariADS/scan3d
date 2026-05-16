/*
 Tóm tắt:
 Xuất mesh scene ARKit dạng Wavefront OBJ / PLY, có màu camera theo đỉnh và pháp tuyến.
 */

import ARKit
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import simd
import UIKit
import UniformTypeIdentifiers

// MARK: - Pipeline fusion màu (KHÔNG giữ ARFrame trong mảng — ARSession giữ ≤~4 buffer camera)

/// Codec snapshot: HEIC (thân thiện 10-bit, ít block artefact hơn JPEG) hoặc JPEG khi fallback.
private enum FusionSnapshotImageCodec: UInt8 {
    case heic = 0
    case jpeg = 1
}

/// Depth đã downsample đi kèm mỗi snapshot để frame cũ vẫn chạy cùng logic median occlusion,
/// không cần lưu cả history `CVPixelBuffer` đầy đủ. ~96×72×2 B ≈ 14 KiB/frame (an toàn RAM hơn full map).
private struct FusionPackedMiniDepth: Equatable {
    let gridW: Int
    let gridH: Int
    /// Độ sâu UInt16 theo hàng (LE), đơn vị mm. `0` = không hợp lệ / không biết.
    let millimetresLE: Data

    private static let maxGridW = 96
    private static let maxGridH = 72

    /// Pack từ depth map ARKit (float mét). Tọa độ căn grid pixel `imageWidth`×`imageHeight`.
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

/// Histogram luma 16 bin → CDF 17 điểm để căn tone rẻ theo pixel (tham chiếu = frame live đầu tiên trong fusion).
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

    /// Ánh xạ luma qua CDF nguồn sang CDF tham chiếu (histogram match, nghịch đảo O(số bin)).
    static func matchLuma(_ y: Float, cdfSource: ContiguousArray<Float>, cdfRef: ContiguousArray<Float>) -> Float {
        guard cdfSource.count == 17, cdfRef.count == 17 else { return y }
        let yy = simd_clamp(y, 0, 1)
        let f = yy * Float(binCount)
        let i0 = min(binCount - 1, max(0, Int(floor(f))))
        let i1 = min(binCount, i0 + 1)
        let t = f - Float(i0)
        let u = cdfSource[i0] * (1 - t) + cdfSource[i1] * t
        // Nghịch đảo CDF tham chiếu
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

/// Snapshot live hoặc đã decode — dùng cho projection + sampling RGB mà không giữ `ARFrame` trong history.
private protocol ColorFusionFrame: AnyObject {
    var fusionTimestamp: TimeInterval { get }
    var fusionCameraTransform: simd_float4x4 { get }
    var fusionIntrinsics: simd_float3x3 { get }
    var fusionImageResolution: CGSize { get }
    var fusionCapturedImage: CVPixelBuffer { get }
    /// Depth LiDAR live full-res khi có.
    var fusionDepthMap: CVPixelBuffer? { get }
    /// Depth thô đi kèm mỗi snapshot (frame cũ); adapter live trả `nil` và dùng `fusionDepthMap`.
    var fusionPackedMiniDepth: FusionPackedMiniDepth? { get }
    /// Phân phối luma tích lũy 17 điểm (0…1) phục vụ histogram match.
    var fusionLumaCDF: ContiguousArray<Float> { get }
    /// ~0–1 từ năng lượng Laplacian thô; frame mờ thì giảm weight.
    var fusionImageSharpness01: Float { get }
    /// Ước lượng độ sáng trung bình scene 0–1 để chỉnh exposure nhẹ trước fusion.
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
        _ = codec // HEIC và JPEG đều decode qua UIImage; giữ codec cho đường nhanh tương lai
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

/// **Metrics ảnh**: trung bình luma + proxy độ nét (mean |Laplacian| trên grid thưa). Đủ rẻ để gọi mỗi lần ghi snapshot hoặc làm fresh cache.
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

    /// Luma trung bình trên grid + năng lượng Laplacian coarse → đưa qua tanh về khoảng 0–1.
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

// MARK: - Diagnostics debug

/// Counter diagnostics thread-safe cho mỗi lần export; reset trước mỗi lần build.
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
        /// Median(depth 3×3) phải khớp độ sâu geometry; lệch nhiều thường là noise/lỗ hổng → bỏ (tránh smear texture).
        var maxMedianDepthNeighborSpreadMeters: Float {
            switch subject {
            case .room: return 0.38
            case .nearbyObject: return 0.28
            case .ultraDetailObject: return 0.20
            }
        }
        /// **`exp(-k * distance²)` trong weight fusion** — k lớn = bias về viewpoint gần. Với `dist² = 1/k` thì Gaussian ≈ 1/e (~37%).
        /// Tune: quét/rời xa nhanh → giảm k; toàn frame xa máy → giảm k.
        var fusionGaussianDistanceK: Float {
            switch subject {
            case .room: return 0.24
            case .nearbyObject: return 0.38
            case .ultraDetailObject: return 0.55
            }
        }
        /// `weight *= 1 + scale * clipped(gradient)`. scale cao → ưu tiên mép/high‑freq; quá đà → artefact JPEG.
        var fusionEdgeBoostScale: Float {
            switch subject {
            case .room: return 0.42
            case .nearbyObject: return 0.56
            case .ultraDetailObject: return 0.79
            }
        }
        /// Ảnh JPEG trong history không có depth LiDAR — chỉ được góp khi mặt tương đối frontal (thay cho occlusion có depth đầy đủ).
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
            case .room: return 12          // trước 6 — thêm ô để phủ quét cả phòng
            case .nearbyObject: return 8   // trước 4
            case .ultraDetailObject: return 24 // trước 16
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
        /// Khi best áp đảo runner-up đủ tỉ lệ này (và đủ `bestFrameMinAbsoluteWeight`) → lấy mỗi best, không blend.
        var bestFrameDominanceRatio: Float {
            switch subject {
            case .room: return 2.05
            case .nearbyObject: return 2.35
            case .ultraDetailObject: return 2.65
            }
        }
        /// Ngưỡng weight tối thiểu để xét dominance (đủ “tín hiệu” raster, không chỉ là noise nhỏ).
        var bestFrameMinAbsoluteWeight: Float {
            switch subject {
            case .room: return 0.11
            case .nearbyObject: return 0.125
            case .ultraDetailObject: return 0.14
            }
        }
        /// Trên ngưỡng này: luôn pick nguyên màu frame best (confidence cao → tránh làm nhòe blend).
        var bestFrameAbsolutePickWeight: Float {
            switch subject {
            case .room: return 0.38
            case .nearbyObject: return 0.44
            case .ultraDetailObject: return 0.52
            }
        }
        /// Best weight rất cao nhưng chưa tới ngưỡng absolute-pick → siết nhẹ blend.
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
        /// Grazing angle (1−n·v): siết tolerance depth để không “ăn nhầm” occlusion ở rìa nghiêng.
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
        /// Micro-contrast (bilinear − Gaussian): tăng chi tiết vi mô có gate Sobel để không khuếch đại nhiễu đồng nhất.
        var fusionMicroContrastStrength: Float {
            switch subject {
            case .room: return 0.22
            case .nearbyObject: return 0.30
            case .ultraDetailObject: return 0.38
            }
        }
        /// Temporal window chặt hơn ↔ ít “nhảy” màu giữa các frame khi fuse.
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
        /// Frame fusion làm neo (thường live/current) được boost weight để bám màu sát viewpoint hiện tại.
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
        /// Độ mạnh “ripple” quanh local luma đỉnh — bù wash-out sau fuse multi‑frame (không cần patch ảnh lân cận).
        var postFusionLocalContrastRipple: Float {
            switch subject {
            case .room: return 0.050
            case .nearbyObject: return 0.072
            case .ultraDetailObject: return 0.095
            }
        }
        var saturationBoost: Float {
            switch subject {
            case .room: return 2.20   // mạnh — phục hồi màu thực tế rực hơn
            case .nearbyObject: return 2.40
            case .ultraDetailObject: return 2.60
            }
        }
        /// Độ mạnh contrast dạng S-curve; cao hơn = tách tonal rõ hơn (tối và sáng tách mép).
        var contrastBoost: Float {
            switch subject {
            case .room: return 1.55   // đậm — trắng tách khỏi mid-tone
            case .nearbyObject: return 1.70
            case .ultraDetailObject: return 1.85
            }
        }
        /// Gamma > 1 làm ảnh tối hơn — bù cảnh sáng quá / washed-out của frame camera auto exposure ARKit.
        var gammaCorrection: Float {
            switch subject {
            case .room: return 1.20   // tối đi ~20% — tránh bề mặt trắng sáng tụt detail
            case .nearbyObject: return 1.12
            case .ultraDetailObject: return 1.05
            }
        }
        /// Laplacian trên vertex colour GLB — ít pass, strength nhẹ để preset polycam-lite không bị nhòe/mất cạnh.
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

    // MARK: - Điểm chuẩn (xuất căn chỉnh mesh)

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

    /// Encode toàn bộ điểm chuẩn thành JSON pretty-print đi kèm OBJ.
    /// Trả `nil` nếu chưa đặt điểm nào.
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

    // MARK: - Frozen mesh block (kiểu quét block Polycam)

    /// Snapshot geometry không gian thế giới khi user bấm "Chụp vùng".
    /// Frozen block không đổi khi anchor ARKit cập nhật — tam giác khu đã quét không mất khi máy đi chỗ khác.
    struct FrozenMeshBlock {
        let positions: [SIMD3<Float>]
        let indices: [UInt32]
        let capturedAt: Date
    }

    private static let frozenQueue = DispatchQueue(label: "ARMeshExporter.frozen")
    private static var _frozenBlocks: [FrozenMeshBlock] = []
    /// ID các `ARMeshAnchor` đã được "đóng băng" vào một block.
    /// `prepareMeshes` bỏ qua các anchor này ở session live để không đếm trùng.
    private static var _frozenAnchorIDs: Set<UUID> = []

    static var frozenBlockCount: Int {
        frozenQueue.sync { _frozenBlocks.count }
    }

    static var frozenBlocks: [FrozenMeshBlock] {
        frozenQueue.sync { _frozenBlocks }
    }

    /// Đã snapshot — `prepareMeshes` dùng để bỏ trùng với geometry live.
    static var frozenAnchorIDs: Set<UUID> {
        frozenQueue.sync { _frozenAnchorIDs }
    }

    /// Snapshot các anchor chỉ định và đánh dấu ID là frozen.
    /// Export sau dùng snapshot đó và bỏ qua geometry live của các anchor đó.
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

    /// Xóa mọi frozen block và reset tập ID frozen.
    static func clearFrozenBlocks() {
        frozenQueue.sync {
            _frozenBlocks.removeAll()
            _frozenAnchorIDs.removeAll()
        }
    }

    // MARK: - History màu đa khung (snapshot HEIC — không stash `ARFrame` trong mảng)

    /// HEIC (HEVC) still: cùng bitrate thường ít blocking/mosquito noise hơn JPEG → giữ high‑frequency cho fusion; thất bại thì fallback JPEG.
    private static let fusionSnapshotHEICQuality: CGFloat = 0.88

    /// Quan sát camera gọn cho fusion; ARKit không cho delegate retain nhiều `ARFrame`
    /// (camera bị backlog → ít frame fusion → rất nhiều xám / fallback UV).
    private struct FusionFrameSnapshot {
        let timestamp: TimeInterval
        let cameraTransform: simd_float4x4
        let intrinsics: simd_float3x3
        let imageResolution: CGSize
        let imageBlob: Data
        let imageCodec: FusionSnapshotImageCodec
        /// Depth pack thumbnail (tuỳ chọn) — phục vụ occlusion trong history không cần full depth buffer.
        let miniDepthPayload: Data?
        let lumaCDF: ContiguousArray<Float>
        /// Metrics tại encode — đưa xuống decode adapter (JPEG/HEIC thường mất exposure metadata của frame camera).
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

    /// ~100 snapshot HEIC + blob nhỏ vẫn tiêu ít RAM hơn cố giữ nhiều `ARFrame` live (ví dụ ~12 frames đã làm backup pipeline ARKit).
    /// ~300 frame ≈ ~90 MB HEIC — đủ quét phòng full mà vẫn giữ các frame đầu trước khi export.
    private static let maxHistorySnapshots = 300
    /// Ít khung hơn `maxHistorySnapshots`: giảm decode mỗi lần materialize và tải CPU khi export.
    private static let maxFusionSnapshots = 11
    /// Ceiling số ảnh still decode **full‑res BGRA** song song cho fusion đỉnh (cache kiểu 1×/patch voxel — không decode × “mọi đỉnh”).
    private static let maxDecodedBGRAFusion = 8
    /// Atlas: cần nhiều view hơn path fusion đỉnh nhưng vẫn cap để không spike decode “dump hết vào IOSurface một lần”.
    /// Atlas decode nhiều frame hơn để greedy coverage bọc được mọi vùng đã quét.
    private static let maxDecodedBGRAAtlas = 20
    /// Không ghi frame quá mờ vào history (`recordFrameForColorFusion` bỏ qua); “fresh” decode từ `ARFrame` live vẫn có thể hơi mờ nhưng thường chấp nhận được.
    private static let minSharpnessToRecordHistory: Float = 0.048

    private static let freshSnapshotCacheLock = NSLock()
    private static var freshSnapshotCache: FusionFrameSnapshot?


    static func recordFrameForColorFusion(_ frame: ARFrame) {
        recordFrameForColorFusion(frame, cameraPosition: nil, detailPatches: [], preferPatchHistory: false)
    }

    /// Cho phép `.initializing` / `.insufficientFeatures`; reject motion quá đà và relocalizing (artefact nặng/nhất quán kém).
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

    /// Evict một frame thừa nhất theo không gian khỏi `history`.
    /// "Thừa nhất": frame nội bộ có vị trí máy gần một trong hai hàng xóm timeline,
    /// weight thêm `(1 − sharpness)` để frame mờ trùng viewpoint bị đẩy trước.
    ///
    /// O(n), gọi mỗi lần append frame mới được (n ≤ maxHistorySnapshots).
    /// Phải gọi trên `historyQueue` (hoặc trong block `sync`).
    private static func spatiallyEvictOneFrame(from history: inout [FusionFrameSnapshot]) {
        guard history.count >= 3 else {
            if !history.isEmpty { history.removeFirst() }
            return
        }
        var bestIdx = 1
        var bestScore: Float = -.greatestFiniteMagnitude  // higher score = more redundant
        for i in 1..<history.count - 1 {
            let pPrev = FusionFrameSnapshot.camPosition(history[i - 1])
            let pCurr = FusionFrameSnapshot.camPosition(history[i])
            let pNext = FusionFrameSnapshot.camPosition(history[i + 1])
            // Khoảng cách tới hàng xóm gần nhất nhỏ → redundant không gian cao.
            let minNeighbourDist = min(simd_length(pCurr - pPrev), simd_length(pCurr - pNext))
            // Nghịch đảo khoảng cách: gần hơn (redundant hơn) → điểm cao hơn.
            // Cộng bonus độ mờ để bản duplicate mờ bị evict trước.
            let redundancyScore = (1.0 / (minNeighbourDist + 0.001)) + (1.0 - history[i].sharpness01) * 0.5
            if redundancyScore > bestScore {
                bestScore = redundancyScore
                bestIdx = i
            }
        }
        history.remove(at: bestIdx)
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
                // Eviction không gian: bỏ frame có viewpoint gần hàng xóm nhất,
                // thay vì luôn bỏ cũ nhất — giữ tập frame đa dạng theo không gian,
                // bọc cả đường đi quét, không chỉ phần timeline gần đây.
                spatiallyEvictOneFrame(from: &frameSnapshotHistory)
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
                spatiallyEvictOneFrame(from: &list)
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

    /// Một snapshot ảnh nén + metric cho một frame export; cache để không encode lặp đi lặp lại cho từng đỉnh GLB/OBJ.
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

    /// Ít khung (`≤ maxKeeps`): sort thô theo độ nét / khoảng cách / thời gian; có vị trí đỉnh → ưu gần + nét để tránh blend quá tay.
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

    /// Sampling thời gian spaced trong phần còn lại (bao gồm keyframe không trùng timestamp).
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

    /// Snapshot pipeline fusion (projection + colour); struct nhẹ, không retain `ARFrame`.
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

    /// Pitch voxel world để chia cache fusion — không còn một global bucket cho whole mesh.
    private static let fusionMaterialVoxelPitchMeters: Float = 0.135

    private static let vertexFusionMaterialLock = NSLock()
    /// LRU nhỏ: tránh spike RAM và dictionary phình không giới hạn.
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

    /// Evict LRU cho đến khi có slot trước khi insert key mới (caller đang giữ lock).
    private static func prepareFusionCacheSlotForNewKey_locked(_ key: VertexFusionMaterialCacheKey) {
        if vertexFusionMaterialCaches[key] != nil { return }
        while vertexFusionMaterialCaches.count >= maxVertexFusionMaterialCacheEntries,
              let oldest = vertexFusionMaterialCacheFifo.first {
            vertexFusionMaterialCacheFifo.removeFirst()
            vertexFusionMaterialCaches.removeValue(forKey: oldest)
        }
    }
    /// Giới hạn decode still song song để tránh spike hàng chục IOSurface full‑res (`NSMallocException` khi export lớn).
    ///
    /// - Parameter useTemporalSpread: `true` (nhánh atlas): giữ frame rải đều theo timeline
    ///   để vùng quét sớm vẫn có frame gốc. `false` (fusion đỉnh): giữ frame nét nhất (mặc định).
    private static func capSnapshotsForMaterialize(
        currentTs: TimeInterval,
        snapshots: [FusionFrameSnapshot],
        maxStillImageDecode: Int,
        useTemporalSpread: Bool = false
    ) -> [FusionFrameSnapshot] {
        guard maxStillImageDecode > 0 else {
            return snapshots.filter { abs($0.timestamp - currentTs) < 1e-4 }
        }
        var nonLive = snapshots.filter { abs($0.timestamp - currentTs) >= 1e-4 }
        if nonLive.count > maxStillImageDecode {
            if useTemporalSpread {
                // Giữ các frame rải đều trên timeline quét để mọi vùng được quét trước
                // đây đều còn ứng viên frame — kể cả quét từ lâu trong session.
                nonLive.sort { $0.timestamp < $1.timestamp }
                let step = max(1, nonLive.count / maxStillImageDecode)
                nonLive = stride(from: 0, to: nonLive.count, by: step).map { nonLive[$0] }
                nonLive = Array(nonLive.prefix(maxStillImageDecode))
            } else {
                nonLive.sort { $0.sharpness01 > $1.sharpness01 }
                nonLive = Array(nonLive.prefix(maxStillImageDecode))
                nonLive.sort { $0.timestamp < $1.timestamp }
            }
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

    /// Materialize snapshots + frame hiện tại thành `ColorFusionFrame` / adapter có `CVPixelBuffer`.
    /// `maxStillImageDecode` cap đồng thời bao nhiêu decode BGRA (thường là điểm nổ khi mesh to).
    /// `useTemporalSpread` chuyển xuống `capSnapshotsForMaterialize`; atlas path đặt `true`.
    private static func materializeFusionSnapshots(
        current: ARFrame,
        snapshots: [FusionFrameSnapshot],
        maxStillImageDecode: Int,
        useTemporalSpread: Bool = false
    ) -> [ColorFusionFrame] {
        let currentTs = current.timestamp
        let capped = capSnapshotsForMaterialize(
            currentTs: currentTs,
            snapshots: snapshots,
            maxStillImageDecode: maxStillImageDecode,
            useTemporalSpread: useTemporalSpread
        )
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

    /// Cache fusion đã materialize (**key** = voxel × frame timestamp × patch); `nearVertex` qua centroid voxel để chọn keyframe kiểu Polycam.
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

    /// Toàn bộ history frame sắp theo timestamp — dùng cho pipeline atlas
    /// để không loại ngầm các frame đầu quét (geometry cũ).
    /// `bestTextureFusionFrames` sau đó chọn greedy theo spatial coverage trên mọi ứng viên,
    /// thay vì chỉ tập lọc gần-đỉnh.
    private static func allHistorySnapshotsForAtlas(current: ARFrame) -> [FusionFrameSnapshot] {
        guard let fresh = freshCachedFusionSnapshot(for: current) else { return [] }
        return historyQueue.sync {
            var all = frameSnapshotHistory
            let currentTs = current.timestamp
            if !all.contains(where: { abs($0.timestamp - currentTs) < 1e-4 }) {
                all.append(fresh)
            }
            all.sort { $0.timestamp < $1.timestamp }
            return all
        }
    }

    /// OBJ chỉ geometry (legacy).
    static func buildOBJString(from session: ARSession) -> String? {
        guard let frame = session.currentFrame else { return nil }
        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshAnchors.isEmpty else { return nil }
        return buildOBJString(from: meshAnchors)
    }

    /// Mesh có màu: `v x y z r g b` + `vn` tuỳ chọn, và `f v//vn` tương ứng.
    static func buildColoredOBJString(from session: ARSession) -> String? {
        guard let frame = session.currentFrame else { return nil }
        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshAnchors.isEmpty else { return nil }
        return buildColoredOBJString(meshAnchors: meshAnchors, frame: frame)
    }

    /// PLY ascii với uchar R/G/B — nhiều viewer hiển thị vertex colour ổn định.
    static func buildColoredPLYString(from session: ARSession) -> String? {
        guard let frame = session.currentFrame else { return nil }
        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshAnchors.isEmpty else { return nil }
        return buildColoredPLYString(meshAnchors: meshAnchors, frame: frame)
    }

    /// Binary glTF 2.0: màu theo face + flat normal — **Xcode Scene Editor hiện `COLOR_0`**; nhìn rõ khối vật thể hơn vertex colour blended.
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

    // MARK: - OBJ có texture (phương án B)

    /// Xuất OBJ + MTL + JPEG texture.
    /// UV sinh bằng cách chiếu mỗi đỉnh về ảnh camera `ARFrame` fusion tốt nhất.
    /// Định dạng tương thích rộng — Blender, MeshLab và viewer phổ biến đọc ổn.
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

        // Dùng FULL history để vùng quét sớm vẫn có ứng viên frame.
        // `selectFusionSnapshots()` chỉ ~11 frame gần đỉnh khiến đỉnh từ frame ARKit cũ
        // rơi vào fallback toàn frame hiện tại.
        let snapSelection = allHistorySnapshotsForAtlas(current: frame)
        print("[TextureAtlas] History for atlas: \(snapSelection.count) snapshots")
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

    /// HEIC trước: entropy coding + block transform lớn hơn → thường ít ringing/blocking của JPEG trên ridge/texture mảnh trong fusion đa khung.
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

    // MARK: - OBJ thuần

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

    // MARK: - OBJ có màu + PLY

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
        ply += "comment LiDARDepth — RGB đỉnh từ camera; vị trí đã Laplacian mịn\n"
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

    // MARK: - glTF 2.0 (GLB)

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

        // 2 pass Laplacian màu đỉnh @ ~28%.
        // Pass 1 làm dịu chỗ discontinuity cứng ở ranh anchor.
        // Pass 2 khuếch gradient còn lại để chuyển màu mượt mắt.
        // 28% giữ được mép màu thật (ví dụ chỗ vách-nền),
        // đồng thời xoá các dải seam chỉ rộng 1–2 đỉnh.
        smoothVertexColors(colors: &colors, indices: indicesOut,
                           vertexCount: vertexCount,
                           passes: profile.glbColorSmoothPasses,
                           strength: profile.glbColorSmoothStrength)

        // Flood-fill đỉnh xám fallback còn lại từ láng giềng đã có màu.
        // Chạy sau smoothing để màu khuếch vào seam tự nhiên.
        fillGrayVertexColors(colors: &colors, indices: indicesOut, vertexCount: vertexCount)

        return encodeIndexedGLB(positions: positions, normals: normals, colors: colors, indices: indicesOut, vertexCount: vertexCount)
    }

    /// Laplacian mịn màu: trộn màu đỉnh với láng giềng trên mesh.
    /// Một pass strength ~0.20–0.30 thường đủ xoá chỗ discontinuity cứng ở ranh anchor
    /// mà không làm nhòe mép màu thật của scene.
    ///
    /// - Parameters:
    ///   - colors:      mảng phẳng [r,g,b,…], sửa tại chỗ.
    ///   - indices:     buffer chỉ mục tam giác (bộ ba UInt32).
    ///   - vertexCount: số đỉnh.
    ///   - passes:      số lần lặp (1 nhẹ, 2 mạnh).
    ///   - strength:    hệ số blend 0–1 (0 = giữ nguyên, 1 = TB láng giềng thuần).
    private static func smoothVertexColors(
        colors: inout [Float],
        indices: [UInt32],
        vertexCount: Int,
        passes: Int,
        strength: Float
    ) {
        guard vertexCount > 0, passes > 0, strength > 0 else { return }

        // Dựng danh sách láng giềng từ index tam giác.
        // Cố ý giữ duplicate: cạnh nội bộ chia sẻ xuất hiện hai lần,
        // trọng số mép trong hơi cao hơn — đúng về geometry.
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

    /// Flood-fill màu từ láng giềng không-xám vào đỉnh vẫn giữ fallback xám 0.45
    /// sau pipeline projection chính.
    ///
    /// Mỗi pass lan màu một bước từ đỉnh đã có màu gần nhất.
    /// Lặp tới `maxPasses` có thể lấp vùng xám rất rộng nếu topo vẫn nối tới ít nhất một đỉnh có màu.
    ///
    /// Heuristic: saturation thấp VÀ luma ~0.45 → coi là "gray fallback".
    /// Đỉnh thực ra gần xám đó (bê tông trần…) cũng có thể bị fill — đổi lấy bớt artefact.
    private static func fillGrayVertexColors(
        colors: inout [Float],
        indices: [UInt32],
        vertexCount: Int,
        maxPasses: Int = 40
    ) {
        guard vertexCount > 0, !indices.isEmpty else { return }

        var isGray = [Bool](repeating: false, count: vertexCount)
        var grayCount = 0
        for i in 0..<vertexCount {
            let r = colors[i * 3], g = colors[i * 3 + 1], b = colors[i * 3 + 2]
            let avg = (r + g + b) / 3
            let maxDiff = max(abs(r - g), max(abs(g - b), abs(r - b)))
            if maxDiff < 0.05 && abs(avg - 0.45) < 0.10 {
                isGray[i] = true
                grayCount += 1
            }
        }
        guard grayCount > 0 else { return }
        let initialGray = grayCount

        var neighbors: [[Int]] = Array(repeating: [], count: vertexCount)
        for i in stride(from: 0, to: indices.count, by: 3) {
            let a = Int(indices[i]), b = Int(indices[i + 1]), c = Int(indices[i + 2])
            neighbors[a].append(b); neighbors[a].append(c)
            neighbors[b].append(a); neighbors[b].append(c)
            neighbors[c].append(a); neighbors[c].append(b)
        }

        for _ in 0..<maxPasses {
            var anyFilled = false
            for i in 0..<vertexCount {
                guard isGray[i] else { continue }
                var sumR: Float = 0, sumG: Float = 0, sumB: Float = 0
                var count = 0
                for n in neighbors[i] where !isGray[n] {
                    sumR += colors[n * 3]
                    sumG += colors[n * 3 + 1]
                    sumB += colors[n * 3 + 2]
                    count += 1
                }
                guard count > 0 else { continue }
                colors[i * 3]     = sumR / Float(count)
                colors[i * 3 + 1] = sumG / Float(count)
                colors[i * 3 + 2] = sumB / Float(count)
                isGray[i] = false
                grayCount -= 1
                anyFilled = true
            }
            if !anyFilled { break }
        }

        let filled = initialGray - grayCount
        print("[GrayFill] \(filled)/\(initialGray) vertices filled; \(grayCount) isolated (no coloured neighbour).")
    }

    /// glTF 2.0: hằng OpenGL ES `ARRAY_BUFFER` / `ELEMENT_ARRAY_BUFFER`.
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

        // KHR_materials_unlit: hiển thị vertex colour không qua chiếu sáng PBR.
        // Không có extension này, PBR roughness=1 + không IBL làm mesh tối/đen ở hầu hết viewer dù RGB đỉnh đúng.
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

    // MARK: - Geometry helpers

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
        // Gộp mọi anchor thành một mesh trước khi mịn.
        // Giúp Laplacian/bilateral không bị cắt ở ranh anchor và
        // weld đỉnh bịt các kẽ đen giữa chunk.
        var allPositions: [SIMD3<Float>] = []
        var allIndices: [UInt32] = []
        var vertexOffset: UInt32 = 0

        // 1. Nối trước geometry từ mọi frozen block (chế độ block).
        //    Snapshot cố định — không đổi dù sau này ARKit xóa/cập nhật anchor đó.
        for block in frozenBlocks {
            allPositions.append(contentsOf: block.positions)
            allIndices.append(contentsOf: block.indices.map { $0 + vertexOffset })
            vertexOffset += UInt32(block.positions.count)
        }

        // 2. Ghép anchor live — bỏ anchor đã được commit vào frozen block để khỏi đếm đôi.
        let frozenIDs = frozenAnchorIDs
        for anchor in meshAnchors where !frozenIDs.contains(anchor.identifier) {
            let verts   = worldVertexPositions(geometry: anchor.geometry, transform: anchor.transform)
            let indices = triangleIndices(geometry: anchor.geometry)
            allPositions.append(contentsOf: verts)
            allIndices.append(contentsOf: indices.map { $0 + vertexOffset })
            vertexOffset += UInt32(verts.count)
        }

        guard !allPositions.isEmpty else { return [] }

        // Hàn đỉnh trong ≤5 mm để bịt khớp mép anchor.
        MeshLaplacianSmooth.weldVertices(positions: &allPositions, triangleIndices: &allIndices, epsilon: 0.005)

        // Mịn + lấp lỗ trên mesh thống nhất (đã có láng giềng xuyên ranh).
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

    /// Chọn fusion frame cho atlas: greedy spatial coverage để không toàn bọc hướng nhìn gần (tránh đỉnh quét trước bị grey).
    ///
    /// Cách cũ: chấm điểm frame toàn cục rồi lấy top-N.
    /// Vấn đề: top-N thường toàn bọc hướng nhìn *hiện tại*; đỉnh quét trước từ góc xa
    /// không có tile atlas → xám.
    ///
    /// Cách mới:
    /// 1. Materialize với temporal spread (không chỉ sort nét đầu tiên) để frame đầu quét còn sống.
    /// 2. Tiền tính từng frame che được điểm mẫu nào.
    /// 3. Greedy: chọn frame phủ nhiều điểm *chưa che* nhất rồi lặp.
    /// Giúp mọi vùng không gian của mesh ít nhất có một tile atlas.
    private static func bestTextureFusionFrames(
        snapshots: [FusionFrameSnapshot],
        current: ARFrame,
        preparedMeshes: [PreparedMesh],
        profile: ExportProfile,
        detailPatches: [DetailPatch]
    ) -> [ColorFusionFrame] {
        let mergedSnapsUnsorted = mergedCandidateSnapshots(baseSnapshots: snapshots, detailPatches: detailPatches)
        let mergedSnaps = mergedSnapsUnsorted.sorted { $0.timestamp < $1.timestamp }

        // Sub-sample nếu quá đông nhưng vẫn rải timeline để miền cũ và mới đều còn ứng viên.
        let snapsForMaterialize: [FusionFrameSnapshot]
        if mergedSnaps.count > 60 {
            let step = max(1, mergedSnaps.count / 60)
            snapsForMaterialize = stride(from: 0, to: mergedSnaps.count, by: step).map { mergedSnaps[$0] }
        } else {
            snapsForMaterialize = mergedSnaps
        }

        // Temporal spread chia ngân sách decode đều khắp timeline quét.
        let materialized = materializeFusionSnapshots(
            current: current,
            snapshots: snapsForMaterialize,
            maxStillImageDecode: maxDecodedBGRAAtlas,
            useTemporalSpread: true
        )

        let allPoints = preparedMeshes.flatMap { $0.positions }
        // Một điểm / ~18 đỉnh để bước check coverage không nổ chi phí (O(số frame × mẫu)).
        let samplePoints = allPoints.enumerated().compactMap { idx, p -> SIMD3<Float>? in
            idx % 18 == 0 ? p : nil
        }
        guard !samplePoints.isEmpty else {
            return materialized.isEmpty ? [ARFrameFusionAdapter(current)] : materialized
        }

        let effectiveAtlasCount = max(
            profile.atlasFrameCount,
            detailPatches.isEmpty ? 0 : ExportProfile(subject: .ultraDetailObject).atlasFrameCount
        )
        let patchCenters = detailPatches.map(\.center)
        let patchRadii  = detailPatches.map(\.radius)

        // ── Bước 1: tiền tính coverage từng frame (điểm mẫu nào frame đó nhìn thấy) ──
        // Và điểm score chất lượng điểm mẫu (mép × trọng số trung tâm / depth²).
        var frameCoveredPoints: [[Int]] = []
        var frameCoverageQuality: [[Float]] = []
        frameCoveredPoints.reserveCapacity(materialized.count)
        frameCoverageQuality.reserveCapacity(materialized.count)

        for fus in materialized {
            var covered: [Int] = []
            var qualities: [Float] = []
            covered.reserveCapacity(samplePoints.count / 3)
            qualities.reserveCapacity(samplePoints.count / 3)
            let camPos = cameraPosition(fusion: fus)
            let pb = fus.fusionCapturedImage
            let w = CVPixelBufferGetWidth(pb)
            let h = CVPixelBufferGetHeight(pb)

            for (idx, sp) in samplePoints.enumerated() {
                let localProfile = profileForPosition(sp, baseProfile: profile, detailPatches: detailPatches)
                let viewDir = simd_normalize(camPos - sp)
                guard let pt = textureCoordinatePointFusion(
                    worldPosition: sp,
                    normal: viewDir,
                    fusion: fus,
                    profile: localProfile,
                    allowRelaxedFallback: false,
                    diag: nil
                ) else { continue }
                let depth = simd_distance(camPos, sp)
                let border  = imageBorderWeight(point: pt, width: w, height: h)
                let center  = centerWeight(point: pt, width: w, height: h, bias: localProfile.centerBias)
                let quality = border * center * (1.0 / (1.0 + 0.35 * depth * depth))
                if quality > 0.04 {
                    covered.append(idx)
                    qualities.append(quality)
                }
            }
            frameCoveredPoints.append(covered)
            frameCoverageQuality.append(qualities)
        }

        // ── Bước 2: greedy set-cover — chọn frame tối đa hoá điểm mẫu *chưa* được che ──
        var selectedIndices: [Int] = []
        var alreadyCovered = Set<Int>()

        for _ in 0..<min(effectiveAtlasCount, materialized.count) {
            var bestFrameIdx = -1
            var bestNewCoverage = 0
            var bestQualitySum: Float = 0

            for (fi, coveredList) in frameCoveredPoints.enumerated() {
                guard !selectedIndices.contains(fi) else { continue }
                var newCount = 0
                var qualSum: Float = 0
                for (k, ptIdx) in coveredList.enumerated() {
                    if !alreadyCovered.contains(ptIdx) {
                        newCount += 1
                        qualSum += frameCoverageQuality[fi][k]
                    }
                }
                if newCount > bestNewCoverage
                    || (newCount == bestNewCoverage && qualSum > bestQualitySum) {
                    bestNewCoverage = newCount
                    bestQualitySum = qualSum
                    bestFrameIdx = fi
                }
            }

            // Dừng khi không frame nào thêm được coverage.
            guard bestFrameIdx >= 0, bestNewCoverage > 0 else { break }
            selectedIndices.append(bestFrameIdx)
            for ptIdx in frameCoveredPoints[bestFrameIdx] {
                alreadyCovered.insert(ptIdx)
            }
        }

        // ── Bước 3: bonus gần detail patch — chắc chắn có frame của vùng chi tiết ──
        if !patchCenters.isEmpty {
            for (fi, fus) in materialized.enumerated() {
                guard !selectedIndices.contains(fi), selectedIndices.count < effectiveAtlasCount else { break }
                let camPos = cameraPosition(fusion: fus)
                for (pidx, centerPos) in patchCenters.enumerated() {
                    let patchRadius = pidx < patchRadii.count ? patchRadii[pidx] : 0.7
                    if simd_distance(camPos, centerPos) < patchRadius * 2.0 {
                        selectedIndices.append(fi)
                        break
                    }
                }
            }
        }

        // ── Fallback greedy rỗng: giữ N frame đầu theo thứ tự thời gian ──
        if selectedIndices.isEmpty {
            print("[TextureAtlas] Greedy coverage: 0 useful frames — falling back to first \(effectiveAtlasCount).")
            return Array(materialized.prefix(effectiveAtlasCount))
        }

        let pct = samplePoints.isEmpty ? 0 : Int(Float(alreadyCovered.count) / Float(samplePoints.count) * 100)
        print("[TextureAtlas] Greedy coverage: \(selectedIndices.count) atlas frames → \(alreadyCovered.count)/\(samplePoints.count) sample pts (\(pct)%)")

        return selectedIndices.map { materialized[$0] }
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

    // MARK: - Tô màu từ camera

    private static func activeInterfaceOrientation() -> UIInterfaceOrientation {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            return .portrait
        }
        return scene.interfaceOrientation
    }

    // MARK: - Chiếu (intrinsics/imageResolution → tọa độ pixel `capturedImage`)

    /// Hay lệch world↔buffer: `ARCamera.projectPoint`/intrinsics ở không gian `imageResolution`,
    /// còn sample dùng `CVPixelBufferGetWidth`; UI portrait thường **transpose** WxH so với plane YUV.
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

    /// Blend màu đa khung qua các `ColorFusionFrame` adapter; history không stash `ARFrame`.
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

        // ── Pass 3 — "đường cùng": nới gate độ nét nhưng vẫn depth check rộng ──
        // Depth với relaxTolerance=true để hạn chế bleed màu từ background
        // (ví dụ tường trắng sau vật có màu).
        do {
            var bestColor: SIMD3<Float>? = nil
            var bestFacing: Float = -1
            for f in materialized {
                let invT = f.fusionCameraTransform.inverse
                let camLocal = invT * SIMD4<Float>(worldPosition.x, worldPosition.y, worldPosition.z, 1)
                guard camLocal.z < -0.01 else { continue }
                guard let projected = projectWorldToImagePixel(worldPosition: worldPosition, fusion: f) else { continue }
                let camPos = cameraPosition(fusion: f)
                let toCam = simd_normalize(camPos - worldPosition)
                let dist = simd_distance(camPos, worldPosition)
                let facing: Float
                if let n = worldNormal {
                    facing = simd_dot(simd_normalize(n), toCam)
                } else {
                    facing = 0.1
                }
                guard facing > -0.15 else { continue }
                let pb = f.fusionCapturedImage
                let w = CVPixelBufferGetWidth(pb)
                let h = CVPixelBufferGetHeight(pb)
                let frontalDepth01 = simd_clamp(simd_max(0, facing), 0, 1)
                // Depth loose — tránh màu nền xuyên qua geometry foreground.
                if let dm = f.fusionDepthMap {
                    guard projectionDepthOcclusionPasses(
                        depthMap: dm, projected: projected,
                        imageWidth: w, imageHeight: h,
                        geometricDepth: dist, surfaceFrontal01: frontalDepth01,
                        profile: profile, relaxTolerance: true
                    ) else { continue }
                } else if let mini = f.fusionPackedMiniDepth {
                    guard projectionMiniDepthOcclusionPasses(
                        mini: mini, projected: projected,
                        imageWidth: w, imageHeight: h,
                        geometricDepth: dist, surfaceFrontal01: frontalDepth01,
                        profile: profile, relaxTolerance: true
                    ) else { continue }
                }
                let sampled = sampleRGB3x3(pixelBuffer: pb, at: projected, width: w, height: h)
                if facing > bestFacing {
                    bestFacing = facing
                    bestColor = sampled
                }
            }
            if let color = bestColor {
                diag?.countColor()
                let enhanced = enhanceSampledColor(color, profile: profile)
                diag?.recordResolvedColor(enhanced)
                return enhanced
            }
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

        // Lấy mẫu RGB thô — không histogram match, không sharpen micro-contrast.
        // Giữ đúng màu máy đã capture.
        let sampled = sampleRGB3x3(pixelBuffer: pb, at: projected, width: w, height: h)

        if worldNormal != nil, ndotl < -0.80 { diag?.countBackface() }

        // Trọng số fusion: sharp × frontal² × exp(−k·d²) × edge-aware × các bonus heuristic.
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

    /// Depth/occlusion gate: median 3×3 trên LiDAR depth đối chiếu khoảng cách geometric dọc ray projection — reject weight/occlusion sai (blur chính khi sai).
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

    /// Cùng ý tolerance nhưng chạy trên coarse depth pack từ snapshot cũ (frame JPEG trong history không có full LiDAR map).
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

    /// Kernel Gaussian 3×3 (9 mẫu, trọng số chuẩn hoá tổng 1).
    /// Chính hơn trung bình đều 5 mẫu cũ: góc đóng góp ít hơn,
    /// tâm chủ đạo → chi tiết sắc hơn và nén noise tốt hơn.
    private static func sampleRGB3x3(pixelBuffer: CVPixelBuffer, at p: CGPoint, width: Int, height: Int) -> SIMD3<Float> {
        // (dx, dy, weight) — trọng Gaussian: tâm=0.25, cạnh=0.125, góc=0.0625
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

    /// Luma NN tại ô pixel lattice (decouple Sobel khỏi bilinear của `sampleRGB`/sample colour path).
    private static func luma01AtLatticePixel(pixelBuffer: CVPixelBuffer, x: Int, y: Int, width: Int, height: Int) -> Float {
        let xi = min(max(x, 0), max(width - 1, 0))
        let yi = min(max(y, 0), max(height - 1, 0))
        let c = sampleRGBAtImage(pixelBuffer: pixelBuffer, x: CGFloat(xi), y: CGFloat(yi), width: width, height: height)
        return simd_clamp(luma01FromRGB(c), 0, 1)
    }

    /// Sobel magnitude trên luma (core edge‑aware multiplier) — tái dùng toán với `fusionEdgeBoostMultiplier`, tránh tính Sobel hai lần.
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

    /// Sobel magnitude trên luma → bump weight chỗ mép/high‑frequency texture (kết hợp `fusionEdgeBoostScale`).
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
        // Giảm penalty mép khung để vẫn giữ được màu cho nhiều vertex trong bounds.
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
        func scoreProjection(
            fus: ColorFusionFrame,
            pt: CGPoint,
            idx: Int,
            relaxedPenalty: Float
        ) -> Float {
            let camPos = cameraPosition(fusion: fus)
            let toCamera = camPos - worldPosition
            let depth = simd_length(toCamera)
            let pb = fus.fusionCapturedImage
            let w = CVPixelBufferGetWidth(pb)
            let h = CVPixelBufferGetHeight(pb)
            let border  = imageBorderWeight(point: pt, width: w, height: h)
            let center  = centerWeight(point: pt, width: w, height: h, bias: profile.centerBias)
            let depthW  = 1.0 / (1.0 + 0.25 * depth * depth)
            // Góc facing: máy nhìn thẳng mặt bao nhiêu.
            let nn = simd_normalize(normal)
            let vd = depth > 1e-5 ? toCamera / depth : nn
            let ndotv = simd_clamp(simd_dot(nn, vd), 0, 1)
            let facingW = 0.3 + 0.7 * ndotv  // [0.3 … 1.0]: gần grazing vẫn dùng được
            return relaxedPenalty * border * center * depthW * facingW + Float(idx) * 0.005
        }

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
            let score = scoreProjection(fus: fus, pt: pt, idx: idx, relaxedPenalty: 1.0)
            if best == nil || score > best!.score {
                best = TextureProjection(frameIndex: idx, point: pt, score: score, isRelaxed: false)
            }
        }
        if best != nil { return best }

        for (idx, fus) in frames.enumerated() {
            guard let pt = textureCoordinatePointFusion(
                worldPosition: worldPosition,
                normal: normal,
                fusion: fus,
                profile: profile,
                allowRelaxedFallback: true,
                diag: nil
            ) else { continue }
            let score = scoreProjection(fus: fus, pt: pt, idx: idx, relaxedPenalty: 0.55)
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

    /// Sigmoide dạng S: [0,1]→[0,1], giữ 0 và 1 cố định.
    /// strength > 1 → S dốc hơn (độ tương phản punch hơn).
    /// strength = 1 → gần đường thẳng.
    @inline(__always)
    private static func sCurveContrast(_ x: Float, strength: Float) -> Float {
        let v = (x - 0.5) * strength
        return simd_clamp(0.5 + v / (1.0 + abs(v)), 0.0, 1.0)
    }

    private static func enhanceSampledColor(_ color: SIMD3<Float>, profile: ExportProfile) -> SIMD3<Float> {
        // Chỗ này tắt color enhancement — trả đúng màu camera.
        // Trước đây từng bật boost S-curve/ripple/gamma nhưng dễ wash-out hay oversat.
        return simd_clamp(color, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
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

    /// World → pixel **trực tiếp trên capture buffer** `frame.capturedImage` (≠ displayTransform của UI preview).
    /// Bug đã có: clamp theo `imageResolution`/`projectPoint(viewport)` rồi sample như WxH `CVPixelBuffer` — lệch transpose/scale → OOB + artefact nặng.
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

    /// Adapter fusion không có `ARCamera` live → project pinhole trong domain intrinsics/`imageResolution`, rồi map vào WxH buffer decode.
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

    /// Log một dòng header: pixel format và kích buffer trước khi vào luồng export.
    private static func logExportHeader(tag: String, frame: ARFrame) {
        let fusionCount = selectFusionSnapshots(including: frame).count
        let historyCount = historyQueue.sync { frameSnapshotHistory.count }
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
  History size   : \(historyCount) snapshots (max \(maxHistorySnapshots))
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
