/*
 Abstract:
 Polycam-style room scan: ARKit world tracking + scene mesh reconstruction, preview, OBJ export.
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

    /// Release AVFoundation capture so ARSession can open the camera (must run before `session.run`).
    var prepareForAR: () -> Void
    /// When false, AR session is paused so the Depth tab can use the camera again.
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

        // Dùng `.mesh` thuần — không dùng `meshWithClassification` làm mặc định vì debug ARKit
        // sẽ tô màu theo loại bề mặt (xanh/lá/vàng) trông rất khác ảnh thật / Polycam.
        if supportsMesh {
            config.sceneReconstruction = .mesh
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
        } else {
            if context.coordinator.didRunInitialSession, !context.coordinator.pausedForTabSwitch {
                uiView.session.pause()
                context.coordinator.pausedForTabSwitch = true
            }
        }
    }

    final class Coordinator: NSObject, ARSessionDelegate {
        var parent: LiDARMeshScanView
        weak var arView: ARView?
        var trackingConfiguration: ARWorldTrackingConfiguration?
        var didRunInitialSession = false
        var pausedForTabSwitch = false

        init(parent: LiDARMeshScanView) {
            self.parent = parent
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            let stats = ARMeshExporter.meshStatistics(from: session)
            DispatchQueue.main.async {
                self.parent.meshAnchorCount = stats.anchors
                self.parent.triangleCount = stats.triangles
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

    var body: some View {
        ZStack(alignment: .bottom) {
            LiDARMeshScanView(
                meshAnchorCount: $meshAnchorCount,
                triangleCount: $triangleCount,
                isMeshSupported: $isMeshSupported,
                arViewRef: $arViewRef,
                prepareForAR: prepareForAR,
                isTabActive: isTabActive
            )
            .ignoresSafeArea()
            .onDisappear {
                arViewRef = nil
            }

            VStack(spacing: 12) {
                if !isMeshSupported {
                    Text("Thiết bị này không hỗ trợ scene mesh (cần LiDAR + iOS đủ mới).")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .padding(8)
                        .background(.ultraThinMaterial)
                        .cornerRadius(10)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mesh anchors: \(meshAnchorCount)")
                        Text("Tam giác: \(triangleCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .font(.subheadline.monospacedDigit())
                .padding(12)
                .background(.ultraThinMaterial)
                .cornerRadius(12)

                Text("Ưu tiên mở file .glb trong Xcode hoặc Blender — có màu đỉnh (COLOR_0) và mặt tam giác tách (nhìn rõ vật hơn). .obj trong Xcode thường chỉ xám.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    exportMesh()
                } label: {
                    if isExporting {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Xuất .glb + .obj + .ply", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(meshAnchorCount == 0 || isExporting)

                if let exportMessage {
                    Text(exportMessage)
                        .font(.caption)
                        .foregroundStyle(exportMessage.contains("Lỗi") ? .red : .primary)
                }
            }
            .padding()
        }
        .sheet(isPresented: $showShare) {
            if !exportURLs.isEmpty {
                ShareSheet(items: exportURLs)
            }
        }
    }

    private func exportMesh() {
        exportMessage = nil
        guard let view = arViewRef else {
            exportMessage = "Chưa sẵn sàng camera AR."
            return
        }
        isExporting = true
        let session = view.session
        let stamp = Int(Date().timeIntervalSince1970)
        DispatchQueue.global(qos: .userInitiated).async {
            let objText = ARMeshExporter.buildColoredOBJString(from: session)
            let plyText = ARMeshExporter.buildColoredPLYString(from: session)
            let glbData = ARMeshExporter.buildFacetedGLB(from: session)
            let dir = FileManager.default.temporaryDirectory
            var urls: [URL] = []
            do {
                if let glbData {
                    let u = dir.appendingPathComponent("LiDARDepth-scan-\(stamp).glb")
                    try glbData.write(to: u, options: .atomic)
                    urls.append(u)
                }
                if let objText {
                    let u = dir.appendingPathComponent("LiDARDepth-scan-\(stamp).obj")
                    try objText.write(to: u, atomically: true, encoding: .utf8)
                    urls.append(u)
                }
                if let plyText {
                    let u = dir.appendingPathComponent("LiDARDepth-scan-\(stamp).ply")
                    try plyText.write(to: u, atomically: true, encoding: .utf8)
                    urls.append(u)
                }
                DispatchQueue.main.async {
                    isExporting = false
                    guard !urls.isEmpty else {
                        exportMessage = "Chưa có mesh — hãy quét thêm vài giây."
                        return
                    }
                    exportURLs = urls
                    exportMessage = "Đã tạo \(urls.count) file — chia sẻ hoặc lưu Files."
                    showShare = true
                }
            } catch {
                DispatchQueue.main.async {
                    isExporting = false
                    exportMessage = "Lỗi ghi file: \(error.localizedDescription)"
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
