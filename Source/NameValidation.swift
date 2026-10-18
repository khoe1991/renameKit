import Foundation
import Combine

struct NameValidationSnapshot: Identifiable {
    let id = UUID()
    let items: [RenameItem]
    let settings: RenameSettings
}
enum NameValidationStatus: String {
    case passed = "通过", mismatch = "不一致", unavailable = "无法校验"
}
struct NameValidationRow: Identifiable {
    let item: RenameItem
    let expected: String?
    let information: FileInformation
    let status: NameValidationStatus
    let detail: String
    var id: String { item.source.path }
}
/// A read-only second pass over fresh file URLs and the frozen preview names.
/// Collision suffixes are checked as part of the complete batch, not stripped off.
enum NameValidator {
    static func evaluate(_ snapshot: NameValidationSnapshot, pattern: String) -> [NameValidationRow] {
        var settings = snapshot.settings
        settings.pattern = pattern
        let freshFiles = snapshot.items.map { URL(fileURLWithPath: $0.source.path) }
        let fresh = RenameEngine.plan(freshFiles, options: RenameOptions(settings: settings))
        let byPath = Dictionary(uniqueKeysWithValues: fresh.map { ($0.source.path, $0) })
        return snapshot.items.map { item in
            let information = FileInformation.read(URL(fileURLWithPath: item.source.path))
            guard !item.error else {
                return NameValidationRow(item: item, expected: byPath[item.source.path]?.target.lastPathComponent,
                                         information: information, status: .unavailable, detail: "原预览存在错误：" + item.note)
            }
            guard let expected = byPath[item.source.path], !expected.error else {
                return NameValidationRow(item: item, expected: nil, information: information,
                                         status: .unavailable, detail: byPath[item.source.path]?.note ?? "无法读取文件信息。")
            }
            let matches = item.target.path == expected.target.path
            return NameValidationRow(item: item, expected: expected.target.lastPathComponent,
                                     information: information, status: matches ? .passed : .mismatch,
                                     detail: matches ? "与校验规则和最新文件信息一致。" : "预览名称与按校验规则重新计算的名称不同。请核对创建时间、规则和冲突后缀。")
        }
    }
}

@MainActor
final class NameValidationModel: ObservableObject {
    let snapshot: NameValidationSnapshot
    @Published var pattern: String
    @Published private(set) var rows: [NameValidationRow] = []
    @Published private(set) var checking = false
    private var job: Task<Void, Never>?
    init(snapshot: NameValidationSnapshot) {
        self.snapshot = snapshot; pattern = snapshot.settings.pattern
    }
    var ruleError: String? { DateNamingRule.validationError(pattern) }
    var passedCount: Int { rows.filter { $0.status == .passed }.count }
    var mismatchCount: Int { rows.filter { $0.status == .mismatch }.count }
    var unavailableCount: Int { rows.filter { $0.status == .unavailable }.count }
    func recheck() {
        job?.cancel()
        rows = []
        guard ruleError == nil else { checking = false; return }
        checking = true
        let input = snapshot, rule = pattern
        job = Task {
            do { try await Task.sleep(nanoseconds: 200_000_000) }
            catch { return }
            let result = await Task.detached(priority: .userInitiated) {
                NameValidator.evaluate(input, pattern: rule)
            }.value
            guard !Task.isCancelled else { return }
            rows = result; checking = false
        }
    }
    func cancel() { job?.cancel() }
}
