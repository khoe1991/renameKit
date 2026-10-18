import Foundation
import Combine

@main
struct Verify {
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("RenameKit-check-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var passes = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try condition() else { throw RenameError.message("FAIL: \(label)") }
            passes += 1; print("PASS: \(label)")
        }
        func expectFailure(_ label: String, _ action: () throws -> Void) throws {
            var failed = false
            do { try action() } catch { failed = true }
            try check(failed, label)
        }
        func directory(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func file(_ dir: URL, _ name: String, _ content: String) throws -> URL {
            let url = dir.appendingPathComponent(name)
            try Data(content.utf8).write(to: url)
            return url
        }
        func contents(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
        func engine(_ dir: URL) -> RenameEngine { RenameEngine(journalURL: dir.appendingPathComponent("journal/last.json")) }
        let sample = DateNamingRule.referenceDate
        let cases: [(String, String)] = [
            ("yyyyMMdd_HHmmss", "20261017_153030"),
            ("yyyy-mm-dd", "2026-10-17"),
            ("yyyy-MM-dd_HH-mm-ss", "2026-10-17_15-30-30"),
            ("yyyymmmdd", "2026Oct17"),
            ("yyyyMMMMdd", "2026October17"),
            ("yyyymmdd_HHmmss", "20261017_153030"),
            ("yyyy年MM月dd日 HH时mm分ss秒", "2026年10月17日 15时30分30秒"),
            ("HHmmss_yyyyMMdd", "153030_20261017"),
            ("yy-M-d_H-m-s", "26-10-17_15-30-30"),
            ("'IMG_'yyyyMMdd", "IMG_20261017"),
            ("yyyy''MM", "2026'10"),
            ("yyyy'it''s'MM", "2026it's10")
        ]
        for (pattern, expected) in cases {
            try check(DateNamingRule(pattern).string(from: sample) == expected, "editable pattern: \(pattern)")
        }
        let invalid = ["", "   ", "yyy-MM-dd", "yyyy-mmmmm-dd", "yyyy-MM-dd_HHmmmmmss", "yyyy-MM-dd_HH:mm:ss", "yyyy/MM/dd", "yyyy\nMMdd", "YYYYMMdd", "yyyy-ddd", "HHH", "sssss", "S", "yyyyMM_MM", "yyyy'open", "IMG_yyyy", "'literal only'", String(repeating: "-", count: 121)]
        for pattern in invalid { try check(DateNamingRule.validationError(pattern) != nil, "invalid pattern blocked: \(pattern.debugDescription)") }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = iso.date(from: "2024-02-29T23:07:05.123Z")!
        try check(DateNamingRule("yyyyMMdd_HHmmss_SSS").string(from: fractional, timeZone: TimeZone(secondsFromGMT: 0)!) == "20240229_230705_123", "milliseconds and leap date are rendered correctly")
        let settingsStore = RenameSettingsStore(url: root.appendingPathComponent("settings/settings.json"))
        let saved = RenameSettings(pattern: "yyyymmmdd_HHmmss", policy: .ask)
        try settingsStore.save(saved)
        try check(settingsStore.load() == saved, "custom pattern and collision policy survive reopen")
        let dir = try directory("files")
        let a = try file(dir, "one.MOV", "FIRST"), b = try file(dir, "two.MOV", "SECOND"), c = try file(dir, "three.MOV", "UNIQUE")
        let stamp = sample
        try fm.setAttributes([.creationDate: stamp], ofItemAtPath: a.path)
        try fm.setAttributes([.creationDate: stamp], ofItemAtPath: b.path)
        try fm.setAttributes([.creationDate: stamp.addingTimeInterval(1)], ofItemAtPath: c.path)
        let input = [a,b,c]
        let plan = RenameEngine.plan(input, options: RenameOptions())
        try check(plan.map { $0.target.lastPathComponent } == ["20261017_153030.MOV", "20261017_153030_a.MOV", "20261017_153031.MOV"], "only same-second collisions receive a letter suffix")
        let worker = engine(dir)
        try check(worker.apply(plan) == 3, "apply creation-time rename")
        try check(contents(plan[0].target) == "FIRST" && contents(plan[1].target) == "SECOND" && contents(plan[2].target) == "UNIQUE", "contents and original extension case are preserved")
        try check(worker.undo() == 3 && contents(a) == "FIRST" && contents(b) == "SECOND", "undo restores original names")
        let customPlan = RenameEngine.plan(input, options: RenameOptions(settings: RenameSettings(pattern: "yyyymmmdd_HHmmss")))
        try check(customPlan[0].target.lastPathComponent == "2026Oct17_153030.MOV" && customPlan[1].target.lastPathComponent == "2026Oct17_153030_a.MOV", "custom month format also uses collision-only suffixes")
        let original = try file(dir, "20261017_153030.MOV", "EXISTING")
        let occupiedA = try file(dir, "20261017_153030_a.MOV", "EXISTING A")
        let occupiedPlan = RenameEngine.plan(input, options: RenameOptions())
        try check(occupiedPlan.map { $0.target.lastPathComponent } == ["20261017_153030_b.MOV", "20261017_153030_c.MOV", "20261017_153031.MOV"], "existing letter suffixes are skipped without suffixing unrelated files")
        _ = try worker.apply(occupiedPlan)
        try check(contents(original) == "EXISTING" && contents(occupiedA) == "EXISTING A", "existing files are never overwritten")
        _ = try worker.undo()
        let numericPlan = RenameEngine.plan(input, options: RenameOptions(settings: RenameSettings(policy: .numbers)))
        try check(numericPlan[0].target.lastPathComponent == "20261017_153030_1.MOV" && numericPlan[2].target.lastPathComponent == "20261017_153031.MOV", "numeric strategy also applies only to conflicts")
        let prompt = RenameEngine.plan(input, options: RenameOptions(settings: RenameSettings(policy: .ask)))
        try check(prompt.filter(\.error).count == 2, "prompt-only strategy marks just colliding files")
        let invalidPlan = RenameEngine.plan(input, options: RenameOptions(settings: RenameSettings(pattern: "yyyy/XX")))
        try check(invalidPlan.allSatisfy(\.error), "invalid editor rule also blocks engine preview")
        try expectFailure("invalid rules cannot execute") { _ = try worker.apply(invalidPlan) }
        try check(contents(a) == "FIRST", "invalid rule leaves disk files unchanged")
        let raceDir = try directory("race")
        let r = try file(raceDir, "original.txt", "ORIGINAL")
        try fm.setAttributes([.creationDate: stamp], ofItemAtPath: r.path)
        let racePlan = RenameEngine.plan([r], options: RenameOptions())
        _ = try file(raceDir, racePlan[0].target.lastPathComponent, "LATE ARRIVAL")
        let raceWorker = engine(raceDir)
        try expectFailure("late collision fails safely") { _ = try raceWorker.apply(racePlan) }
        try check(contents(r) == "ORIGINAL" && contents(racePlan[0].target) == "LATE ARRIVAL", "late collision rolls back without overwrite")
        let swapDir = try directory("swap")
        let x = try file(swapDir, "x.txt", "X"), y = try file(swapDir, "y.txt", "Y")
        let swapWorker = engine(swapDir)
        try expectFailure("direct rename rejects filename swaps before touching files") {
            _ = try swapWorker.apply([RenameItem(source: x, target: y, note: "", error: false), RenameItem(source: y, target: x, note: "", error: false)])
        }
        try check(contents(x) == "X" && contents(y) == "Y", "rejected swaps leave both files untouched")
        let recoveryDir = try directory("recovery")
        let source = try file(recoveryDir, "original.txt", "RECOVER")
        let temporary = recoveryDir.appendingPathComponent(".stage"), final = recoveryDir.appendingPathComponent("final.txt")
        let recovery = engine(recoveryDir)
        let entry = JournalEntry(source: source.path, target: final.path, temporary: temporary.path, identity: try FileIdentity.read(source))
        try recovery.save(RenameJournal(date: Date(), complete: false, entries: [entry]))
        try fm.moveItem(at: source, to: temporary)
        _ = try recovery.undo()
        try check(contents(source) == "RECOVER", "interrupted staging can be recovered")
        try recovery.save(RenameJournal(date: Date(), complete: false, entries: [entry]))
        try fm.moveItem(at: source, to: final)
        _ = try file(recoveryDir, "original.txt", "NEW OWNER")
        try expectFailure("occupied recovery path blocks undo") { _ = try recovery.undo() }
        try check(contents(source) == "NEW OWNER" && contents(final) == "RECOVER" && recovery.hasHistory, "failed undo preserves existing files and recovery record")
        try fm.removeItem(at: source)
        _ = try recovery.undo()
        try check(contents(source) == "RECOVER", "undo succeeds after recovery conflict is removed")
        try check(RenameEngine.letters(26) == "z" && RenameEngine.letters(27) == "aa", "conflict lettering continues beyond z")
        let oldSettings = Data("{\"pattern\":\"yyyyMMdd_HHmmss\",\"policy\":\"增加字母\"}".utf8)
        let migrated = try JSONDecoder().decode(RenameSettings.self, from: oldSettings)
        try check(migrated.visibleInformation == [.created], "existing settings default to showing original creation time")
        try check(migrated.executionInterval == .milliseconds200, "existing settings migrate to the 200 ms default")
        let timedSettings = RenameSettings(executionInterval: .milliseconds500)
        try settingsStore.save(timedSettings)
        try check(settingsStore.load() == timedSettings && ExecutionInterval.allCases.map(\.rawValue) == [0, 100, 200, 500], "interval options persist and match the offered choices")
        let configuredColumns = RenameSettings(pattern: "yyyyMMdd_HHmmss", policy: .letters, visibleInformation: [.created, .modified, .size, .type])
        try settingsStore.save(configuredColumns)
        try check(settingsStore.load() == configuredColumns, "selected metadata columns survive reopening")
        let beforeAttributes = try fm.attributesOfItem(atPath: a.path)
        let metadata = FileInformation.read(a)
        let afterAttributes = try fm.attributesOfItem(atPath: a.path)
        try check(metadata.created == stamp, "original creation time is read from filesystem metadata")
        try check(metadata.size == 5 && metadata.fileExtension == "MOV", "size and original extension are available as optional columns")
        try check(metadata.text(for: .created) == "2026-10-17 15:30:30" && metadata.text(for: .fileExtension) == ".MOV", "metadata columns display seconds and preserve extension case")
        try check(beforeAttributes[.creationDate] as? Date == afterAttributes[.creationDate] as? Date && beforeAttributes[.modificationDate] as? Date == afterAttributes[.modificationDate] as? Date && contents(a) == "FIRST", "reading display metadata does not modify file content or dates")
        let infoOnlyPlan = RenameEngine.plan(input, options: RenameOptions(settings: configuredColumns))
        let normalPlan = RenameEngine.plan(input, options: RenameOptions())
        try check(infoOnlyPlan.map(\.target) == normalPlan.map(\.target), "display-column selections never change the rename plan")
        let review = RenameReview(items: normalPlan, options: RenameOptions())
        try review.validate(RenameEngine.plan(input, options: review.options))
        try check(review.changes.count == 3 && review.collisionCount == 2, "confirmation freezes exact changed names and collision counts")
        let unchanged = RenameItem(source: a, target: a, note: "名称不变", error: false)
        let mixedReview = RenameReview(items: [normalPlan[0], unchanged], options: RenameOptions())
        try check(mixedReview.changes.count == 1, "confirmation shows only files that will actually be renamed")
        let lateTarget = try file(dir, normalPlan[0].target.lastPathComponent, "NEW AFTER REVIEW")
        let changedSinceReview = RenameEngine.plan(input, options: review.options)
        try expectFailure("confirmation rejects a target-name change after the review was shown") { try review.validate(changedSinceReview) }
        try check(contents(a) == "FIRST" && contents(lateTarget) == "NEW AFTER REVIEW", "review validation alone never renames or overwrites files")
        try expectFailure("confirmation rejects invalid preview items") {
            try RenameReview(items: invalidPlan, options: RenameOptions()).validate(invalidPlan)
        }
        func expectAsyncFailure(_ label: String, _ action: () async throws -> Void) async throws {
            var failed = false
            do { try await action() } catch { failed = true }
            try check(failed, label)
        }
        func batch(_ label: String, count: Int = 4, interval: ExecutionInterval = .milliseconds200) throws -> (URL, [URL], RenameReview, RenameEngine) {
            let folder = try directory(label)
            var files: [URL] = []
            for index in 0..<count {
                let url = try file(folder, "source-\(index).txt", "CONTENT-\(index)")
                try fm.setAttributes([.creationDate: stamp.addingTimeInterval(Double(index))], ofItemAtPath: url.path)
                files.append(url)
            }
            let options = RenameOptions(settings: RenameSettings(executionInterval: interval))
            let plan = RenameEngine.plan(files, options: options)
            return (folder, files, RenameReview(items: plan, options: options), engine(folder))
        }
        let (stopDir, stopFiles, stopReview, stopEngine) = try batch("sequential-stop")
        let stopSession = try SequentialRenameSession(review: stopReview, engine: stopEngine)
        try await stopSession.execute(0)
        try check(contents(stopReview.changes[0].target) == "CONTENT-0" && stopFiles.dropFirst().allSatisfy { fm.fileExists(atPath: $0.path) }, "one-file execution leaves every pending file at its original name")
        try check(fm.contentsOfDirectory(atPath: stopDir.path).allSatisfy { !$0.hasPrefix(".renamekit-") }, "a completed file boundary leaves no hidden temporary filenames")
        try await stopSession.finishKeepingResults()
        try check(stopEngine.readJournal().complete && stopEngine.readJournal().entries.count == 1, "stop retains undo history only for files actually renamed")
        let oldJournalData = try Data(contentsOf: stopEngine.journalURL)
        let pendingReview = RenameReview(items: RenameEngine.plan(Array(stopFiles.dropFirst()), options: RenameOptions()), options: RenameOptions())
        let noOpSession = try SequentialRenameSession(review: pendingReview, engine: stopEngine)
        try await noOpSession.finishKeepingResults()
        try check(Data(contentsOf: stopEngine.journalURL) == oldJournalData, "stopping before the first file preserves the preceding undo record")
        _ = try stopEngine.undo()
        try check(stopFiles.allSatisfy { fm.fileExists(atPath: $0.path) }, "main undo restores a stopped partial batch")
        let (_, failureFiles, failureReview, failureEngine) = try batch("sequential-failure")
        let failureSession = try SequentialRenameSession(review: failureReview, engine: failureEngine)
        try await failureSession.execute(0)
        let blocker = try file(failureFiles[0].deletingLastPathComponent(), failureReview.changes[1].target.lastPathComponent, "EXTERNAL")
        try await expectAsyncFailure("per-file late collision reports failure") { try await failureSession.execute(1) }
        try check(contents(failureReview.changes[0].target) == "CONTENT-0" && contents(failureFiles[1]) == "CONTENT-1" && contents(blocker) == "EXTERNAL", "failed current file restores itself without rolling back earlier successes")
        try await failureSession.finishKeepingResults()
        try check(failureEngine.readJournal().entries.count == 1, "failed file is not recorded as successfully renamed")
        try await failureSession.rollback(0)
        try check(contents(failureFiles[0]) == "CONTENT-0" && contents(blocker) == "EXTERNAL", "rollback restores only this task's successful changes")
        let (_, blockedFiles, blockedReview, blockedEngine) = try batch("sequential-rollback-conflict")
        let blockedSession = try SequentialRenameSession(review: blockedReview, engine: blockedEngine)
        try await blockedSession.execute(0); try await blockedSession.execute(1)
        let foreign = try file(blockedFiles[0].deletingLastPathComponent(), blockedFiles[0].lastPathComponent, "FOREIGN")
        try await expectAsyncFailure("rollback refuses to overwrite a newly occupied original name") { try await blockedSession.rollback(0) }
        try await blockedSession.rollback(1)
        let remaining = await blockedSession.recordedIndices
        try check(remaining == [0] && contents(foreign) == "FOREIGN" && contents(blockedFiles[1]) == "CONTENT-1", "rollback continues other files and retains only failed recovery records")
        try fm.removeItem(at: foreign)
        try await blockedSession.rollback(0)
        try check(contents(blockedFiles[0]) == "CONTENT-0" && !blockedEngine.hasHistory, "failed rollback can be retried after the conflict is removed")
        let reservedDir = try directory("reserved-originals")
        let reservedA = try file(reservedDir, "source.txt", "A")
        let reservedB = try file(reservedDir, "20261017_153030.txt", "B")
        try fm.setAttributes([.creationDate: stamp], ofItemAtPath: reservedA.path)
        try fm.setAttributes([.creationDate: stamp.addingTimeInterval(1)], ofItemAtPath: reservedB.path)
        let reservedPlan = RenameEngine.plan([reservedA, reservedB], options: RenameOptions())
        try check(reservedPlan[0].target.lastPathComponent == "20261017_153030_a.txt", "planning reserves the original name of every pending selected file")
        let reservedSession = try SequentialRenameSession(review: RenameReview(items: reservedPlan, options: RenameOptions()), engine: engine(reservedDir))
        try await reservedSession.execute(0); try await reservedSession.finishKeepingResults()
        try check(contents(reservedB) == "B", "stopping cannot rename or displace a pending source used as another target")
        let (_, crashFiles, crashReview, crashEngine) = try batch("sequential-crash")
        let crashSession = try SequentialRenameSession(review: crashReview, engine: crashEngine)
        try await crashSession.execute(0)
        _ = try crashEngine.undo()
        try check(crashFiles.allSatisfy { fm.fileExists(atPath: $0.path) }, "persisted per-file history can recover an interrupted session after reopening")
        let caseDir = try directory("sequential-case")
        let caseSource = try file(caseDir, "img_20261017_153030.MOV", "CASE")
        try fm.setAttributes([.creationDate: stamp], ofItemAtPath: caseSource.path)
        let caseOptions = RenameOptions(settings: RenameSettings(pattern: "'IMG_'yyyyMMdd_HHmmss"))
        let caseReview = RenameReview(items: RenameEngine.plan([caseSource], options: caseOptions), options: caseOptions)
        let caseSession = try SequentialRenameSession(review: caseReview, engine: engine(caseDir))
        try await caseSession.execute(0)
        try check(fm.contentsOfDirectory(atPath: caseDir.path).contains("IMG_20261017_153030.MOV"), "per-file case-only rename reaches the exact intended spelling")
        try await caseSession.rollback(0)
        try check(fm.contentsOfDirectory(atPath: caseDir.path).contains("img_20261017_153030.MOV"), "per-file rollback restores the original case")
        @MainActor func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(15)
            while !condition() {
                guard Date() < deadline else { throw RenameError.message("Timed out waiting for task state") }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        @MainActor func verifyTaskControls() async throws {
            let (_, pauseFiles, pauseReview, pauseEngine) = try batch("task-pause")
            var activeStates: [Bool] = []
            let pausedTask = RenameTaskModel(review: pauseReview, engine: pauseEngine, onActive: { activeStates.append($0) })
            var requestedPause = false
            let pauseObserver = pausedTask.$rows.sink { rows in
                if !requestedPause && rows.first?.phase == .succeeded {
                    requestedPause = true; pausedTask.pause()
                }
            }
            try await waitUntil { pausedTask.canStart }
            pausedTask.start()
            try await waitUntil { pausedTask.phase == .paused }
            try check(pausedTask.successCount == 1 && pauseFiles.dropFirst().allSatisfy { fm.fileExists(atPath: $0.path) }, "task pause takes effect exactly after the current file")
            try await Task.sleep(nanoseconds: 30_000_000)
            try check(pausedTask.successCount == 1 && activeStates == [true], "paused task performs no further work and remains protected from closing")
            pausedTask.resume()
            try await waitUntil { pausedTask.phase.terminal && pausedTask.canClose }
            try check(pausedTask.phase == .completed && pausedTask.successCount == pauseFiles.count, "continue resumes the next pending file and marks each success")
            pausedTask.rollback()
            try await waitUntil { pausedTask.phase.terminal && pausedTask.canClose }
            try check(pausedTask.phase == .rolledBack && pausedTask.restoredCount == pauseFiles.count && pauseFiles.allSatisfy { fm.fileExists(atPath: $0.path) }, "completed task can roll back all files with per-row restored status")
            pauseObserver.cancel()
            let (_, cancelFiles, cancelReview, cancelEngine) = try batch("task-stop")
            var stoppedResult: RenameTaskResult?
            let stoppedTask = RenameTaskModel(review: cancelReview, engine: cancelEngine, onResult: { stoppedResult = $0 })
            var requestedStop = false
            let stopObserver = stoppedTask.$rows.sink { rows in
                if !requestedStop && rows.first?.phase == .succeeded { requestedStop = true; stoppedTask.stop() }
            }
            try await waitUntil { stoppedTask.canStart }
            stoppedTask.start()
            try await waitUntil { stoppedTask.phase.terminal && stoppedTask.canClose }
            try check(stoppedTask.phase == .stopped && stoppedTask.successCount == 1 && stoppedTask.rows.filter { $0.phase == .notExecuted }.count == cancelFiles.count - 1, "stop preserves the successful row and marks remaining rows unexecuted")
            try check(contents(cancelReview.changes[0].target) == "CONTENT-0" && cancelFiles.dropFirst().allSatisfy { fm.fileExists(atPath: $0.path) } && stoppedResult?.currentPaths[cancelFiles[0].path] == cancelReview.changes[0].target, "stopped task reports the actual mixed old and new filenames")
            stoppedTask.rollback()
            try await waitUntil { stoppedTask.phase.terminal && stoppedTask.canClose }
            try check(stoppedTask.phase == .rolledBack && cancelFiles.allSatisfy { fm.fileExists(atPath: $0.path) }, "stopped task can subsequently roll back only its completed prefix")
            stopObserver.cancel()
            let (_, rollbackFiles, rollbackReview, rollbackEngine) = try batch("task-stop-rollback")
            let rollbackTask = RenameTaskModel(review: rollbackReview, engine: rollbackEngine)
            var requestedRollback = false
            let rollbackObserver = rollbackTask.$rows.sink { rows in
                if !requestedRollback && rows.first?.phase == .succeeded { requestedRollback = true; rollbackTask.rollback() }
            }
            try await waitUntil { rollbackTask.canStart }
            rollbackTask.start()
            try await waitUntil { rollbackTask.phase.terminal && rollbackTask.canClose }
            try check(rollbackTask.phase == .rolledBack && rollbackTask.restoredCount == 1 && rollbackFiles.allSatisfy { fm.fileExists(atPath: $0.path) }, "stop-and-rollback request at a file boundary does not execute later files")
            rollbackObserver.cancel()
            let (retryDir, retryFiles, retryReview, retryEngine) = try batch("task-failure-retry")
            let retryTask = RenameTaskModel(review: retryReview, engine: retryEngine)
            var injected = false
            var retryBlocker: URL?
            let retryObserver = retryTask.$rows.sink { rows in
                if !injected && rows.count > 1 && rows[1].phase == .running {
                    injected = true
                    retryBlocker = try? file(retryDir, retryReview.changes[1].target.lastPathComponent, "BLOCK")
                }
            }
            try await waitUntil { retryTask.canStart }
            retryTask.start()
            try await waitUntil { retryTask.phase == .paused }
            try check(retryTask.failedFilePaused && retryTask.successCount == 1 && retryTask.failureCount == 1 && retryFiles.dropFirst().allSatisfy { fm.fileExists(atPath: $0.path) }, "a failed file automatically pauses while earlier successes remain")
            if let retryBlocker { try fm.removeItem(at: retryBlocker) }
            retryTask.resume()
            try await waitUntil { retryTask.phase.terminal && retryTask.canClose }
            try check(retryTask.phase == .completed && retryTask.failureCount == 0 && retryTask.successCount == retryFiles.count, "retry continues the same failed row after the conflict is removed")
            let conflict = try file(retryDir, retryFiles[0].lastPathComponent, "NEW OWNER")
            retryTask.rollback()
            try await waitUntil { retryTask.phase.terminal && retryTask.canClose }
            try check(retryTask.phase == .rollbackFailed && retryTask.failureCount == 1 && retryTask.restoredCount == retryFiles.count - 1 && retryEngine.hasHistory, "task rollback reports per-file failures while restoring the other files")
            try check(contents(conflict) == "NEW OWNER", "failed rollback never overwrites an external file")
            try fm.removeItem(at: conflict)
            retryTask.rollback()
            try await waitUntil { retryTask.phase.terminal && retryTask.canClose }
            try check(retryTask.phase == .rolledBack && retryTask.failureCount == 0 && retryFiles.allSatisfy { fm.fileExists(atPath: $0.path) }, "retry rollback restores only outstanding failed rows")
            retryObserver.cancel()
            let (_, earlyFiles, earlyReview, earlyEngine) = try batch("task-stop-preparing")
            let earlyTask = RenameTaskModel(review: earlyReview, engine: earlyEngine)
            try await waitUntil { earlyTask.canStart }
            earlyTask.start(); earlyTask.stop()
            try await waitUntil { earlyTask.phase.terminal && earlyTask.canClose }
            try check(earlyTask.phase == .stopped && earlyTask.successCount == 0 && earlyFiles.allSatisfy { fm.fileExists(atPath: $0.path) } && !earlyEngine.hasHistory, "stop requested during preflight prevents the first rename")
        }
        try await verifyTaskControls()
        @MainActor func verifyConfirmationValidation() async throws {
            let (_, files, review, worker) = try batch("confirmation-validation")
            var active: [Bool] = []
            let task = RenameTaskModel(review: review, engine: worker, onActive: { active.append($0) })
            try check(task.validating && !task.canStart && task.canClose, "entering confirmation automatically validates while allowing cancellation")
            task.start()
            try check(!task.started && task.successCount == 0 && active.isEmpty, "start cannot bypass an in-progress confirmation check")
            try await waitUntil { !task.validating }
            try check(task.canStart && task.validationResults.count == files.count && !worker.hasHistory && files.allSatisfy { fm.fileExists(atPath: $0.path) }, "passing confirmation validation enables start without modifying files or recovery records")
            let blocker = try file(files[0].deletingLastPathComponent(), review.changes[0].target.lastPathComponent, "LATE BLOCKER")
            task.validatePreview()
            try check(task.validating && !task.canStart && task.validationResults.isEmpty, "rechecking clears old passes and disables start immediately")
            try await waitUntil { !task.validating }
            try check(!task.canStart && task.validationIssues.contains { $0.status == .mismatch && $0.expected != nil }, "changed target availability blocks confirmation with the expected filename")
            task.start()
            try check(!task.started && files.allSatisfy { fm.fileExists(atPath: $0.path) } && contents(blocker) == "LATE BLOCKER", "failed confirmation validation cannot start a rename")
            try fm.removeItem(at: blocker)
            task.validatePreview()
            try await waitUntil { task.canStart }
            task.start()
            try await waitUntil { task.canClose }
            try check(task.phase == .completed && task.successCount == files.count, "rechecking after fixing a conflict allows the normal serial task")
            task.rollback(); try await waitUntil { task.canClose }

            let (_, staleFiles, staleReview, staleWorker) = try batch("confirmation-change-after-pass")
            let staleTask = RenameTaskModel(review: staleReview, engine: staleWorker)
            try await waitUntil { staleTask.canStart }
            let late = try file(staleFiles[0].deletingLastPathComponent(), staleReview.changes[0].target.lastPathComponent, "AFTER PASS")
            staleTask.start()
            try await waitUntil { staleTask.canClose }
            try check(staleTask.phase == .failed && staleTask.successCount == 0 && staleFiles.allSatisfy { fm.fileExists(atPath: $0.path) } && contents(late) == "AFTER PASS", "final preflight still rejects directory changes after the automatic check passed")

            let skippedDir = try directory("confirmation-skipped-file")
            let unchanged = try file(skippedDir, "20261017_153030.txt", "UNCHANGED")
            let pending = try file(skippedDir, "pending.txt", "PENDING")
            try fm.setAttributes([.creationDate: stamp], ofItemAtPath: unchanged.path)
            try fm.setAttributes([.creationDate: stamp.addingTimeInterval(1)], ofItemAtPath: pending.path)
            let skippedReview = RenameReview(items: RenameEngine.plan([unchanged, pending], options: RenameOptions()), options: RenameOptions())
            let skippedWorker = engine(skippedDir)
            let previous = RenameJournal(date: stamp, complete: true, entries: [])
            try skippedWorker.save(previous)
            let oldRecovery = try Data(contentsOf: skippedWorker.journalURL)
            let skippedTask = RenameTaskModel(review: skippedReview, engine: skippedWorker)
            try fm.removeItem(at: unchanged)
            try await waitUntil { !skippedTask.validating }
            try check(skippedTask.rows.count == 1 && skippedTask.validationResults.count == 2 && !skippedTask.canStart && skippedTask.validationIssues.contains { $0.item.source == unchanged && $0.status == .unavailable }, "automatic validation includes unchanged files outside the execution rows")
            skippedTask.start()
            try check(!skippedTask.started && contents(pending) == "PENDING" && Data(contentsOf: skippedWorker.journalURL) == oldRecovery, "a missing skipped file blocks execution and preserves preceding recovery history")
        }
        try await verifyConfirmationValidation()

        @MainActor func verifyIntervals() async throws {
            let (_, files, review, worker) = try batch("interval-pause", count: 2, interval: .milliseconds500)
            let task = RenameTaskModel(review: review, engine: worker)
            task.setExecutionInterval(.milliseconds100)
            try check(task.review.options.settings.executionInterval == .milliseconds100 && task.review.items.map(\.target) == review.items.map(\.target), "confirmation can adjust interval without changing confirmed filenames")
            task.setExecutionInterval(.milliseconds500)
            try await waitUntil { task.canStart }
            task.start()
            task.setExecutionInterval(.immediate)
            try check(task.review.options.settings.executionInterval == .milliseconds500, "starting freezes the interval used by execution and task records")
            try await waitUntil { task.waitingBetweenFiles }
            try check(task.successCount == 1 && task.rows[1].phase == .waiting, "interval begins only after a successful file, before the next file")
            try await Task.sleep(nanoseconds: 80_000_000)
            try check(task.successCount == 1 && task.waitingBetweenFiles, "configured interval really delays the next rename")
            let pauseTime = Date()
            task.pause()
            try await waitUntil { task.phase == .paused }
            try check(Date().timeIntervalSince(pauseTime) < 0.3 && !task.waitingBetweenFiles, "pause interrupts the 500 ms wait immediately")
            try await Task.sleep(nanoseconds: 550_000_000)
            try check(task.successCount == 1 && fm.fileExists(atPath: files[1].path), "paused timer never starts another file")
            let resumeTime = Date()
            task.resume()
            try await waitUntil { task.canClose }
            try check(task.phase == .completed && Date().timeIntervalSince(resumeTime) < 0.4, "resume processes the next file immediately with no trailing delay")
            task.rollback()
            try await waitUntil { task.canClose }
            try check(try files.enumerated().allSatisfy { try contents($0.element) == "CONTENT-\($0.offset)" }, "interval controls preserve file contents and rollback restores original names")

            for rollback in [false, true] {
                let (_, pending, review, worker) = try batch(rollback ? "interval-rollback" : "interval-stop", interval: .milliseconds500)
                let task = RenameTaskModel(review: review, engine: worker)
                try await waitUntil { task.canStart }
                task.start()
                try await waitUntil { task.waitingBetweenFiles }
                let requestTime = Date()
                if rollback { task.rollback() } else { task.stop() }
                try await waitUntil { task.canClose }
                try check(Date().timeIntervalSince(requestTime) < 0.3 && task.phase == (rollback ? .rolledBack : .stopped), "stop or rollback interrupts interval without waiting for the timer")
                try check(pending.dropFirst().allSatisfy { fm.fileExists(atPath: $0.path) } && (rollback ? task.restoredCount == 1 : task.successCount == 1), "stop or rollback during interval never renames pending files")
                if !rollback { task.rollback(); try await waitUntil { task.canClose } }
            }
            let (_, _, fastReview, fastWorker) = try batch("interval-zero", interval: .immediate)
            let fastTask = RenameTaskModel(review: fastReview, engine: fastWorker)
            var waited = false
            let observer = fastTask.$waitingBetweenFiles.sink { if $0 { waited = true } }
            try await waitUntil { fastTask.canStart }
            fastTask.start()
            try await waitUntil { fastTask.canClose }
            try check(fastTask.phase == .completed && fastTask.successCount == 4 && !waited, "zero interval completes serially without an artificial wait")
            observer.cancel()
            fastTask.rollback(); try await waitUntil { fastTask.canClose }
        }
        try await verifyIntervals()
        let validationDir = try directory("name-validation")
        let validationA = try file(validationDir, "first.JPG", "VALIDATION-A")
        let validationB = try file(validationDir, "second.JPG", "VALIDATION-B")
        for file in [validationA, validationB] { try fm.setAttributes([.creationDate: stamp], ofItemAtPath: file.path) }
        let validationPlan = RenameEngine.plan([validationA, validationB], options: RenameOptions())
        let validationSnapshot = NameValidationSnapshot(items: Array(validationPlan.reversed()), settings: RenameSettings())
        let initialNames = try fm.contentsOfDirectory(atPath: validationDir.path).sorted()
        let validRows = NameValidator.evaluate(validationSnapshot, pattern: DateNamingRule.defaultPattern)
        try check(validRows.count == 2 && validRows.allSatisfy { $0.status == .passed }, "second-pass validation checks exact letter suffixes and maps rows by source path")
        try check(validRows.allSatisfy { $0.information.created == stamp }, "validation displays freshly read creation timestamps beside each proposed name")
        let otherRule = NameValidator.evaluate(validationSnapshot, pattern: "yyyy-MM-dd_HH-mm-ss")
        try check(otherRule.allSatisfy { $0.status == .mismatch } && validationSnapshot.settings.pattern == DateNamingRule.defaultPattern, "alternate validation rule reports mismatch without changing preview or configuration")
        let invalidRows = NameValidator.evaluate(validationSnapshot, pattern: "yyyy/MM/dd")
        try check(invalidRows.allSatisfy { $0.status == .unavailable }, "invalid validation rules never produce passing rows")
        let numericOptions = RenameOptions(settings: RenameSettings(policy: .numbers))
        let numericValidation = NameValidationSnapshot(items: RenameEngine.plan([validationA, validationB], options: numericOptions), settings: numericOptions.settings)
        try check(NameValidator.evaluate(numericValidation, pattern: DateNamingRule.defaultPattern).allSatisfy { $0.status == .passed }, "second-pass validation also handles numeric collision suffixes")
        try check(fm.contentsOfDirectory(atPath: validationDir.path).sorted() == initialNames && contents(validationA) == "VALIDATION-A" && contents(validationB) == "VALIDATION-B", "validation leaves actual filenames and contents untouched")
        try fm.setAttributes([.creationDate: stamp.addingTimeInterval(10)], ofItemAtPath: validationA.path)
        try check(NameValidator.evaluate(validationSnapshot, pattern: DateNamingRule.defaultPattern).contains { $0.item.source == validationA && $0.status == .mismatch }, "a changed creation timestamp invalidates a frozen preview name")
        try fm.removeItem(at: validationB)
        try check(NameValidator.evaluate(validationSnapshot, pattern: DateNamingRule.defaultPattern).contains { $0.item.source == validationB && $0.status == .unavailable }, "missing files are explicitly unavailable rather than passing")
        @MainActor func verifyValidationEdits() async throws {
            let model = NameValidationModel(snapshot: validationSnapshot)
            model.recheck()
            model.pattern = "yyyy/MM/dd"; model.recheck()
            try await Task.sleep(nanoseconds: 300_000_000)
            try check(model.ruleError != nil && model.rows.isEmpty && !model.checking, "invalid edits immediately clear previous or pending validation results")
            model.pattern = DateNamingRule.defaultPattern; model.recheck()
            try await waitUntil { !model.checking }
            try check(model.rows.count == 2 && model.rows.contains { $0.status == .unavailable }, "valid edits recompute the current results without publishing stale passes")
            model.cancel()
        }
        try await verifyValidationEdits()

        let importDir = try directory("folder-import")
        let explicit = try file(importDir, "explicit.txt", "EXPLICIT")
        let nested = importDir.appendingPathComponent("nested", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try file(nested, "nested.txt", "NESTED")
        let grouped = try file(importDir, "grouped.txt", "GROUPED")
        _ = try file(importDir, ".hidden.txt", "HIDDEN")
        try fm.createSymbolicLink(at: importDir.appendingPathComponent("link.txt"), withDestinationURL: explicit)
        var selection = ImportSelection()
        let imported = selection.add([importDir, explicit])
        try check(imported.addedFolders == 1 && imported.addedFiles == 1 && selection.files == [explicit] && !selection.folders[0].includesFiles, "mixed file and folder import adds a folder group without expanding it")
        let duplicateImport = selection.add([explicit, importDir])
        try check(duplicateImport.addedFiles == 0 && duplicateImport.addedFolders == 0 && selection.folders.count == 1, "repeated drops do not duplicate groups or files")
        try selection.setIncludesFiles(true, folder: importDir)
        try check(Set(selection.files) == Set([explicit, grouped]) && selection.folders[0].members.count == 2, "checking a folder imports only top-level ordinary files, excluding hidden files, links and subfolders")
        try check(!selection.files.contains(importDir), "folder groups never enter the rename file list")
        try selection.setIncludesFiles(false, folder: importDir)
        try check(selection.files == [explicit], "unchecking a folder preserves a file that was explicitly dropped")
        try selection.setIncludesFiles(true, folder: importDir)
        selection.removeFile(grouped)
        try check(selection.files == [explicit] && !selection.folders[0].members.contains(grouped), "removing an imported file also updates its group membership")
        try selection.setIncludesFiles(false, folder: importDir)
        try selection.setIncludesFiles(true, folder: importDir)
        _ = selection.add([grouped])
        selection.removeFolder(importDir)
        try check(selection.folders.isEmpty && Set(selection.files) == Set([explicit, grouped]), "removing a group retains all separately added files, regardless of import order")
        var renameOwnership = ImportSelection()
        _ = renameOwnership.add([importDir]); try renameOwnership.setIncludesFiles(true, folder: importDir)
        let renamedPaths = Dictionary(uniqueKeysWithValues: renameOwnership.files.map { ($0.path, $0.deletingLastPathComponent().appendingPathComponent("renamed-" + $0.lastPathComponent)) })
        renameOwnership.files = renameOwnership.files.map { renamedPaths[$0.path]! }
        renameOwnership.remapOwnership(renamedPaths)
        try renameOwnership.setIncludesFiles(false, folder: importDir)
        try check(renameOwnership.files.isEmpty, "folder ownership follows renamed paths so unchecking removes the correct listed files")
        try check(contents(explicit) == "EXPLICIT" && contents(grouped) == "GROUPED" && contents(nested.appendingPathComponent("nested.txt")) == "NESTED", "grouping and toggling imports never modify any disk filename or content")
        print("All \(passes) checks passed. Temporary files removed on exit.")
    }
}
