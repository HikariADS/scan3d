/*
 Abstract:
 Dark-mode bottom sheet for pre-scan / in-scan configuration (ScanPro style).
 */

import SwiftUI

struct ScanSettingsBottomSheet: View {
    @Binding var smoothingPreset: MeshLaplacianSmooth.QualityPreset
    @Binding var detailPatches: [ARMeshExporter.DetailPatch]

    var onAddPatch: () -> Void
    var onDeletePatch: (UUID) -> Void
    var onClose: () -> Void
    var onExport: () -> Void

    static let maxPatches = 5

    private let sheetBackground = Color(red: 0.14, green: 0.14, blue: 0.15)
    private let cardBackground = Color(red: 0.20, green: 0.20, blue: 0.22)
    private let primaryBlue = Color(red: 0.0, green: 0.48, blue: 1.0)

    var body: some View {
        VStack(spacing: 0) {
            grabHandle
            header
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    meshSmoothingSection
                    detailPatchesSection
                    addPatchButton
                    bottomInfoGrid
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
        }
        .background(sheetBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 24, y: -8)
    }

    private var grabHandle: some View {
        Capsule()
            .fill(Color.white.opacity(0.22))
            .frame(width: 40, height: 4)
            .padding(.top, 10)
            .padding(.bottom, 6)
    }

    private var header: some View {
        HStack {
            Text("Cài đặt quét")
                .font(.title3.weight(.bold))
                .foregroundColor(.white)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    private var meshSmoothingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel(icon: "slider.horizontal.3", title: "LÀM MỊN MESH")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(MeshLaplacianSmooth.QualityPreset.allCases) { preset in
                        smoothingPill(preset)
                    }
                }
            }
        }
    }

    private func smoothingPill(_ preset: MeshLaplacianSmooth.QualityPreset) -> some View {
        let selected = smoothingPreset == preset
        return Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                smoothingPreset = preset
            }
        } label: {
            Text(shortSmoothingName(preset))
                .font(.caption.weight(.semibold))
                .foregroundColor(selected ? .black : .white.opacity(0.55))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(selected ? Color.white : Color.white.opacity(0.06))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func shortSmoothingName(_ preset: MeshLaplacianSmooth.QualityPreset) -> String {
        switch preset {
        case .precise: return "Chính xác"
        case .low: return "Taubin"
        case .medium: return "Bilateral"
        case .high: return "Bilateral+"
        }
    }

    private var detailPatchesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionLabel(icon: "square.3.layers.3d.down.right", title: "VÙNG CHI TIẾT")
                Spacer()
                Text("\(detailPatches.count)/\(Self.maxPatches) vùng")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.white.opacity(0.45))
            }

            if detailPatches.isEmpty {
                Text("Chưa có vùng nào. Chĩa tâm màn hình vào khu vực cần chi tiết rồi bấm nút bên dưới.")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(detailPatches.enumerated()), id: \.element.id) { index, patch in
                        patchCard(patch: patch, index: index)
                    }
                }
            }
        }
    }

    private func patchCard(patch: ARMeshExporter.DetailPatch, index: Int) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(index == 0 ? primaryBlue.opacity(0.85) : Color.white.opacity(0.12))
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: index == 0 ? "scope" : "viewfinder")
                        .font(.body.weight(.medium))
                        .foregroundColor(.white)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(patch.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                Text("Bán kính: \(String(format: "%.2f", patch.radius))m")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.45))
            }

            Spacer()

            Button { onDeletePatch(patch.id) } label: {
                Image(systemName: "trash")
                    .font(.body)
                    .foregroundColor(.white.opacity(0.35))
            }
        }
        .padding(12)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var addPatchButton: some View {
        Button(action: onAddPatch) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.body.weight(.semibold))
                Text("Đánh dấu vùng tâm màn hình")
                    .font(.subheadline.weight(.bold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(detailPatches.count >= Self.maxPatches ? Color.gray.opacity(0.4) : primaryBlue)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(detailPatches.count >= Self.maxPatches)
    }

    private var bottomInfoGrid: some View {
        HStack(spacing: 12) {
            infoCard(
                icon: "globe.americas.fill",
                title: "Hệ tọa độ",
                subtitle: "Toàn cầu (WGS84)"
            )
            Button(action: onExport) {
                infoCard(
                    icon: "square.and.arrow.up",
                    title: "Xuất File",
                    subtitle: "OBJ / PLY"
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func infoCard(icon: String, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.white.opacity(0.7))
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundColor(.white)
            Text(subtitle)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func sectionLabel(icon: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2.weight(.semibold))
                .foregroundColor(.white.opacity(0.35))
            Text(title)
                .font(.caption2.weight(.bold))
                .tracking(0.8)
                .foregroundColor(.white.opacity(0.35))
        }
    }
}
