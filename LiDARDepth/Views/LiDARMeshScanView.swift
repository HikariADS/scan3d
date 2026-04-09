/*
 Abstract:
 Polycam-style room scan: ARKit world tracking + scene mesh reconstruction, preview, export.
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

            let recordDistanceThreshold: Float = parent.exportSubject == .nearbyObject ? 0.008 : 0.03
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

            let tooFast = speed > (parent.exportSubject == .nearbyObject ? 0.18 : 0.45)
            let triangles = cachedTriangleCount
            let triangleTarget = parent.exportSubject == .nearbyObject ? 45_000.0 : 80_000.0
            let densityProgress = min(Double(triangles) / triangleTarget, 1.0)
            let stabilityPenalty: Double = tooFast ? 0.15 : 0
            let finalProgress = max(0, min(1, densityProgress - stabilityPenalty))

            let stage: String
            if triangles == 0 {
                stage = "Đang khởi động mesh..."
            } else if finalProgress < 0.25 {
                stage = parent.exportSubject == .nearbyObject ? "Bước 1/4: Tiến gần vật thể" : "Bước 1/4: Quét khung tổng thể"
            } else if finalProgress < 0.5 {
                stage = parent.exportSubject == .nearbyObject ? "Bước 2/4: Quét các mép và gờ" : "Bước 2/4: Bổ sung góc khuất"
            } else if finalProgress < 0.8 {
                stage = parent.exportSubject == .nearbyObject ? "Bước 3/4: Giữ khoảng cách gần, quét chậm" : "Bước 3/4: Tăng chi tiết bề mặt"
            } else {
                stage = parent.exportSubject == .nearbyObject ? "Bước 4/4: Khóa chi tiết vật gần" : "Bước 4/4: Gần hoàn tất - quét chậm thêm"
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
    @State private var smoothingPreset: MeshLaplacianSmooth.QualityPreset = .precise
    @State private var exportSubject: ARMeshExporter.ExportSubject = .nearbyObject
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

                if isMovingTooFast {
                    Text(exportSubject == .nearbyObject
                         ? "Quét vật gần cần di chuyển rất chậm để giữ đúng mép, chiều sâu và màu."
                         : "Di chuyển hơi nhanh - quét chậm để giữ màu và hình khối tốt hơn.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .padding(6)
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                }

                Picker("Chế độ", selection: $exportSubject) {
                    ForEach(ARMeshExporter.ExportSubject.allCases) { subject in
                        Text(subject.displayName).tag(subject)
                    }
                }
                .pickerStyle(.segmented)

                Text(exportSubject == .nearbyObject
                     ? "Vật gần: lọc nền xa, siết chiều sâu, ưu tiên laptop, màn hình, bàn."
                     : "Không gian: giữ phạm vi rộng hơn, phù hợp quét phòng và bố cục tổng thể.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if exportSubject == .nearbyObject {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hướng dẫn quét vật gần")
                            .font(.caption.bold())
                        Text("1. Giữ vật ở giữa khung hình, cách khoảng 25-70cm.")
                            .font(.caption2)
                        Text("2. Lia rất chậm, ưu tiên quét mép, góc và mặt trước.")
                            .font(.caption2)
                        Text("3. Tránh để vật sát viền ảnh hoặc bị phản chiếu quá mạnh.")
                            .font(.caption2)
                        Text("4. Nếu log còn out of bounds cao, hãy giữ vật lớn hơn trong khung.")
                            .font(.caption2)
                        Text("5. Nếu depth mismatch cao, hãy giảm lia nhanh và bớt góc xiên.")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.ultraThinMaterial)
                    .cornerRadius(10)
                }

                Picker("Độ mịn", selection: $smoothingPreset) {
                    ForEach(MeshLaplacianSmooth.QualityPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.segmented)

                Button { exportAll() } label: {
                    if isExporting {
                        HStack(spacing: 8) {
                            ProgressView().tint(.white)
                            Text("Đang xuất...").bold()
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Label("Xuất GLB + OBJ + JPG", systemImage: "square.and.arrow.up.fill")
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
        let profile = ARMeshExporter.ExportProfile(subject: exportSubject)

        DispatchQueue.global(qos: .userInitiated).async {
            MeshLaplacianSmooth.applyPreset(preset)
            let dir = FileManager.default.temporaryDirectory
            var urls: [URL] = []
            var errors: [String] = []

            do {
                if let glbData = ARMeshExporter.buildFacetedGLB(from: session, profile: profile) {
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
                    profile: profile
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
                    self.exportMessage = "Đã tạo \(urls.count) file\(note) - ưu tiên mesh chính xác và texture tốt hơn."
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
