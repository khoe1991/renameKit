import Foundation
import Darwin

enum CollisionPolicy: String, Codable, CaseIterable, Identifiable {
    case ask = "提示冲突", numbers = "增加数字", letters = "增加字母"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ask: return "提示冲突，等待处理"
        case .numbers: return "仅冲突文件追加数字"
        case .letters: return "仅冲突文件追加字母"
        }
    }
}
struct RenameOptions {
    var settings = RenameSettings()
}

struct RenameItem: Identifiable {
    let source: URL
    let target: URL
    let note: String
    let error: Bool
    var id: String { source.path }
    var changed: Bool { source.path != target.path }
}
/// Immutable plan shown in the confirmation sheet. A different fresh plan must
/// be reviewed again instead of silently executing different names.
struct RenameReview: Identifiable {
    let id = UUID()
    let items: [RenameItem]
    let options: RenameOptions
    var changes: [RenameItem] { items.filter { !$0.error && $0.changed } }
    var collisionCount: Int { changes.filter { $0.note == "已自动避开冲突" }.count }
    func validate(_ fresh: [RenameItem]) throws {
        guard !items.contains(where: \.error), !changes.isEmpty,
              fresh.count == items.count,
              zip(fresh, items).allSatisfy({ !$0.0.error && $0.0.source == $0.1.source && $0.0.target == $0.1.target }) else {
            throw RenameError.message("目录内容已变化，确认列表已失效。请检查更新后的预览，再次确认。")
        }
    }
}
struct FileIdentity: Codable, Equatable, Hashable {
    let device: Int32
    let inode: UInt64
    static func read(_ url: URL) throws -> Self {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw RenameError.message("无法读取文件：\(url.lastPathComponent)（\(String(cString: strerror(errno)))）") }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw RenameError.message("仅支持普通文件：\(url.lastPathComponent)") }
        return Self(device: info.st_dev, inode: info.st_ino)
    }
}
enum RenameError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
struct JournalEntry: Codable {
    let source: String
    let target: String
    let temporary: String
    var identity: FileIdentity
    var fileSize: UInt64? = nil
    var createdAt: Date? = nil
    var modifiedAt: Date? = nil
    var status: String? = nil
    var updatedAt: Date? = nil
    var error: String? = nil
}
struct RenameAuditEvent: Codable {
    let date: Date
    let source: String?
    let action: String
    let error: String?
}
struct RenameAudit: Codable {
    let schemaVersion: Int
    let taskID: UUID
    let startedAt: Date
    let settings: RenameSettings
    var entries: [JournalEntry]
    var events: [RenameAuditEvent]
}
struct RenameJournal: Codable {
    let date: Date
    var complete: Bool
    let entries: [JournalEntry]
    var taskID: UUID? = nil
}

private final class RenameOnlyDelegate: NSObject, FileManagerDelegate {
    func fileManager(_ fileManager: FileManager, shouldCopyItemAt srcURL: URL, to dstURL: URL) -> Bool { false }
    func fileManager(_ fileManager: FileManager, shouldCopyItemAtPath srcPath: String, toPath dstPath: String) -> Bool { false }
}

final class RenameEngine {
    let journalURL: URL
    let fm = FileManager()
    private let renameOnlyDelegate = RenameOnlyDelegate()
    private let renameOperation: (URL, URL, UInt32) -> Int32
    init(journalURL: URL, renameOperation: @escaping (URL, URL, UInt32) -> Int32 = { source, target, flags in
        source.path.withCString { from in target.path.withCString { to in renamex_np(from, to, flags) } }
    }) {
        self.journalURL = journalURL; self.renameOperation = renameOperation
        fm.delegate = renameOnlyDelegate
    }
    var hasHistory: Bool { fm.fileExists(atPath: journalURL.path) }
    func readJournal() throws -> RenameJournal {
        try JSONDecoder().decode(RenameJournal.self, from: Data(contentsOf: journalURL))
    }
    func save(_ journal: RenameJournal) throws {
        try fm.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(journal)
        try data.write(to: journalURL, options: .atomic)
    }
    static func letters(_ number: Int) -> String {
        var n = max(1, number), result = ""
        while n > 0 {
            n -= 1
            result = String(UnicodeScalar(97 + n % 26)!) + result
            n /= 26
        }
        return result
    }
    private static func nameKey(_ name: String, sensitive: Bool) -> String {
        let normalized = name.precomposedStringWithCanonicalMapping
        return sensitive ? normalized : normalized.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
    static func plan(_ files: [URL], options: RenameOptions) -> [RenameItem] {
        let fm = FileManager.default
        var occupied: [String: Set<String>] = [:]
        var sensitivities: [String: Bool] = [:]
        var directoryErrors: [String: String] = [:]
        let parents = Set(files.map { $0.deletingLastPathComponent() })
        for parent in parents {
            let sensitive = (try? parent.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) ?? false
            sensitivities[parent.path] = sensitive
            do {
                let names = try fm.contentsOfDirectory(atPath: parent.path)
                let used = Set(names.map { nameKey($0, sensitive: sensitive) })
                occupied[parent.path] = used
            } catch { directoryErrors[parent.path] = error.localizedDescription }
        }
        let settings = options.settings
        let rule: DateNamingRule?
        let ruleError: String?
        do { rule = try DateNamingRule(settings.pattern); ruleError = nil }
        catch { rule = nil; ruleError = error.localizedDescription }
        var dates: [String: Date] = [:]
        var dateErrors: [String: String] = [:]
        for file in files {
            do {
                guard let date = try file.resourceValues(forKeys: [.creationDateKey]).creationDate else {
                    throw RenameError.message("无法读取文件创建时间")
                }
                dates[file.path] = date
            } catch { dateErrors[file.path] = error.localizedDescription }
        }
        let ordered = files.sorted { lhs, rhs in
            let a = dates[lhs.path] ?? .distantPast, b = dates[rhs.path] ?? .distantPast
            if a == b {
                let comparison = lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent)
                return comparison == .orderedSame ? lhs.path < rhs.path : comparison == .orderedAscending
            }
            return a < b
        }
        return ordered.map { source in
            let parent = source.deletingLastPathComponent()
            let sensitive = sensitivities[parent.path] ?? false
            func bad(_ reason: String, _ target: URL? = nil) -> RenameItem {
                RenameItem(source: source, target: target ?? source, note: reason, error: true)
            }
            if let error = ruleError { return bad(error) }
            if let error = dateErrors[source.path] { return bad(error) }
            if let error = directoryErrors[parent.path] { return bad("目录不可读：\(error)") }
            do { _ = try FileIdentity.read(source) } catch { return bad(error.localizedDescription) }
            guard let rule, let date = dates[source.path] else { return bad("无法读取文件创建时间") }
            let ext = source.pathExtension
            let root = rule.string(from: date)
            func filename(_ root: String) -> String { ext.isEmpty ? root : root + "." + ext }
            func valid(_ name: String) -> Bool {
                !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains(":") && !name.contains("\0") && name.utf8.count <= 255
            }
            guard !root.isEmpty, valid(filename(root)) else { return bad("文件名为空、过长或包含 /、: 等无效字符") }
            let originalKey = nameKey(source.lastPathComponent, sensitive: sensitive)
            func conflicts(_ name: String) -> Bool {
                let key = nameKey(name, sensitive: sensitive)
                return key != originalKey && occupied[parent.path, default: []].contains(key)
            }
            var name = filename(root)
            var note = "可重命名"
            if conflicts(name) {
                if settings.policy == .ask { return bad("名称冲突，请选择增加数字或字母", parent.appendingPathComponent(name)) }
                var index = 1
                repeat {
                    let extra = settings.policy == .numbers ? String(index) : letters(index)
                    name = filename(root + "_" + extra)
                    guard valid(name) else { return bad("添加后缀后文件名过长") }
                    index += 1
                } while conflicts(name)
                note = "已自动避开冲突"
            }
            occupied[parent.path, default: []].insert(nameKey(name, sensitive: sensitive))
            let target = parent.appendingPathComponent(name)
            return RenameItem(source: source, target: target, note: target.path == source.path ? "名称不变" : note, error: false)
        }
    }
    func moveExclusively(_ source: URL, _ target: URL) throws {
        guard source.deletingLastPathComponent().standardizedFileURL == target.deletingLastPathComponent().standardizedFileURL else {
            throw RenameError.message("仅允许在同一目录内修改文件名。")
        }
        _ = try FileIdentity.read(source) // Only ordinary files, including during rollback.
        // Keep the atomic no-overwrite operation where the volume supports it.
        let result = renameOperation(source, target, UInt32(RENAME_EXCL))
        guard result != 0 else { return }
        let code = errno
        if code == ENOTSUP || code == ENOSYS {
            // Foundation supports mounted SMB volumes and refuses an existing
            // destination. Same-directory moves cannot become cross-volume copies.
            try fm.moveItem(at: source, to: target)
            _ = try FileIdentity.read(target)
            return
        }
        throw RenameError.message("无法将「\(source.lastPathComponent)」改为「\(target.lastPathComponent)」：\(String(cString: strerror(code)))")
    }
    func saveAudit(_ audit: RenameAudit) throws {
        let directory = journalURL.deletingLastPathComponent().appendingPathComponent("history", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(audit).write(to: directory.appendingPathComponent("\(audit.taskID.uuidString).json"), options: .atomic)
    }
    private func appendRecoveryEvent(_ journal: RenameJournal, entry: JournalEntry, action: String, error: String? = nil) throws {
        guard let taskID = journal.taskID else { return }
        let url = journalURL.deletingLastPathComponent().appendingPathComponent("history/\(taskID.uuidString).json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var audit = try decoder.decode(RenameAudit.self, from: Data(contentsOf: url))
        if let index = audit.entries.firstIndex(where: { $0.source == entry.source }) {
            audit.entries[index].status = action
            audit.entries[index].updatedAt = Date()
            audit.entries[index].error = error
        }
        audit.events.append(RenameAuditEvent(date: Date(), source: entry.source, action: action, error: error))
        try saveAudit(audit)
    }
    func apply(_ plan: [RenameItem]) throws -> Int {
        guard !plan.contains(where: \.error) else { throw RenameError.message("请先解决预览中的冲突或错误。") }
        if hasHistory, !(try readJournal()).complete { throw RenameError.message("上次操作未完成，请先点击“撤销 / 恢复”。") }
        let changes = plan.filter(\.changed)
        guard !changes.isEmpty else { return 0 }
        var seen = Set<FileIdentity>()
        let entries = try changes.map { item -> JournalEntry in
            let identity = try FileIdentity.read(item.source)
            guard seen.insert(identity).inserted else { throw RenameError.message("本批次包含指向同一文件的硬链接，请分批操作。") }
            guard !changes.contains(where: { $0.source.path == item.target.path && $0.source.path != item.source.path }) else {
                throw RenameError.message("目标占用了同批其他文件的原名，请重新预览。")
            }
            return JournalEntry(source: item.source.path, target: item.target.path, temporary: "", identity: identity)
        }
        // Write every recovery path before the first filesystem mutation.
        var journal = RenameJournal(date: Date(), complete: false, entries: entries)
        try save(journal)
        do {
            for entry in entries {
                let source = URL(fileURLWithPath: entry.source)
                guard try FileIdentity.read(source) == entry.identity else { throw RenameError.message("文件已发生变化，请重新预览。") }
                try moveExclusively(source, URL(fileURLWithPath: entry.target))
            }
            journal.complete = true
            try save(journal)
            return entries.count
        } catch {
            let original = error.localizedDescription
            do {
                _ = try undo()
            } catch {
                throw RenameError.message("操作失败：\(original)\n恢复未完成：\(error.localizedDescription)。恢复记录已保留，请点击“撤销 / 恢复”。")
            }
            throw RenameError.message("操作失败，已恢复原名称。\n\(original)")
        }
    }
    @discardableResult func undo() throws -> Int {
        let journal = try readJournal()
        var locations: [URL] = []
        for entry in journal.entries {
            let candidates = [entry.temporary, entry.target, entry.source].filter { !$0.isEmpty }
            guard let path = candidates.first(where: {
                let url = URL(fileURLWithPath: $0)
                return (try? fm.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).contains(url.lastPathComponent)) == true
                    && (entry.temporary.isEmpty || (try? FileIdentity.read(url)) == entry.identity)
            }) else {
                throw RenameError.message("找不到原文件「\(URL(fileURLWithPath: entry.source).lastPathComponent)」，文件可能已被移动或替换。恢复记录已保留。")
            }
            locations.append(URL(fileURLWithPath: path))
        }
        if journal.entries.allSatisfy({ $0.temporary.isEmpty }) {
            // New journals recover directly; the persisted intent also covers a
            // crash after rename succeeds but before its status is saved.
            // New records resolve by exact full paths, without inode matching.
            var unresolved = journal.entries
            for (entry, current) in zip(journal.entries, locations) {
                try appendRecoveryEvent(journal, entry: entry, action: "recoveryIntent")
                do {
                    if current.path != entry.source {
                        try moveExclusively(current, URL(fileURLWithPath: entry.source))
                    }
                    try appendRecoveryEvent(journal, entry: entry, action: "rolledBack")
                } catch {
                    try appendRecoveryEvent(journal, entry: entry, action: "recoveryFailed", error: error.localizedDescription)
                    throw error
                }
                unresolved.removeAll { $0.source == entry.source }
                if !unresolved.isEmpty {
                    try save(RenameJournal(date: journal.date, complete: false, entries: unresolved, taskID: journal.taskID))
                }
            }
            try fm.removeItem(at: journalURL)
            return journal.entries.count
        }
        // Compatibility only: old versions may have left staged files or swaps.
        let identities = Set(journal.entries.map(\.identity))
        // Preflight all original and staging paths before touching any file.
        for entry in journal.entries {
            for path in [entry.source, entry.temporary] {
                if fm.fileExists(atPath: path) || (try? fm.destinationOfSymbolicLink(atPath: path)) != nil {
                    guard let identity = try? FileIdentity.read(URL(fileURLWithPath: path)), identities.contains(identity) else {
                        throw RenameError.message("恢复位置已被其他文件占用：\(path)。请移开该文件后重试。")
                    }
                }
            }
        }
        for (entry, current) in zip(journal.entries, locations) {
            let temporary = URL(fileURLWithPath: entry.temporary)
            if current.path != temporary.path { try moveExclusively(current, temporary) }
        }
        for entry in journal.entries { try moveExclusively(URL(fileURLWithPath: entry.temporary), URL(fileURLWithPath: entry.source)) }
        try fm.removeItem(at: journalURL)
        return journal.entries.count
    }
}
