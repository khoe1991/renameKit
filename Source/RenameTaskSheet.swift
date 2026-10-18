import SwiftUI

struct RenameTaskSheet: View {
    @StateObject private var task: RenameTaskModel
    @State private var selectedRow: String?
    @State private var confirmRollback = false
    private let onIntervalChange: (ExecutionInterval) -> Void
    private let close: () -> Void
    init(review: RenameReview, engine: RenameEngine, onActive: @escaping (Bool) -> Void,
         onResult: @escaping (RenameTaskResult) -> Void, onIntervalChange: @escaping (ExecutionInterval) -> Void,
         close: @escaping () -> Void) {
        _task = StateObject(wrappedValue: RenameTaskModel(review: review, engine: engine, onActive: onActive, onResult: onResult))
        self.close = close; self.onIntervalChange = onIntervalChange
    }
    private var displayedError: RenameTaskRow? {
        let errors = task.rows.filter { $0.phase == .failed || $0.phase == .rollbackFailed }
        return errors.first { $0.id == selectedRow } ?? errors.first
    }
    private var displayedValidationIssue: NameValidationRow? {
        task.validationIssues.first { $0.id == selectedRow } ?? task.validationIssues.first
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(task.phase == .ready ? "确认重命名 \(task.rows.count) 个文件" : task.phase.rawValue)
                        .font(.title2.bold())
                    Spacer()
                    if task.started {
                        Text("成功 \(task.successCount) / 共 \(task.rows.count) · 失败 \(task.failureCount) · 已恢复 \(task.restoredCount)")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Text(task.detail).font(.subheadline).foregroundStyle(task.phase == .failed || task.phase == .rollbackFailed ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if task.phase == .ready {
                    HStack(spacing: 10) {
                        if task.validating {
                            ProgressView().controlSize(.small)
                            Text("二次校验中，完成前不能开始重命名。")
                        } else {
                            Label("校验通过 \(task.validationResults.count - task.validationIssues.count) / \(task.review.items.count)",
                                  systemImage: task.canStart ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(task.canStart ? Color.green : Color.orange)
                            Spacer()
                            Button("重新校验", action: task.validatePreview)
                        }
                    }.font(.caption)
                    if let issue = displayedValidationIssue {
                        Text(issue.item.source.lastPathComponent + "：" + issue.detail
                             + (issue.expected.map { " 应为：" + $0 } ?? ""))
                            .font(.caption).foregroundStyle(.orange).lineLimit(3)
                            .textSelection(.enabled).help(issue.item.source.path + "\n" + issue.detail)
                    }
                }
                if task.started {
                    Text("执行间隔：\(task.review.options.settings.executionInterval.title)").font(.caption).foregroundStyle(.secondary)
                }
                if task.phase == .ready {
                    let skipped = task.review.items.filter { !$0.error && !$0.changed }.count
                    if skipped > 0 {
                        Label("另有 \(skipped) 个文件名称不变，已自动跳过。", systemImage: "minus.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if task.phase == .ready, task.review.collisionCount > 0 {
                    Label("\(task.review.collisionCount) 项重名已自动追加后缀", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if task.started {
                    ProgressView(value: Double(task.successCount + task.restoredCount), total: Double(max(1, task.rows.count)))
                }
                if let error = displayedError {
                    Text(error.item.source.lastPathComponent + "：" + error.detail)
                        .font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled).help(error.detail)
                }
            }.padding(20)
            Divider()
            Table(task.rows, selection: $selectedRow) {
                TableColumn("原始名称") { row in
                    Text(row.item.source.lastPathComponent).lineLimit(1).truncationMode(.middle).help(row.item.source.lastPathComponent)
                }.width(min: 150, ideal: 225)
                TableColumn("修改后名称") { row in
                    Text(row.item.target.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(Color.accentColor).help(row.item.target.lastPathComponent)
                }.width(min: 180, ideal: 250)
                TableColumn("状态") { row in
                    if task.phase == .ready {
                        if task.validating {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("校验中")
                            }.font(.caption)
                        } else if let result = task.validationResults[row.id] {
                            Label(result.status == .passed ? "校验通过" : result.status.rawValue,
                                  systemImage: result.status == .passed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .font(.caption).foregroundStyle(result.status == .passed ? Color.green : Color.orange)
                                .help(result.detail + (result.expected.map { "\n应为：" + $0 } ?? ""))
                        } else { Text("待校验").font(.caption).foregroundStyle(.secondary) }
                    } else { RowStatusView(row: row) }
                }.width(min: 100, ideal: 130)
                TableColumn("文件目录") { row in
                    Text(row.item.source.deletingLastPathComponent().path).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary).help(row.item.source.deletingLastPathComponent().path)
                }.width(min: 150, ideal: 300)
            }
            Divider()
            HStack(spacing: 12) {
                if task.phase.terminal, task.canRollback {
                    Button {
                        confirmRollback = true
                    } label: {
                        Label(task.phase == .rollbackFailed ? "重试回滚…" : "回滚本次…", systemImage: "arrow.uturn.backward")
                    }.buttonStyle(.borderless).foregroundStyle(.secondary)
                    Divider().frame(height: 16)
                }
                Text("仅改文件名，保留内容和扩展名。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if task.phase == .ready {
                    Picker("执行间隔", selection: Binding(
                        get: { task.review.options.settings.executionInterval },
                        set: { interval in
                            task.setExecutionInterval(interval)
                            onIntervalChange(interval)
                        })) {
                        ForEach(ExecutionInterval.allCases) { interval in
                            Text(interval.title).tag(interval)
                        }
                    }.frame(width: 220)
                        .help("两个文件之间的等待时间；暂停、停止和回滚可立即打断等待。")
                    Button("取消", action: close).keyboardShortcut(.cancelAction)
                    Button("确认并开始", action: task.start).buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction).disabled(!task.canStart)
                } else if task.phase.terminal {
                    Button("关闭", action: close)
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(!task.canClose)
                } else {
                    if task.phase == .paused {
                        Button(task.failedFilePaused ? "重试并继续" : "继续", action: task.resume)
                            .buttonStyle(.borderedProminent)
                    } else if task.phase != .rollingBack {
                        Button(task.phase == .pausing ? "正在暂停…" : "暂停", action: task.pause)
                            .disabled(!task.canPause)
                    }
                    Button("停止，保留已完成", action: task.stop).disabled(!task.canStop)
                    Button("停止并回滚", action: task.rollback).disabled(!task.canRollback)
                }
            }.padding(18)
        }.frame(minWidth: 700, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
            .interactiveDismissDisabled(!task.canClose)
            .onDisappear { task.cancelValidation() }
            .onExitCommand {
                if task.canClose, !confirmRollback { close() }
            }
            .alert("将本次文件恢复为原名称？", isPresented: $confirmRollback) {
                Button("保留当前名称", role: .cancel) {}
                Button("确认回滚", role: .destructive) {
                    if task.canRollback { task.rollback() }
                }
            } message: {
                Text("将按记录把本次已修改的文件名恢复为原名。点击“保留当前名称”可取消回滚。")
            }
    }
}
private struct RowStatusView: View {
    let row: RenameTaskRow
    private var color: Color {
        switch row.phase {
        case .succeeded: return .green
        case .failed, .rollbackFailed: return .red
        case .rolledBack: return .blue
        case .running, .rollingBack: return .accentColor
        case .waiting, .notExecuted: return .secondary
        }
    }
    private var symbol: String {
        switch row.phase {
        case .succeeded: return "checkmark.circle.fill"
        case .failed, .rollbackFailed: return "xmark.circle.fill"
        case .rolledBack: return "arrow.uturn.backward.circle.fill"
        case .notExecuted: return "minus.circle"
        default: return "circle"
        }
    }
    var body: some View {
        HStack(spacing: 6) {
            if row.phase == .running || row.phase == .rollingBack {
                ProgressView().controlSize(.small).frame(width: 13, height: 13)
            } else { Image(systemName: symbol).frame(width: 13) }
            Text(row.phase.rawValue).lineLimit(1)
        }.font(.caption).foregroundStyle(color)
            .help(row.detail.isEmpty ? row.phase.rawValue : row.detail)
    }
}
