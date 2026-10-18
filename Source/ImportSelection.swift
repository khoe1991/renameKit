import Foundation

struct FolderImportGroup: Identifiable {
    let url: URL
    var includesFiles = false
    var members = Set<URL>()
    var id: String { url.path }
}
struct ImportReport {
    var addedFiles = 0
    var addedFolders = 0
    var skipped = 0
    var errors: [String] = []
}
/// Folders are presentation groups only. Only ordinary file URLs enter the
/// rename list. Track ownership so unchecking a group preserves explicit files.
struct ImportSelection {
    var files: [URL] = []
    private(set) var folders: [FolderImportGroup] = []
    private var explicitFiles = Set<URL>()
    mutating func add(_ urls: [URL]) -> ImportReport {
        var report = ImportReport()
        for raw in urls {
            let url = raw.standardizedFileURL
            guard url.isFileURL else { report.skipped += 1; continue }
            do {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey])
                guard values.isSymbolicLink != true else { report.skipped += 1; continue }
                if values.isDirectory == true && values.isPackage != true {
                    if !folders.contains(where: { $0.id == url.path }) {
                        folders.append(FolderImportGroup(url: url)); report.addedFolders += 1
                    }
                } else if values.isRegularFile == true {
                    explicitFiles.insert(url)
                    if !files.contains(url) { files.append(url); report.addedFiles += 1 }
                } else { report.skipped += 1 }
            } catch { report.errors.append("无法添加「\(url.lastPathComponent)」：\(error.localizedDescription)") }
        }
        return report
    }
    static func readFolderFiles(_ folder: URL) throws -> [URL] {
        let candidates = try FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return try candidates.filter {
            let values = try $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values.isRegularFile == true && values.isSymbolicLink != true
        }.map(\.standardizedFileURL)
    }
    mutating func setIncludesFiles(_ included: Bool, folder: URL, candidates: [URL]? = nil) throws {
        guard let index = folders.firstIndex(where: { $0.id == folder.path }), folders[index].includesFiles != included else { return }
        if included {
            let ordinary = try candidates ?? Self.readFolderFiles(folder)
            folders[index].members = Set(ordinary)
            folders[index].includesFiles = true
            var known = Set(files)
            files.append(contentsOf: ordinary.filter { known.insert($0).inserted })
        } else {
            let removed = folders[index].members
            folders[index].members = []; folders[index].includesFiles = false
            let retained = explicitFiles.union(folders.reduce(into: Set<URL>()) { $0.formUnion($1.members) })
            files.removeAll { removed.contains($0) && !retained.contains($0) }
        }
    }
    mutating func removeFile(_ url: URL) {
        files.removeAll { $0 == url }; explicitFiles.remove(url)
        for index in folders.indices { folders[index].members.remove(url) }
    }
    mutating func removeFolder(_ url: URL) {
        // Disabling performs no filesystem IO and preserves explicitly added files.
        try? setIncludesFiles(false, folder: url)
        folders.removeAll { $0.id == url.path }
    }
    mutating func remapOwnership(_ paths: [String: URL]) {
        let current = Set(files)
        explicitFiles = Set(explicitFiles.map { paths[$0.path] ?? $0 }).intersection(current)
        for index in folders.indices {
            folders[index].members = Set(folders[index].members.map { paths[$0.path] ?? $0 }).intersection(current)
        }
    }
}
