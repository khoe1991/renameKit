import SwiftUI
import AppKit

enum PreviewFilter: String, CaseIterable, Identifiable {
    case all = "全部", changes = "待修改", unchanged = "名称不变", errors = "需处理"
    var id: String { rawValue }
    func includes(_ item: RenameItem) -> Bool {
        switch self {
        case .all: return true
        case .changes: return !item.error && item.changed
        case .unchanged: return !item.error && !item.changed
        case .errors: return item.error
        }
    }
}

/// NSTableView provides dynamic columns and horizontal scrolling on macOS 13,
/// without raising the application's deployment target.
struct FilePreviewTable: NSViewRepresentable {
    let items: [RenameItem]
    let information: [String: FileInformation]
    let visibleInformation: Set<FileInfoColumn>
    @Binding var selectedFile: URL?
    let policy: CollisionPolicy
    let onRemove: (URL) -> Void
    let onReveal: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.rowHeight = 26
        table.intercellSpacing = NSSize(width: 8, height: 2)
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsColumnResizing = true
        table.allowsColumnReordering = false
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.setAccessibilityLabel("重命名预览")
        let menu = NSMenu()
        menu.addItem(withTitle: "在 Finder 中显示", action: #selector(Coordinator.reveal), keyEquivalent: "").target = context.coordinator
        menu.addItem(withTitle: "从列表移除", action: #selector(Coordinator.remove), keyEquivalent: "").target = context.coordinator
        table.menu = menu
        context.coordinator.table = table
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = table
        context.coordinator.updateColumns()
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.synchronizingSelection = true
        coordinator.parent = self
        coordinator.updateColumns()
        if let table = coordinator.table {
            table.reloadData()
            if let selectedFile, let index = items.firstIndex(where: { $0.source == selectedFile }) {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            } else { table.deselectAll(nil) }
        }
        coordinator.synchronizingSelection = false
    }
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: FilePreviewTable
        weak var table: NSTableView?
        var synchronizingSelection = false
        init(_ parent: FilePreviewTable) { self.parent = parent }
        func updateColumns() {
            guard let table else { return }
            let fixed: [(String, String, Double)] = [("directory", "文件目录", 210), ("original", "原始名称", 175), ("target", "修改后名称", 195), ("status", "状态", 130)]
            let optional = FileInfoColumn.allCases.filter { parent.visibleInformation.contains($0) }
                .map { ($0.rawValue, $0.title, $0.preferredWidth) }
            let desired = fixed + optional
            let identifiers = desired.map { NSUserInterfaceItemIdentifier($0.0) }
            for column in table.tableColumns where !identifiers.contains(column.identifier) { table.removeTableColumn(column) }
            for (index, descriptor) in desired.enumerated() {
                let id = NSUserInterfaceItemIdentifier(descriptor.0)
                if !table.tableColumns.contains(where: { $0.identifier == id }) {
                    let column = NSTableColumn(identifier: id)
                    column.title = descriptor.1
                    column.width = descriptor.2
                    column.minWidth = descriptor.0 == "fileExtension" ? 65 : 90
                    column.maxWidth = 1800
                    column.isEditable = false
                    column.resizingMask = .userResizingMask
                    table.addTableColumn(column)
                }
                let current = table.column(withIdentifier: id)
                if current != index { table.moveColumn(current, toColumn: index) }
            }
        }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.items.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let column = tableColumn, parent.items.indices.contains(row) else { return nil }
            let item = parent.items[row]
            let cell = (tableView.makeView(withIdentifier: column.identifier, owner: nil) as? PreviewCell) ?? PreviewCell(identifier: column.identifier)
            let id = column.identifier.rawValue
            var text: String
            var help: String
            var symbol: String? = nil
            var color = NSColor.labelColor
            switch id {
            case "directory": text = item.source.deletingLastPathComponent().path; help = text
            case "original": text = item.source.lastPathComponent; help = text
            case "target":
                text = item.target.lastPathComponent
                help = text + "\n" + item.note
                color = item.error ? .systemOrange : item.changed ? .controlAccentColor : .secondaryLabelColor
                if item.error { symbol = "exclamationmark.triangle.fill" }
                else if item.note == "已自动避开冲突" { symbol = parent.policy == .letters ? "a.circle" : "number.circle" }
            case "status":
                if item.error {
                    text = "需处理"; symbol = "exclamationmark.triangle.fill"; color = .systemOrange
                    help = item.note
                } else if !item.changed {
                    text = "名称不变 · 跳过"; symbol = "minus.circle.fill"; color = .secondaryLabelColor
                    help = "原始名称与修改后名称完全相同，执行时会自动跳过，不会重复改名。"
                } else {
                    text = "待修改"; symbol = "arrow.right.circle"; color = .controlAccentColor
                    help = item.note
                }
            default:
                if let field = FileInfoColumn(rawValue: id) {
                    text = parent.information[item.source.path]?.text(for: field) ?? "—"
                } else { text = "—" }
                help = text
                color = .secondaryLabelColor
            }
            cell.configure(text: text, color: color, symbol: symbol, help: help)
            return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !synchronizingSelection, let table else { return }
            let index = table.selectedRow
            parent.selectedFile = parent.items.indices.contains(index) ? parent.items[index].source : nil
        }
        private var contextItem: RenameItem? {
            guard let row = table?.clickedRow, parent.items.indices.contains(row) else { return nil }
            return parent.items[row]
        }
        @objc func reveal() { if let item = contextItem { parent.onReveal(item.source) } }
        @objc func remove() { if let item = contextItem { parent.onRemove(item.source) } }
    }
}

final class PreviewCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var iconWidth: NSLayoutConstraint!
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label); addSubview(icon)
        textField = label
        imageView = icon
        iconWidth = icon.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            label.trailingAnchor.constraint(equalTo: icon.leadingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor), icon.heightAnchor.constraint(equalToConstant: 15), iconWidth
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(text: String, color: NSColor, symbol: String?, help: String) {
        label.stringValue = text
        label.textColor = color
        icon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: help) }
        icon.contentTintColor = color
        iconWidth.constant = symbol == nil ? 0 : 15
        toolTip = help
        setAccessibilityLabel(text)
    }
}
