/*
 Abstract:
 Root navigation: SCANNER PRO home + custom tab bar.
 LiDAR mesh scan opens full-screen from the home CTA.
 AVFoundation and ARKit cannot use the LiDAR camera at the same time — pause depth when scanning.
 */

import SwiftUI

struct MainTabView: View {

    @StateObject private var cameraManager = CameraManager()
    @State private var selectedTab: ScannerTab = .scan
    @State private var showScanSession = false

    var body: some View {
        ZStack(alignment: .bottom) {
            ScannerTheme.background.ignoresSafeArea()

            Group {
                switch selectedTab {
                case .scan:
                    ScannerHomeView(onStartScan: { showScanSession = true })
                case .projects:
                    ScannerProjectsView()
                case .cloud:
                    ScannerCloudView()
                case .settings:
                    ScannerSettingsView(cameraManager: cameraManager)
                }
            }
            .padding(.bottom, tabBarClearance)

            ScannerTabBar(selectedTab: $selectedTab)
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $showScanSession) {
            LiDARMeshScanContainer(
                isTabActive: showScanSession,
                prepareForAR: { cameraManager.pauseForARSession() },
                onDismiss: {
                    showScanSession = false
                    cameraManager.resumeAfterARSession()
                }
            )
        }
    }

    private var tabBarClearance: CGFloat { 72 }
}
