import Foundation
import Darwin

@main
struct VerifyDirect {
    static func main() async throws {
        let fm = FileManager.default
        let parent = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : fm.temporaryDirectory
        let root = parent.appendingPathComponent("RenameKit-direct-check-\(UUID().uuidString)")
        let logs = fm.temporaryDirectory.appendingPathComponent("RenameKit-logs-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: logs) }
        func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try value() else { throw RenameError.message("FAIL: " + label) }
            print("PASS: " + label)
        }
        func audit(_ engine: RenameEngine) throws -> RenameAudit {
            let folder = engine.journalURL.deletingLastPathComponent().appendingPathComponent("history")
            let path = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first!
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(RenameAudit.self, from: Data(contentsOf: path))
        }
        let source = root.appendingPathComponent("IMG_test.JPG")
        let payload = Data("RenameKit dedicated verification file; not a user photo.\n".utf8)
        try payload.write(to: source)
        let fixtureFD = open(source.path, O_RDONLY)
        guard fixtureFD >= 0 else { throw RenameError.message("Cannot open dedicated fixture") }
        fsync(fixtureFD); close(fixtureFD)
        let identity = try FileIdentity.read(source)
        let attributes = try fm.attributesOfItem(atPath: source.path)
        let options = RenameOptions()
        let review = RenameReview(items: RenameEngine.plan([source], options: options), options: options)
        let engine = RenameEngine(journalURL: logs.appendingPathComponent("normal/last.json"))
        let session = try SequentialRenameSession(review: review, engine: engine)
        try await session.execute(0)
        try await session.finishKeepingResults()
        let target = review.changes[0].target
        try check(!fm.fileExists(atPath: source.path) && Data(contentsOf: target) == payload, "direct rename preserves exact content")
        let after = try fm.attributesOfItem(atPath: target.path)
        try check(attributes[.creationDate] as? Date == after[.creationDate] as? Date && attributes[.modificationDate] as? Date == after[.modificationDate] as? Date, "creation and modification timestamps stay unchanged")
        let journal = try engine.readJournal()
        let recorded = try audit(engine)
        try check(journal.entries.allSatisfy { $0.temporary.isEmpty } && recorded.entries[0].fileSize == UInt64(payload.count) && recorded.entries[0].status == "succeeded", "detailed journal records metadata and success without temporary paths")
        try check(recorded.events.map(\.action) == ["renameIntent", "succeeded", "completed"], "intent and outcome are recorded separately")
        try engine.undo()
        try check(Data(contentsOf: source) == payload && audit(engine).entries[0].status == "rolledBack", "main recovery restores directly and updates retained audit")
        try check(fm.contentsOfDirectory(atPath: root.path) == [source.lastPathComponent], "no staging names remain")

        let conflictSession = try SequentialRenameSession(review: review, engine: engine)
        let blocker = Data("FOREIGN FILE".utf8)
        try blocker.write(to: target)
        var conflictRejected = false
        do { try await conflictSession.execute(0) } catch { conflictRejected = true }
        try check(conflictRejected && Data(contentsOf: target) == blocker && Data(contentsOf: source) == payload, "real volume collision refuses to overwrite either file")
        try fm.removeItem(at: target)
        let interruptedSession = try SequentialRenameSession(review: review, engine: engine)
        try await interruptedSession.execute(0)
        try engine.undo()
        try check(Data(contentsOf: source) == payload, "real volume recovers an interrupted direct operation from persisted record")

        if CommandLine.arguments.count == 1 {
            // Simulate a volume that cannot implement RENAME_EXCL.
            let fallback = RenameEngine(journalURL: logs.appendingPathComponent("fallback/last.json"), renameOperation: { _, _, _ in errno = ENOTSUP; return -1 })
            let fallbackSession = try SequentialRenameSession(review: review, engine: fallback)
            try await fallbackSession.execute(0)
            try check(Data(contentsOf: target) == payload, "unsupported exclusive flag falls back to same-directory system move")
            try await fallbackSession.rollback(0)
            try payload.write(to: target)
            var rejected = false
            do { try await fallbackSession.execute(0) } catch { rejected = true }
            try check(rejected && Data(contentsOf: source) == payload && Data(contentsOf: target) == payload, "fallback refuses an occupied destination without changing either file")
            try check(audit(fallback).events.contains { $0.action == "failed" && $0.error != nil }, "failed fallback remains in detailed history")
            try fm.removeItem(at: target)
            var count = 0
            var prelogged = false
            let journalURL = logs.appendingPathComponent("count/last.json")
            let counting = RenameEngine(journalURL: journalURL, renameOperation: { from, to, flags in
                count += 1
                prelogged = fm.fileExists(atPath: journalURL.path)
                    && (try? fm.contentsOfDirectory(atPath: journalURL.deletingLastPathComponent().appendingPathComponent("history").path).count) == 1
                return renamex_np(from.path, to.path, flags)
            })
            let countedSession = try SequentialRenameSession(review: review, engine: counting)
            try await countedSession.execute(0)
            try check(count == 1 && prelogged, "one rename call per file, with recovery and audit intent already on disk")
            try await countedSession.rollback(0)
            try check(count == 2 && Data(contentsOf: source) == payload, "rollback requires exactly one more direct rename")
            // Simulate restart after intent was persisted, before any mutation.
            let intent = JournalEntry(source: source.path, target: target.path, temporary: "", identity: identity)
            let recovery = RenameEngine(journalURL: logs.appendingPathComponent("crash/last.json"))
            try recovery.save(RenameJournal(date: Date(), complete: false, entries: [intent]))
            try recovery.undo()
            try check(Data(contentsOf: source) == payload, "recovery handles persisted intent before rename")
            try recovery.save(RenameJournal(date: Date(), complete: false, entries: [intent]))
            try fm.moveItem(at: source, to: target)
            try recovery.undo()
            try check(Data(contentsOf: source) == payload, "recovery handles successful rename before result record")
        }
        print("Direct rename verification passed; dedicated fixtures removed on exit.")
    }
}
