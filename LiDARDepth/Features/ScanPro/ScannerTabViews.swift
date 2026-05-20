/*
 Abstract:
 Tab bar and placeholder screens for ScanPro navigation.
 */

import SwiftUI

struct ScannerTabBar: View {
    @Binding var selectedTab: ScannerTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ScannerTab.allCases) { tab in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.body.weight(selectedTab == tab ? .semibold : .regular))
                        Text(tab.title)
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(selectedTab == tab ? ScannerTheme.accentDeep : ScannerTheme.mutedText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        Group {
                            if selectedTab == tab {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(ScannerTheme.accent.opacity(0.55))
                            }
                        }
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            ScannerTheme.cardBackground
                .overlay(ScannerTheme.divider.frame(height: 1), alignment: .top)
        )
    }
}

struct ScannerProjectsView: View {
    var body: some View {
        placeholderScreen(
            icon: "folder.fill",
            title: "Dự án",
            subtitle: "Các bản quét đã lưu sẽ hiển thị tại đây."
        )
    }
}

struct ScannerCloudView: View {
    var body: some View {
        placeholderScreen(
            icon: "cloud.fill",
            title: "Cloud",
            subtitle: "Đồng bộ và chia sẻ mô hình 3D lên cloud."
        )
    }
}

struct ScannerSettingsView: View {
    @ObservedObject var cameraManager: CameraManager
    @State private var showDepthLab = false

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Công cụ")) {
                    Button {
                        showDepthLab = true
                    } label: {
                        Label("Depth Lab", systemImage: "camera.metering.matrix")
                    }
                }
                Section(header: Text("Thông tin")) {
                    settingsRow(title: "Phiên bản", value: "1.0")
                    settingsRow(title: "Thiết bị", value: UIDevice.current.model)
                }
            }
            .listStyle(.insetGrouped)
            .background(ScannerTheme.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $showDepthLab) {
                NavigationView {
                    ContentView(manager: cameraManager)
                        .navigationTitle("Depth Lab")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Xong") { showDepthLab = false }
                            }
                        }
                }
            }
        }
        .navigationViewStyle(.stack)
        .background(ScannerTheme.background)
    }

    private func settingsRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
        }
    }
}

private func placeholderScreen(icon: String, title: String, subtitle: String) -> some View {
    VStack(spacing: 16) {
        Spacer()
        Image(systemName: icon)
            .font(.system(size: 48))
            .foregroundStyle(ScannerTheme.accent.opacity(0.6))
        Text(title)
            .font(.title2.weight(.bold))
        Text(subtitle)
            .font(.subheadline)
            .foregroundStyle(ScannerTheme.mutedText)
            .multilineTextAlignment(.center)
        Spacer()
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(ScannerTheme.background)
    .foregroundStyle(.white)
}
