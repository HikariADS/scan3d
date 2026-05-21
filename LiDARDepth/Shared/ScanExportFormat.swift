/*
 Abstract:
 Export format options for scan share sheet.
 */

import Foundation

enum ScanExportFormat: String, CaseIterable, Identifiable {
    case glb
    case objColored
    case ply
    case objTextured
    case markersJSON

    var id: String { rawValue }

    var title: String {
        switch self {
        case .glb: return "GLB"
        case .objColored: return "OBJ (màu)"
        case .ply: return "PLY"
        case .objTextured: return "OBJ + Texture"
        case .markersJSON: return "JSON điểm chuẩn"
        }
    }

    var subtitle: String {
        switch self {
        case .glb: return "Texture atlas ưu tiên — Blender, Reality Composer"
        case .objColored: return "Wavefront + vertex color"
        case .ply: return "Point cloud / mesh viewer"
        case .objTextured: return "OBJ + MTL + JPEG atlas"
        case .markersJSON: return "Điểm căn chỉnh P1, P2…"
        }
    }

    var fileExtension: String {
        switch self {
        case .glb: return "glb"
        case .objColored, .objTextured: return "obj"
        case .ply: return "ply"
        case .markersJSON: return "json"
        }
    }

    /// Chỉ xuất JSON khi đã có điểm chuẩn.
    func isEnabled(hasReferencePoints: Bool) -> Bool {
        switch self {
        case .markersJSON: return hasReferencePoints
        default: return true
        }
    }
}
