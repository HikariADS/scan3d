/*
 Abstract:
 Dropdown picker for scan export format.
 */

import SwiftUI

struct ScanExportFormatPicker: View {
    @Binding var selection: ScanExportFormat
    var hasReferencePoints: Bool
    var style: ScanExportFormatPickerStyle = .compact

    enum ScanExportFormatPickerStyle {
        case compact
        case card
    }

    var body: some View {
        switch style {
        case .compact:
            compactPicker
        case .card:
            cardPicker
        }
    }

    private var compactPicker: some View {
        Menu {
            ForEach(ScanExportFormat.allCases) { format in
                Button {
                    selection = format
                } label: {
                    Label(format.title, systemImage: selection == format ? "checkmark" : format.iconName)
                }
                .disabled(!format.isEnabled(hasReferencePoints: hasReferencePoints))
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selection.iconName)
                    .font(.caption.weight(.semibold))
                Text(selection.title)
                    .font(.caption.weight(.semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(.white.opacity(0.45))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.12))
            .clipShape(Capsule())
        }
    }

    private var cardPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel(icon: "square.and.arrow.up", title: "XUẤT FILE")
                Spacer()
            }

            Menu {
                ForEach(ScanExportFormat.allCases) { format in
                    Button {
                        selection = format
                    } label: {
                        VStack(alignment: .leading) {
                            Text(format.title)
                            Text(format.subtitle)
                        }
                    }
                    .disabled(!format.isEnabled(hasReferencePoints: hasReferencePoints))
                }
            } label: {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(red: 0.0, green: 0.48, blue: 1.0).opacity(0.85))
                        .frame(width: 44, height: 44)
                        .overlay(
                            Image(systemName: selection.iconName)
                                .font(.body.weight(.medium))
                                .foregroundColor(.white)
                        )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(selection.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.white)
                        Text(selection.subtitle)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.45))
                            .multilineTextAlignment(.leading)
                    }

                    Spacer()

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white.opacity(0.35))
                }
                .padding(12)
                .background(Color(red: 0.20, green: 0.20, blue: 0.22))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
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

private extension ScanExportFormat {
    var iconName: String {
        switch self {
        case .glb: return "cube.fill"
        case .objColored: return "square.stack.3d.up"
        case .ply: return "triangle.fill"
        case .objTextured: return "photo.stack"
        case .markersJSON: return "mappin.and.ellipse"
        }
    }
}
