/*
 Abstract:
 SCANNER PRO home screen — dark-mode landing with hero CTA and recent projects.
 */

import SwiftUI

// MARK: - Theme

enum ScannerTheme {
    static let background = Color(red: 0.047, green: 0.047, blue: 0.047)       // #0C0C0C
    static let cardBackground = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let accent = Color(red: 0.69, green: 0.77, blue: 1.0)             // #B0C4FF
    static let accentDeep = Color(red: 0.22, green: 0.35, blue: 0.72)
    static let mutedText = Color.white.opacity(0.55)
    static let divider = Color.white.opacity(0.08)
}

// MARK: - Tab enum

enum ScannerTab: Int, CaseIterable, Identifiable {
    case scan, projects, cloud, settings
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .scan: return "Scan"
        case .projects: return "Projects"
        case .cloud: return "Cloud"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .scan: return "camera.viewfinder"
        case .projects: return "folder.fill"
        case .cloud: return "cloud.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

// MARK: - Models

struct ScanProject: Identifiable {
    let id = UUID()
    let name: String
    let pointCount: String
    let gradient: [Color]
}

private let sampleProjects: [ScanProject] = [
    ScanProject(
        name: "Phòng khách",
        pointCount: "2.4M pts",
        gradient: [Color(red: 0.35, green: 0.55, blue: 0.85), Color(red: 0.15, green: 0.25, blue: 0.45)]
    ),
    ScanProject(
        name: "Ngoại thất",
        pointCount: "1.1M pts",
        gradient: [Color(red: 0.55, green: 0.65, blue: 0.75), Color(red: 0.25, green: 0.35, blue: 0.42)]
    ),
]

// MARK: - Home

struct ScannerHomeView: View {
    var onStartScan: () -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 28) {
                header
                heroSection
                recentProjectsCard
                quickActionCards
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(ScannerTheme.background)
    }

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 6) {
                Text("SCANNER PRO")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .tracking(1.2)
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ScannerTheme.accent)
            }
            Spacer()
            Button {} label: {
                Image(systemName: "person.crop.circle")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .foregroundStyle(.white)
    }

    private var heroSection: some View {
        VStack(spacing: 22) {
            ScannerCubeHeroIcon()
                .padding(.top, 12)

            Text("Biến thế giới thực thành\nmô hình 3D chính xác")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(ScannerTheme.mutedText)
                .lineSpacing(4)

            Button(action: onStartScan) {
                VStack(spacing: 10) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.title2.weight(.medium))
                        .foregroundStyle(ScannerTheme.accentDeep)
                    Text("Bắt đầu Quét mới")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ScannerTheme.accentDeep)
                }
                .frame(width: 148, height: 148)
                .background(
                    Circle()
                        .fill(ScannerTheme.accent)
                        .shadow(color: ScannerTheme.accent.opacity(0.35), radius: 24, y: 8)
                )
            }
            .buttonStyle(.plain)
            .padding(.vertical, 8)
        }
    }

    private var recentProjectsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {} label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.green)
                    Text("Dự án hiện có")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ScannerTheme.mutedText)
                }
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(sampleProjects) { project in
                        ProjectThumbnailCard(project: project)
                    }
                }
            }
        }
        .padding(16)
        .background(ScannerTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(ScannerTheme.divider, lineWidth: 1)
        )
    }

    private var quickActionCards: some View {
        HStack(spacing: 12) {
            QuickActionCard(title: "Cloud", icon: "cloud.fill", tint: ScannerTheme.accent)
            QuickActionCard(title: "Hướng dẫn", icon: "book.fill", tint: .orange)
        }
    }
}

// MARK: - Subviews

private struct ScannerCubeHeroIcon: View {
    var body: some View {
        ZStack {
            ViewfinderBrackets()
                .frame(width: 120, height: 120)
            Image(systemName: "cube.transparent")
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.9))
        }
        .frame(height: 130)
    }
}

private struct ViewfinderBrackets: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let len: CGFloat = 22
            let stroke = Color.white.opacity(0.35)
            Path { p in
                // top-left
                p.move(to: CGPoint(x: 0, y: len))
                p.addLine(to: .zero)
                p.addLine(to: CGPoint(x: len, y: 0))
                // top-right
                p.move(to: CGPoint(x: w - len, y: 0))
                p.addLine(to: CGPoint(x: w, y: 0))
                p.addLine(to: CGPoint(x: w, y: len))
                // bottom-right
                p.move(to: CGPoint(x: w, y: h - len))
                p.addLine(to: CGPoint(x: w, y: h))
                p.addLine(to: CGPoint(x: w - len, y: h))
                // bottom-left
                p.move(to: CGPoint(x: len, y: h))
                p.addLine(to: CGPoint(x: 0, y: h))
                p.addLine(to: CGPoint(x: 0, y: h - len))
            }
            .stroke(stroke, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
    }
}

private struct ProjectThumbnailCard: View {
    let project: ScanProject

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: project.gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                ScanPointCloudPreview()
                    .opacity(0.85)
                Text(project.pointCount)
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.45))
                    .clipShape(Capsule())
                    .padding(8)
            }
            .frame(width: 140, height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(project.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.top, 8)
                .padding(.horizontal, 2)
        }
    }
}

private struct ScanPointCloudPreview: View {
    var body: some View {
        Canvas { context, size in
            let pts: [(CGFloat, CGFloat, CGFloat)] = [
                (0.2, 0.3, 2), (0.35, 0.25, 1.5), (0.5, 0.4, 2.5), (0.65, 0.3, 1.8),
                (0.75, 0.55, 2), (0.4, 0.6, 1.2), (0.55, 0.7, 2.2), (0.3, 0.75, 1.6),
                (0.6, 0.15, 1.4), (0.8, 0.4, 1.9), (0.15, 0.5, 1.3), (0.45, 0.45, 2.8),
            ]
            for (x, y, r) in pts {
                let rect = CGRect(
                    x: x * size.width - r,
                    y: y * size.height - r,
                    width: r * 2,
                    height: r * 2
                )
                context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.55)))
            }
        }
    }
}

private struct QuickActionCard: View {
    let title: String
    let icon: String
    let tint: Color

    var body: some View {
        Button {} label: {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .background(ScannerTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(ScannerTheme.divider, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tab bar

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

// MARK: - Placeholder tabs

struct ScannerProjectsView: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "folder.fill")
                .font(.system(size: 48))
                .foregroundStyle(ScannerTheme.accent.opacity(0.6))
            Text("Dự án")
                .font(.title2.weight(.bold))
            Text("Các bản quét đã lưu sẽ hiển thị tại đây.")
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
}

struct ScannerCloudView: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "cloud.fill")
                .font(.system(size: 48))
                .foregroundStyle(ScannerTheme.accent.opacity(0.6))
            Text("Cloud")
                .font(.title2.weight(.bold))
            Text("Đồng bộ và chia sẻ mô hình 3D lên cloud.")
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
