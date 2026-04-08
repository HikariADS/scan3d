/*
 Abstract:
 Level 3 — Laplacian mesh smoothing (pure Swift, no SPM).
 Uniform Laplacian: v' = (1−λ)v + λ·mean(neighbors). Reduces ARKit “gồ ghề” nhẹ trước khi tô màu.
 */

import Foundation
import simd

enum MeshLaplacianSmooth {

    /// Số vòng lặp mặc định (càng nhiều càng mịn nhưng càng co / chậm).
    static var exportIterations: Int = 4
    /// 0…1 — độ mạnh một bước làm mịn.
    static var exportLambda: Float = 0.32

    /// Làm mịn đỉnh theo cạnh mesh (mỗi anchor độc lập).
    static func smoothUniform(positions: inout [SIMD3<Float>], triangleIndices: [UInt32]) {
        let n = positions.count
        guard n > 0, triangleIndices.count >= 3 else { return }

        var neighbors = Array(repeating: Set<Int>(), count: n)
        for t in stride(from: 0, to: triangleIndices.count, by: 3) {
            let a = Int(triangleIndices[t])
            let b = Int(triangleIndices[t + 1])
            let c = Int(triangleIndices[t + 2])
            guard a < n, b < n, c < n else { continue }
            neighbors[a].insert(b); neighbors[a].insert(c)
            neighbors[b].insert(a); neighbors[b].insert(c)
            neighbors[c].insert(a); neighbors[c].insert(b)
        }

        let iterations = max(0, exportIterations)
        let lambda = min(max(exportLambda, 0), 1)

        var pos = positions
        for _ in 0..<iterations {
            var next = pos
            for i in 0..<n {
                let nbr = neighbors[i]
                if nbr.isEmpty {
                    continue
                }
                var sum = SIMD3<Float>(0, 0, 0)
                for j in nbr {
                    sum += pos[j]
                }
                let avg = sum / Float(nbr.count)
                next[i] = (1 - lambda) * pos[i] + lambda * avg
            }
            pos = next
        }
        positions = pos
    }

    /// Pháp tuyến đỉnh (trung bình pháp tuyến mặt) sau khi đã làm mịn — dùng cho chiếu màu / xuất vn.
    static func vertexNormals(positions: [SIMD3<Float>], triangleIndices: [UInt32]) -> [SIMD3<Float>] {
        let n = positions.count
        var accum = Array(repeating: SIMD3<Float>(0, 0, 0), count: n)
        for t in stride(from: 0, to: triangleIndices.count, by: 3) {
            let i0 = Int(triangleIndices[t])
            let i1 = Int(triangleIndices[t + 1])
            let i2 = Int(triangleIndices[t + 2])
            guard i0 < n, i1 < n, i2 < n else { continue }
            let p0 = positions[i0]
            let p1 = positions[i1]
            let p2 = positions[i2]
            var fn = simd_cross(p1 - p0, p2 - p0)
            let len = simd_length(fn)
            guard len >= 1e-10 else { continue }
            fn = fn / len
            accum[i0] += fn
            accum[i1] += fn
            accum[i2] += fn
        }
        return accum.map { v in
            let len = simd_length(v)
            if len < 1e-8 {
                return SIMD3<Float>(0, 1, 0)
            }
            return v / len
        }
    }
}
