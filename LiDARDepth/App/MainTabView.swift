/*
 Abstract:
 Root navigation: SCANNER PRO home + custom tab bar.
 Scan session overlays AR view with settings bottom sheet on start.
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
            .allowsHitTesting(!showScanSession)

            if showScanSession {
                LiDARMeshScanContainer(
                    isTabActive: showScanSession,
                    prepareForAR: { cameraManager.pauseForARSession() },
                    onDismiss: { endScanSession() },
                    onOpenProjects: {
                        endScanSession()
                        selectedTab = .projects
                    }
                )
                .padding(.bottom, tabBarClearance)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            ScannerTabBar(selectedTab: $selectedTab)
        }
        .preferredColorScheme(.dark)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showScanSession)
    }

    private var tabBarClearance: CGFloat { 72 }

    private func endScanSession() {
        showScanSession = false
        cameraManager.resumeAfterARSession()
    }
}
