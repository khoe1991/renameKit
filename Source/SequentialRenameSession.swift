import Foundation

/// All filesystem mutations for a controlled task are serialized by this actor.
/// Each file moves directly from source to target after its intent is persisted.
actor SequentialRenameSession {
    let review: RenameReview
    private let engine: RenameEngine
    private let prepared: [JournalEntry]
    private let previousJournal: RenameJournal?
    private var records: [Int: JournalEntry] = [:]
    private var completed = Set<Int>()
    private var wroteJournal = false
    private var audit: RenameAudit

    init(review: RenameReview, engine: RenameEngine) throws {
        self.review = review
        self.engine = engine
        let fresh = RenameEngine.plan(review.items.map(\.source), options: review.options)
        try review.validate(fresh)
        if engine.hasHistory {
            let journal = try engine.readJournal()
            guard journal.complete else { throw RenameError.message("存在未完成的恢复记录，请先使用主窗口的“撤销 / 恢复”。") }
            previousJournal = journal
        } else { previousJournal = nil }
        var seen = Set<String>()
        var entries: [JournalEntry] = []
        var sensitivities: [String: Bool] = [:]
        for item in review.items {
            let parent = item.source.deletingLastPathComponent()
            if sensitivities[parent.path] == nil {
                sensitivities[parent.path] = (try? parent.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) ?? false
            }
        }
        func key(_ url: URL) -> String {
            let parent = url.deletingLastPathComponent().path
            let name = url.lastPathComponent.precomposedStringWithCanonicalMapping
            return parent + "/" + ((sensitivities[parent] ?? false) ? name : name.lowercased(with: Locale(identifier: "en_US_POSIX")))
        }
        let originalOwners = Dictionary(grouping: review.items, by: { key($0.source) })
        // A stop must not leave an unfinished dependency or filename swap behind.
        for item in review.changes {
            guard !(originalOwners[key(item.target)] ?? []).contains(where: { $0.source != item.source }) else {
                throw RenameError.message("目标名称占用了同批其他文件的原名，请刷新预览后重新确认。")
            }
            let identity = try FileIdentity.read(item.source)
            guard seen.insert("\(identity.device):\(identity.inode)").inserted else { throw RenameError.message("本批次包含同一文件的硬链接，请分批处理。") }
            let attributes = try engine.fm.attributesOfItem(atPath: item.source.path)
            entries.append(JournalEntry(source: item.source.path, target: item.target.path,
                                        temporary: "", identity: identity,
                                        fileSize: (attributes[.size] as? NSNumber)?.uint64Value,
                                        createdAt: attributes[.creationDate] as? Date,
                                        modifiedAt: attributes[.modificationDate] as? Date,
                                        status: "planned"))
        }
        prepared = entries
        audit = RenameAudit(schemaVersion: 2, taskID: UUID(), startedAt: Date(), settings: review.options.settings,
                            entries: entries, events: [])
    }
    var recordedIndices: [Int] { records.keys.sorted() }
    var completedIndices: Set<Int> { completed }

    private func log(_ index: Int, _ action: String, error: String? = nil) throws {
        audit.entries[index].status = action
        audit.entries[index].updatedAt = Date()
        audit.entries[index].error = error
        audit.events.append(RenameAuditEvent(date: Date(), source: prepared[index].source, action: action, error: error))
        try engine.saveAudit(audit)
    }
    private func persist(complete: Bool) throws {
        if records.isEmpty {
            guard wroteJournal else { return }
            if let previousJournal { try engine.save(previousJournal) }
            else if engine.hasHistory { try engine.fm.removeItem(at: engine.journalURL) }
        } else {
            try engine.save(RenameJournal(date: Date(), complete: complete,
                                          entries: records.keys.sorted().compactMap { records[$0] }, taskID: audit.taskID))
            wroteJournal = true
        }
    }
    private func exactlyExists(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        return (try? engine.fm.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).contains(url.lastPathComponent)) == true
    }
    private func located(_ entry: JournalEntry) -> URL? {
        for path in [entry.target, entry.source] {
            let url = URL(fileURLWithPath: path)
            if exactlyExists(path) { return url }
        }
        return nil
    }
    func currentPaths() -> [String: URL] {
        var result = Dictionary(uniqueKeysWithValues: review.items.map { ($0.source.path, $0.source) })
        for (index, entry) in records {
            // Display the actual path without reading file contents.
            if completed.contains(index), exactlyExists(entry.target) {
                result[prepared[index].source] = URL(fileURLWithPath: entry.target)
            } else if let location = located(entry) { result[prepared[index].source] = location }
        }
        return result
    }
    func execute(_ index: Int) throws {
        guard prepared.indices.contains(index) else { return }
        if completed.contains(index) {
            // Retry a failed result-record write without renaming again.
            try log(index, "succeeded"); try persist(complete: false); return
        }
        let entry = prepared[index]
        let source = URL(fileURLWithPath: entry.source)
        let target = URL(fileURLWithPath: entry.target)
        do {
            _ = try FileIdentity.read(source)
            guard exactlyExists(entry.source) else {
                throw RenameError.message("原文件已移动或被替换：\(source.lastPathComponent)。")
            }
        } catch {
            try log(index, "failed", error: error.localizedDescription)
            throw error
        }
        guard records[index] == nil else {
            throw RenameError.message("该文件存在未恢复的操作记录，请选择“停止并回滚”。")
        }
        try log(index, "renameIntent")
        records[index] = entry
        do { try persist(complete: false) }
        catch { records.removeValue(forKey: index); throw error }
        do {
            try engine.moveExclusively(source, target)
        } catch {
            let failure = error.localizedDescription
            // A failed rename leaves the original name untouched. Keep an
            // unresolved intent if its source path cannot be confirmed.
            try log(index, "failed", error: failure)
            if exactlyExists(entry.source) {
                records.removeValue(forKey: index)
                do { try persist(complete: false) }
                catch { records[index] = entry; throw error }
            }
            throw error
        }
        completed.insert(index)
        records[index]?.status = "succeeded"
        records[index]?.updatedAt = Date()
        try persist(complete: false)
        try log(index, "succeeded")
    }
    func finishKeepingResults() throws {
        guard Set(records.keys).isSubset(of: completed) else {
            try persist(complete: false)
            throw RenameError.message("任务已停止，成功文件保留新名称；有文件需要恢复，请查看失败原因并使用回滚或“撤销 / 恢复”。")
        }
        for index in audit.entries.indices where audit.entries[index].status == "planned" {
            audit.entries[index].status = "notExecuted"
            audit.entries[index].updatedAt = Date()
        }
        audit.events.append(RenameAuditEvent(date: Date(), source: nil,
                                             action: completed.count == prepared.count ? "completed" : "stopped", error: nil))
        if wroteJournal || !audit.events.isEmpty { try engine.saveAudit(audit) }
        try persist(complete: true)
    }
    func rollback(_ index: Int) throws {
        guard let entry = records[index] else { return }
        let source = URL(fileURLWithPath: entry.source)
        try log(index, "rollbackIntent")
        do {
            guard let current = located(entry) else { throw RenameError.message("记录中的文件路径不存在，恢复记录已保留。") }
            if current.path != entry.source {
                try engine.moveExclusively(current, source)
            }
            try log(index, "rolledBack")
        } catch {
            try log(index, "rollbackFailed", error: error.localizedDescription)
            throw error
        }
        completed.remove(index)
        records.removeValue(forKey: index)
        do { try persist(complete: false) }
        catch {
            records[index] = entry
            throw RenameError.message("文件已恢复原名，但恢复记录保存失败：\(error.localizedDescription)。请重试回滚。")
        }
    }
}
