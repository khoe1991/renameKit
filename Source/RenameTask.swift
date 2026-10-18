import Foundation
import Combine

enum RenameTaskPhase: String {
    case ready = "等待确认", preparing = "正在检查文件", running = "正在重命名"
    case pausing = "当前文件完成后暂停", paused = "已暂停"
    case stopping = "当前文件完成后停止", stoppingForRollback = "当前文件完成后回滚"
    case rollingBack = "正在回滚", completed = "全部完成", stopped = "已停止，保留已完成"
    case rolledBack = "已回滚", rollbackFailed = "回滚未全部完成", failed = "任务未完成"
    var terminal: Bool {
        switch self { case .completed, .stopped, .rolledBack, .rollbackFailed, .failed: return true; default: return false }
    }
}
enum RenameRowPhase: String {
    case waiting = "待执行", running = "执行中", succeeded = "成功", failed = "失败"
    case notExecuted = "未执行", rollingBack = "回滚中", rolledBack = "已恢复原名", rollbackFailed = "恢复失败"
}
struct RenameTaskRow: Identifiable {
    let item: RenameItem
    var phase: RenameRowPhase = .waiting
    var detail = ""
    var id: String { item.id }
}
struct RenameTaskResult {
    let currentPaths: [String: URL]
    let summary: String
}

@MainActor
final class RenameTaskModel: ObservableObject {
    @Published private(set) var phase = RenameTaskPhase.ready
    @Published private(set) var rows: [RenameTaskRow]
    @Published private(set) var detail = "核对名称后点击确认，才会开始修改。"
    @Published private(set) var started = false
    @Published private(set) var failedFilePaused = false
    @Published private(set) var review: RenameReview
    private let engine: RenameEngine
    private let onActive: (Bool) -> Void
    private let onResult: (RenameTaskResult) -> Void
    private enum Request { case run, pause, stop, rollback }
    private var request = Request.run
    private var session: SequentialRenameSession?
    private var cursor = 0
    private var intervalWait: Task<Void, Never>?
    @Published private(set) var waitingBetweenFiles = false
    @Published private(set) var driving = false
    @Published private(set) var validating = false
    @Published private(set) var validationResults: [String: NameValidationRow] = [:]
    private var validationJob: Task<Void, Never>?
    private var validationGeneration = 0
    init(review: RenameReview, engine: RenameEngine,
         onActive: @escaping (Bool) -> Void = { _ in }, onResult: @escaping (RenameTaskResult) -> Void = { _ in }) {
        self.review = review; self.engine = engine
        self.onActive = onActive; self.onResult = onResult
        rows = review.changes.map { RenameTaskRow(item: $0) }
        validatePreview()
    }
    var canStart: Bool {
        phase == .ready && !validating && !review.changes.isEmpty
            && validationResults.count == review.items.count
            && validationResults.values.allSatisfy { $0.status == .passed }
    }
    var validationIssues: [NameValidationRow] {
        review.items.compactMap { validationResults[$0.id] }.filter { $0.status != .passed }
    }
    func validatePreview() {
        guard phase == .ready else { return }
        validationJob?.cancel(); validationGeneration += 1
        let generation = validationGeneration
        validating = true; validationResults = [:]
        detail = "正在二次校验文件名和最新文件信息，请稍候……"
        let snapshot = NameValidationSnapshot(items: review.items, settings: review.options.settings)
        validationJob = Task {
            let result = await Task.detached(priority: .userInitiated) {
                NameValidator.evaluate(snapshot, pattern: snapshot.settings.pattern)
            }.value
            guard !Task.isCancelled, validationGeneration == generation, phase == .ready else { return }
            validationResults = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
            validating = false
            if canStart {
                detail = "二次校验全部通过。核对清单后，可点击“确认并开始”。"
            } else {
                detail = "二次校验未通过，暂不能执行。请核对下方原因；必要时取消并刷新主界面预览。"
            }
        }
    }
    func cancelValidation() {
        validationJob?.cancel(); validationGeneration += 1
    }
    var successCount: Int { rows.filter { $0.phase == .succeeded }.count }
    var failureCount: Int { rows.filter { $0.phase == .failed || $0.phase == .rollbackFailed }.count }
    var restoredCount: Int { rows.filter { $0.phase == .rolledBack }.count }
    var canClose: Bool { phase == .ready || (phase.terminal && !driving) }
    var canPause: Bool { phase == .running || phase == .preparing }
    var canStop: Bool { started && !phase.terminal && phase != .rollingBack && phase != .stopping && phase != .stoppingForRollback }
    var canRollback: Bool { started && (!phase.terminal || !driving) && phase != .rolledBack && session != nil && phase != .rollingBack && phase != .stoppingForRollback && (successCount > 0 || failureCount > 0 || !phase.terminal) }
    func setExecutionInterval(_ interval: ExecutionInterval) {
        guard phase == .ready else { return }
        var options = review.options
        options.settings.executionInterval = interval
        review = RenameReview(items: review.items, options: options)
    }
    func start() {
        guard canStart else { return }
        started = true; phase = .preparing; onActive(true)
        detail = "重新检查确认清单和恢复记录……"
        driving = true
        Task {
            do {
                let review = self.review, worker = engine
                session = try await Task.detached(priority: .userInitiated) {
                    try SequentialRenameSession(review: review, engine: worker)
                }.value
                driving = false
                scheduleDrive()
            } catch {
                phase = .failed; detail = error.localizedDescription
                for index in rows.indices { rows[index].phase = .notExecuted }
                await publishResult()
                driving = false
            }
        }
    }
    func pause() {
        guard canPause else { return }
        intervalWait?.cancel()
        request = .pause; phase = .pausing; detail = "正在等待当前文件处理完成。"
    }
    func resume() {
        guard phase == .paused else { return }
        request = .run; phase = .running
        if failedFilePaused, rows.indices.contains(cursor) {
            rows[cursor].phase = .waiting; rows[cursor].detail = ""
        }
        failedFilePaused = false
        scheduleDrive()
    }
    func stop() {
        guard canStop else { return }
        intervalWait?.cancel()
        request = .stop; phase = .stopping; detail = "停止后保留已完成的新名称，剩余文件不执行。"
        scheduleDrive()
    }
    func rollback() {
        guard canRollback else { return }
        intervalWait?.cancel()
        request = .rollback; phase = .stoppingForRollback
        detail = "正在等待当前文件完成，然后恢复本次已修改的名称。"
        onActive(true)
        scheduleDrive()
    }
    private func scheduleDrive() {
        guard !driving, session != nil else { return }
        driving = true
        Task { await drive() }
    }
    private func drive() async {
        guard let session else { driving = false; return }
        while true {
            switch request {
            case .pause:
                phase = .paused; detail = "已暂停，未执行的文件仍保留原名。"; driving = false; return
            case .stop:
                do {
                    try await session.finishKeepingResults()
                    phase = .stopped; detail = "已停止。已成功的 \(successCount) 个文件保留新名称。"
                } catch { phase = .failed; detail = error.localizedDescription }
                for index in rows.indices where rows[index].phase == .waiting { rows[index].phase = .notExecuted }
                await publishResult(); driving = false; return
            case .rollback:
                await performRollback(session)
                await publishResult(); driving = false; return
            case .run: break
            }
            guard cursor < rows.count else {
                do { try await session.finishKeepingResults(); phase = .completed; detail = "全部 \(successCount) 个文件已重命名成功。" }
                catch { phase = .failed; detail = error.localizedDescription }
                await publishResult(); driving = false; return
            }
            phase = .running
            rows[cursor].phase = .running
            detail = "正在处理第 \(cursor + 1) / \(rows.count) 个文件。"
            do {
                try await session.execute(cursor)
                rows[cursor].phase = .succeeded
                rows[cursor].detail = "已修改名称"
                cursor += 1
            } catch {
                rows[cursor].phase = .failed; rows[cursor].detail = error.localizedDescription
                // A stop/rollback requested during this file takes precedence over
                // automatic failure-pause. A normal failure retries this same row.
                if request != .stop && request != .rollback {
                    request = .pause; phase = .paused; failedFilePaused = true
                    detail = "文件处理失败，已暂停。可排除原因后重试，或停止 / 回滚。"
                    driving = false; return
                }
            }
            // Return control to SwiftUI after every individual file. The filesystem
            // operation itself is never interrupted halfway through a rename.
            await Task.yield()
            await waitBetweenFiles()
        }
    }
    private func waitBetweenFiles() async {
        let interval = review.options.settings.executionInterval
        guard request == .run, cursor < rows.count, interval != .immediate else { return }
        // Only the idle timer is cancellable. Never cancel a filesystem operation.
        let wait = Task<Void, Never> { try? await Task.sleep(nanoseconds: interval.nanoseconds) }
        intervalWait = wait
        waitingBetweenFiles = true
        detail = "已完成 \(successCount) / \(rows.count)，等待 \(interval.rawValue) 毫秒后处理下一项。"
        await wait.value
        intervalWait = nil
        waitingBetweenFiles = false
    }
    private func performRollback(_ session: SequentialRenameSession) async {
        phase = .rollingBack; detail = "逐个恢复本次已修改的文件名……"
        let indices = await session.recordedIndices.reversed()
        var errors = 0
        for index in indices {
            rows[index].phase = .rollingBack
            do {
                try await session.rollback(index)
                rows[index].phase = .rolledBack; rows[index].detail = "原名称已恢复"
            } catch {
                errors += 1; rows[index].phase = .rollbackFailed; rows[index].detail = error.localizedDescription
            }
            await Task.yield()
        }
        for index in rows.indices where rows[index].phase == .waiting { rows[index].phase = .notExecuted }
        if errors == 0 {
            phase = .rolledBack; detail = "本次已修改的名称已恢复。未执行的文件保持原名。"
        } else {
            phase = .rollbackFailed; detail = "\(errors) 个文件恢复失败，记录已保留。排除原因后可重试回滚。"
        }
    }
    private func publishResult() async {
        let paths: [String: URL]
        if let session { paths = await session.currentPaths() }
        else { paths = Dictionary(uniqueKeysWithValues: review.items.map { ($0.source.path, $0.source) }) }
        onActive(false)
        onResult(RenameTaskResult(currentPaths: paths, summary: detail))
    }
}
