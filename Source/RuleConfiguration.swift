import Foundation

/// The editor and rename engine share this parser. Lowercase month aliases are
/// accepted in the date portion; after HH, mm denotes minutes.
struct DateNamingRule {
    private enum Component {
        case token(String)
        case literal(String)
    }
    let pattern: String
    private let components: [Component]
    static let defaultPattern = "yyyyMMdd_HHmmss"
    static let referenceDate: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 15, minute: 30, second: 30))!
    }()

    init(_ pattern: String) throws {
        self.pattern = pattern
        guard !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RenameError.message("请输入命名规则，例如 yyyyMMdd_HHmmss。") }
        guard pattern.count <= 120 else { throw RenameError.message("规则过长，请控制在 120 个字符以内。") }
        for character in pattern {
            if character == "/" || character == ":" || character.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                throw RenameError.message("规则不能包含 /、:、换行等文件名无效字符。可用 -、_ 或 . 分隔。")
            }
        }
        let chars = Array(pattern)
        var result: [Component] = []
        var index = 0
        var timePortion = false
        var fields = Set<String>()
        func addToken(_ token: String, field: String) throws {
            guard fields.insert(field).inserted else { throw RenameError.message("\(field)重复。日期中的月份用 MM，时间中的分钟用 mm。") }
            result.append(.token(token))
        }
        while index < chars.count {
            let char = chars[index]
            if char == "'" {
                let opening = index
                index += 1
                if index < chars.count && chars[index] == "'" {
                    result.append(.literal("'")); index += 1; continue
                }
                var literal = "", closed = false
                while index < chars.count {
                    if chars[index] == "'" {
                        if index + 1 < chars.count && chars[index + 1] == "'" {
                            literal.append("'"); index += 2
                        } else { index += 1; closed = true; break }
                    } else { literal.append(chars[index]); index += 1 }
                }
                guard closed else { throw RenameError.message("第 \(opening + 1) 位的单引号没有闭合。") }
                result.append(.literal(literal))
                continue
            }
            let asciiLetter = char.unicodeScalars.count == 1 && (("a"..."z").contains(String(char)) || ("A"..."Z").contains(String(char)))
            guard asciiLetter else { result.append(.literal(String(char))); index += 1; continue }
            let beginning = index
            while index < chars.count && chars[index] == char { index += 1 }
            let run = String(chars[beginning..<index])
            switch char {
            case "y":
                guard run == "yyyy" || run == "yy" else { throw RenameError.message("年份请使用 yyyy（2026）或 yy（26）。") }
                timePortion = false
                try addToken(run, field: "年份")
            case "M":
                guard (1...4).contains(run.count) else { throw RenameError.message("月份支持 M、MM、MMM 或 MMMM。") }
                timePortion = false
                try addToken(run, field: "月份")
            case "m":
                if timePortion {
                    guard run.count <= 2 else { throw RenameError.message("分钟请使用 mm；毫秒请使用 SSS。") }
                    try addToken(run, field: "分钟")
                } else {
                    guard run.count <= 4 else { throw RenameError.message("日期中的月份支持 m、mm、mmm 或 mmmm。") }
                    try addToken(String(repeating: "M", count: run.count), field: "月份")
                }
            case "d":
                guard run.count <= 2 else { throw RenameError.message("日期中的日请使用 dd（17）或 d。") }
                timePortion = false
                try addToken(run, field: "日")
            case "H":
                guard run.count <= 2 else { throw RenameError.message("小时请使用 HH（24 小时制）。") }
                timePortion = true
                try addToken(run, field: "小时")
            case "s":
                guard run.count <= 2 else { throw RenameError.message("秒请使用 ss；毫秒请使用 SSS。") }
                timePortion = true
                try addToken(run, field: "秒")
            case "S":
                guard run == "SSS" else { throw RenameError.message("毫秒请使用 SSS，例如 123。") }
                try addToken(run, field: "毫秒")
            default:
                throw RenameError.message("不支持第 \(beginning + 1) 位的“\(run)”。使用 yyyy、MM、dd、HH、mm、ss；固定英文请用单引号包住。")
            }
        }
        guard !fields.isEmpty else { throw RenameError.message("规则中至少需要一个日期或时间字段，例如 yyyy-MM-dd。") }
        components = result
        let example = string(from: Self.referenceDate)
        guard !example.isEmpty && example != "." && example != ".." && example.utf8.count <= 240 else { throw RenameError.message("规则生成的文件名为空或过长，请简化规则。") }
    }
    func string(from date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        // Formatting tokens separately makes every literal (including apostrophes)
        // unambiguous rather than feeding arbitrary user input to DateFormatter.
        return components.map { component in
            switch component {
            case .literal(let text): return text
            case .token(let token): formatter.dateFormat = token; return formatter.string(from: date)
            }
        }.joined()
    }
    static func validationError(_ pattern: String) -> String? {
        do { _ = try Self(pattern); return nil }
        catch { return error.localizedDescription }
    }
}

enum ExecutionInterval: Int, Codable, CaseIterable, Identifiable {
    case immediate = 0, milliseconds100 = 100, milliseconds200 = 200, milliseconds500 = 500
    var id: Int { rawValue }
    var title: String { rawValue == 0 ? "0 毫秒（最快）" : "\(rawValue) 毫秒" }
    var nanoseconds: UInt64 { UInt64(rawValue) * 1_000_000 }
}

struct RenameSettings: Codable, Equatable {
    var pattern = DateNamingRule.defaultPattern
    var policy: CollisionPolicy = .letters
    var visibleInformation: Set<FileInfoColumn> = [.created]
    var executionInterval: ExecutionInterval = .milliseconds200
    var validationError: String? { DateNamingRule.validationError(pattern) }
}
extension RenameSettings {
    enum CodingKeys: String, CodingKey { case pattern, policy, visibleInformation, executionInterval }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        executionInterval = try container.decodeIfPresent(ExecutionInterval.self, forKey: .executionInterval) ?? .milliseconds200
        pattern = try container.decodeIfPresent(String.self, forKey: .pattern) ?? DateNamingRule.defaultPattern
        policy = try container.decodeIfPresent(CollisionPolicy.self, forKey: .policy) ?? .letters
        visibleInformation = try container.decodeIfPresent(Set<FileInfoColumn>.self, forKey: .visibleInformation) ?? [.created]
    }
}
struct RenameSettingsStore {
    let url: URL
    func load() throws -> RenameSettings { try JSONDecoder().decode(RenameSettings.self, from: Data(contentsOf: url)) }
    func save(_ settings: RenameSettings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(settings).write(to: url, options: .atomic)
    }
}
