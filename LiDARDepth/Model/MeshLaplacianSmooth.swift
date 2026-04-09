/*
 Abstract:
 Level 3+ — Mesh smoothing pipeline.
 Modes:
   • Taubin   — fast λ/μ pass, minimal shrinkage (Low preset).
   • Bilateral — feature-preserving: spatial + normal Gaussian weights; preserves sharp
                 edges and corners while smoothing flat surfaces (Medium preset).
   • Combined  — Bilateral then a light Taubin micro-noise pass (High preset).

 Normal estimation uses area-weighted accumulation (more accurate at non-uniform meshes).
 */

import Foundation
import simd

enum MeshLaplacianSmooth {

    // MARK: - Quality presets

    enum QualityPreset: String, CaseIterable, Identifiable {
        case precise
        case low
        case medium
        case high

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .precise: return "Chính xác"
            case .low:    return "Taubin (Fast)"
            case .medium: return "Bilateral"
            case .high:   return "Bilateral+"
            }
        }
    }

    // MARK: - Smoothing mode

    enum SmoothingMode {
        /// Keep raw mesh positions.
        case none
        /// Classic Taubin λ/μ — fast, low memory, slight shrinkage.
        case taubin
        /// Feature-preserving bilateral — preserves corners/edges, heavier compute.
        case bilateral
        /// Bilateral followed by a light Taubin pass to remove residual micro-noise.
        case combined
    }

    // MARK: - Taubin parameters

    static var exportIterations: Int = 4
    static var exportLambda: Float  = 0.32
    static var exportMu: Float      = -0.34

    // MARK: - Bilateral parameters

    static var smoothingMode: SmoothingMode = .bilateral
    /// Spatial bandwidth (metres). Controls how far neighbourhood influence reaches.
    static var bilateralSpatialSigma: Float = 0.04
    /// Normal bandwidth. Lower = sharper feature preservation; higher = more aggressive smooth.
    static var bilateralNormalSigma: Float  = 0.35
    static var bilateralIterations: Int     = 3

    // MARK: - Hole-fill parameters

    static var exportHoleMaxEdges: Int              = 44
    static var exportHoleMaxRadius: Float           = 0.10
    static var exportHoleMaxPlanarDeviation: Float  = 0.012
    static var exportHoleMaxLargeEdges: Int         = 180
    static var exportHoleFillEnabled: Bool          = true

    // MARK: - Main dispatch

    /// Applies the currently-configured smoothing mode to the mesh.
    static func smooth(positions: inout [SIMD3<Float>], triangleIndices: [UInt32]) {
        switch smoothingMode {
        case .none:
            return
        case .taubin:
            smoothTaubin(positions: &positions, triangleIndices: triangleIndices)

        case .bilateral:
            smoothBilateral(positions: &positions, triangleIndices: triangleIndices)

        case .combined:
            smoothBilateral(positions: &positions, triangleIndices: triangleIndices)
            // Light Taubin pass (2 iter) to remove residual high-frequency noise
            let savedIter   = exportIterations
            let savedLambda = exportLambda
            let savedMu     = exportMu
            exportIterations = 2
            exportLambda     = 0.15
            exportMu         = -0.17
            smoothTaubin(positions: &positions, triangleIndices: triangleIndices)
            exportIterations = savedIter
            exportLambda     = savedLambda
            exportMu         = savedMu
        }
    }

    // MARK: - Bilateral smoothing

    /// Feature-preserving bilateral mesh smoothing.
    ///
    /// For each vertex i, its new position is a weighted average of its 1-ring neighbours,
    /// where the weight combines a spatial Gaussian and a normal-domain Gaussian:
    ///
    ///   w(i,j) = exp(−‖pᵢ−pⱼ‖² / 2σ_s²) · exp(−‖nᵢ−nⱼ‖² / 2σ_n²)
    ///
    /// This suppresses smoothing across sharp features (large normal difference)
    /// while aggressively smoothing flat regions (small spatial + normal difference).
    /// Normals are recomputed between iterations for compounding feature preservation.
    static func smoothBilateral(positions: inout [SIMD3<Float>], triangleIndices: [UInt32]) {
        let n = positions.count
        guard n > 0, triangleIndices.count >= 3 else { return }

        let ss   = max(bilateralSpatialSigma, 1e-5)
        let ns   = max(bilateralNormalSigma,  1e-5)
        let iter = max(1, bilateralIterations)

        let invSs2 = 1.0 / (2.0 * ss * ss)
        let invSn2 = 1.0 / (2.0 * ns * ns)

        // Build 1-ring neighbour list (array-of-arrays, more cache-friendly than Set)
        let neighbors = buildNeighborsList(count: n, triangleIndices: triangleIndices)

        var pos     = positions
        var normals = vertexNormals(positions: pos, triangleIndices: triangleIndices)

        for _ in 0..<iter {
            var next = pos
            for i in 0..<n {
                let pi = pos[i]
                let ni = normals[i]
                var sumPos = SIMD3<Float>(0, 0, 0)
                var sumW: Float = 0

                for j in neighbors[i] {
                    let pj = pos[j]
                    let nj = normals[j]
                    let spatialD2 = simd_length_squared(pj - pi)
                    let normalD2  = simd_length_squared(nj - ni)
                    let w = exp(-spatialD2 * invSs2 - normalD2 * invSn2)
                    sumPos += pj * w
                    sumW   += w
                }

                if sumW > 1e-8 {
                    // Blend factor 0.7 to prevent over-smoothing in a single step
                    let alpha: Float = 0.70
                    next[i] = (1.0 - alpha) * pi + alpha * (sumPos / sumW)
                }
            }
            pos = next
            // Recompute normals each iteration — crucial: updated normals feed
            // the normal-weight term so feature edges stay sharper over iterations.
            normals = vertexNormals(positions: pos, triangleIndices: triangleIndices)
        }
        positions = pos
    }

    // MARK: - Taubin smoothing

    /// Uniform Laplacian: v' = (1−λ)v + λ·mean(neighbors).
    static func smoothUniform(positions: inout [SIMD3<Float>], triangleIndices: [UInt32]) {
        let n = positions.count
        guard n > 0, triangleIndices.count >= 3 else { return }

        let neighbors = buildNeighbors(count: n, triangleIndices: triangleIndices)
        let iterations = max(0, exportIterations)
        let lambda     = min(max(exportLambda, 0), 1)

        var pos = positions
        for _ in 0..<iterations {
            var next = pos
            for i in 0..<n {
                let nbr = neighbors[i]
                if nbr.isEmpty { continue }
                var sum = SIMD3<Float>(0, 0, 0)
                for j in nbr { sum += pos[j] }
                let avg = sum / Float(nbr.count)
                next[i] = (1 - lambda) * pos[i] + lambda * avg
            }
            pos = next
        }
        positions = pos
    }

    /// Taubin λ/μ smoothing — reduces shrinkage vs plain Laplacian.
    static func smoothTaubin(positions: inout [SIMD3<Float>], triangleIndices: [UInt32]) {
        let n = positions.count
        guard n > 0, triangleIndices.count >= 3 else { return }

        let neighbors  = buildNeighbors(count: n, triangleIndices: triangleIndices)
        let iterations = max(0, exportIterations)
        let lambda     = min(max(exportLambda, 0), 1)
        let mu         = min(max(exportMu, -1), 0)

        var pos = positions
        for _ in 0..<iterations {
            pos = smoothStep(pos, neighbors: neighbors, alpha: lambda)
            pos = smoothStep(pos, neighbors: neighbors, alpha: mu)
        }
        positions = pos
    }

    // MARK: - Preset configuration

    static func applyPreset(_ preset: QualityPreset) {
        switch preset {
        case .precise:
            smoothingMode           = .none
            exportIterations        = 0
            exportLambda            = 0
            exportMu                = 0
            bilateralIterations     = 0
            bilateralSpatialSigma   = 0.012
            bilateralNormalSigma    = 0.18
            exportHoleFillEnabled   = false
            exportHoleMaxEdges      = 0
            exportHoleMaxRadius     = 0
            exportHoleMaxPlanarDeviation = 0
            exportHoleMaxLargeEdges = 0

        case .low:
            smoothingMode           = .taubin
            exportIterations        = 2
            exportLambda            = 0.20
            exportMu                = -0.23
            bilateralIterations     = 2
            bilateralSpatialSigma   = 0.025
            bilateralNormalSigma    = 0.45
            exportHoleFillEnabled   = true
            exportHoleMaxEdges      = 26
            exportHoleMaxRadius     = 0.055
            exportHoleMaxPlanarDeviation = 0.008
            exportHoleMaxLargeEdges = 120

        case .medium:
            smoothingMode           = .bilateral
            exportIterations        = 4
            exportLambda            = 0.28
            exportMu                = -0.31
            bilateralIterations     = 3
            bilateralSpatialSigma   = 0.040
            bilateralNormalSigma    = 0.35
            exportHoleFillEnabled   = true
            exportHoleMaxEdges      = 44
            exportHoleMaxRadius     = 0.10
            exportHoleMaxPlanarDeviation = 0.012
            exportHoleMaxLargeEdges = 180

        case .high:
            smoothingMode           = .combined
            exportIterations        = 2    // used only by the light Taubin post-pass
            exportLambda            = 0.15
            exportMu                = -0.17
            bilateralIterations     = 4
            bilateralSpatialSigma   = 0.050
            bilateralNormalSigma    = 0.30
            exportHoleFillEnabled   = true
            exportHoleMaxEdges      = 72
            exportHoleMaxRadius     = 0.18
            exportHoleMaxPlanarDeviation = 0.018
            exportHoleMaxLargeEdges = 240
        }
    }

    // MARK: - Hole filling

    /// Patch boundary loops:
    /// - Small holes  → triangle fan from centroid (fast).
    /// - Large holes  → fit plane + 2-D ear-clipping triangulation (handles concave boundaries).
    static func fillSmallBoundaryHoles(
        positions: inout [SIMD3<Float>],
        triangleIndices: inout [UInt32],
        maxEdges: Int          = MeshLaplacianSmooth.exportHoleMaxEdges,
        maxRadius: Float       = MeshLaplacianSmooth.exportHoleMaxRadius,
        maxPlanarDeviation: Float = MeshLaplacianSmooth.exportHoleMaxPlanarDeviation,
        maxLargeEdges: Int     = MeshLaplacianSmooth.exportHoleMaxLargeEdges
    ) {
        let vertexCount = positions.count
        guard exportHoleFillEnabled, vertexCount > 2, triangleIndices.count >= 3 else { return }

        var orientedEdges: [(Int, Int)] = []
        var undirectedEdgeCount: [UInt64: Int] = [:]

        for t in stride(from: 0, to: triangleIndices.count, by: 3) {
            let a = Int(triangleIndices[t])
            let b = Int(triangleIndices[t + 1])
            let c = Int(triangleIndices[t + 2])
            guard a < vertexCount, b < vertexCount, c < vertexCount else { continue }

            let tri = [(a, b), (b, c), (c, a)]
            for (u, v) in tri {
                undirectedEdgeCount[edgeKey(u, v), default: 0] += 1
                orientedEdges.append((u, v))
            }
        }

        var boundaryAdj: [Int: [Int]] = [:]
        for (u, v) in orientedEdges {
            if undirectedEdgeCount[edgeKey(u, v)] == 1 {
                boundaryAdj[u, default: []].append(v)
            }
        }
        if boundaryAdj.isEmpty { return }

        var visited = Set<UInt64>()
        var loops: [[Int]] = []
        for (start, nextList) in boundaryAdj {
            for next in nextList {
                let startKey = directedEdgeKey(start, next)
                if visited.contains(startKey) { continue }
                var loop: [Int] = [start]
                var u = start
                var v = next
                var guard2 = 0
                while guard2 < 4096 {
                    guard2 += 1
                    let dKey = directedEdgeKey(u, v)
                    if visited.contains(dKey) { break }
                    visited.insert(dKey)
                    loop.append(v)
                    if v == start { break }
                    guard let cands = boundaryAdj[v], !cands.isEmpty else { break }
                    let w = cands.first { $0 != u } ?? cands[0]
                    u = v; v = w
                }
                if loop.count >= 4, loop.first == loop.last {
                    loop.removeLast()
                    loops.append(loop)
                }
            }
        }

        for loop in loops {
            if loop.count < 3 || loop.count > maxLargeEdges { continue }
            let verts    = loop.map { positions[$0] }
            let centroid = verts.reduce(SIMD3<Float>(0, 0, 0), +) / Float(verts.count)

            var radius: Float = 0
            for p in verts { radius = max(radius, simd_length(p - centroid)) }

            let normal = loopNormal(loop: loop, positions: positions)
            if simd_length(normal) < 1e-6 { continue }
            let planeN = simd_normalize(normal)

            var maxDeviation: Float = 0
            for p in verts {
                maxDeviation = max(maxDeviation, abs(simd_dot(p - centroid, planeN)))
            }
            if maxDeviation > maxPlanarDeviation { continue }

            let isSmall = loop.count <= maxEdges && radius <= maxRadius
            if isSmall {
                fillLoopByFan(loop: loop, centroid: centroid,
                              triangleIndices: &triangleIndices, positions: &positions)
                continue
            }

            if let tris = triangulateLoopPlanar(loop: loop, positions: positions,
                                                planeNormal: planeN, planeCentroid: centroid) {
                for tri in tris {
                    triangleIndices.append(UInt32(tri.0))
                    triangleIndices.append(UInt32(tri.1))
                    triangleIndices.append(UInt32(tri.2))
                }
            } else {
                fillLoopByFan(loop: loop, centroid: centroid,
                              triangleIndices: &triangleIndices, positions: &positions)
            }
        }
    }

    // MARK: - Vertex normals (area-weighted)

    /// Area-weighted vertex normals: accumulate unnormalised cross-products (whose magnitude
    /// equals 2×triangle-area) so larger triangles contribute proportionally more.
    /// This gives more accurate shading normals, especially at mesh boundaries.
    static func vertexNormals(positions: [SIMD3<Float>], triangleIndices: [UInt32]) -> [SIMD3<Float>] {
        let n = positions.count
        var accum = Array(repeating: SIMD3<Float>(0, 0, 0), count: n)
        for t in stride(from: 0, to: triangleIndices.count, by: 3) {
            let i0 = Int(triangleIndices[t])
            let i1 = Int(triangleIndices[t + 1])
            let i2 = Int(triangleIndices[t + 2])
            guard i0 < n, i1 < n, i2 < n else { continue }
            // Unnormalised cross product; magnitude = 2 × area → area-weighting for free.
            let fn = simd_cross(positions[i1] - positions[i0], positions[i2] - positions[i0])
            guard simd_length_squared(fn) >= 1e-20 else { continue }
            accum[i0] += fn
            accum[i1] += fn
            accum[i2] += fn
        }
        return accum.map { v in
            let len = simd_length(v)
            return len < 1e-8 ? SIMD3<Float>(0, 1, 0) : v / len
        }
    }

    // MARK: - Private: neighbour builders

    /// Returns Set-of-neighbour indices (used by Taubin passes).
    private static func buildNeighbors(count: Int, triangleIndices: [UInt32]) -> [Set<Int>] {
        var nb = Array(repeating: Set<Int>(), count: count)
        for t in stride(from: 0, to: triangleIndices.count, by: 3) {
            let a = Int(triangleIndices[t])
            let b = Int(triangleIndices[t + 1])
            let c = Int(triangleIndices[t + 2])
            guard a < count, b < count, c < count else { continue }
            nb[a].insert(b); nb[a].insert(c)
            nb[b].insert(a); nb[b].insert(c)
            nb[c].insert(a); nb[c].insert(b)
        }
        return nb
    }

    /// Returns Array-of-neighbour indices (used by bilateral; better cache locality).
    private static func buildNeighborsList(count: Int, triangleIndices: [UInt32]) -> [[Int]] {
        var sets = Array(repeating: Set<Int>(), count: count)
        for t in stride(from: 0, to: triangleIndices.count, by: 3) {
            let a = Int(triangleIndices[t])
            let b = Int(triangleIndices[t + 1])
            let c = Int(triangleIndices[t + 2])
            guard a < count, b < count, c < count else { continue }
            sets[a].insert(b); sets[a].insert(c)
            sets[b].insert(a); sets[b].insert(c)
            sets[c].insert(a); sets[c].insert(b)
        }
        return sets.map { Array($0) }
    }

    // MARK: - Private: Taubin helper

    private static func smoothStep(_ positions: [SIMD3<Float>],
                                   neighbors: [Set<Int>], alpha: Float) -> [SIMD3<Float>] {
        var next = positions
        for i in 0..<positions.count {
            let nbr = neighbors[i]
            if nbr.isEmpty { continue }
            var sum = SIMD3<Float>(0, 0, 0)
            for j in nbr { sum += positions[j] }
            let avg = sum / Float(nbr.count)
            next[i] = (1 - alpha) * positions[i] + alpha * avg
        }
        return next
    }

    // MARK: - Private: hole-fill helpers

    private static func fillLoopByFan(
        loop: [Int], centroid: SIMD3<Float>,
        triangleIndices: inout [UInt32], positions: inout [SIMD3<Float>]
    ) {
        let centerIndex = UInt32(positions.count)
        positions.append(centroid)
        for i in 0..<loop.count {
            triangleIndices.append(UInt32(loop[i]))
            triangleIndices.append(UInt32(loop[(i + 1) % loop.count]))
            triangleIndices.append(centerIndex)
        }
    }

    private static func triangulateLoopPlanar(
        loop: [Int], positions: [SIMD3<Float>],
        planeNormal: SIMD3<Float>, planeCentroid: SIMD3<Float>
    ) -> [(Int, Int, Int)]? {
        guard loop.count >= 3 else { return nil }

        let axisSeed: SIMD3<Float> = abs(planeNormal.x) < 0.8 ? SIMD3(1,0,0) : SIMD3(0,1,0)
        let u = simd_normalize(simd_cross(planeNormal, axisSeed))
        let v = simd_normalize(simd_cross(planeNormal, u))
        if !u.x.isFinite || !v.x.isFinite { return nil }

        var pts2D: [SIMD2<Float>] = []
        pts2D.reserveCapacity(loop.count)
        for idx in loop {
            let d = positions[idx] - planeCentroid
            pts2D.append(SIMD2<Float>(simd_dot(d, u), simd_dot(d, v)))
        }

        var area2 = polygonSignedArea2D(pts2D)
        if abs(area2) < 1e-9 { return nil }

        var loopOrdered = loop
        if area2 < 0 { loopOrdered.reverse(); pts2D.reverse(); area2 = -area2 }

        var remaining = Array(0..<loopOrdered.count)
        var out: [(Int, Int, Int)] = []
        out.reserveCapacity(loopOrdered.count - 2)

        var guardIter = 0
        while remaining.count > 3 && guardIter < 10_000 {
            guardIter += 1
            var bestIdx: Int?
            var bestScore: Float = -Float.greatestFiniteMagnitude

            for i in 0..<remaining.count {
                let iPrev = remaining[(i - 1 + remaining.count) % remaining.count]
                let iCurr = remaining[i]
                let iNext = remaining[(i + 1) % remaining.count]
                let a = pts2D[iPrev]; let b = pts2D[iCurr]; let c = pts2D[iNext]
                let cross = orient2D(a, b, c)
                if cross <= 1e-7 { continue }
                var inside = false
                for j in remaining {
                    if j == iPrev || j == iCurr || j == iNext { continue }
                    if pointInTriangle2D(pts2D[j], a, b, c) { inside = true; break }
                }
                if inside { continue }
                if diagonalIntersectsPolygon(aIndex: iPrev, bIndex: iNext,
                                             polygon: pts2D, remaining: remaining) { continue }
                if cross > bestScore { bestScore = cross; bestIdx = i }
            }

            guard let earIdx = bestIdx else { return nil }
            let iPrev = remaining[(earIdx - 1 + remaining.count) % remaining.count]
            let iCurr = remaining[earIdx]
            let iNext = remaining[(earIdx + 1) % remaining.count]
            out.append((loopOrdered[iPrev], loopOrdered[iCurr], loopOrdered[iNext]))
            remaining.remove(at: earIdx)
        }

        if remaining.count == 3 {
            out.append((loopOrdered[remaining[0]], loopOrdered[remaining[1]], loopOrdered[remaining[2]]))
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Private: edge keys

    private static func edgeKey(_ a: Int, _ b: Int) -> UInt64 {
        (UInt64(min(a, b)) << 32) | UInt64(max(a, b))
    }

    private static func directedEdgeKey(_ a: Int, _ b: Int) -> UInt64 {
        (UInt64(a) << 32) | UInt64(b)
    }

    // MARK: - Private: loop geometry

    private static func loopNormal(loop: [Int], positions: [SIMD3<Float>]) -> SIMD3<Float> {
        var n = SIMD3<Float>(0, 0, 0)
        for i in 0..<loop.count {
            n += simd_cross(positions[loop[i]], positions[loop[(i + 1) % loop.count]])
        }
        return n
    }

    // MARK: - Private: 2-D geometry helpers

    private static func polygonSignedArea2D(_ pts: [SIMD2<Float>]) -> Float {
        guard pts.count >= 3 else { return 0 }
        var a: Float = 0
        for i in 0..<pts.count {
            let p = pts[i]; let q = pts[(i + 1) % pts.count]
            a += p.x * q.y - p.y * q.x
        }
        return 0.5 * a
    }

    private static func orient2D(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Float {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    private static func pointInTriangle2D(
        _ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>
    ) -> Bool {
        let ab = orient2D(a, b, p); let bc = orient2D(b, c, p); let ca = orient2D(c, a, p)
        return !((ab < -1e-7 || bc < -1e-7 || ca < -1e-7) && (ab > 1e-7 || bc > 1e-7 || ca > 1e-7))
    }

    private static func diagonalIntersectsPolygon(
        aIndex: Int, bIndex: Int, polygon: [SIMD2<Float>], remaining: [Int]
    ) -> Bool {
        let a = polygon[aIndex]; let b = polygon[bIndex]
        for i in 0..<remaining.count {
            let u = remaining[i]; let v = remaining[(i + 1) % remaining.count]
            if u == aIndex || u == bIndex || v == aIndex || v == bIndex { continue }
            if segmentsIntersect2D(a, b, polygon[u], polygon[v]) { return true }
        }
        return false
    }

    private static func segmentsIntersect2D(
        _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, _ d: SIMD2<Float>
    ) -> Bool {
        let o1 = orient2D(a,b,c); let o2 = orient2D(a,b,d)
        let o3 = orient2D(c,d,a); let o4 = orient2D(c,d,b)
        let eps: Float = 1e-7
        return ((o1 > eps && o2 < -eps) || (o1 < -eps && o2 > eps))
            && ((o3 > eps && o4 < -eps) || (o3 < -eps && o4 > eps))
    }
}
