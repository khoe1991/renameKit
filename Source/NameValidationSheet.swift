import SwiftUI
import AppKit

struct NameValidationSheet: View {
    @StateObject private var model: NameValidationModel
    @State private var columns: Set<FileInfoColumn>
    @State private var issuesOnly = false
    let close: () -> Void
    init(snapshot: NameValidationSnapshot, close: @escaping () -> Void) {
        _model = StateObject(wrappedValue: NameValidationModel(snapshot: snapshot))
        _columns = State(initialValue: snapshot.settings.visibleInformation.union([.created]))
        self.close = close
    }
    private var ruleEditor: some View {
        HStack(spacing: 10) {
            Text("校验规则")
            TextField("yyyyMMdd_HHmmss", text: $model.pattern)
                .font(.system(.body, design: .monospaced)).textFieldStyle(.roundedBorder).frame(width: 250)
                .accessibilityLabel("校验规则")
            Menu("选择规则") {
                Button("使用预览中的规则") { model.pattern = model.snapshot.settings.pattern }
                Divider()
                ForEach(["yyyyMMdd_HHmmss", "yyyy-MM-dd_HH-mm-ss", "yyyy年MM月dd日 HH时mm分ss秒"], id: \.self) { pattern in
                    Button(pattern) { model.pattern = pattern }
                }
            }.fixedSize()
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("文件名校验").font(.title2.bold())
                    Spacer()
                    Menu("文件信息") {
                        ForEach(FileInfoColumn.allCases) { column in
                            Toggle(column.menuTitle, isOn: Binding(
                                get: { columns.contains(column) },
                                set: { if $0 { columns.insert(column) } else { columns.remove(column) } }))
                        }
                    }.fixedSize()
                    Button("重新校验") { model.recheck() }.disabled(model.checking || model.ruleError != nil)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        ruleEditor
                        Spacer(minLength: 8)
                        Toggle("只看不一致 / 无法校验", isOn: $issuesOnly).toggleStyle(.checkbox).fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        ruleEditor
                        Toggle("只看不一致 / 无法校验", isOn: $issuesOnly).toggleStyle(.checkbox)
                    }
                }
                if let error = model.ruleError {
                    Label(error, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red).font(.caption)
                } else if model.checking {
                    HStack { ProgressView().controlSize(.small); Text("正在重新读取文件信息并比对预览名称……").font(.caption) }
                } else {
                    HStack(spacing: 16) {
                        Text("通过 \(model.passedCount)").foregroundStyle(.green)
                        Text("不一致 \(model.mismatchCount)").foregroundStyle(.orange)
                        Text("无法校验 \(model.unavailableCount)").foregroundStyle(model.unavailableCount > 0 ? Color.red : Color.secondary)
                        Spacer()
                        Text("来源：文件创建时间 · 时区：\(TimeZone.current.identifier)").foregroundStyle(.secondary)
                    }.font(.caption)
                }
                Text("校验规则只用于比对；命名规则需在主界面调整。重名后缀按预览使用的冲突策略一起校验。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(20)
            Divider()
            ValidationTable(rows: issuesOnly ? model.rows.filter { $0.status != .passed } : model.rows,
                            columns: columns)
            Divider()
            HStack {
                Text("仅读取文件信息，不修改文件名或内容。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("关闭", action: close).keyboardShortcut(.cancelAction)
            }.padding(18)
        }.frame(minWidth: 700, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
            .onAppear { model.recheck() }
            .onChange(of: model.pattern) { _ in model.recheck() }
            .onDisappear { model.cancel() }
    }
}

private struct ValidationTable: NSViewRepresentable {
    let rows: [NameValidationRow]
    let columns: Set<FileInfoColumn>
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.rowHeight = 28; table.intercellSpacing = NSSize(width: 8, height: 2)
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsColumnResizing = true; table.allowsColumnReordering = false
        table.setAccessibilityLabel("文件名校验列表")
        context.coordinator.table = table
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.documentView = table
        context.coordinator.updateColumns()
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updateColumns(); context.coordinator.table?.reloadData()
    }
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: ValidationTable
        weak var table: NSTableView?
        init(_ parent: ValidationTable) { self.parent = parent }
        func updateColumns() {
            guard let table else { return }
            let fixed: [(String, String, Double)] = [("proposed", "修改后的名称（预览）", 250), ("result", "校验结果", 100), ("expected", "按校验规则应为", 250)]
            let desired = fixed + FileInfoColumn.allCases.filter { parent.columns.contains($0) }.map { ($0.rawValue, $0.menuTitle, $0.preferredWidth) }
            let ids = desired.map { NSUserInterfaceItemIdentifier($0.0) }
            for column in table.tableColumns where !ids.contains(column.identifier) { table.removeTableColumn(column) }
            for (index, descriptor) in desired.enumerated() {
                let id = NSUserInterfaceItemIdentifier(descriptor.0)
                if !table.tableColumns.contains(where: { $0.identifier == id }) {
                    let column = NSTableColumn(identifier: id)
                    column.title = descriptor.1; column.width = descriptor.2
                    column.minWidth = 80; column.maxWidth = 1800
                    column.isEditable = false; column.resizingMask = .userResizingMask
                    table.addTableColumn(column)
                }
                let current = table.column(withIdentifier: id)
                if current != index { table.moveColumn(current, toColumn: index) }
            }
        }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.rows.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let column = tableColumn, parent.rows.indices.contains(row) else { return nil }
            let item = parent.rows[row]
            let cell = (tableView.makeView(withIdentifier: column.identifier, owner: nil) as? PreviewCell) ?? PreviewCell(identifier: column.identifier)
            let text: String
            var color = NSColor.labelColor
            switch column.identifier.rawValue {
            case "proposed": text = item.item.target.lastPathComponent
            case "result":
                text = item.status.rawValue
                color = item.status == .passed ? .systemGreen : item.status == .mismatch ? .systemOrange : .systemRed
            case "expected": text = item.expected ?? "—"
            default:
                text = FileInfoColumn(rawValue: column.identifier.rawValue).map { item.information.text(for: $0) } ?? "—"
                color = .secondaryLabelColor
            }
            cell.configure(text: text, color: color, symbol: nil,
                           help: text + "\n" + item.detail + "\n原文件：" + item.item.source.path)
            return cell
        }
    }
}
