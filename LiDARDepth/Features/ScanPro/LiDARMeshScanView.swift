/*
 Abstract:
 Polycam-style 3D scan UI.
   • Area mode  → room-scale mesh
   • Object mode → focused object scan (Standard / Ultra Detail)
 Reference point markers can be tapped into any surface for alignment export.
*/

import SwiftUI
import UIKit
import RealityKit
import ARKit

// MARK: - Logging

/// Helper log có prefix cố định; ra console debug Xcode.
/// Lọc console: "[SCAN]" "[AR]" "[EXPORT]" "[ERROR]" để tập trung.
private enum ScanLog {
    static func ar(_ msg: String)     { print("[AR]     \(msg)") }
    static func scan(_ msg: String)   { print("[SCAN]   \(msg)") }
    static func export(_ msg: String) { print("[EXPORT] \(msg)") }
    static func ref(_ msg: String)    { print("[REF-PT] \(msg)") }
    static func error(_ msg: String)  { print("[ERROR]  ⚠️ \(msg)") }
}

// MARK: - Scan-mode enums

private enum ScanCategory: String, CaseIterable, Identifiable {
    case area, object
    var id: String { rawValue }
    var title: String { switch self { case .area: "Khu vực"; case .object: "Vật thể" } }
    var icon: String  { switch self { case .area: "house.fill"; case .object: "cube.fill" } }
}

private enum ObjectDetailMode: String, CaseIterable, Identifiable {
    case standard, ultra
    var id: String { rawValue }
    var title: String { switch self { case .standard: "Chuẩn"; case .ultra: "Siêu chi tiết" } }
    var exportSubject: ARMeshExporter.ExportSubject {
        switch self { case .standard: .nearbyObject; case .ultra: .ultraDetailObject }
    }
}

// MARK: - AR UIViewRepresentable

struct LiDARMeshScanView: UIViewRepresentable {

    @Binding var meshAnchorCount: Int
    @Binding var triangleCount: Int
    @Binding var isMeshSupported: Bool
    @Binding var arViewRef: ARView?
    @Binding var scanProgress: Double
    @Binding var scanStageText: String
    @Binding var isMovingTooFast: Bool
    @Binding var exportSubject: ARMeshExporter.ExportSubject
    @Binding var detailPatches: [ARMeshExporter.DetailPatch]
    @Binding var prefersPatchCapture: Bool
    @Binding var autoFrozenCount: Int
    @Binding var isMarkingReferencePoints: Bool
    @Binding var captureHintText: String
    /// `true`: gợi ý nghiêm trọng (motion/tracking) — banner cam đậm + `bolt.triangle.fill` (khác nền đen khi ổn).
    @Binding var captureHintCritical: Bool

    var onReferenceTapped: (SIMD3<Float>) -> Void
    var prepareForAR: () -> Void
    var isTabActive: Bool

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> ARView {
        ScanLog.ar("makeUIView — bắt đầu khởi tạo ARView")
        prepareForAR()

        let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        arView.session.delegate = context.coordinator
        context.coordinator.arView = arView

        let config = ARWorldTrackingConfiguration()
        let supportsMesh = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        isMeshSupported = supportsMesh
        ScanLog.ar("LiDAR mesh hỗ trợ: \(supportsMesh)")

        if supportsMesh { config.sceneReconstruction = .mesh }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
            ScanLog.ar("frameSemantics: smoothedSceneDepth")
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
            ScanLog.ar("frameSemantics: sceneDepth")
        } else {
            ScanLog.ar("frameSemantics: không hỗ trợ depth")
        }
        context.coordinator.trackingConfiguration = config
        arView.environment.lighting.intensityExponent = 1
        if supportsMesh { arView.debugOptions.insert(.showSceneUnderstanding) }

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        arView.addGestureRecognizer(tap)

        DispatchQueue.main.async {
            arViewRef = arView
            ScanLog.ar("arViewRef đã được gán ✓")
        }

        if isTabActive {
            arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
            context.coordinator.didRunInitialSession = true
            ScanLog.ar("Session run (initial) — isTabActive=true")
        } else {
            ScanLog.ar("makeUIView — tab không active, chờ updateUIView")
        }
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.parent = self
        guard let config = context.coordinator.trackingConfiguration else { return }
        if isTabActive {
            if context.coordinator.pausedForTabSwitch {
                uiView.session.run(config, options: [])
                context.coordinator.pausedForTabSwitch = false
                ScanLog.ar("Session resumed sau tab switch")
            } else if !context.coordinator.didRunInitialSession {
                uiView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
                context.coordinator.didRunInitialSession = true
                ScanLog.ar("Session run (lazy initial)")
            }
        } else if context.coordinator.didRunInitialSession, !context.coordinator.pausedForTabSwitch {
            uiView.session.pause()
            context.coordinator.pausedForTabSwitch = true
            ScanLog.ar("Session paused — tab không active")
        }
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, ARSessionDelegate {
        var parent: LiDARMeshScanView
        weak var arView: ARView?
        var trackingConfiguration: ARWorldTrackingConfiguration?
        var didRunInitialSession = false
        var pausedForTabSwitch = false

        private var meshAnchorsByID: [UUID: ARMeshAnchor] = [:]
        private var cachedAnchorCount = 0
        private var cachedTriangleCount = 0
        private var lastUIUpdateTime: TimeInterval = 0
        private let uiUpdateInterval: TimeInterval = 0.25
        private var lastRecordedCamPos: SIMD3<Float>?
        private var lastSpeedTimestamp: TimeInterval?
        private var lastSpeedCamPos: SIMD3<Float>?
        /// Tốc độ tức thời: cập nhật mỗi ARFrame (khác phần stats UI đang throttle ~0.25s).
        private var lastMotionPos: SIMD3<Float>?
        private var lastMotionTime: TimeInterval?
        private var lastNegativeHapticTime: TimeInterval = 0

        private lazy var hapticHeavy: UIImpactFeedbackGenerator = {
            UIImpactFeedbackGenerator(style: .heavy)
        }()

        /// (timestamp, forward đã chuẩn hóa) để ước lượng vận tốc góc (rad/s).
        private var lastForwardSample: (TimeInterval, SIMD3<Float>)?
        private let autoFreezeDelay: TimeInterval = 3.0
        private var anchorLastChangeTime: [UUID: TimeInterval] = [:]
        private var anchorVertexCounts: [UUID: Int] = [:]
        private var localFrozenAnchorIDs: Set<UUID> = []

        // ── Voxel tracking ───────────────────────────────────────────────
        private enum RegionState { case scanning, almostComplete, complete }
        private let voxelSize: Float = 0.25
        private let voxelObsThreshold = 8
        private struct VoxelKey: Hashable { let x, y, z: Int }
        private struct VoxelCell {
            var observationCount: Int = 0
            var lastObservedTime: TimeInterval = 0
            var state: RegionState = .scanning
        }
        private var voxelGrid: [VoxelKey: VoxelCell] = [:]
        private var activeVoxelBoxes: Set<VoxelKey> = []
        private let maxActiveBoxes = 20
        private var voxelUpdateCounter = 0
        private let voxelUpdateInterval = 10

        static let frozenVisualName = "frozen_visual"

        func clearLocalFrozenIDs() {
            localFrozenAnchorIDs.removeAll()
            anchorLastChangeTime.removeAll()
            anchorVertexCounts.removeAll()
            voxelGrid.removeAll()
            activeVoxelBoxes.removeAll()
            voxelUpdateCounter = 0
        }

        // MARK: ARSession lifecycle logs

        func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
            let state: String
            switch camera.trackingState {
            case .notAvailable:
                state = "notAvailable"
            case .limited(let reason):
                switch reason {
                case .initializing:      state = "limited(initializing)"
                case .excessiveMotion:   state = "limited(excessiveMotion)"
                case .insufficientFeatures: state = "limited(insufficientFeatures)"
                case .relocalizing:      state = "limited(relocalizing)"
                @unknown default:        state = "limited(unknown)"
                }
            case .normal:
                state = "normal ✓"
            @unknown default:
                state = "unknown"
            }
            ScanLog.ar("Tracking state: \(state)")
        }

        func session(_ session: ARSession, didFailWithError error: Error) {
            ScanLog.error("ARSession didFailWithError: \(error.localizedDescription)")
            if let arError = error as? ARError {
                ScanLog.error("  ARError code: \(arError.code.rawValue) — \(arError.localizedDescription)")
            }
        }

        func sessionWasInterrupted(_ session: ARSession) {
            ScanLog.ar("Session bị ngắt (sessionWasInterrupted)")
        }

        func sessionInterruptionEnded(_ session: ARSession) {
            ScanLog.ar("Session ngắt kết thúc (sessionInterruptionEnded)")
        }

        // MARK: Reference-point tap

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard parent.isMarkingReferencePoints else { return }
            guard let av = arView else { return }
            let location = recognizer.location(in: av)
            let results = av.raycast(from: location, allowing: .estimatedPlane, alignment: .any)
            let worldPos: SIMD3<Float>
            if let hit = results.first {
                let c = hit.worldTransform.columns.3
                worldPos = SIMD3<Float>(c.x, c.y, c.z)
            } else if let frame = av.session.currentFrame {
                let t = frame.camera.transform
                let p = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
                let f = -SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)
                worldPos = p + simd_normalize(f) * 0.5
            } else { return }
            DispatchQueue.main.async { self.parent.onReferenceTapped(worldPos) }
        }

        // MARK: Bounding-box visualization

        private func voxelKey(_ pos: SIMD3<Float>) -> VoxelKey {
            VoxelKey(x: Int(floor(pos.x / voxelSize)),
                     y: Int(floor(pos.y / voxelSize)),
                     z: Int(floor(pos.z / voxelSize)))
        }

        private func voxelEntityName(_ key: VoxelKey) -> String {
            "\(Coordinator.frozenVisualName)_v_\(key.x)_\(key.y)_\(key.z)"
        }

        private func showVoxelBox(key: VoxelKey, in arView: ARView) {
            let lo = SIMD3<Float>(Float(key.x), Float(key.y), Float(key.z)) * voxelSize
            buildAndAddBox(lo: lo, hi: lo + SIMD3<Float>(repeating: voxelSize),
                           transform: matrix_identity_float4x4,
                           name: voxelEntityName(key), in: arView)
        }

        private func fadeVoxelBox(key: VoxelKey, in arView: ARView) {
            let targetName = voxelEntityName(key)
            let steps = 6; let dt: Double = 0.05
            DispatchQueue.main.async { [weak arView] in
                guard let arView,
                      let entity = arView.scene.anchors.first(where: { $0.name == targetName })
                else { return }
                for step in 1...steps {
                    DispatchQueue.main.asyncAfter(deadline: .now() + dt * Double(step)) { [weak entity, weak arView] in
                        guard let entity else { return }
                        let alpha = CGFloat(1.0 - Double(step) / Double(steps))
                        entity.children.forEach {
                            if let m = $0 as? ModelEntity {
                                var mat = UnlitMaterial()
                                mat.color = .init(tint: UIColor(white: 1.0, alpha: alpha))
                                m.model?.materials = [mat]
                            }
                        }
                        if step == steps { arView?.scene.removeAnchor(entity) }
                    }
                }
            }
        }

        private func sampleAnchorIntoVoxels(mesh: ARMeshAnchor, at time: TimeInterval) {
            let src = mesh.geometry.vertices
            guard src.count > 0 else { return }
            let base = src.buffer.contents() + src.offset
            let step = max(1, src.count / 25)
            for i in stride(from: 0, to: src.count, by: step) {
                let local = (base + i * src.stride).assumingMemoryBound(to: SIMD3<Float>.self).pointee
                let w = mesh.transform * SIMD4<Float>(local.x, local.y, local.z, 1)
                let key = voxelKey(SIMD3<Float>(w.x, w.y, w.z))
                var cell = voxelGrid[key] ?? VoxelCell()
                guard cell.state != .complete else { continue }
                cell.observationCount += 1
                cell.lastObservedTime  = time
                voxelGrid[key] = cell
            }
        }

        private func checkVoxelTransitions(at now: TimeInterval) {
            guard let av = arView else { return }
            var completedCount = 0
            for key in voxelGrid.keys {
                guard var cell = voxelGrid[key] else { continue }
                guard cell.state != .complete else { completedCount += 1; continue }
                let elapsed = now - cell.lastObservedTime
                switch cell.state {
                case .scanning where cell.observationCount >= voxelObsThreshold:
                    cell.state = .almostComplete
                    voxelGrid[key] = cell
                    if !activeVoxelBoxes.contains(key), activeVoxelBoxes.count < maxActiveBoxes {
                        activeVoxelBoxes.insert(key)
                        showVoxelBox(key: key, in: av)
                    }
                case .almostComplete where elapsed >= autoFreezeDelay:
                    cell.state = .complete
                    voxelGrid[key] = cell
                    if activeVoxelBoxes.remove(key) != nil { fadeVoxelBox(key: key, in: av) }
                    completedCount += 1
                default: break
                }
            }
            let total = completedCount
            DispatchQueue.main.async { self.parent.autoFrozenCount = total }
        }

        func addFrozenVisualization(for anchor: ARMeshAnchor, in arView: ARView) {
            let src = anchor.geometry.vertices
            guard src.count > 0 else { return }
            let base = src.buffer.contents() + src.offset
            var lo = SIMD3<Float>(repeating:  Float.greatestFiniteMagnitude)
            var hi = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
            for i in 0..<src.count {
                let v = (base + i * src.stride).assumingMemoryBound(to: SIMD3<Float>.self).pointee
                lo = simd_min(lo, v); hi = simd_max(hi, v)
            }
            buildAndAddBox(lo: lo, hi: hi, transform: anchor.transform,
                           name: Self.frozenVisualName, in: arView)
        }

        private func buildAndAddBox(lo: SIMD3<Float>, hi: SIMD3<Float>,
                                    transform: float4x4, name: String, in arView: ARView) {
            let lx = hi.x - lo.x, ly = hi.y - lo.y, lz = hi.z - lo.z
            guard lx > 0.01, ly > 0.01, lz > 0.01 else { return }
            let t  = max(0.005, min(0.014, min(lx, min(ly, lz)) * 0.018))
            let cx = (lo.x + hi.x) * 0.5
            let cy = (lo.y + hi.y) * 0.5
            let cz = (lo.z + hi.z) * 0.5
            DispatchQueue.main.async { [weak arView] in
                guard let arView else { return }
                if let old = arView.scene.anchors.first(where: { $0.name == name }) {
                    arView.scene.removeAnchor(old)
                }
                var mat = UnlitMaterial()
                mat.color = .init(tint: UIColor(white: 1.0, alpha: 1.0))
                let root = AnchorEntity(world: transform)
                root.name = name
                func bar(_ pos: SIMD3<Float>, _ size: SIMD3<Float>) {
                    let e = ModelEntity(mesh: MeshResource.generateBox(size: size), materials: [mat])
                    e.position = pos; root.addChild(e)
                }
                bar(SIMD3(cx, lo.y, lo.z), SIMD3(lx, t, t)); bar(SIMD3(cx, hi.y, lo.z), SIMD3(lx, t, t))
                bar(SIMD3(cx, lo.y, hi.z), SIMD3(lx, t, t)); bar(SIMD3(cx, hi.y, hi.z), SIMD3(lx, t, t))
                bar(SIMD3(lo.x, cy, lo.z), SIMD3(t, ly, t)); bar(SIMD3(hi.x, cy, lo.z), SIMD3(t, ly, t))
                bar(SIMD3(lo.x, cy, hi.z), SIMD3(t, ly, t)); bar(SIMD3(hi.x, cy, hi.z), SIMD3(t, ly, t))
                bar(SIMD3(lo.x, lo.y, cz), SIMD3(t, t, lz)); bar(SIMD3(hi.x, lo.y, cz), SIMD3(t, t, lz))
                bar(SIMD3(lo.x, hi.y, cz), SIMD3(t, t, lz)); bar(SIMD3(hi.x, hi.y, cz), SIMD3(t, t, lz))
                arView.scene.addAnchor(root)
            }
        }

        // MARK: init

        init(parent: LiDARMeshScanView) { self.parent = parent }

        // MARK: ARSessionDelegate

        func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { mergeMeshAnchors(from: anchors) }
        func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) { mergeMeshAnchors(from: anchors) }
        func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
            var changed = false
            for anchor in anchors where meshAnchorsByID.removeValue(forKey: anchor.identifier) != nil { changed = true }
            if changed { recomputeAndPublishStats() }
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            let camPos = SIMD3<Float>(
                frame.camera.transform.columns.3.x,
                frame.camera.transform.columns.3.y,
                frame.camera.transform.columns.3.z
            )
            let col2 = frame.camera.transform.columns.2
            let forwardUnit = simd_normalize(-SIMD3<Float>(col2.x, col2.y, col2.z))

            var linearInst: Float = 0
            if let lp = lastMotionPos, let lt = lastMotionTime {
                linearInst = simd_length(camPos - lp) / max(Float(frame.timestamp - lt), Float(1e-4))
            }
            lastMotionPos = camPos
            lastMotionTime = frame.timestamp

            var angularInst: Float = 0
            if let (prevT, prevF) = lastForwardSample {
                let dt = Float(frame.timestamp - prevT)
                if dt > Float(1e-4) {
                    let dp = simd_clamp(simd_dot(prevF, forwardUnit), -1, 1)
                    angularInst = acos(dp) / dt
                }
            }
            lastForwardSample = (frame.timestamp, forwardUnit)

            let subj = parent.exportSubject
            let linMax = fusionLinearLimit(subj)
            let angMax = fusionAngularLimit(subj)

            let fusionMotionOK = linearInst <= linMax && angularInst <= angMax
            let fusionOK = fusionMotionOK && ARMeshExporter.shouldRecordFrameForFusion(frame)

            let recordDistanceThreshold: Float
            switch parent.exportSubject {
            case .room:              recordDistanceThreshold = 0.015
            case .nearbyObject:      recordDistanceThreshold = 0.008
            case .ultraDetailObject: recordDistanceThreshold = 0.004
            }

            if fusionOK {
                if let lastRec = lastRecordedCamPos {
                    if simd_length(camPos - lastRec) >= recordDistanceThreshold {
                        ARMeshExporter.recordFrameForColorFusion(
                            frame, cameraPosition: camPos,
                            detailPatches: parent.detailPatches,
                            preferPatchHistory: parent.prefersPatchCapture
                        )
                        lastRecordedCamPos = camPos
                    }
                } else {
                    ARMeshExporter.recordFrameForColorFusion(
                        frame, cameraPosition: camPos,
                        detailPatches: parent.detailPatches,
                        preferPatchHistory: parent.prefersPatchCapture
                    )
                    lastRecordedCamPos = camPos
                }
            }

            guard frame.timestamp - lastUIUpdateTime >= uiUpdateInterval else { return }
            lastUIUpdateTime = frame.timestamp

            var uiLinearSpeed: Float = 0
            if let prevT = lastSpeedTimestamp, let prevP = lastSpeedCamPos {
                uiLinearSpeed = simd_length(camPos - prevP) / max(Float(frame.timestamp - prevT), 1e-3)
            }
            lastSpeedTimestamp = frame.timestamp
            lastSpeedCamPos = camPos

            let linH = linearHardThreshold(subj)
            let angH = angularHardThreshold(subj)

            let arExcessiveMotion: Bool = {
                if case .limited(.excessiveMotion) = frame.camera.trackingState { return true }
                return false
            }()

            let tooFastLinear = uiLinearSpeed > linH || linearInst > linH * 1.12
            let tooFastAngular = angularInst > angH
            let tooFast = arExcessiveMotion || tooFastLinear || tooFastAngular

            let triangleTarget: Double
            switch parent.exportSubject {
            case .room:              triangleTarget = 80_000
            case .nearbyObject:      triangleTarget = 45_000
            case .ultraDetailObject: triangleTarget = 65_000
            }

            let triangles = cachedTriangleCount
            let finalProgress = max(0, min(1,
                min(Double(triangles) / triangleTarget, 1.0) - (tooFast ? 0.15 : 0)))

            let stage: String
            if triangles == 0 {
                stage = "Đang khởi động mesh..."
            } else if finalProgress < 0.25 {
                switch parent.exportSubject {
                case .room:              stage = "Bước 1/4: Quét khung tổng thể"
                case .nearbyObject:      stage = "Bước 1/4: Tiến gần vật thể"
                case .ultraDetailObject: stage = "Bước 1/4: Khóa vật ở giữa khung"
                }
            } else if finalProgress < 0.5 {
                switch parent.exportSubject {
                case .room:              stage = "Bước 2/4: Bổ sung góc khuất"
                case .nearbyObject:      stage = "Bước 2/4: Quét các mép và gờ"
                case .ultraDetailObject: stage = "Bước 2/4: Quét mép và cạnh thật chậm"
                }
            } else if finalProgress < 0.8 {
                switch parent.exportSubject {
                case .room:              stage = "Bước 3/4: Tăng chi tiết bề mặt"
                case .nearbyObject:      stage = "Bước 3/4: Giữ khoảng cách gần, quét chậm"
                case .ultraDetailObject: stage = "Bước 3/4: Tích lũy texture sắc nét"
                }
            } else {
                switch parent.exportSubject {
                case .room:              stage = "Bước 4/4: Gần hoàn tất – quét chậm thêm"
                case .nearbyObject:      stage = "Bước 4/4: Khóa chi tiết vật gần"
                case .ultraDetailObject: stage = "Bước 4/4: Hoàn thiện cận cảnh"
                }
            }

            let hint = captureHint(for: frame.camera.trackingState,
                                   linearUISpeed: uiLinearSpeed,
                                   linearInstant: linearInst,
                                   angularRadPerSec: angularInst,
                                   subject: subj)

            let ac = cachedAnchorCount
            let tc = cachedTriangleCount

            DispatchQueue.main.async {
                self.parent.meshAnchorCount = ac
                self.parent.triangleCount = tc
                self.parent.isMovingTooFast = tooFast
                self.parent.scanProgress = finalProgress
                self.parent.scanStageText = stage
                self.parent.captureHintText = hint.text
                self.parent.captureHintCritical = hint.isCritical
                if hint.shouldHapticPulse {
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - self.lastNegativeHapticTime >= 1.3 {
                        self.lastNegativeHapticTime = now
                        self.hapticHeavy.prepare()
                        self.hapticHeavy.impactOccurred()
                    }
                }
            }

            if !fusionMotionOK || !ARMeshExporter.shouldRecordFrameForFusion(frame) {
                throttleFusionSkipLog {
                    ScanLog.scan(
                        "[fusion skip] lin \(String(format: "%.3f", linearInst))/max \(linMax)" +
                            " ang \(String(format: "%.3f", angularInst))/max \(angMax) " +
                            " tracking=\(frame.camera.trackingState)"
                    )
                }
            }
        }

        /// Throttle log fusion-skip — không in mỗi frame (~60 FPS) làm đầy console.
        private var lastFusionSkipLogWall: TimeInterval = 0
        private func throttleFusionSkipLog(_ block: () -> Void) {
            let t = ProcessInfo.processInfo.systemUptime
            guard t - lastFusionSkipLogWall >= 1.8 else { return }
            lastFusionSkipLogWall = t
            block()
        }

        private struct CaptureHintOutcome {
            var text = ""
            var isCritical = false
            var shouldHapticPulse = false
        }

        private func captureHint(
            for tracking: ARCamera.TrackingState,
            linearUISpeed: Float,
            linearInstant: Float,
            angularRadPerSec: Float,
            subject: ARMeshExporter.ExportSubject
        ) -> CaptureHintOutcome {
            var out = CaptureHintOutcome()
            let linH = linearHardThreshold(subject)
            let angH = angularHardThreshold(subject)
            let linS = linH * 0.55
            let angS = angH * 0.62
            let tip: String = {
                subject == .room
                    ? " Quét cực chậm như chỉnh film — mục tiêu ~\(Int(linH * 100)) cm/s max."
                    : (" Quét rất chậm — " + (subject == .ultraDetailObject ? "đứng yên một nhịp" : "từng bước nhỏ") + ".")
            }()

            switch tracking {
            case .notAvailable:
                out.text = "Tracking AR không ổn định. Thêm vật thể vào khung, tránh tường trắng trơn không viền."
                out.isCritical = true
                out.shouldHapticPulse = true
                return out
            case .limited(let r):
                switch r {
                case .excessiveMotion:
                    out.text = "Chuyển động quá mạnh — ARKit dừng ghi chi tiết. Đứng yên ~1 giây, quét cực chậm để tránh ghosting và mờ texture."
                    out.isCritical = true
                    out.shouldHapticPulse = true
                    return out
                case .relocalizing:
                    out.text = "Đang tái ghép không gian — giữ trong cùng một phòng, quét chậm, không chạy nhanh qua chỗ khác."
                    out.isCritical = true
                    return out
                case .initializing:
                    out.text = "Tracking khởi tạo — di chuyển điện thoại từ từ, quét các góc phòng trong vài mét."
                    return out
                case .insufficientFeatures:
                    out.text = "Ít chi tiết để neo map — nhắm góc bàn/ghế cửa, tránh chỉ có một vách phẳng."
                    return out
                @unknown default:
                    break
                }
            case .normal:
                break
            @unknown default:
                break
            }

            if angularRadPerSec > angH || linearInstant > linH {
                let dps = Int(angularRadPerSec * 180 / Float.pi)
                if angularRadPerSec > angH && linearInstant > linH {
                    out.text = "Đang đi ~\(Int(linearInstant * 100)) cm/s và xoay ~\(dps)°/giây — dễ bị chồng ảnh (ghosting)." + tip
                } else if angularRadPerSec > angH {
                    out.text = "Xoay điện thoại quá nhanh (~\(dps)°/giây) — ảnh dán lên mesh sẽ bị mờ và double edges." + tip
                } else {
                    out.text = "Đi tay quá nhanh (~\(Int(linearInstant * 100)) cm/s) — frame motion blur không được ghép vào texture."
                    out.shouldHapticPulse = true
                }
                out.isCritical = true
                if angularRadPerSec > angH || linearInstant > linH {
                    out.shouldHapticPulse = true
                }
                return out
            }
            if angularRadPerSec > angS || linearUISpeed > linS || linearInstant > linS {
                out.text = "Hơi nhanh — chậm hơn một chút. Tay vững, xoay như tripod; mỗi góc nên được giữ trong vài giây."
                return out
            }

            switch subject {
            case .room:
                out.text = "Điều kiện tốt ✓ Ghim mỗi góc 2–3 giây, tránh chỉ vuốt nhanh qua mặt máy/màn/kệ."
            case .nearbyObject:
                out.text = "Điều kiện tốt ✓ Quanh vật 2–3 vòng với hai khoảng cách cố định, đứng yên trong mỗi khung một chút."
            case .ultraDetailObject:
                out.text = "Điều kiện tốt ✓ Mép và lỗ nhỏ: chạy rất chậm, có thể dừng hẳn 1 nhịp tại chỗ mép để không trôi mesh."
            }
            return out
        }

        private func fusionLinearLimit(_ s: ARMeshExporter.ExportSubject) -> Float {
            switch s { case .room: 0.34; case .nearbyObject: 0.12; case .ultraDetailObject: 0.075 }
        }

        private func fusionAngularLimit(_ s: ARMeshExporter.ExportSubject) -> Float {
            switch s { case .room: 0.92; case .nearbyObject: 0.52; case .ultraDetailObject: 0.34 }
        }

        private func linearHardThreshold(_ s: ARMeshExporter.ExportSubject) -> Float {
            switch s { case .room: 0.32; case .nearbyObject: 0.12; case .ultraDetailObject: 0.068 }
        }

        private func angularHardThreshold(_ s: ARMeshExporter.ExportSubject) -> Float {
            fusionAngularLimit(s)
        }

        private func mergeMeshAnchors(from anchors: [ARAnchor]) {
            var changed = false
            let now = Date().timeIntervalSinceReferenceDate
            for anchor in anchors {
                guard let mesh = anchor as? ARMeshAnchor else { continue }
                let id = mesh.identifier
                if localFrozenAnchorIDs.contains(id) { continue }
                let currentCount = mesh.geometry.vertices.count
                let prevCount    = anchorVertexCounts[id] ?? 0
                let threshold    = max(2, prevCount / 200)
                if prevCount == 0 || abs(currentCount - prevCount) > threshold {
                    anchorVertexCounts[id]   = currentCount
                    anchorLastChangeTime[id] = now
                    if currentCount >= 20 { sampleAnchorIntoVoxels(mesh: mesh, at: now) }
                }
                meshAnchorsByID[id] = mesh
                changed = true
            }
            if changed {
                recomputeAndPublishStats()
                voxelUpdateCounter += 1
                if voxelUpdateCounter >= voxelUpdateInterval {
                    voxelUpdateCounter = 0
                    checkVoxelTransitions(at: now)
                }
            }
        }

        private var lastStatLogTime: TimeInterval = 0

        private func recomputeAndPublishStats() {
            cachedTriangleCount = meshAnchorsByID.values.reduce(0) { $0 + $1.geometry.faces.count }
            cachedAnchorCount   = meshAnchorsByID.count
            let ac = cachedAnchorCount, tc = cachedTriangleCount

            // Throttle stat log to once per 3 seconds
            let now = Date().timeIntervalSinceReferenceDate
            if now - lastStatLogTime >= 3.0 {
                lastStatLogTime = now
                let frozen = ARMeshExporter.frozenBlockCount
                ScanLog.scan("Mesh stats — anchors:\(ac)  triangles:\(tc)  frozenBlocks:\(frozen)  voxels:\(voxelGrid.count)")
            }

            DispatchQueue.main.async {
                self.parent.meshAnchorCount = ac
                self.parent.triangleCount   = tc
            }
        }
    }
}

// MARK: - Container (Polycam-style shell)

struct LiDARMeshScanContainer: View {

    var isTabActive: Bool
    var prepareForAR: () -> Void
    var onDismiss: (() -> Void)? = nil
    var onOpenProjects: (() -> Void)? = nil

    // Scan mode
    @State private var scanCategory: ScanCategory = .area
    @State private var objectDetailMode: ObjectDetailMode = .standard
    @State private var exportSubject: ARMeshExporter.ExportSubject = .room

    // Settings
    @State private var smoothingPreset: MeshLaplacianSmooth.QualityPreset = .precise
    @State private var detailPatches: [ARMeshExporter.DetailPatch] = []

    // Reference points
    @State private var referencePoints: [ARMeshExporter.ReferencePoint] = []
    @State private var isMarkingMode = false

    // Scan stats
    @State private var meshAnchorCount = 0
    @State private var triangleCount   = 0
    @State private var isMeshSupported = true
    @State private var scanProgress: Double = 0
    @State private var scanStageText  = "Đang khởi động..."
    @State private var isMovingTooFast = false
    @State private var frozenBlockCount = 0
    @State private var captureHintText = ""
    @State private var captureHintCritical = false

    // Export / share
    @State private var isExporting    = false
    @State private var exportMessage: String?
    @State private var exportURLs: [URL] = []
    @State private var showShare      = false
    @State private var showSettings   = false
    @State private var arViewRef: ARView?

    private var hasData: Bool { triangleCount > 0 || meshAnchorCount > 0 }

    // MARK: Body

    var body: some View {
        ZStack {
            LiDARMeshScanView(
                meshAnchorCount: $meshAnchorCount,
                triangleCount:   $triangleCount,
                isMeshSupported: $isMeshSupported,
                arViewRef:       $arViewRef,
                scanProgress:    $scanProgress,
                scanStageText:   $scanStageText,
                isMovingTooFast: $isMovingTooFast,
                exportSubject:   $exportSubject,
                detailPatches:   $detailPatches,
                prefersPatchCapture: .constant(scanCategory == .object && !detailPatches.isEmpty),
                autoFrozenCount: $frozenBlockCount,
                isMarkingReferencePoints: $isMarkingMode,
                captureHintText: $captureHintText,
                captureHintCritical: $captureHintCritical,
                onReferenceTapped: placeReferencePoint,
                prepareForAR: prepareForAR,
                isTabActive: isTabActive
            )
            .ignoresSafeArea()
            // NOTE: Đừng set arViewRef = nil ở đây khi mở sheet — SwiftUI vẫn có thể gọi
            // onDisappear trong lúc present sheet, khiến export tưởng ref mất.
            // Chỉ giải phóng ARView khi user thật sự thoát tab Quét.
            .onDisappear {
                ScanLog.ar("LiDARMeshScanView onDisappear — arViewRef giữ nguyên để export tiếp được")
            }

            VStack(spacing: 0) {
                scanProTopBar.padding(.top, 8)
                if !showSettings {
                    compactModeSelector
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                }
                if !captureHintText.isEmpty, !showSettings {
                    captureQualityBanner
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                Spacer()
                if isMarkingMode, !showSettings { markingOverlay.padding(.bottom, 20) }
                if !showSettings { bottomPanel }
            }

            if showSettings {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { withAnimation { showSettings = false } }

                VStack {
                    Spacer()
                    ScanSettingsBottomSheet(
                        smoothingPreset: $smoothingPreset,
                        detailPatches: $detailPatches,
                        onAddPatch: addDetailPatch,
                        onDeletePatch: deleteDetailPatch,
                        onClose: { withAnimation { showSettings = false } },
                        onExport: {
                            withAnimation { showSettings = false }
                            exportAll()
                        }
                    )
                    .frame(maxHeight: UIScreen.main.bounds.height * 0.72)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: showSettings)
        .sheet(isPresented: $showShare) {
            if !exportURLs.isEmpty { ShareSheet(items: exportURLs) }
        }
        .onAppear { syncExportSubject() }
    }

    // MARK: ScanPro top bar

    private var scanProTopBar: some View {
        HStack(spacing: 10) {
            Button {
                onDismiss?()
            } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.body.weight(.medium))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Circle())
            }

            Text("ScanPro")
                .font(.subheadline.weight(.bold))
                .foregroundColor(ScannerTheme.accent)

            Spacer()

            HStack(spacing: 0) {
                Text("Scan")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.white)
                    .clipShape(Capsule())

                Button {
                    onOpenProjects?()
                } label: {
                    Text("Projects")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.white.opacity(0.55))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                }
            }
            .padding(3)
            .background(Color.white.opacity(0.12))
            .clipShape(Capsule())

            Button { withAnimation { showSettings = true } } label: {
                Image(systemName: "gearshape.fill")
                    .font(.body.weight(.medium))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: Mode selector (visible when settings sheet is closed)

    private var compactModeSelector: some View {
        VStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(ScanCategory.allCases) { cat in
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                            scanCategory = cat
                            isMarkingMode = false
                            syncExportSubject()
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: cat.icon).font(.caption2.weight(.semibold))
                            Text(cat.title).font(.caption.weight(.semibold))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(scanCategory == cat ? Color.accentColor : Color.clear)
                        .foregroundColor(scanCategory == cat ? .white : .white.opacity(0.6))
                        .clipShape(Capsule())
                    }
                }
            }
            .padding(3)
            .background(Color.white.opacity(0.12))
            .clipShape(Capsule())

            if scanCategory == .object {
                Picker("Chi tiết", selection: $objectDetailMode) {
                    ForEach(ObjectDetailMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: objectDetailMode) { _ in syncExportSubject() }
            }
        }
    }

    // MARK: Marking crosshair overlay

    private var markingOverlay: some View {
        VStack(spacing: 8) {
            Image(systemName: "plus.circle")
                .font(.system(size: 46, weight: .ultraLight))
                .foregroundStyle(.orange)
                .shadow(color: .black.opacity(0.5), radius: 6)
            Text("Chạm vào bề mặt để đặt điểm chuẩn")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Color.black.opacity(0.55))
                .foregroundStyle(.white)
                .clipShape(Capsule())
        }
        .transition(.opacity)
    }

    /// Banner gợi ý chất lượng quét — motion blur + trạng thái tracking ARKit.
    private var captureQualityBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: captureHintCritical ? "bolt.triangle.fill" : "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(Color.white.opacity(0.95))
                .shadow(radius: 2)
            Text(captureHintText)
                .font(.caption)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .frame(maxWidth: .infinity)
        .background(captureHintCritical ? Color.orange.opacity(0.93) : Color.black.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(captureHintCritical ? 0.28 : 0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
        .allowsHitTesting(false)
    }

    // MARK: Bottom panel

    private var bottomPanel: some View {
        VStack(spacing: 0) {
            // Thin scan-progress bar pinned to top of panel
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.12)).frame(height: 3)
                    Rectangle()
                        .fill(isMovingTooFast ? Color.orange : Color.accentColor)
                        .frame(width: geo.size.width * CGFloat(scanProgress), height: 3)
                        .animation(.linear(duration: 0.2), value: scanProgress)
                }
            }
            .frame(height: 3)

            VStack(spacing: 10) {
                // Stage + percentage
                HStack(alignment: .top) {
                    Text(isMeshSupported ? scanStageText : "⚠️ Thiết bị không hỗ trợ LiDAR mesh")
                        .font(.caption2)
                        .foregroundStyle(isMeshSupported ? Color.gray : Color.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(Int(scanProgress * 100))%")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                }

                // Metric chips
                HStack(spacing: 8) {
                    statChip("\(meshAnchorCount)", icon: "point.3.filled.connected.trianglepath.dotted", color: .blue)
                    statChip("\(triangleCount)",   icon: "triangle",             color: .purple)
                    if frozenBlockCount > 0 {
                        statChip("\(frozenBlockCount)", icon: "snowflake",       color: .cyan)
                    }
                    if !referencePoints.isEmpty {
                        statChip("\(referencePoints.count)", icon: "mappin.circle.fill", color: .orange)
                    }
                    Spacer()
                }

                // Reference-point strip
                if !referencePoints.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.circle.fill").foregroundStyle(.orange).font(.caption)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 5) {
                                ForEach(referencePoints) { pt in
                                    Text(pt.label)
                                        .font(.caption2.weight(.medium))
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(Color.orange.opacity(0.18))
                                        .foregroundStyle(.orange)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                        Button {
                            referencePoints.removeAll()
                            ARMeshExporter.clearReferencePoints()
                            arViewRef?.scene.anchors
                                .filter { $0.name.hasPrefix("ref_pt_") }
                                .forEach { arViewRef?.scene.removeAnchor($0) }
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).font(.caption)
                        }
                    }
                }

                Divider().opacity(0.35)

                // Action buttons row
                HStack(spacing: 8) {
                    actionBtn("Chụp vùng", icon: "camera.fill", color: .green) { freezeCurrentBlock() }
                        .disabled(!hasData)
                    actionBtn(
                        isMarkingMode ? "Dừng" : "Đánh dấu",
                        icon: isMarkingMode ? "xmark.circle.fill" : "mappin.and.ellipse",
                        color: .orange
                    ) { withAnimation { isMarkingMode.toggle() } }
                    if frozenBlockCount > 0 {
                        actionBtn("Xóa hết", icon: "trash.fill", color: .red) { clearAll() }
                    }
                }

                // Export button
                Button(action: exportAll) {
                    Group {
                        if isExporting {
                            HStack(spacing: 8) { ProgressView().tint(.white); Text("Đang xuất...").font(.body.weight(.bold)) }
                        } else {
                            let jsonNote = referencePoints.isEmpty ? "" : " + \(referencePoints.count) điểm JSON"
                            Label("Export GLB + OBJ\(jsonNote)", systemImage: "square.and.arrow.up.fill").font(.body.weight(.bold))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(hasData && !isExporting ? Color.accentColor : Color.secondary.opacity(0.25))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(!hasData || isExporting)

                if let msg = exportMessage {
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(msg.hasPrefix("Lỗi") ? Color.red : Color.gray)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 18, x: 0, y: -4)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: View helpers

    @ViewBuilder
    private func statChip(_ value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.caption2).foregroundStyle(color)
            Text(value).font(.caption2.monospacedDigit())
        }
    }

    @ViewBuilder
    private func actionBtn(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption2.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }


    // MARK: Logic helpers

    private func syncExportSubject() {
        switch scanCategory {
        case .area:   exportSubject = .room
        case .object: exportSubject = objectDetailMode.exportSubject
        }
    }

    private func placeReferencePoint(_ position: SIMD3<Float>) {
        let index = referencePoints.count + 1
        let pt = ARMeshExporter.ReferencePoint(worldPosition: position, label: "P\(index)")
        ARMeshExporter.addReferencePoint(pt)
        referencePoints.append(pt)
        ScanLog.ref("Đặt P\(index) tại world(\(String(format:"%.3f",position.x)), \(String(format:"%.3f",position.y)), \(String(format:"%.3f",position.z)))")

        // Orange sphere marker in AR
        if let view = arViewRef {
            let sphere = ModelEntity(mesh: MeshResource.generateSphere(radius: 0.015),
                                     materials: [{ var m = UnlitMaterial(); m.color = .init(tint: .systemOrange); return m }()])
            var t = matrix_identity_float4x4
            t.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)
            let anchor = AnchorEntity(world: t)
            anchor.name = "ref_pt_\(index)"
            anchor.addChild(sphere)
            view.scene.addAnchor(anchor)
        }
        exportMessage = "📍 Điểm \(pt.label) đã đặt — chạm tiếp để thêm hoặc bấm Dừng khi xong."
    }

    private func freezeCurrentBlock() {
        ScanLog.scan("freezeCurrentBlock — arViewRef=\(arViewRef != nil ? "✓" : "NIL ✗")")
        guard let view = arViewRef else {
            ScanLog.error("freezeCurrentBlock FAIL: arViewRef nil")
            exportMessage = "ARSession chưa sẵn sàng."; return
        }
        guard let frame = view.session.currentFrame else {
            ScanLog.error("freezeCurrentBlock FAIL: currentFrame nil — session state=\(view.session.identifier)")
            exportMessage = "ARSession chưa sẵn sàng."; return
        }
        let anchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        ScanLog.scan("freezeCurrentBlock — tổng anchors trong frame: \(frame.anchors.count), mesh anchors: \(anchors.count)")
        guard !anchors.isEmpty else { exportMessage = "Chưa có mesh – hãy quét thêm."; return }
        ARMeshExporter.freezeCurrentAnchors(anchors)
        frozenBlockCount = ARMeshExporter.frozenBlockCount
        ScanLog.scan("freezeCurrentBlock ✓ — frozenBlockCount=\(frozenBlockCount)")
        if let coord = view.session.delegate as? LiDARMeshScanView.Coordinator {
            for anchor in anchors { coord.addFrozenVisualization(for: anchor, in: view) }
        }
        // Compute world-space bounding box of this capture for instant dimension feedback
        let dims = boundingBoxDimensions(of: anchors)
        let dimText: String
        if let d = dims {
            let vol = d.x * d.y * d.z
            dimText = String(format: "  %d×%d×%d cm (V≈%.1f L)",
                             Int(d.x * 100), Int(d.y * 100), Int(d.z * 100), vol * 1000)
        } else { dimText = "" }
        exportMessage = "✅ Vùng \(frozenBlockCount) đã lưu.\(dimText)"
    }

    /// Phạm vi X/Y/Z (mét) của AABB không gian thế giới chứa toàn bộ đỉnh trong `anchors`.
    private func boundingBoxDimensions(of anchors: [ARMeshAnchor]) -> SIMD3<Float>? {
        var lo = SIMD3<Float>(repeating:  Float.greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
        var found = false
        for anchor in anchors {
            let src  = anchor.geometry.vertices
            guard src.count > 0 else { continue }
            let base = src.buffer.contents() + src.offset
            for i in 0..<src.count {
                let local = (base + i * src.stride).assumingMemoryBound(to: SIMD3<Float>.self).pointee
                let w = anchor.transform * SIMD4<Float>(local.x, local.y, local.z, 1)
                let wp = SIMD3<Float>(w.x, w.y, w.z)
                lo = simd_min(lo, wp); hi = simd_max(hi, wp)
                found = true
            }
        }
        return found ? (hi - lo) : nil
    }

    private func addDetailPatch() {
        guard detailPatches.count < ScanSettingsBottomSheet.maxPatches else { return }
        guard let view = arViewRef else { return }
        let center  = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let results = view.raycast(from: center, allowing: .estimatedPlane, alignment: .any)
        let pos: SIMD3<Float>
        if let hit = results.first {
            let c = hit.worldTransform.columns.3; pos = SIMD3<Float>(c.x, c.y, c.z)
        } else if let frame = view.session.currentFrame {
            let t = frame.camera.transform
            let p = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            let f = -SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)
            pos = p + simd_normalize(f) * 0.55
        } else { return }

        let index = detailPatches.count
        let label = index == 0 ? "Vùng trung tâm" : "Vùng chi tiết \(index + 1)"
        let radius: Float = index == 0 ? 0.9 : 0.45
        detailPatches.append(ARMeshExporter.DetailPatch(center: pos, radius: radius, label: label))
    }

    private func deleteDetailPatch(_ id: UUID) {
        detailPatches.removeAll { $0.id == id }
    }

    private func clearAll() {
        let cleared = frozenBlockCount
        ARMeshExporter.clearFrozenBlocks()
        frozenBlockCount = 0
        if let view = arViewRef {
            let prefix = LiDARMeshScanView.Coordinator.frozenVisualName
            view.scene.anchors.filter { $0.name.hasPrefix(prefix) }.forEach { view.scene.removeAnchor($0) }
            (view.session.delegate as? LiDARMeshScanView.Coordinator)?.clearLocalFrozenIDs()
        }
        exportMessage = "Đã xóa \(cleared) vùng đã lưu."
    }

    private func exportAll() {
        exportMessage = nil
        ScanLog.export("exportAll bắt đầu — arViewRef=\(arViewRef != nil ? "✓" : "NIL ✗")  triangles=\(triangleCount)  frozen=\(frozenBlockCount)")

        guard let view = arViewRef else {
            ScanLog.error("exportAll FAIL: arViewRef nil — có thể do sheet/disappear đã nil ref. Thử bấm lại tab Quét 3D.")
            exportMessage = "Camera AR chưa sẵn sàng — bấm lại tab Quét 3D rồi thử lại."
            return
        }

        isExporting = true
        exportMessage = "Đang xuất..."
        let session   = view.session
        let stamp     = Int(Date().timeIntervalSince1970)
        let preset    = smoothingPreset
        let profile   = ARMeshExporter.ExportProfile(subject: exportSubject)
        let patches   = detailPatches
        let hasRefPts = !referencePoints.isEmpty

        ScanLog.export("profile=\(exportSubject.rawValue)  patches=\(patches.count)  refPts=\(referencePoints.count)  smoothing=\(preset.rawValue)")

        let t0 = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            MeshLaplacianSmooth.applyPreset(preset)
            let dir = FileManager.default.temporaryDirectory
            var urls: [URL] = []; var errors: [String] = []
            do {
                // GLB
                ScanLog.export("Đang build GLB...")
                let t1 = Date()
                if let data = ARMeshExporter.buildFacetedGLB(from: session, profile: profile, detailPatches: patches) {
                    let url = dir.appendingPathComponent("scan-\(stamp).glb")
                    try data.write(to: url, options: .atomic)
                    urls.append(url)
                    ScanLog.export("GLB ✓  size=\(data.count / 1024)KB  elapsed=\(String(format:"%.1f",Date().timeIntervalSince(t1)))s")
                } else {
                    errors.append("GLB thất bại")
                    ScanLog.error("GLB build trả về nil")
                }

                // Reference points JSON
                if hasRefPts, let json = ARMeshExporter.buildReferencePointsJSON() {
                    let jsonURL = dir.appendingPathComponent("scan-\(stamp)-markers.json")
                    try json.write(to: jsonURL, options: .atomic)
                    urls.append(jsonURL)
                    ScanLog.export("markers.json ✓  \(ARMeshExporter.referencePointCount) điểm")
                }

                ScanLog.export("Export hoàn tất — \(urls.count) files  tổng=\(String(format:"%.1f",Date().timeIntervalSince(t0)))s  errors=\(errors)")
            } catch {
                ScanLog.error("exportAll ghi file thất bại: \(error)")
                DispatchQueue.main.async {
                    self.isExporting = false
                    self.exportMessage = "Lỗi ghi file: \(error.localizedDescription)"
                }
                return
            }
            DispatchQueue.main.async {
                self.isExporting = false
                if urls.isEmpty {
                    self.exportMessage = "Chưa có mesh – tiếp tục quét."
                } else {
                    self.exportURLs    = urls
                    let errNote        = errors.isEmpty ? "" : " (\(errors.joined(separator: ", ")))"
                    self.exportMessage = "Xuất \(urls.count) file\(errNote)"
                    self.showShare     = true
                }
            }
        }
    }
}

// MARK: - Share sheet

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uvc: UIActivityViewController, context: Context) {}
}
