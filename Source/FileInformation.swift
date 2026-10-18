import Foundation

enum FileInfoColumn: String, Codable, CaseIterable, Identifiable {
    case created, modified, accessed, size, type, fileExtension
    var id: String { rawValue }
    var menuTitle: String {
        switch self {
        case .created: return "文件创建时间"
        case .modified: return "文件修改时间"
        case .accessed: return "上次访问时间"
        case .size: return "文件大小"
        case .type: return "文件类型"
        case .fileExtension: return "扩展名"
        }
    }
    var title: String { self == .created ? "原始创建时间" : menuTitle }
    var preferredWidth: Double {
        switch self {
        case .created, .modified, .accessed: return 170
        case .size: return 105
        case .type: return 135
        case .fileExtension: return 90
        }
    }
}

/// Read-only snapshot taken before renaming. Reading these attributes never opens
/// the file for writing or interprets/re-encodes its contents.
struct FileInformation {
    let created: Date?
    let modified: Date?
    let accessed: Date?
    let size: Int64?
    let type: String?
    let fileExtension: String
    static func read(_ url: URL) -> Self {
        let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [
            .creationDateKey, .contentModificationDateKey, .contentAccessDateKey,
            .fileSizeKey, .localizedTypeDescriptionKey
        ])
        return Self(created: values?.creationDate, modified: values?.contentModificationDate,
                    accessed: values?.contentAccessDate, size: values?.fileSize.map(Int64.init),
                    type: values?.localizedTypeDescription, fileExtension: url.pathExtension)
    }
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
    private static func dateText(_ date: Date?) -> String {
        date.map { dateFormatter.string(from: $0) } ?? "—"
    }
    func text(for column: FileInfoColumn) -> String {
        switch column {
        case .created: return Self.dateText(created)
        case .modified: return Self.dateText(modified)
        case .accessed: return Self.dateText(accessed)
        case .size: return size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
        case .type: return type ?? "—"
        case .fileExtension: return fileExtension.isEmpty ? "—" : "." + fileExtension
        }
    }
}
