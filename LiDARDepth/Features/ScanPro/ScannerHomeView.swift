/*
 Abstract:
 SCANNER PRO home screen — dark-mode landing with hero CTA and recent projects.
 */

import SwiftUI

private let projectGradients: [[Color]] = [
    [Color(red: 0.35, green: 0.55, blue: 0.85), Color(red: 0.15, green: 0.25, blue: 0.45)],
    [Color(red: 0.55, green: 0.65, blue: 0.75), Color(red: 0.25, green: 0.35, blue: 0.42)],
    [Color(red: 0.45, green: 0.72, blue: 0.58), Color(red: 0.18, green: 0.38, blue: 0.32)],
    [Color(red: 0.72, green: 0.48, blue: 0.55), Color(red: 0.38, green: 0.22, blue: 0.28)],
]

struct ScannerHomeView: View {
    @ObservedObject private var library = ScanLibrary.shared
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
        .onAppear { library.reload() }
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

            if library.records.isEmpty {
                Text("Chưa có bản quét — xuất GLB để lưu vào máy.")
                    .font(.caption)
                    .foregroundStyle(ScannerTheme.mutedText)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(library.records.prefix(6).enumerated()), id: \.element.id) { idx, record in
                            ProjectThumbnailCard(
                                record: record,
                                gradient: projectGradients[idx % projectGradients.count],
                                library: library
                            )
                        }
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
                p.move(to: CGPoint(x: 0, y: len))
                p.addLine(to: .zero)
                p.addLine(to: CGPoint(x: len, y: 0))
                p.move(to: CGPoint(x: w - len, y: 0))
                p.addLine(to: CGPoint(x: w, y: 0))
                p.addLine(to: CGPoint(x: w, y: len))
                p.move(to: CGPoint(x: w, y: h - len))
                p.addLine(to: CGPoint(x: w, y: h))
                p.addLine(to: CGPoint(x: w - len, y: h))
                p.move(to: CGPoint(x: len, y: h))
                p.addLine(to: CGPoint(x: 0, y: h))
                p.addLine(to: CGPoint(x: 0, y: h - len))
            }
            .stroke(stroke, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
    }
}

private struct ProjectThumbnailCard: View {
    let record: ScanRecord
    let gradient: [Color]
    @ObservedObject var library: ScanLibrary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                ScanPointCloudPreview()
                    .opacity(0.85)
                HStack(spacing: 4) {
                    Text(library.pointCountLabel(record.triangleCount))
                    if record.usedTexturedGLB {
                        Image(systemName: "photo.fill")
                            .font(.caption2)
                    }
                }
                .font(.caption2.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.45))
                .clipShape(Capsule())
                .padding(8)
            }
            .frame(width: 140, height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(record.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.top, 8)
                .padding(.horizontal, 2)
                .lineLimit(1)
        }
        .frame(width: 140)
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
