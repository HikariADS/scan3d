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

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        arView.session.delegate = context.coordinator
        context.coordinator.arView = arView
        DispatchQueue.main.async {
            arViewRef = arView
        }

        let config = ARWorldTrackingConfiguration()
        let supportsMesh = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        isMeshSupported = supportsMesh

        if supportsMesh {
            if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
                config.sceneReconstruction = .meshWithClassification
            } else {
                config.sceneReconstruction = .mesh
            }
        }
        arView.environment.lighting.intensityExponent = 1
        if supportsMesh {
            arView.debugOptions.insert(.showSceneUnderstanding)
        }
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, ARSessionDelegate {
        var parent: LiDARMeshScanView
        weak var arView: ARView?

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
                arViewRef: $arViewRef
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

                Text("Quét chậm, đứng cách tường ~1–2 m để mesh dày hơn. Màu lấy từ khung camera tại thời điểm xuất; mở file .ply nếu app xem OBJ không hiện màu.")
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
                        Label("Xuất mesh có màu (.obj + .ply)", systemImage: "square.and.arrow.up")
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
            let dir = FileManager.default.temporaryDirectory
            var urls: [URL] = []
            do {
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
