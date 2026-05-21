/*
 Abstract:
 Local scan library — persists exported models under Documents/ScanPro/Library.
 Cloud tab reads the same store (future: sync to remote).
 */

import Foundation
import SwiftUI

struct ScanRecord: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    let createdAt: Date
    let triangleCount: Int
    let exportFormat: String
    let primaryFilename: String
    let fileSizeBytes: Int64
    let sidecarFilenames: [String]
    let usedTexturedGLB: Bool

    var folderName: String { id.uuidString }
}

final class ScanLibrary: ObservableObject {
    static let shared = ScanLibrary()

    @Published private(set) var records: [ScanRecord] = []

    private let libraryRoot: URL
    private let indexURL: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        libraryRoot = docs.appendingPathComponent("ScanPro/Library", isDirectory: true)
        indexURL = libraryRoot.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        loadIndex()
    }

    var libraryDirectory: URL { libraryRoot }

    var totalBytesOnDevice: Int64 {
        records.reduce(0) { $0 + $1.fileSizeBytes }
    }

    func reload() { loadIndex() }

    @discardableResult
    func saveExport(
        fromTemporaryFiles files: [URL],
        format: ScanExportFormat,
        triangleCount: Int,
        usedTexturedGLB: Bool = false,
        customName: String? = nil
    ) -> ScanRecord? {
        guard !files.isEmpty else { return nil }

        let id = UUID()
        let folder = libraryRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        let fm = FileManager.default

        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)

            var primaryName = "model.glb"
            var sidecars: [String] = []
            var totalSize: Int64 = 0

            let sorted = files.sorted { a, b in
                rankFile(a) < rankFile(b)
            }

            for (idx, src) in sorted.enumerated() {
                let ext = src.pathExtension.lowercased()
                let destName: String
                if idx == 0 {
                    destName = primaryNameForFormat(format, ext: ext, primary: &primaryName)
                } else {
                    destName = "sidecar-\(idx).\(ext)"
                    sidecars.append(destName)
                }
                let dest = folder.appendingPathComponent(destName)
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: src, to: dest)
                if let attrs = try? fm.attributesOfItem(atPath: dest.path),
                   let size = attrs[.size] as? Int64 {
                    totalSize += size
                }
            }

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "vi_VN")
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            let defaultName = "Quét \(formatter.string(from: Date()))"

            let record = ScanRecord(
                id: id,
                name: customName ?? defaultName,
                createdAt: Date(),
                triangleCount: triangleCount,
                exportFormat: format.rawValue,
                primaryFilename: primaryName,
                fileSizeBytes: totalSize,
                sidecarFilenames: sidecars,
                usedTexturedGLB: usedTexturedGLB
            )

            let manifestURL = folder.appendingPathComponent("manifest.json")
            let manifestData = try encoder.encode(record)
            try manifestData.write(to: manifestURL, options: .atomic)

            DispatchQueue.main.async {
                self.records.insert(record, at: 0)
                self.persistIndex()
            }
            return record
        } catch {
            print("[ScanLibrary] save failed: \(error)")
            try? fm.removeItem(at: folder)
            return nil
        }
    }

    func primaryFileURL(for record: ScanRecord) -> URL {
        libraryRoot
            .appendingPathComponent(record.folderName, isDirectory: true)
            .appendingPathComponent(record.primaryFilename)
    }

    func allFileURLs(for record: ScanRecord) -> [URL] {
        let folder = libraryRoot.appendingPathComponent(record.folderName, isDirectory: true)
        var urls = [folder.appendingPathComponent(record.primaryFilename)]
        for name in record.sidecarFilenames {
            urls.append(folder.appendingPathComponent(name))
        }
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func delete(_ record: ScanRecord) {
        let folder = libraryRoot.appendingPathComponent(record.folderName, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        records.removeAll { $0.id == record.id }
        persistIndex()
    }

    func formattedSize(_ bytes: Int64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }

    func pointCountLabel(_ triangles: Int) -> String {
        if triangles >= 1_000_000 {
            return String(format: "%.1fM △", Double(triangles) / 1_000_000)
        }
        if triangles >= 1000 {
            return String(format: "%.1fk △", Double(triangles) / 1000)
        }
        return "\(triangles) △"
    }

    // MARK: - Private

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? decoder.decode([ScanRecord].self, from: data) else {
            records = rebuildIndexFromFolders()
            persistIndex()
            return
        }
        records = decoded.sorted { $0.createdAt > $1.createdAt }
    }

    private func persistIndex() {
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private func rebuildIndexFromFolders() -> [ScanRecord] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: libraryRoot, includingPropertiesForKeys: nil) else { return [] }
        return dirs.compactMap { dir -> ScanRecord? in
            let manifest = dir.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifest),
                  let record = try? decoder.decode(ScanRecord.self, from: data) else { return nil }
            return record
        }.sorted { $0.createdAt > $1.createdAt }
    }

    private func rankFile(_ url: URL) -> Int {
        switch url.pathExtension.lowercased() {
        case "glb": return 0
        case "obj": return 1
        case "ply": return 2
        case "json": return 3
        case "jpg", "jpeg": return 4
        case "mtl": return 5
        default: return 9
        }
    }

    private func primaryNameForFormat(_ format: ScanExportFormat, ext: String, primary: inout String) -> String {
        switch format {
        case .glb:
            primary = "model.glb"
        case .objColored, .objTextured:
            primary = "model.obj"
        case .ply:
            primary = "model.ply"
        case .markersJSON:
            primary = "markers.json"
        }
        return primary
    }
}
