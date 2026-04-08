                                                                               /*
 Abstract:
 Root tabs: original depth sample + LiDAR mesh scan demo.
 AVFoundation and ARKit cannot use the LiDAR camera at the same time — we pause one when switching tabs.
 */

import SwiftUI

struct MainTabView: View {

    @StateObject private var cameraManager = CameraManager()
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            ContentView(manager: cameraManager)
                .tabItem {
                    Label("Depth", systemImage: "camera.metering.matrix")
                }
                .tag(0)

            LiDARMeshScanContainer(
                isTabActive: selectedTab == 1,
                prepareForAR: { cameraManager.pauseForARSession() }
            )
            .tabItem {
                Label("Quét 3D", systemImage: "cube.transparent")
            }
            .tag(1)
        }
        .onChange(of: selectedTab) { newValue in
            if newValue == 0 {
                cameraManager.resumeAfterARSession()
            }
        }
    }
}
