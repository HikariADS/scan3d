/*
 Abstract:
 Shared list UI for saved scans (Projects + Cloud local storage).
 */

import SwiftUI

struct LocalScanLibraryView: View {
    @ObservedObject var library: ScanLibrary
    var showsCloudBanner: Bool

    @State private var shareURLs: [URL] = []
    @State private var showShare = false

    var body: some View {
        VStack(spacing: 0) {
            if showsCloudBanner {
                cloudBanner
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
            }

            if library.records.isEmpty {
                emptyState
            } else {
                List {
                    Section(header: Text("Trên thiết bị (\(library.records.count))")) {
                        ForEach(library.records) { record in
                            scanRow(record)
                        }
                        .onDelete { indexSet in
                            indexSet.map { library.records[$0] }.forEach { library.delete($0) }
                        }
                    }

                    Section {
                        HStack {
                            Text("Dung lượng")
                            Spacer()
                            Text(library.formattedSize(library.totalBytesOnDevice))
                                .foregroundColor(.secondary)
                        }
                        Text("Thư mục: Documents/ScanPro/Library")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .background(ScannerTheme.background)
        .sheet(isPresented: $showShare) {
            if !shareURLs.isEmpty {
                ShareSheet(items: shareURLs)
            }
        }
    }

    private var cloudBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "internaldrive")
                .font(.title3)
                .foregroundColor(ScannerTheme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("Lưu trữ trên máy")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                Text("File GLB được lưu cục bộ sau mỗi lần xuất. Cloud sẽ đồng bộ từ thư mục này sau.")
                    .font(.caption)
                    .foregroundColor(ScannerTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(ScannerTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 44))
                .foregroundStyle(ScannerTheme.accent.opacity(0.5))
            Text("Chưa có bản quét")
                .font(.title3.weight(.bold))
            Text("Hoàn tất quét và bấm Xuất GLB — file sẽ tự lưu vào máy.")
                .font(.subheadline)
                .foregroundStyle(ScannerTheme.mutedText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scanRow(_ record: ScanRecord) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [ScannerTheme.accent.opacity(0.5), ScannerTheme.accentDeep.opacity(0.8)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 52, height: 52)
                .overlay(
                    Image(systemName: record.usedTexturedGLB ? "cube.fill" : "cube.transparent")
                        .foregroundColor(.white.opacity(0.9))
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(record.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(library.pointCountLabel(record.triangleCount))
                    Text("•")
                    Text(library.formattedSize(record.fileSizeBytes))
                    if record.usedTexturedGLB {
                        Text("•")
                        Text("Texture")
                            .foregroundColor(ScannerTheme.accent)
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            Button {
                shareURLs = library.allFileURLs(for: record)
                showShare = true
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.body)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uvc: UIActivityViewController, context: Context) {}
}
