import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class RenameModel: ObservableObject {
    @Published private var imports = ImportSelection()
    var files: [URL] {
        get { imports.files }
        set { imports.files = newValue }
    }
    var folders: [FolderImportGroup] { imports.folders }
    @Published private(set) var importingFolders = Set<String>()
    private var folderRequests: [String: UUID] = [:]
    @Published var preview: [RenameItem] = []
    @Published var information: [String: FileInformation] = [:]
    @Published var settings = RenameSettings()
    @Published var busy = false
    @Published var message = "添加文件后，先预览，再执行。"
    @Published var alertText: String?
    @Published var hasHistory = false
    private var previewTask: Task<Void, Never>?
    private var revision = 0
    let engine: RenameEngine
    let settingsStore: RenameSettingsStore
    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        engine = RenameEngine(journalURL: support.appendingPathComponent("RenameKit/last-operation.json"))
        settingsStore = RenameSettingsStore(url: support.appendingPathComponent("RenameKit/settings.json"))
        if FileManager.default.fileExists(atPath: settingsStore.url.path) {
            do { settings = try settingsStore.load() }
            catch { alertText = "设置读取失败，已载入默认规则。原设置文件未修改：\(error.localizedDescription)" }
        }
        hasHistory = engine.hasHistory
        if hasHistory {
            if let journal = try? engine.readJournal(), !journal.complete {
                message = "检测到未完成的操作，请先点击“撤销 / 恢复”。"
            } else {
                message = "上次重命名的记录已保留，可点击“撤销 / 恢复”。"
            }
        }
    }
    var options: RenameOptions { RenameOptions(settings: settings) }
    var ruleError: String? { settings.validationError }
    var ruleExample: String {
        (try? DateNamingRule(settings.pattern).string(from: DateNamingRule.referenceDate)) ?? "—"
    }
    func saveSettings() {
        do { try settingsStore.save(settings) }
        catch { alertText = "设置保存失败：\(error.localizedDescription)" }
    }
    func settingsChanged() { saveSettings(); refresh() }
    func review() -> RenameReview? {
        guard canApply else { return nil }
        return RenameReview(items: preview, options: options)
    }
    var errorCount: Int { preview.filter(\.error).count }
    var resolvedCollisionCount: Int { preview.filter { !$0.error && $0.note == "已自动避开冲突" }.count }
    var changeCount: Int { preview.filter { !$0.error && $0.changed }.count }
    var canApply: Bool { !busy && importingFolders.isEmpty && ruleError == nil && errorCount == 0 && changeCount > 0 && preview.count == files.count }
    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = "选择要重命名的文件或文件夹"
        panel.prompt = "添加"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if let window = NSApplication.shared.keyWindow {
            panel.beginSheetModal(for: window) { [weak self] response in
                if response == .OK { self?.add(panel.urls) }
            }
        } else {
            panel.begin { [weak self] response in
                if response == .OK { self?.add(panel.urls) }
            }
        }
    }
    func add(_ urls: [URL]) {
        guard !busy else { return }
        let report = imports.add(urls)
        message = "已添加 \(report.addedFiles) 个文件、\(report.addedFolders) 个文件夹分组。"
            + (report.skipped > 0 ? "已跳过 \(report.skipped) 个链接或不支持的项目。" : "")
        if !report.errors.isEmpty { alertText = report.errors.joined(separator: "\n") }
        refresh()
    }
    func setFolderImport(_ url: URL, included: Bool) {
        guard !busy else { return }
        if !included {
            folderRequests.removeValue(forKey: url.path); importingFolders.remove(url.path)
            do {
                try imports.setIncludesFiles(false, folder: url)
                message = "已取消导入该分组文件，单独添加的文件仍保留。"
                refresh()
            }
            catch { alertText = error.localizedDescription }
            return
        }
        guard !importingFolders.contains(url.path), folders.contains(where: { $0.id == url.path }) else { return }
        let request = UUID()
        folderRequests[url.path] = request; importingFolders.insert(url.path)
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try ImportSelection.readFolderFiles(url) }
            }.value
            guard folderRequests[url.path] == request else { return }
            folderRequests.removeValue(forKey: url.path); importingFolders.remove(url.path)
            guard folders.contains(where: { $0.id == url.path }) else { return }
            switch result {
            case .success(let candidates):
                do {
                    try imports.setIncludesFiles(true, folder: url, candidates: candidates)
                    message = "已导入文件夹本层文件，文件夹名不会修改。"
                    refresh()
                } catch { alertText = error.localizedDescription }
            case .failure(let error): alertText = "无法读取文件夹：\(error.localizedDescription)"
            }
        }
    }
    func removeFolder(_ url: URL) {
        guard !busy else { return }
        folderRequests.removeValue(forKey: url.path); importingFolders.remove(url.path)
        imports.removeFolder(url)
        message = "已移出文件夹分组，单独添加的文件仍保留。"
        refresh()
    }
    func remove(_ url: URL) { guard !busy else { return }; imports.removeFile(url); refresh() }
    func clear() {
        guard !busy else { return }
        folderRequests.removeAll(); importingFolders = []
        imports = ImportSelection(); information = [:]; refresh(); message = "列表已清空，磁盘文件不受影响。"
    }
    func refresh() {
        guard !busy else { return }
        previewTask?.cancel()
        revision += 1
        let expected = revision
        let input = files, settings = options
        preview = []
        previewTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
                let plan = RenameEngine.plan(input, options: settings)
                let info = Dictionary(uniqueKeysWithValues: input.map { ($0.path, FileInformation.read($0)) })
                return (plan, info)
            }.value
            guard !Task.isCancelled, revision == expected else { return }
            information = result.1
            preview = result.0
        }
    }
    func setTaskActive(_ active: Bool) {
        busy = active
        AppDelegate.operationInProgress = active
        for window in NSApplication.shared.windows {
            window.standardWindowButton(.closeButton)?.isEnabled = !active
        }
    }
    func acceptTaskResult(_ result: RenameTaskResult, review: RenameReview) {
        files = review.items.map { result.currentPaths[$0.source.path] ?? $0.source }
        imports.remapOwnership(result.currentPaths)
        var updated: [String: FileInformation] = [:]
        for item in review.items {
            let current = result.currentPaths[item.source.path] ?? item.source
            updated[current.path] = information[item.source.path] ?? FileInformation.read(current)
        }
        information = updated
        preview = files.map { RenameItem(source: $0, target: $0, note: "当前名称", error: false) }
        hasHistory = engine.hasHistory
        message = result.summary
    }
    func undo() {
        guard !busy, importingFolders.isEmpty, hasHistory else { return }
        busy = true
        AppDelegate.operationInProgress = true
        let worker = engine
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<(Int, [URL], [String: FileInformation], [String: URL]), Error> in
                Result {
                    let journal = try worker.readJournal()
                    let count = try worker.undo()
                    let restored = journal.entries.map { URL(fileURLWithPath: $0.source) }
                    let info = Dictionary(uniqueKeysWithValues: restored.map { ($0.path, FileInformation.read($0)) })
                    var paths: [String: URL] = [:]
                    for entry in journal.entries {
                        paths[entry.target] = URL(fileURLWithPath: entry.source)
                        if !entry.temporary.isEmpty { paths[entry.temporary] = URL(fileURLWithPath: entry.source) }
                    }
                    return (count, restored, info, paths)
                }
            }.value
            busy = false
            AppDelegate.operationInProgress = false
            hasHistory = engine.hasHistory
            switch result {
            case .success(let (count, restored, info, paths)):
                files = restored
                imports.remapOwnership(paths)
                information = info
                preview = restored.map { RenameItem(source: $0, target: $0, note: "已恢复原名称", error: false) }
                message = "已恢复 \(count) 个文件的原名称。"
            case .failure(let error): alertText = error.localizedDescription; message = "恢复未完成，记录已保留。"
            }
        }
    }
}

struct RenameView: View {
    @StateObject private var model = RenameModel()
    @State private var pendingReview: RenameReview?
    @State private var pendingValidation: NameValidationSnapshot?
    @State private var previewFilter = PreviewFilter.all
    @State private var selectedFolder: URL?
    @State private var selectedPreviewFile: URL?
    @State private var confirmUndo = false
    @State private var dropTargeted = false
    @State private var showSettings = true
    @State private var sidebarEdgeHovered = false
    @State private var windowSize = CGSize(width: 1000, height: 640)
    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 960
            VStack(alignment: .leading, spacing: 0) {
                header(compact: compact)
                Divider()
                ZStack(alignment: .leading) {
                    HStack(alignment: .top, spacing: 0) {
                        if showSettings && !compact {
                            settingsSidebar
                                .transition(.move(edge: .leading).combined(with: .opacity))
                            Divider()
                        } else if !showSettings {
                            sidebarRevealButton
                        }
                        previewPane(folderHeight: geometry.size.height < 640 ? 66 : 132)
                    }
                    if compact && showSettings {
                        settingsSidebar
                            .background(Color(nsColor: .windowBackgroundColor))
                            .overlay(alignment: .trailing) { Divider() }
                            .shadow(color: .black.opacity(0.15), radius: 8, x: 4)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
                .clipped()
                .animation(.easeInOut(duration: 0.2), value: showSettings)
                Divider()
                footer
            }
            .onAppear {
                windowSize = geometry.size
                if compact { showSettings = false }
            }
            .onChange(of: geometry.size) { size in
                if windowSize.width >= 960 && size.width < 960 { showSettings = false }
                windowSize = size
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.files) { files in
            if let selectedPreviewFile, !files.contains(selectedPreviewFile) { self.selectedPreviewFile = nil }
        }
        .onChange(of: filteredPreview.map(\.id)) { paths in
            if !model.preview.isEmpty, let selectedPreviewFile, !paths.contains(selectedPreviewFile.path) {
                self.selectedPreviewFile = nil
            }
        }
        .onChange(of: selectedPreviewFile) { file in
            if file != nil { selectedFolder = nil }
        }
        .onChange(of: model.folders.map(\.id)) { paths in
            if let selectedFolder, !paths.contains(selectedFolder.path) { self.selectedFolder = nil }
        }
        .onChange(of: model.settings.pattern) { _ in model.settingsChanged() }
        .onChange(of: model.settings.policy) { _ in model.settingsChanged() }
        .onChange(of: model.settings.executionInterval) { _ in model.saveSettings() }
        .onChange(of: model.settings.visibleInformation) { _ in model.saveSettings() }
        .sheet(item: $pendingReview) { review in
            RenameTaskSheet(review: review, engine: model.engine,
                            onActive: { model.setTaskActive($0) },
                            onResult: { model.acceptTaskResult($0, review: review) },
                            onIntervalChange: { model.settings.executionInterval = $0 },
                            close: { pendingReview = nil })
                .frame(width: min(1000, max(720, windowSize.width - 24)),
                       height: min(600, max(420, windowSize.height - 50)))
        }
        .sheet(item: $pendingValidation) { snapshot in
            NameValidationSheet(snapshot: snapshot, close: { pendingValidation = nil })
                .frame(width: min(1100, max(720, windowSize.width - 24)),
                       height: min(620, max(420, windowSize.height - 50)))
        }
        .alert("操作提示", isPresented: Binding(get: { model.alertText != nil }, set: { if !$0 { model.alertText = nil } })) {
            Button("知道了", role: .cancel) { model.alertText = nil }
        } message: { Text(model.alertText ?? "") }
        .alert("恢复上一批文件的原名称？", isPresented: $confirmUndo) {
            Button("取消", role: .cancel) {}
            Button("撤销 / 恢复") { model.undo() }
        } message: { Text("如果恢复位置已被其他文件占用，软件会提示并保留恢复记录。") }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTargeted) { providers in
            guard !model.busy, pendingReview == nil else { return false }
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.add([url]) }
                }
            }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [9])).padding(8).allowsHitTesting(false)
            }
        }
    }
    private func header(compact: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "character.cursor.ibeam").font(.system(size: 21, weight: .medium)).foregroundStyle(.blue)
                .frame(width: 36, height: 36).background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text("轻改名").font(.title3.bold())
                if !compact { Text("本地批量重命名 · 预览后执行").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            Button { model.chooseFiles() } label: { Label("添加文件 / 文件夹", systemImage: "plus") }
                .keyboardShortcut("o", modifiers: .command).disabled(model.busy)
            Button("刷新预览") { model.refresh() }.disabled(model.busy || model.files.isEmpty)
            Button("清空列表") { model.clear() }.disabled(model.busy || (model.files.isEmpty && model.folders.isEmpty))
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }
    private var settingsSidebar: some View {
        ScrollView { controls }
            .frame(width: 270)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .trailing) {
                Button { showSettings = false } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 20, height: 54)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("收起左侧设置")
                .help("收起到左侧边缘，点击同一高度的右箭头可展开。")
            }
    }
    private var sidebarRevealButton: some View {
        Button {
            sidebarEdgeHovered = false
            showSettings = true
        } label: {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 20, height: 54)
                    .background(sidebarEdgeHovered ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 6))
                Spacer(minLength: 0)
            }
            .frame(width: 22)
            .frame(maxHeight: .infinity)
            .foregroundStyle(sidebarEdgeHovered ? Color.accentColor : Color.secondary)
            .background(sidebarEdgeHovered ? Color.accentColor.opacity(0.05) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { sidebarEdgeHovered = $0 }
        .accessibilityLabel("展开左侧设置")
        .help("点击向右展开命名设置。")
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("命名设置").font(.headline)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("命名方案").font(.headline)
                Picker("命名方案", selection: .constant("creation")) {
                    Text("文件创建时间（日期 时分秒）").tag("creation")
                }.labelsHidden()
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("命名规则").font(.headline)
                    Spacer()
                    Button("恢复默认") { model.settings.pattern = DateNamingRule.defaultPattern }
                        .font(.caption).buttonStyle(.borderless)
                }
                TextField("yyyyMMdd_HHmmss", text: $model.settings.pattern)
                    .font(.system(.body, design: .monospaced)).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("命名规则")
            }
            ruleValidation
            Text("yyyy 年 · MM 月 · dd 日\nHH 时 · mm 分 · ss 秒\nmmm 为英文月份简称，例如 Oct")
                .font(.caption).foregroundStyle(.secondary).lineSpacing(4)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("遇到重名时").font(.headline)
                Picker("冲突处理", selection: $model.settings.policy) {
                    Text("提示").tag(CollisionPolicy.ask)
                    Text("加数字").tag(CollisionPolicy.numbers)
                    Text("加字母").tag(CollisionPolicy.letters)
                }.pickerStyle(.segmented).labelsHidden()
                Text("只给冲突文件追加 _a、_b 或 _1、_2。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Label("保留扩展名，不覆盖已有文件", systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).disabled(model.busy)
    }
    private var ruleValidation: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(model.ruleError == nil ? "规则验证通过" : "规则有误",
                  systemImage: model.ruleError == nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(model.ruleError == nil ? Color.green : Color.red)
            if let error = model.ruleError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(model.ruleExample).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Text("示例：2026-10-17 15:30:30").font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background((model.ruleError == nil ? Color.green : Color.red).opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
    private func folderGroups(maxHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("文件夹分组 · 不修改文件夹名").font(.subheadline.weight(.medium))
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.folders) { group in
                        HStack(spacing: 12) {
                            Image(systemName: "folder.fill").foregroundStyle(.blue).font(.title2)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(group.url.lastPathComponent).font(.subheadline.weight(.semibold))
                                Text(group.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            if model.importingFolders.contains(group.id) {
                                ProgressView().controlSize(.small)
                                Text("正在读取…").font(.caption).foregroundStyle(.secondary)
                            }
                            if group.includesFiles { Text("\(group.members.count) 个文件").font(.caption).foregroundStyle(.secondary) }
                            Toggle("导入内部文件", isOn: Binding(
                                get: { group.includesFiles },
                                set: { model.setFolderImport(group.url, included: $0) }))
                                .toggleStyle(.checkbox).fixedSize().disabled(model.busy || model.importingFolders.contains(group.id))
                        }.padding(10).frame(maxWidth: .infinity)
                            .background(selectedFolder == group.url ? Color.accentColor.opacity(0.12) : Color.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                            .onTapGesture { selectedPreviewFile = nil; selectedFolder = group.url }
                    }
                }
            }.frame(height: min(CGFloat(model.folders.count) * 66, maxHeight))
            Text("默认不导入；勾选后只读取本层普通文件，不递归子文件夹。").font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 20).padding(.bottom, 14)
    }
    private var filteredPreview: [RenameItem] { model.preview.filter { previewFilter.includes($0) } }
    private func previewCount(_ filter: PreviewFilter) -> Int { model.preview.filter { filter.includes($0) }.count }
    private func previewPane(folderHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("重命名预览").font(.headline)
                Spacer()
                Text("\(model.files.count) 个文件 · \(model.folders.count) 个文件夹").font(.subheadline).foregroundStyle(.secondary)
                Button {
                    pendingValidation = NameValidationSnapshot(items: model.preview, settings: model.settings)
                } label: { Label("校验", systemImage: "checkmark.magnifyingglass") }
                    .disabled(model.busy || model.preview.isEmpty || model.preview.count != model.files.count)
                Menu {
                    ForEach(FileInfoColumn.allCases) { field in
                        Toggle(field.menuTitle, isOn: Binding(
                            get: { model.settings.visibleInformation.contains(field) },
                            set: { shown in
                                if shown { model.settings.visibleInformation.insert(field) }
                                else { model.settings.visibleInformation.remove(field) }
                            }))
                    }
                    Divider()
                    Button("恢复默认列") { model.settings.visibleInformation = [.created] }
                } label: { Label("文件信息", systemImage: "line.3.horizontal.decrease.circle") }

            }.padding(.horizontal, 16).padding(.vertical, 12)
            if model.errorCount > 0 || model.resolvedCollisionCount > 0 {
                HStack(spacing: 14) {
                    if model.errorCount > 0 {
                        Label("需处理 \(model.errorCount) 项", systemImage: "exclamationmark.triangle.fill")
                    }
                    if model.resolvedCollisionCount > 0 {
                        Label("重名已避让 \(model.resolvedCollisionCount) 项", systemImage: "checkmark.shield")
                    }
                }.font(.caption).foregroundStyle(.orange).padding(.horizontal, 16).padding(.bottom, 8)
            }
            if !model.folders.isEmpty { folderGroups(maxHeight: folderHeight) }
            if !model.preview.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Picker("预览筛选", selection: $previewFilter) {
                        ForEach(PreviewFilter.allCases) { filter in
                            Text("\(filter.rawValue) \(previewCount(filter))").tag(filter)
                        }
                    }.pickerStyle(.segmented).labelsHidden()
                    Text("名称不变项自动跳过；筛选仅影响显示，不改变本次执行范围。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 20).padding(.bottom, 12)
            }
            if model.files.isEmpty {
                Spacer()
                VStack(spacing: 14) {
                    Image(systemName: "doc.on.doc").font(.system(size: 42, weight: .light)).foregroundStyle(.secondary)
                    Text(model.folders.isEmpty ? "将文件或文件夹拖到这里" : "文件夹已作为分组添加").font(.title3.weight(.medium))
                    Text(model.folders.isEmpty ? "也可以点击顶部的添加按钮" : "勾选“导入内部文件”，或继续添加单独文件。")
                        .foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity)
                Spacer()
            } else if model.preview.isEmpty {
                Spacer(); ProgressView("正在检查文件名……").frame(maxWidth: .infinity); Spacer()
            } else if filteredPreview.isEmpty {
                Spacer()
                Text("没有“\(previewFilter.rawValue)”的文件").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                FilePreviewTable(items: filteredPreview, information: model.information,
                                 visibleInformation: model.settings.visibleInformation,
                                 selectedFile: $selectedPreviewFile, policy: model.settings.policy,
                                 onRemove: { model.remove($0) },
                                 onReveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) })
            }
            if let folder = selectedFolder, model.folders.contains(where: { $0.url == folder }) {
                Divider()
                HStack(spacing: 12) {
                    Label(folder.lastPathComponent, systemImage: "folder").font(.caption).lineLimit(1).help(folder.path)
                    Spacer()
                    Button("定位到文件夹") { NSWorkspace.shared.open(folder) }
                    Button("移出分组") { model.removeFolder(folder) }
                        .help("移出分组及仅由它导入的文件；单独添加的文件仍保留，不删除磁盘文件。")
                }.padding(.horizontal, 16).padding(.vertical, 10).disabled(model.busy)
            }
            if let file = selectedPreviewFile, filteredPreview.contains(where: { $0.source == file }) {
                Divider()
                HStack(spacing: 12) {
                    Text(file.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle).help(file.path)
                    Spacer(minLength: 8)
                    Button { NSWorkspace.shared.activateFileViewerSelecting([file]) } label: {
                        Label("定位到文件夹", systemImage: "folder")
                    }.help("在 Finder 中打开所在文件夹并选中该文件。")
                    Button { model.remove(file) } label: {
                        Label("移出列表", systemImage: "minus.circle")
                    }.help("只从列表移出，不删除磁盘文件。")
                }.padding(.horizontal, 16).padding(.vertical, 10).disabled(model.busy)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.45))
    }
    private var footer: some View {
        HStack(spacing: 16) {
            if model.busy { ProgressView().controlSize(.small) }
            Text(model.message).font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 10)
            Button("撤销 / 恢复") { confirmUndo = true }.disabled(model.busy || !model.importingFolders.isEmpty || !model.hasHistory)
            Button("重命名 \(model.changeCount) 个文件") { pendingReview = model.review() }
                .buttonStyle(.borderedProminent).disabled(!model.canApply)
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }
}

@main
struct RenameKitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup { RenameView() }
            .defaultSize(width: 1000, height: 640)
            .windowResizability(.contentMinSize)
            .commands {
                CommandGroup(replacing: .newItem) {}
                CommandGroup(replacing: .help) {
                    Button("查看操作记录") {
                        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                            .appendingPathComponent("RenameKit/history", isDirectory: true)
                        do {
                            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(folder)
                        } catch {
                            let alert = NSAlert(error: error); alert.runModal()
                        }
                    }
                    Divider()
                    Button("关于轻改名") {
                        NSApplication.shared.orderFrontStandardAboutPanel(options: [.applicationName: "轻改名", .applicationVersion: "1.16.0", .credits: NSAttributedString(string: "本地批量文件重命名工具\n数字 / 字母冲突后缀 · 操作恢复")])
                    }
                }
            }
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var operationInProgress = false
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.operationInProgress {
            let alert = NSAlert()
            alert.messageText = "正在处理文件"
            alert.informativeText = "请先在任务窗口继续、停止或回滚当前任务，再退出应用。"
            alert.addButton(withTitle: "继续等待")
            alert.runModal()
            return .terminateCancel
        }
        return .terminateNow
    }
}
