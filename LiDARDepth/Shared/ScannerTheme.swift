/*
 Abstract:
 Shared colors and tab definitions for ScanPro UI.
 */

import SwiftUI

enum ScannerTheme {
    static let background = Color(red: 0.047, green: 0.047, blue: 0.047)
    static let cardBackground = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let accent = Color(red: 0.69, green: 0.77, blue: 1.0)
    static let accentDeep = Color(red: 0.22, green: 0.35, blue: 0.72)
    static let mutedText = Color.white.opacity(0.55)
    static let divider = Color.white.opacity(0.08)
}

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
