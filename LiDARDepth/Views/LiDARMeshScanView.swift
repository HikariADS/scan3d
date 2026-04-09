/*
 Abstract:
 Product-oriented room scan workflow:
 1. Room Base
 2. Detail Patch capture
 3. Fusion Export
 */

import SwiftUI
import UIKit
import RealityKit
import ARKit

struct LiDARMeshScanView: UIViewRepresentable {

    @Binding var meshAnchorCount: Int
    @Binding var triangleCount: Int
    @Binding var isMeshSupported: Bool
    @Binding var arViewRef: ARView?
    @Binding var scanProgress: Double
    @Binding var scanStageText: String
    @Binding var isMovingTooFast: Bool
    @Binding var exportSubject: ARMeshExporter.ExportSubject

    var prepareForAR: () -> Void
    var isTabActive: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> ARView {
        prepareForAR()

        let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        arView.session.delegate = context.coordinator
        context.coordinator.arView = arView

        let config = ARWorldTrackingConfiguration()
        let supportsMesh = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        isMeshSupported = supportsMesh

        if supportsMesh {
            config.sceneReconstruction = .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        context.coordinator.trackingConfiguration = config

        arView.environment.lighting.intensityExponent = 1
        if supportsMesh {
            arView.debugOptions.insert(.showSceneUnderstanding)
        }

        DispatchQueue.main.async {
            arViewRef = arView
        }

        if isTabActive {
            arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
            context.coordinator.didRunInitialSession = true
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
            } else if !context.coordinator.didRunInitialSession {
                uiView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
                context.coordinator.didRunInitialSession = true
            }
        } else if context.coordinator.didRunInitialSession, !context.coordinator.pausedForTabSwitch {
            uiView.session.pause()
            context.coordinator.pausedForTabSwitch = true
        }
    }

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

        init(parent: LiDARMeshScanView) {
            self.parent = parent
        }

        func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
            mergeMeshAnchors(from: anchors)
        }

        func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
            mergeMeshAnchors(from: anchors)
        }

        func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
            var changed = false
            for anchor in anchors where meshAnchorsByID.removeValue(forKey: anchor.identifier) != nil {
                changed = true
            }
            if changed {
                recomputeAndPublishStats()
            }
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            let camPos = SIMD3<Float>(
                frame.camera.transform.columns.3.x,
                frame.camera.transform.columns.3.y,
                frame.camera.transform.columns.3.z
            )

            let recordDistanceThreshold: Float
            switch parent.exportSubject {
            case .room: recordDistanceThreshold = 0.03
            case .nearbyObject: recordDistanceThreshold = 0.008
            case .ultraDetailObject: recordDistanceThreshold = 0.004
            }

            if let last = lastRecordedCamPos {
                if simd_length(camPos - last) >= recordDistanceThreshold {
                    ARMeshExporter.recordFrameForColorFusion(frame)
                    lastRecordedCamPos = camPos
                }
            } else {
                ARMeshExporter.recordFrameForColorFusion(frame)
                lastRecordedCamPos = camPos
            }

            guard frame.timestamp - lastUIUpdateTime >= uiUpdateInterval else { return }
            lastUIUpdateTime = frame.timestamp

            var speed: Float = 0
            if let prevT = lastSpeedTimestamp, let prevP = lastSpeedCamPos {
                let dt = max(Float(frame.timestamp - prevT), 1e-3)
                speed = simd_length(camPos - prevP) / dt
            }
            lastSpeedTimestamp = frame.timestamp
            lastSpeedCamPos = camPos

            let tooFast: Bool
            let triangleTarget: Double
            switch parent.exportSubject {
            case .room:
                tooFast = speed > 0.45
                triangleTarget = 80_000
            case .nearbyObject:
                tooFast = speed > 0.18
                triangleTarget = 45_000
            case .ultraDetailObject:
                tooFast = speed > 0.10
                triangleTarget = 65_000
            }

            let triangles = cachedTriangleCount
            let densityProgress = min(Double(triangles) / triangleTarget, 1.0)
            let stabilityPenalty: Double = tooFast ? 0.15 : 0
            let finalProgress = max(0, min(1, densityProgress - stabilityPenalty))

            let stage: String
            if triangles == 0 {
                stage = "Đang khởi động mesh..."
            } else if finalProgress < 0.25 {
                switch parent.exportSubject {
                case .room: stage = "Bước 1/4: Quét khung tổng thể"
                case .nearbyObject: stage = "Bước 1/4: Tiến gần vật thể"
                case .ultraDetailObject: stage = "Bước 1/4: Khóa vật ở giữa khung"
                }
            } else if finalProgress < 0.5 {
                switch parent.exportSubject {
                case .room: stage = "Bước 2/4: Bổ sung góc khuất"
                case .nearbyObject: stage = "Bước 2/4: Quét các mép và gờ"
                case .ultraDetailObject: stage = "Bước 2/4: Quét mép và cạnh thật chậm"
                }
            } else if finalProgress < 0.8 {
                switch parent.exportSubject {
                case .room: stage = "Bước 3/4: Tăng chi tiết bề mặt"
                case .nearbyObject: stage = "Bước 3/4: Giữ khoảng cách gần, quét chậm"
                case .ultraDetailObject: stage = "Bước 3/4: Tích lũy texture sắc nét"
                }
            } else {
                switch parent.exportSubject {
                case .room: stage = "Bước 4/4: Gần hoàn tất - quét chậm thêm"
                case .nearbyObject: stage = "Bước 4/4: Khóa chi tiết vật gần"
                case .ultraDetailObject: stage = "Bước 4/4: Hoàn thiện cận cảnh"
                }
            }

            let ac = cachedAnchorCount
            let tc = cachedTriangleCount
            DispatchQueue.main.async {
                self.parent.meshAnchorCount = ac
                self.parent.triangleCount = tc
                self.parent.isMovingTooFast = tooFast
                self.parent.scanProgress = finalProgress
                self.parent.scanStageText = stage
            }
        }

        private func mergeMeshAnchors(from anchors: [ARAnchor]) {
            var changed = false
            for anchor in anchors {
                guard let mesh = anchor as? ARMeshAnchor else { continue }
                meshAnchorsByID[mesh.identifier] = mesh
                changed = true
            }
            if changed {
                recomputeAndPublishStats()
            }
        }

        private func recomputeAndPublishStats() {
            var total = 0
            for mesh in meshAnchorsByID.values {
                total += mesh.geometry.faces.count
            }
            cachedTriangleCount = total
            cachedAnchorCount = meshAnchorsByID.count

            let ac = cachedAnchorCount
            let tc = cachedTriangleCount
            DispatchQueue.main.async {
                self.parent.meshAnchorCount = ac
                self.parent.triangleCount = tc
            }
        }
    }
}

private enum CaptureWorkflowMode: String, CaseIterable, Identifiable {
    case roomBase
    case detailPatch
    case fusionExport

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .roomBase: return "Room Base"
        case .detailPatch: return "Detail Patch"
        case .fusionExport: return "Fusion Export"
        }
    }

    var exportSubject: ARMeshExporter.ExportSubject {
        switch self {
        case .roomBase: return .room
        case .detailPatch: return .ultraDetailObject
        case .fusionExport: return .room
        }
    }
}

struct LiDARMeshScanContainer: View {

    var isTabActive: Bool
    var prepareForAR: () -> Void

    @State private var meshAnchorCount = 0
    @State private var triangleCount = 0
    @State private var isMeshSupported = true
    @State private var exportMessage: String?
    @State private var showShare = false
    @State private var exportURLs: [URL] = []
    @State private var isExporting = false
    @State private var arViewRef: ARView?
    @State private var workflowMode: CaptureWorkflowMode = .roomBase
    @State private var exportSubject: ARMeshExporter.ExportSubject = .room
    @State private var smoothingPreset: MeshLaplacianSmooth.QualityPreset = .precise
    @State private var detailPatches: [ARMeshExporter.DetailPatch] = []
    @State private var scanProgress: Double = 0
    @State private var scanStageText: String = "Đang khởi động mesh..."
    @State private var isMovingTooFast: Bool = false

    private var hasData: Bool { triangleCount > 0 || meshAnchorCount > 0 }

    var body: some View {
        ZStack(alignment: .bottom) {
            LiDARMeshScanView(
                meshAnchorCount: $meshAnchorCount,
                triangleCount: $triangleCount,
                isMeshSupported: $isMeshSupported,
                arViewRef: $arViewRef,
                scanProgress: $scanProgress,
                scanStageText: $scanStageText,
                isMovingTooFast: $isMovingTooFast,
                exportSubject: $exportSubject,
                prepareForAR: prepareForAR,
                isTabActive: isTabActive
            )
            .ignoresSafeArea()
            .onDisappear { arViewRef = nil }

            VStack(spacing: 10) {
                if !isMeshSupported {
                    Text("Thiết bị không hỗ trợ LiDAR mesh.")
                        .font(.caption)
                        .padding(8)
                        .background(.ultraThinMaterial)
                        .cornerRadius(10)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Anchors: \(meshAnchorCount) · Tam giác: \(triangleCount)")
                                .font(.caption.monospacedDigit())
                        }
                        Spacer()
                        Text("\(Int(scanProgress * 100))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: scanProgress, total: 1)
                        .tint(isMovingTooFast ? .orange : .green)
                    Text(scanStageText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.ultraThinMaterial)
                .cornerRadius(12)

                Picker("Quy trình", selection: $workflowMode) {
                    ForEach(CaptureWorkflowMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: workflowMode) { newValue in
                    exportSubject = newValue.exportSubject
                }

                Text(workflowDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if isMovingTooFast {
                    Text(speedWarning)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .padding(6)
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                }

                Picker("Độ mịn", selection: $smoothingPreset) {
                    ForEach(MeshLaplacianSmooth.QualityPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.segmented)

                if workflowMode == .detailPatch {
                    HStack(spacing: 8) {
                        Button(action: markDetailPatch) {
                            Label("Đánh dấu vùng chi tiết", systemImage: "plus.viewfinder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Xóa tất cả") {
                            detailPatches.removeAll()
                        }
                        .buttonStyle(.bordered)
                        .disabled(detailPatches.isEmpty)
                    }
                }

                if !detailPatches.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Vùng chi tiết đã đánh dấu: \(detailPatches.count)")
                            .font(.caption.bold())
                        ForEach(Array(detailPatches.enumerated()), id: \.element.id) { idx, patch in
                            HStack {
                                Text("\(idx + 1). \(patch.label)")
                                    .font(.caption2)
                                Spacer()
                                Text("r=\(String(format: "%.2f", patch.radius))m")
                                    .font(.caption2.monospacedDigit())
                                Button {
                                    detailPatches.removeAll { $0.id == patch.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.ultraThinMaterial)
                    .cornerRadius(10)
                }

                detailGuidanceCard

                Button { exportAll() } label: {
                    if isExporting {
                        HStack(spacing: 8) {
                            ProgressView().tint(.white)
                            Text("Đang xuất...").bold()
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Label("Fusion Export: GLB + OBJ + JPG", systemImage: "square.and.arrow.up.fill")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!hasData || isExporting)

                if let exportMessage {
                    Text(exportMessage)
                        .font(.caption2)
                        .foregroundStyle(exportMessage.hasPrefix("Lỗi") ? .red : .secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $showShare) {
            if !exportURLs.isEmpty {
                ShareSheet(items: exportURLs)
            }
        }
        .onAppear {
            exportSubject = workflowMode.exportSubject
        }
    }

    private var workflowDescription: String {
        switch workflowMode {
        case .roomBase:
            return "Room Base: quét toàn phòng để lấy hình khối, khoảng cách và bố cục nền."
        case .detailPatch:
            return "Detail Patch: chĩa giữa màn hình vào vùng quan trọng rồi bấm đánh dấu để tăng texture/chi tiết khi export."
        case .fusionExport:
            return "Fusion Export: giữ full phòng nhưng vá mạnh texture và màu cho các vùng đã đánh dấu."
        }
    }

    private var speedWarning: String {
        switch exportSubject {
        case .room:
            return "Di chuyển hơi nhanh - quét chậm để giữ màu và hình khối tốt hơn."
        case .nearbyObject:
            return "Quét vật gần cần di chuyển rất chậm để giữ đúng mép, chiều sâu và màu."
        case .ultraDetailObject:
            return "Cận cảnh siêu chi tiết yêu cầu gần như đứng yên giữa các khung. Hãy quét cực chậm."
        }
    }

    @ViewBuilder
    private var detailGuidanceCard: some View {
        if workflowMode != .roomBase {
            VStack(alignment: .leading, spacing: 4) {
                Text(workflowMode == .detailPatch ? "Hướng dẫn đánh dấu patch" : "Hướng dẫn fusion export")
                    .font(.caption.bold())
                Text("1. Giữ vùng cần tăng chi tiết ở giữa khung hình.")
                    .font(.caption2)
                Text("2. Với patch quan trọng, giữ khoảng cách khoảng 20-45cm và quét cực chậm.")
                    .font(.caption2)
                Text("3. Ưu tiên mép, bàn phím, màn hình, mặt bàn và vật thể chính.")
                    .font(.caption2)
                Text("4. Export cuối sẽ giữ full phòng nhưng vá texture mạnh hơn trong các patch đã đánh dấu.")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.ultraThinMaterial)
            .cornerRadius(10)
        }
    }

    private func markDetailPatch() {
        guard let view = arViewRef else {
            exportMessage = "ARView chưa sẵn sàng để đánh dấu patch."
            return
        }

        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let results = view.raycast(from: center, allowing: .estimatedPlane, alignment: .any)

        let patchCenter: SIMD3<Float>
        if let first = results.first {
            patchCenter = SIMD3<Float>(first.worldTransform.columns.3.x, first.worldTransform.columns.3.y, first.worldTransform.columns.3.z)
        } else if let frame = view.session.currentFrame {
            let t = frame.camera.transform
            let camPos = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            let forward = -SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)
            patchCenter = camPos + simd_normalize(forward) * 0.55
        } else {
            exportMessage = "Không xác định được vùng giữa khung hình để tạo patch."
            return
        }

        let index = detailPatches.count + 1
        let patch = ARMeshExporter.DetailPatch(
            center: patchCenter,
            radius: workflowMode == .detailPatch ? 0.65 : 0.75,
            label: "Patch \(index)"
        )
        detailPatches.append(patch)
        exportMessage = "Đã thêm \(patch.label). Hãy quét chậm quanh vùng này để tăng chi tiết."
    }

    private func exportAll() {
        exportMessage = nil
        guard let view = arViewRef else {
            exportMessage = "Chưa sẵn sàng camera AR."
            return
        }
        isExporting = true
        exportMessage = "Đang xuất..."
        let session = view.session
        let stamp = Int(Date().timeIntervalSince1970)
        let preset = smoothingPreset
        let baseProfile = ARMeshExporter.ExportProfile(subject: .room)
        let patches = detailPatches

        DispatchQueue.global(qos: .userInitiated).async {
            MeshLaplacianSmooth.applyPreset(preset)
            let dir = FileManager.default.temporaryDirectory
            var urls: [URL] = []
            var errors: [String] = []

            do {
                if let glbData = ARMeshExporter.buildFacetedGLB(from: session, profile: baseProfile, detailPatches: patches) {
                    let glbURL = dir.appendingPathComponent("scan-\(stamp).glb")
                    try glbData.write(to: glbURL, options: .atomic)
                    urls.append(glbURL)
                } else {
                    errors.append("GLB thất bại")
                }

                let texName = "scan-\(stamp).jpg"
                if let bundle = ARMeshExporter.buildTexturedOBJBundle(
                    from: session,
                    textureFilename: texName,
                    profile: baseProfile,
                    detailPatches: patches
                ) {
                    let objURL = dir.appendingPathComponent("scan-\(stamp).obj")
                    let mtlURL = dir.appendingPathComponent("scan-\(stamp).mtl")
                    let texURL = dir.appendingPathComponent(texName)
                    try bundle.obj.write(to: objURL, atomically: true, encoding: .utf8)
                    try bundle.mtl.write(to: mtlURL, atomically: true, encoding: .utf8)
                    try bundle.textureJPEG.write(to: texURL, options: .atomic)
                    urls.append(contentsOf: [objURL, mtlURL, texURL])
                } else {
                    errors.append("OBJ thất bại")
                }
            } catch {
                DispatchQueue.main.async {
                    self.isExporting = false
                    self.exportMessage = "Lỗi ghi file: \(error.localizedDescription)"
                }
                return
            }

            DispatchQueue.main.async {
                self.isExporting = false
                if urls.isEmpty {
                    self.exportMessage = "Chưa có mesh - tiếp tục quét thêm."
                } else {
                    self.exportURLs = urls
                    let note = errors.isEmpty ? "" : " (\(errors.joined(separator: ", ")))"
                    self.exportMessage = "Đã tạo \(urls.count) file\(note) - full phòng + vá chi tiết cho \(patches.count) patch."
                    self.showShare = true
                }
            }
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
