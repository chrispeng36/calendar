import AppKit
import CoreImage
import Foundation
import SwiftUI
import Vision

// MARK: - 事件与提醒

struct Reminder: Codable, Identifiable, Hashable {
    enum Scope: String, Codable, CaseIterable {
        case notification, voice, both
        var label: String {
            switch self {
            case .notification: return "仅横幅"
            case .voice: return "仅语音"
            case .both: return "语音+横幅"
            }
        }
    }
    var id = UUID()
    var offsetMinutes: Int   // 负=提前
    var scope: Scope = .both
    var label: String?

    var humanOffset: String {
        let m = abs(offsetMinutes)
        let unit = m == 60 ? "1 小时" : (m == 30 ? "30 分钟" : "\(m) 分钟")
        return offsetMinutes < 0 ? "提前 \(unit)" : "延后 \(unit)"
    }
}

struct EventItem: Codable, Identifiable, Hashable {
    enum RepeatRule: String, Codable, CaseIterable {
        case none, daily, weekly, monthly, yearly, workdays
        var label: String {
            switch self {
            case .none: return "不重复"
            case .daily: return "每天"
            case .weekly: return "每周"
            case .monthly: return "每月"
            case .yearly: return "每年"
            case .workdays: return "工作日"
            }
        }
    }
    enum CategoryColor: String, Codable, CaseIterable {
        case red, orange, blue, green, purple
        var color: Color {
            switch self {
            case .red: return .red
            case .orange: return .orange
            case .blue: return .blue
            case .green: return .green
            case .purple: return .purple
            }
        }
        /// 默认分类标签（可被用户在设置里改）
        var defaultLabel: String {
            switch self {
            case .red: return "重要"
            case .orange: return "工作"
            case .blue: return "个人"
            case .green: return "生活"
            case .purple: return "学习"
            }
        }
        var nsColor: NSColor {
            switch self {
            case .red: return .systemRed
            case .orange: return .systemOrange
            case .blue: return .systemBlue
            case .green: return .systemGreen
            case .purple: return .systemPurple
            }
        }
    }

    var id = UUID()
    var title: String
    var body: String?
    var startDate: Date
    var endDate: Date?
    var isAllDay = true
    var categoryColor: CategoryColor = .blue
    var categoryID: String?   // 用户自定义分类 id；nil = 用内置 5 色
    var reminders: [Reminder] = []
    var repeatRule: RepeatRule = .none
    /// 是否弹窗提醒（nil=默认弹；用户在编辑事项时配置）。Optional 以兼容旧 events.json 缺字段
    var popupReminder: Bool? = nil
    var isDone = false
    var createdAt = Date()
    var updatedAt = Date()
    var deletedAt: Date?
    var source = "manual"

    var startTime: Date { startDate } // 提醒基准时间

    var isDeleted: Bool { deletedAt != nil }
}

// MARK: - 持久化（JSON 轻量存储）

final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var events: [EventItem] = []
    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MyCalendar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("events.json")
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([EventItem].self, from: data) else { return }
        events = decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func events(on day: Date) -> [EventItem] {
        events.filter {
            !$0.isDeleted &&
            Calendar.current.isDate($0.startDate, inSameDayAs: day)
        }
    }

    func add(_ e: EventItem) {
        events.append(e)
        save()
        ReminderScheduler.shared.sync()
    }

    func update(_ e: EventItem) {
        if let idx = events.firstIndex(where: { $0.id == e.id }) {
            var copy = e
            copy.updatedAt = Date()
            events[idx] = copy
        }
        save()
        ReminderScheduler.shared.sync()
    }

    func remove(_ id: UUID) {
        if let idx = events.firstIndex(where: { $0.id == id }) {
            events[idx].deletedAt = Date()
            events[idx].updatedAt = Date()
        }
        save()
        ReminderScheduler.shared.sync()
    }

    func toggleDone(_ id: UUID) {
        if let idx = events.firstIndex(where: { $0.id == id }) {
            events[idx].isDone.toggle()
            events[idx].updatedAt = Date()
        }
        save()
        ReminderScheduler.shared.sync()
    }
}

// MARK: - 十六进制颜色转换

enum HexColor {
    static func hexString(from color: NSColor) -> String {
        guard let s = color.usingColorSpace(.sRGB) else { return "" }
        return String(format: "#%02X%02X%02X",
                      Int(round(s.redComponent * 255)),
                      Int(round(s.greenComponent * 255)),
                      Int(round(s.blueComponent * 255)))
    }

    static func nsColor(fromHex hex: String) -> NSColor? {
        var h = hex.trimmingCharacters(in: .whitespaces).uppercased()
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt64(h, radix: 16) else { return nil }
        return NSColor(calibratedRed: CGFloat((v >> 16) & 0xFF) / 255,
                       green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255,
                       alpha: 1)
    }
}

// MARK: - 自定义分类（用户可增删）

struct CategoryDef: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var label: String
    var hex: String   // #RRGGBB
    var color: Color {
        Color(nsColor: HexColor.nsColor(fromHex: hex) ?? .systemBlue)
    }
    var nsColor: NSColor {
        HexColor.nsColor(fromHex: hex) ?? .systemBlue
    }
}

// MARK: - LLM 配置 + 凭证

enum LLMProvider: String, Codable, CaseIterable {
    case openAICompatible, anthropic
    var label: String {
        switch self {
        case .openAICompatible: return "OpenAI 兼容(DeepSeek/Qwen/GLM/Kimi/Ollama)"
        case .anthropic: return "Anthropic (Claude)"
        }
    }
}

struct LLMConfig: Codable {
    var enabled = false
    var provider: LLMProvider = .openAICompatible
    var baseURL = "https://api.deepseek.com/v1"
    var modelName = "deepseek-chat"
    var temperature = 0.7
    var maxTokens = 512      // 64 太小会把分析/润色截断成空，默认调大
    var timeout: Double = 20
    var privacyOK = false       // 用户确认发送事件信息到模型
    // 本地偏好全存 plist；apiKey 也存 plist（避免 ad-hoc 签名下 Keychain 每次启动重复弹窗鉴权）
}

enum Theme: String, Codable, CaseIterable {
    case glass, neon, aurora, minimal
    var label: String {
        switch self {
        case .glass: return "玻璃"
        case .neon: return "霓虹"
        case .aurora: return "渐变"
        case .minimal: return "极简"
        }
    }
    var tagline: String {
        switch self {
        case .glass: return "透明磨砂，与壁纸融为一体"
        case .neon: return "暗色底 + 霓虹描边发光，酷炫"
        case .aurora: return "多色流动渐变，炫丽"
        case .minimal: return "近纯透明，只看信息"
        }
    }
}

final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    @Published var petName: String
    @Published var personalityKind: Personality.Kind
    @Published var desktopPin: Bool = false      // 贴桌面层（默认关：钉住会沉到图标层导致点不动/拖不动）
    @Published var desktopTransparent: Bool
    @Published var voiceEnabled: Bool
    @Published var voiceRate: Float
    @Published var onlineTTS: Bool = true   // 在线 Edge TTS（每性格一条真声线），失败回退本地
    @Published var theme: Theme = .glass
    @Published var transparentPet: Bool = false
    // 背景墙 & 自定义色系（覆盖字段：空值=用主题默认，非空=用户自定义）
    @Published var wallpaperPath: String = ""        // 本机背景图片路径，空=未设置
    @Published var presetWallpaper: String = "theme" // theme/sunset/ocean/forest/midnight/sakura/custom
    @Published var customBgHex: String = ""          // 自定义背景色（#RRGGBB）
    @Published var customFgHex: String = ""          // 自定义文本色
    @Published var customAccentHex: String = ""      // 自定义强调色
    @Published var reminderDefaults: [Int]   // 提前分钟数集合
    @Published var petVideoPath: String = "" // 用户自选的宠物视频（循环播放取代照片形象）
    @Published var categoryLabels: [String: String] = [:]  // 颜色分类标签（用户可配置）
    @Published var categoryColors: [String: String] = [:]  // 颜色分类的自定义色值（hex，#RRGGBB）
    @Published var customCategories: [CategoryDef] = []    // 用户自定义分类（可增删）
    @Published var categoryWeights: [String: Double] = [:] // 分类工作量权重（工作量评估用，默认 1.0）
    @Published var hiddenCategories: [String: Bool] = [:]  // 被「删除/隐藏」的内置分类（rawValue->true）
    @Published var llm: LLMConfig
    @Published var apiKey: String
    @Published var aiPromptShown: Bool = false   // 首次启动的 AI 配置引导是否已展示
    @Published var calendarLocked: Bool = false  // 主日历窗口「锁定」禁止拖拽
    @Published var petLocked: Bool = false       // 宠物窗口「锁定」禁止拖拽（与日历独立）
    @Published var dayPersonality: DayPersonality?  // 宠物当日性格（手动/AI），跨天失效

    private let fileURL: URL

    init() {
        // 默认值
        petName = "咪咪"
        personalityKind = .energetic
        desktopPin = false
        desktopTransparent = true
        voiceEnabled = true
        voiceRate = 0.5
        reminderDefaults = [-60, -30]
        llm = LLMConfig()
        apiKey = ""
        fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MyCalendar/_preferences.plist", isDirectory: false)
        load()
    }

    func save() {
        let dict: [String: Any] = [
            "petName": petName,
            "personalityKind": personalityKind.rawValue,
            "desktopPin": desktopPin,
            "desktopTransparent": desktopTransparent,
            "voiceEnabled": voiceEnabled,
            "voiceRate": voiceRate,
            "onlineTTS": onlineTTS,
            "theme": theme.rawValue,
            "transparentPet": transparentPet,
            "reminderDefaults": reminderDefaults,
            "petVideoPath": petVideoPath,
            "categoryLabels": try! JSONEncoder().encode(categoryLabels),
            "categoryColors": try! JSONEncoder().encode(categoryColors),
            "customCategories": try! JSONEncoder().encode(customCategories),
            "categoryWeights": try! JSONEncoder().encode(categoryWeights),
            "hiddenCategories": try! JSONEncoder().encode(hiddenCategories),
            "llm": try! JSONEncoder().encode(llm),
            "aiPromptShown": aiPromptShown,
            "apiKey": apiKey,
            "calendarLocked": calendarLocked,
            "petLocked": petLocked,
            "dayPersonality": try! JSONEncoder().encode(dayPersonality),
            "wallpaperPath": wallpaperPath,
            "presetWallpaper": presetWallpaper,
            "customBgHex": customBgHex,
            "customFgHex": customFgHex,
            "customAccentHex": customAccentHex,
        ]
        (dict as NSDictionary).write(to: fileURL, atomically: true)
    }

    func load() {
        guard let dict = NSDictionary(contentsOf: fileURL) as? [String: Any] else { return }
        if let v = dict["petName"] as? String { petName = v }
        if let v = dict["personalityKind"] as? String, let k = Personality.Kind(rawValue: v) { personalityKind = k }
        if let v = dict["desktopPin"] as? Bool { desktopPin = v }
        if let v = dict["desktopTransparent"] as? Bool { desktopTransparent = v }
        if let v = dict["voiceEnabled"] as? Bool { voiceEnabled = v }
        if let v = dict["voiceRate"] as? Float { voiceRate = v }
        if let v = dict["onlineTTS"] as? Bool { onlineTTS = v }
        if let v = dict["theme"] as? String, let t = Theme(rawValue: v) { theme = t }
        if let v = dict["transparentPet"] as? Bool { transparentPet = v }
        if let v = dict["reminderDefaults"] as? [Int] { reminderDefaults = v }
        if let v = dict["petVideoPath"] as? String { petVideoPath = v }
        if let d = dict["categoryLabels"] as? Data,
           let map = try? JSONDecoder().decode([String: String].self, from: d) { categoryLabels = map }
        if let d = dict["categoryColors"] as? Data,
           let map = try? JSONDecoder().decode([String: String].self, from: d) { categoryColors = map }
        if let d = dict["customCategories"] as? Data,
           let list = try? JSONDecoder().decode([CategoryDef].self, from: d) { customCategories = list }
        if let d = dict["categoryWeights"] as? Data,
           let map = try? JSONDecoder().decode([String: Double].self, from: d) { categoryWeights = map }
        if let d = dict["hiddenCategories"] as? Data,
           let map = try? JSONDecoder().decode([String: Bool].self, from: d) { hiddenCategories = map }
        if let d = dict["llm"] as? Data, let cfg = try? JSONDecoder().decode(LLMConfig.self, from: d) { llm = cfg }
        // 旧版本默认 maxTokens=64/timeout=5 过小，会把 AI 输出截断成空 → 迁移调大
        if llm.maxTokens < 128 { llm.maxTokens = 512 }
        if llm.timeout < 10 { llm.timeout = 20 }
        if let v = dict["aiPromptShown"] as? Bool { aiPromptShown = v }
        if let v = dict["apiKey"] as? String { apiKey = v }
        if let v = dict["calendarLocked"] as? Bool { calendarLocked = v }
        if let v = dict["petLocked"] as? Bool { petLocked = v }
        if let d = dict["dayPersonality"] as? Data,
           let p = try? JSONDecoder().decode(DayPersonality.self, from: d) { dayPersonality = p }
        if let v = dict["wallpaperPath"] as? String { wallpaperPath = v }
        if let v = dict["presetWallpaper"] as? String { presetWallpaper = v }
        if let v = dict["customBgHex"] as? String { customBgHex = v }
        if let v = dict["customFgHex"] as? String { customFgHex = v }
        if let v = dict["customAccentHex"] as? String { customAccentHex = v }
    }

    // MARK: - 背景墙 & 自定义色系

    /// 用户自定义强调色；未设置用系统 .accentColor
    func customAccent() -> Color {
        customAccentHex.isEmpty ? Color.accentColor
            : (Color(nsColor: HexColor.nsColor(fromHex: customAccentHex) ?? .systemBlue))
    }

    /// 用户自定义文本色；未设置用主题默认（霓虹/渐变=白，其余=primary）
    func textTone(for t: Theme) -> Color {
        if !customFgHex.isEmpty, let nc = HexColor.nsColor(fromHex: customFgHex) { return Color(nsColor: nc) }
        switch t {
        case .neon, .aurora: return .white
        case .glass, .minimal: return .primary
        }
    }

    /// 背景墙图片；未设置/无法加载返回 nil（缓存解码结果，避免每次渲染都读盘解码大图）
    private static var wallpaperCache: (path: String, image: NSImage?)?
    func wallpaperImage() -> NSImage? {
        guard !wallpaperPath.isEmpty else { return nil }
        if let c = Self.wallpaperCache, c.path == wallpaperPath { return c.image }
        let img = NSImage(contentsOfFile: wallpaperPath)
        Self.wallpaperCache = (wallpaperPath, img)
        return img
    }

    /// 预设渐变卡；不用于 theme/custom 时返回渐变，否则 nil
    func presetGradient() -> LinearGradient? {
        switch presetWallpaper {
        case "sunset":
            return LinearGradient(colors: [Color(red: 0.98, green: 0.55, blue: 0.45),
                                           Color(red: 0.9, green: 0.45, blue: 0.75),
                                           Color(red: 0.5, green: 0.35, blue: 0.9)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case "ocean":
            return LinearGradient(colors: [Color(red: 0.15, green: 0.45, blue: 0.7),
                                           Color(red: 0.2, green: 0.7, blue: 0.75),
                                           Color(red: 0.1, green: 0.35, blue: 0.6)],
                                  startPoint: .top, endPoint: .bottom)
        case "forest":
            return LinearGradient(colors: [Color(red: 0.25, green: 0.5, blue: 0.32),
                                           Color(red: 0.45, green: 0.65, blue: 0.4),
                                           Color(red: 0.15, green: 0.35, blue: 0.25)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case "midnight":
            return LinearGradient(colors: [Color(red: 0.08, green: 0.12, blue: 0.25),
                                           Color(red: 0.18, green: 0.22, blue: 0.42),
                                           Color(red: 0.05, green: 0.08, blue: 0.18)],
                                  startPoint: .top, endPoint: .bottom)
        case "sakura":
            return LinearGradient(colors: [Color(red: 0.98, green: 0.75, blue: 0.82),
                                           Color(red: 0.95, green: 0.6, blue: 0.75),
                                           Color(red: 0.9, green: 0.8, blue: 0.95)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        default: return nil
        }
    }

    /// 重置背景墙 & 自定义色系为默认（不改 theme）
    func resetAppearance() {
        wallpaperPath = ""
        presetWallpaper = "theme"
        customBgHex = ""
        customFgHex = ""
        customAccentHex = ""
        save()
    }

    /// 某颜色的当前分类标签（未配置则用默认）
    func label(for color: EventItem.CategoryColor) -> String {
        let map = categoryLabels
        let raw = color.rawValue
        if let v = map[raw], !v.trimmingCharacters(in: .whitespaces).isEmpty { return v }
        return color.defaultLabel
    }

    /// 某颜色的当前色值（用户自定义优先，否则内置色）
    func categoryColor(_ color: EventItem.CategoryColor) -> Color {
        if let hex = categoryColors[color.rawValue], !hex.isEmpty,
           let nc = HexColor.nsColor(fromHex: hex) {
            return Color(nsColor: nc)
        }
        return color.color
    }

    func isHidden(_ key: String) -> Bool { hiddenCategories[key] == true }
    /// 未被隐藏的内置分类（编辑器/图例/设置/权重共用）
    var visibleBuiltIn: [EventItem.CategoryColor] {
        EventItem.CategoryColor.allCases.filter { !isHidden($0.rawValue) }
    }

    /// 事件分类：自定义分类优先，否则用内置 5 色（含用户改的标签/色值）
    func categoryFor(_ e: EventItem) -> (label: String, color: Color) {
        if let id = e.categoryID, let c = customCategories.first(where: { $0.id == id }) {
            return (c.label, c.color)
        }
        return (label(for: e.categoryColor), categoryColor(e.categoryColor))
    }

    func customCategory(id: String?) -> CategoryDef? {
        guard let id = id else { return nil }
        return customCategories.first { $0.id == id }
    }

    @discardableResult
    func addCategory(label: String, hex: String) -> CategoryDef {
        var c = CategoryDef(label: label, hex: hex)
        c.id = UUID().uuidString
        customCategories.append(c)
        save()
        return c
    }

    func removeCategory(id: String) {
        customCategories.removeAll { $0.id == id }
        save()
    }

    // MARK: - 宠物当日性格（手动 / AI 评估）

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func dayString(_ d: Date = Date()) -> String { Self.dayFormatter.string(from: d) }

    /// 当天有效的当日性格（否则为 nil，回到全局 base）
    var effectiveDayPersonality: DayPersonality? {
        guard let p = dayPersonality, p.day == dayString() else { return nil }
        return p
    }

    /// 实际生效的性格：当日覆盖优先，否则全局 base
    func effectivePersonality() -> Personality.Kind {
        effectiveDayPersonality?.kind ?? personalityKind
    }

    /// 手动设定当日性格
    func setDayPersonality(_ kind: Personality.Kind, source: DayPersonality.Source,
                           reason: String? = nil, summary: String? = nil) {
        dayPersonality = DayPersonality(day: dayString(), kind: kind, source: source,
                                        reason: reason, summary: summary)
        save()
    }

    /// 清空当日性格（回到全局 base）
    func clearDayPersonality() {
        guard dayPersonality != nil else { return }
        dayPersonality = nil
        save()
    }

    /// 今日工作量统计（供 AI 评估用）
    struct Workload {
        var total: Int
        var timed: Int
        var allDay: Int
        var nextMinutes: Int?
    }

    func todayWorkload() -> Workload {
        let cal = Calendar.current
        let events = AppModel.shared.events.filter {
            !$0.isDeleted && cal.isDate($0.startDate, inSameDayAs: Date())
        }
        let timed = events.filter { !$0.isAllDay }
        var next: Int?
        let now = Date()
        if let n = timed.filter({ $0.startDate > now }).map({ $0.startDate }).min() {
            next = max(0, cal.dateComponents([.minute], from: now, to: n).minute ?? 0)
        }
        return Workload(total: events.count, timed: timed.count,
                        allDay: events.count - timed.count, nextMinutes: next)
    }

    /// 用 AI 按今日工作量评估宠物性格；成功后写回 dayPersonality(source:.ai)。
    /// 未配置 AI / 解析失败 / 网络错误时返回 false（由 UI 提示）。
    @MainActor
    @discardableResult
    func evaluateDayPersonality() async -> Bool {
        let cfg = llm
        guard cfg.enabled, !apiKey.isEmpty, cfg.privacyOK else {
            AILogStore.shared.log("[宠物情绪] 跳过：enabled=\(cfg.enabled) hasKey=\(!apiKey.isEmpty) privacyOK=\(cfg.privacyOK)")
            return false
        }
        let w = todayWorkload()
        AILogStore.shared.log("[宠物情绪] 开始评估 enabled=\(llm.enabled) hasKey=\(!apiKey.isEmpty) privacyOK=\(llm.privacyOK)")
        var workloadText = "今天共有 \(w.total) 个事项"
        if w.timed > 0 { workloadText += "，其中定时事项 \(w.timed) 个" }
        if w.allDay > 0 { workloadText += "，全天事项 \(w.allDay) 个" }
        if let n = w.nextMinutes { workloadText += "；最近一个定时事项还有约 \(n) 分钟" }
        else if w.total > 0 { workloadText += "；今天的定时事项都已过点" }
        else { workloadText += "；今天暂无待办，比较清闲" }

        let kinds = Personality.Kind.all
        let names = kinds.map { $0.label }.joined(separator: "、")
        let system = "你是「\(petName)」，一只猫咪日历助手。根据今天的工作安排统计，从这 4 个性格里选最贴合的一个：\(names)。"
            + " 只按一行输出：<性格名>|<一句话理由（不超过25字，口语化）>。不要把性格名写错。"
        let user = "今天的工作统计：\(workloadText)。"
        do {
            let text = try await makeClient(for: cfg).complete(system: system, user: user, config: cfg)
            AILogStore.shared.log("[宠物情绪] 响应: \(text)")
            let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "|")
            let name = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let reason = parts.count > 1
                ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : nil
            guard let kind = kinds.first(where: { $0.label == name }) else {
                AILogStore.shared.log("[宠物情绪] 解析失败：性格名「\(name)」不在候选中")
                return false
            }
            setDayPersonality(kind, source: .ai, reason: reason, summary: workloadText)
            AILogStore.shared.log("[宠物情绪] 成功：\(kind.label)（\(reason ?? "")）")
            return true
        } catch {
            AILogStore.shared.log("[宠物情绪] 失败: \(error.localizedDescription)")
            return false
        }
    }

    /// AI 分析近期工作量：返回【总结】+【建议】文本。未启用 AI/无 Key 时 throw。
    @MainActor
    func analyzeWorkload(_ range: WorkloadRange) async throws -> String {
        let cfg = llm
        AILogStore.shared.log("[工作量分析] 开始 range=\(range.rawValue) provider=\(cfg.provider.rawValue) model=\(cfg.modelName) enabled=\(cfg.enabled) hasKey=\(!apiKey.isEmpty)")
        guard cfg.enabled, !apiKey.isEmpty else {
            let msg = "请先在「AI 助理」启用模型并填写 API Key"
            AILogStore.shared.log("[工作量分析] 中止：\(msg)")
            throw NSError(domain: "MyCalendar", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }
        let system = "你是一名资深效率教练。根据用户日历的加权工作量统计，分析其近期工作情况与工作重心，"
            + "给出简明总结与可执行建议。用中文，输出两段，分别以【总结】和【建议】开头，每段不超过 120 字。"
        let user = WorkloadEngine.summaryText(range)
        // 分析需要两段中文，默认 64 token 会被截断/清空 → 本次调用放大上限与超时
        var reqCfg = cfg
        reqCfg.maxTokens = max(cfg.maxTokens, 600)
        reqCfg.timeout = max(cfg.timeout, 30)
        AILogStore.shared.log("[工作量分析] 请求 maxTokens=\(reqCfg.maxTokens) timeout=\(reqCfg.timeout) user=\(user)")
        do {
            let text = try await makeClient(for: reqCfg).complete(system: system, user: user, config: reqCfg)
            AILogStore.shared.log("[工作量分析] 响应(\(text.count)字): \(text)")
            if text.isEmpty {
                throw NSError(domain: "MyCalendar", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "AI 返回空内容，请检查模型/Key 是否可用"])
            }
            return text
        } catch {
            AILogStore.shared.log("[工作量分析] 失败: \(error.localizedDescription)")
            throw error
        }
    }
}

// MARK: - 工作量评估（权重 + 趋势 + AI 分析）

enum WorkloadRange: String, CaseIterable, Identifiable {
    case week = "过去一周"
    case month = "过去一月"
    case year = "过去一年"
    var id: String { rawValue }
    var days: Int {
        switch self { case .week: 7; case .month: 30; case .year: 365 }
    }
}

struct WorkloadPoint: Identifiable {
    let id = UUID()
    let label: String
    let value: Double
    let date: Date
}

enum WorkloadEngine {
    /// 事件分类键：自定义分类 custom:<id>，否则内置色 rawValue
    static func categoryKey(_ e: EventItem) -> String {
        if let id = e.categoryID { return "custom:\(id)" }
        return e.categoryColor.rawValue
    }

    static func weight(of e: EventItem, cfg: ConfigStore = .shared) -> Double {
        max(0, cfg.categoryWeights[categoryKey(e)] ?? 1.0)
    }

    /// 某天的加权工作量
    static func load(on day: Date, cfg: ConfigStore = .shared) -> Double {
        let cal = Calendar.current
        return AppModel.shared.events
            .filter { !$0.isDeleted && cal.isDate($0.startDate, inSameDayAs: day) }
            .reduce(0) { $0 + weight(of: $1, cfg: cfg) }
    }

    /// 趋势序列：周/月按天，年按月（12 柱，最多一年）
    static func series(_ range: WorkloadRange, cfg: ConfigStore = .shared) -> [WorkloadPoint] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        switch range {
        case .week, .month:
            return (0..<range.days).reversed().map { off in
                let d = cal.date(byAdding: .day, value: -off, to: today)!
                let label: String
                if off == 0 { label = "今天" }
                else {
                    let f = DateFormatter(); f.dateFormat = "M/d"; label = f.string(from: d)
                }
                return WorkloadPoint(label: label, value: load(on: d, cfg: cfg), date: d)
            }
        case .year:
            return (0..<12).reversed().map { off in
                let anchor = cal.date(byAdding: .month, value: -off, to: today)!
                let comps = cal.dateComponents([.year, .month], from: anchor)
                let start = cal.date(from: comps)!
                let next = cal.date(byAdding: .month, value: 1, to: start)!
                let total = AppModel.shared.events
                    .filter { !$0.isDeleted && $0.startDate >= start && $0.startDate < next }
                    .reduce(0) { $0 + weight(of: $1, cfg: cfg) }
                let f = DateFormatter(); f.dateFormat = "yy/M"
                return WorkloadPoint(label: f.string(from: start), value: total, date: start)
            }
        }
    }

    struct TodaySplit {
        var doneCount = 0; var undoneCount = 0
        var doneWeight: Double = 0; var undoneWeight: Double = 0
    }

    /// 当天已完成 / 未完成拆分（加权）
    static func todaySplit(cfg: ConfigStore = .shared) -> TodaySplit {
        let cal = Calendar.current
        var s = TodaySplit()
        for e in AppModel.shared.events
        where !e.isDeleted && cal.isDate(e.startDate, inSameDayAs: Date()) {
            let w = weight(of: e, cfg: cfg)
            if e.isDone { s.doneCount += 1; s.doneWeight += w }
            else { s.undoneCount += 1; s.undoneWeight += w }
        }
        return s
    }

    /// 分类加权占比（工作重心），由高到低
    static func breakdown(_ range: WorkloadRange, cfg: ConfigStore = .shared) -> [(key: String, label: String, value: Double)] {
        let cal = Calendar.current
        let since = cal.date(byAdding: .day, value: -range.days, to: Date())!
        var acc: [String: Double] = [:]
        var labels: [String: String] = [:]
        for e in AppModel.shared.events where !e.isDeleted && e.startDate >= since {
            let k = categoryKey(e)
            acc[k, default: 0] += weight(of: e, cfg: cfg)
            labels[k] = cfg.categoryFor(e).label
        }
        return acc.map { (key: $0.key, label: labels[$0.key] ?? $0.key, value: $0.value) }
            .sorted { $0.value > $1.value }
    }

    static func fmt(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(v)) : String(format: "%.1f", v)
    }

    /// 供 AI 分析的文本摘要
    static func summaryText(_ range: WorkloadRange, cfg: ConfigStore = .shared) -> String {
        let pts = series(range, cfg: cfg)
        let total = pts.reduce(0) { $0 + $1.value }
        var s = "统计区间：\(range.rawValue)；加权工作量合计 \(fmt(total))"
        let ts = todaySplit(cfg: cfg)
        s += "；今天：已完成 \(ts.doneCount) 件(权重 \(fmt(ts.doneWeight)))、未完成 \(ts.undoneCount) 件(权重 \(fmt(ts.undoneWeight)))"
        if let peak = pts.max(by: { $0.value < $1.value }), peak.value > 0 {
            s += "；峰值在 \(peak.label)（\(fmt(peak.value))）"
        }
        let bd = breakdown(range, cfg: cfg).prefix(5)
        if !bd.isEmpty {
            s += "；分类占比（高→低）：" + bd.map { "\($0.label) \(fmt($0.value))" }.joined(separator: "、")
        }
        let half = pts.count / 2
        if half > 0 {
            let earlier = pts.prefix(pts.count - half).reduce(0) { $0 + $1.value }
            let recent = pts.suffix(half).reduce(0) { $0 + $1.value }
            s += "；前半段 \(fmt(earlier)) vs 后半段 \(fmt(recent))（体现增减趋势）"
        }
        return s
    }

    /// 本地规则摘要（AI 不可用时的兜底输出，保证用户始终有结果可看）
    static func localAnalysis(_ range: WorkloadRange) -> String {
        let pts = series(range)
        let total = pts.reduce(0) { $0 + $1.value }
        let bd = breakdown(range)
        var trend = "持平"
        let half = pts.count / 2
        if half > 0 {
            let earlier = pts.prefix(pts.count - half).reduce(0) { $0 + $1.value }
            let recent = pts.suffix(half).reduce(0) { $0 + $1.value }
            if recent > earlier * 1.15 { trend = "上升" }
            else if recent < earlier * 0.85 { trend = "下降" }
        }
        let ts = todaySplit()
        var s = "【总结】\(range.rawValue)加权工作量合计 \(fmt(total))，整体趋势\(trend)"
        if let peak = pts.max(by: { $0.value < $1.value }), peak.value > 0 {
            s += "，峰值在 \(peak.label)"
        }
        if let top = bd.first { s += "；工作重心为「\(top.label)」" }
        s += "。今天已完成 \(ts.doneCount) 件（权重 \(fmt(ts.doneWeight))）、未完成 \(ts.undoneCount) 件（权重 \(fmt(ts.undoneWeight))）"
        if ts.undoneCount > 0 {
            s += "，今日完成率约 \(Int(Double(ts.doneCount) / Double(max(1, ts.doneCount + ts.undoneCount)) * 100))%"
        }
        s += "。【建议】"
        if ts.undoneCount > ts.doneCount {
            s += "今天未完成多于已完成，优先清掉高权重未办事项、避免滚到明天。"
        }
        switch trend {
        case "上升": s += "近期负荷加重，给高权重事项预留整块时间、控制并行数量。"
        case "下降": s += "近期负荷回落，适合安排复盘与学习类低权重事项。"
        default: s += "负荷平稳，保持当前节奏，定期检查高权重事项是否按期推进。"
        }
        if let top = bd.first { s += " 重心集中在「\(top.label)」，注意平衡其他分类。" }
        return s
    }
}

// MARK: - 性格

enum PersonalityPreference: String, Codable, CaseIterable {
    case energetic, lazy, tsundere, aloof
}

struct Personality: Codable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case energetic, lazy, tsundere, aloof
        var label: String {
            switch self {
            case .energetic: return "元气"
            case .lazy: return "慵懒"
            case .tsundere: return "傲娇"
            case .aloof: return "高冷"
            }
        }
        var promptTag: String {
            switch self {
            case .energetic: return "热情、活泼、爱用\"冲鸭/加油\"，偶尔卖萌"
            case .lazy: return "懒洋洋、随性、慢节奏，常说\"慢慢来\""
            case .tsundere: return "嘴硬心软、别扭，\"才不是催你\""
            case .aloof: return "话少、冷静、直接"
            }
        }
        var rate: Float {
            switch self {
            case .energetic: return 0.55
            case .lazy: return 0.42
            case .tsundere: return 0.5
            case .aloof: return 0.45
            }
        }
        /// 语音音调（1.0 基准，越高越尖）
        var pitch: Float {
            switch self {
            case .energetic: return 1.3    // 元气：高亢
            case .lazy: return 0.9         // 慵懒：低沉
            case .tsundere: return 1.15    // 傲娇：偏尖
            case .aloof: return 0.78       // 高冷：低冷
            }
        }
        /// 首选嗓音（按优先级，系统未安装则顺延，最终回退 zh-CN）
        var voiceIdentifiers: [String] {
            switch self {
            case .energetic:
                return ["com.apple.voice.compact.zh-TW.Meijia",
                        "com.apple.ttsbundle.Ting-Ting-compact"]
            case .lazy:
                return ["com.apple.ttsbundle.Ting-Ting-compact"]
            case .tsundere:
                return ["com.apple.voice.compact.zh-HK.Sinji",
                        "com.apple.ttsbundle.Ting-Ting-compact"]
            case .aloof:
                return ["com.apple.ttsbundle.Ting-Ting-compact"]
            }
        }
        var baseLines: [String] {
            switch self {
            case .energetic:
                return ["主人！『{title}』还有 {n} 分钟就要截止啦，冲鸭！",
                        "喵！{title} 只剩 {n} 分钟咯，拜托拜托，快去做嘛～"]
            case .lazy:
                return ["唔…『{title}』还有 {n} 分钟，你可以慢慢来～",
                        "喵～还有 {n} 分钟才截止，不急不急，喝口水先。"]
            case .tsundere:
                return ["才、才不是在催你！『{title}』只剩 {n} 分钟了！",
                        "喵哼，{title} 还有 {n} 分钟，你自己看着办啦。"]
            case .aloof:
                return ["『{title}』，{n} 分钟后截止。",
                        "{title}，{n} 分钟。"]
            }
        }
        static let all: [Kind] = [.energetic, .lazy, .tsundere, .aloof]
    }

    var kind: Kind
    var id: String { kind.rawValue }
    func baseLine(title: String, remaining: Int) -> String {
        let t = kind.baseLines.randomElement()!
        return t.replacingOccurrences(of: "{title}", with: title)
                .replacingOccurrences(of: "{n}", with: "\(max(1, remaining))")
    }
}

// MARK: - 宠物当日性格（用户手动设定 或 AI 按当日工作量评估）

/// 某一天对全局性格的覆盖；跨天自动失效（day 用 "yyyy-MM-dd"）
struct DayPersonality: Codable, Identifiable {
    enum Source: String, Codable {
        case user, ai
        var label: String {
            switch self {
            case .user: return "用户设置"
            case .ai: return "AI 评估"
            }
        }
    }
    var id = UUID()
    var day: String             // "yyyy-MM-dd"，只有当天的才生效
    var kind: Personality.Kind
    var source: Source
    var reason: String?         // AI 评估理由（source == .ai 时展示，可展开）
    var summary: String?        // 评估时的工作量摘要（展示用）
}

// MARK: - 农历/节气（真实农历：Apple 中文历，含闰月与农历节日）

enum LunarService {
    /// 中文农历日历（当前年份区间准确；个别远年 2057 等为系统已知边界，属可接受简化）
    private static var lunarcal: Calendar {
        var c = Calendar(identifier: .chinese)
        c.locale = Locale(identifier: "zh_CN")
        return c
    }

    struct LunarDate {
        var year: Int
        var month: Int      // 1..12
        var day: Int        // 1..30
        var isLeap: Bool
    }

    static func lunarDate(for date: Date) -> LunarDate {
        let comps = lunarcal.dateComponents([.year, .month, .day, .isLeapMonth], from: date)
        return LunarDate(year: comps.year ?? 1900,
                         month: comps.month ?? 1,
                         day: comps.day ?? 1,
                         isLeap: comps.isLeapMonth ?? false)
    }

    static func text(for date: Date) -> String {
        let lunar = lunarDate(for: date)
        if let term = solarTerm(for: date) { return term }
        if let f = festival(for: date) { return f }
        let monthName = (lunar.isLeap ? "闰" : "") + monthName(lunar.month)
        return "\(monthName)\(dayName(lunar.day))"
    }

    static func monthName(_ m: Int) -> String {
        let names = ["正月","二月","三月","四月","五月","六月","七月","八月","九月","十月","冬月","腊月"]
        guard m >= 1, m <= 12 else { return "N月" }
        return names[m-1]
    }

    static func dayName(_ day: Int) -> String {
        let names = ["初一","初二","初三","初四","初五","初六","初七","初八","初九","初十",
                     "十一","十二","十三","十四","十五","十六","十七","十八","十九","二十",
                     "廿一","廿二","廿三","廿四","廿五","廿六","廿七","廿八","廿九","三十"]
        guard day >= 1, day <= 30 else { return "初一" }
        return names[day-1]
    }

    /// 农历节日（按农历月日识别）
    static func festival(for date: Date) -> String? {
        let lunar = lunarDate(for: date)
        switch (lunar.month, lunar.day) {
        case (1,1): return "春节"
        case (1,15): return "元宵"
        case (5,5): return "端午"
        case (7,7): return "七夕"
        case (7,15): return "中元"
        case (8,15): return "中秋"
        case (9,9): return "重阳"
        case (12,8): return "腊八"
        default:
            // 除夕 = 该农历年最后一天（腊月最后一日的判定较复杂，按腊月三十近似；小年腊月廿三）
            if lunar.month == 12 && lunar.day == 23 { return "小年" }
            return nil
        }
    }

    /// 24 节气（天文近似算法，基于太阳黄经平分回归年，误差在小时级，远优于固定月日）
    private static let termIndexInfo = [0, 21208, 42467, 63836, 85337, 107014, 128867, 150921,
                                       173149, 195551, 218072, 240693, 263343, 285989, 308563,
                                       331033, 353350, 375494, 397447, 419210, 440795, 462224,
                                       483532, 504758]
    private static let termNames = ["小寒","大寒","立春","雨水","惊蛰","春分","清明","谷雨",
                                    "立夏","小满","芒种","夏至","小暑","大暑","立秋","处暑",
                                    "白露","秋分","寒露","霜降","立冬","小雪","大雪","冬至"]
    private static var base1900: Date = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        var comps = DateComponents()
        comps.year = 1900; comps.month = 1; comps.day = 6; comps.hour = 2; comps.minute = 5
        return c.date(from: comps)!
    }()
    static func solarTermDate(year: Int, index: Int) -> Date {
        let ms = 31_556_925_974.7 * Double(year - 1900) + Double(termIndexInfo[index]) * 60_000.0
        return base1900.addingTimeInterval(ms / 1000.0)
    }
    static func solarTerm(for date: Date) -> String? {
        let year = Calendar.current.component(.year, from: date)
        guard year >= 1900, year <= 2100 else { return nil }
        for (i, name) in termNames.enumerated() {
            let t = solarTermDate(year: year, index: i)
            if Calendar.current.isDate(t, inSameDayAs: date) { return name }
        }
        return nil
    }
}

// MARK: - 资源加载

enum ResourceLoader {
    static func image(_ name: String) -> NSImage? {
        if let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: nil) {
            return NSImage(contentsOf: url)
        }
        // 开发回退：项目 pics/
        let cwd = FileManager.default.currentDirectoryPath
        for base in [cwd, (cwd as NSString).deletingLastPathComponent] {
            let url = URL(fileURLWithPath: base).appendingPathComponent("pics/\(name).png")
            if FileManager.default.fileExists(atPath: url.path) { return NSImage(contentsOf: url) }
        }
        return nil
    }
}

// MARK: - 导入导出（ICS / CSV）

enum EventExporter {
    static func ics(_ events: [EventItem]) -> String {
        var lines: [String] = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//MyCalendar//桌面日历//CN", "CALSCALE:GREGORIAN"]
        for e in events where !e.isDeleted {
            lines.append("BEGIN:VEVENT")
            lines.append("UID:\(e.id.uuidString)")
            lines.append("DTSTAMP:\(utcDate())")
            lines.append("DTSTART:\(utcDate(e.startDate))")
            lines.append("SUMMARY:\(e.title)")
            if let b = e.body, !b.isEmpty { lines.append("DESCRIPTION:\(b)") }
            for r in e.reminders {
                lines.append("BEGIN:VALARM")
                lines.append("ACTION:DISPLAY")
                lines.append("TRIGGER:-PT\(abs(r.offsetMinutes))M")
                lines.append("DESCRIPTION:\(e.title)")
                lines.append("END:VALARM")
            }
            lines.append("END:VEVENT")
        }
        lines.append("END:VCALENDAR")
        return lines.joined(separator: "\r\n")
    }

    static func csv(_ events: [EventItem]) -> String {
        var rows = ["标题,开始时间,颜色,全天,已完成,提醒"]
        for e in events where !e.isDeleted {
            let remind = e.reminders.map { String($0.offsetMinutes) }.joined(separator: " ")
            rows.append([
                csvEsc(e.title),
                csvEsc(startString(e.startDate)),
                e.categoryColor.rawValue,
                e.isAllDay ? "是" : "否",
                e.isDone ? "是" : "否",
                csvEsc(remind),
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    private static func utcDate(_ d: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: d)
    }

    private static func startString(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    private static func csvEsc(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }
}

// MARK: - ICS 导入

enum EventImporter {
    /// 解析 ICS v2.0，返回事件列表（含换行折叠与 UTC/本地/全天日期）
    static func parse(_ data: Data) -> [EventItem] {
        guard var text = String(data: data, encoding: .utf8) else { return [] }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")

        // 折叠逻辑：以空格/制表符开头的续行并入上一行
        var lines: [String] = []
        for l in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(l)
            if s.hasPrefix(" ") || s.hasPrefix("\t") {
                if let last = lines.last { lines[lines.count - 1] = last + s.dropFirst() }
            } else {
                lines.append(s)
            }
        }

        var events: [EventItem] = []
        var i = 0
        while i < lines.count {
            if lines[i].hasPrefix("BEGIN:VEVENT") {
                var j = i + 1
                var props: [String: String] = [:]
                while j < lines.count && !lines[j].hasPrefix("END:VEVENT") {
                    if let colon = lines[j].firstIndex(of: ":") {
                        let key = String(lines[j][..<colon]).split(separator: ";").first.map(String.init) ?? ""
                        let valueStart = lines[j].index(after: colon)
                        let value = String(lines[j][valueStart...])
                        props[key] = value
                    }
                    j += 1
                }
                if let title = props["SUMMARY"], let rawStart = props["DTSTART"],
                   let start = parseDate(rawStart) {
                    var e = EventItem(title: title,
                                      body: props["DESCRIPTION"],
                                      startDate: start,
                                      endDate: props["DTEND"].flatMap { parseDate($0) },
                                      isAllDay: isAllDay(rawStart),
                                      source: "ics")
                    e.updatedAt = Date()
                    events.append(e)
                }
                i = j
            } else {
                i += 1
            }
        }
        return events
    }

    static func isAllDay(_ raw: String) -> Bool {
        if raw.uppercased().contains("VALUE=DATE") { return true }
        let value = raw.split(separator: ":").last.map(String.init) ?? raw
        return value.count == 8
    }

    static func parseDate(_ raw: String) -> Date? {
        let value = raw.split(separator: ":").last.map(String.init) ?? raw
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        if value.hasSuffix("Z") {
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            return f.date(from: value)
        }
        if value.count == 8 {
            f.timeZone = TimeZone.current
            f.dateFormat = "yyyyMMdd"
            return f.date(from: value)
        }
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        return f.date(from: value)
    }
}

// MARK: - 宠物抠像（Vision 前景实例分割，去掉照片背景；macOS 15+，14 自动退回相框式）

final class PetCutoutStore: ObservableObject {
    static let shared = PetCutoutStore()
    @Published private(set) var cache: [String: NSImage] = [:]

    func current(_ name: String) -> NSImage? { cache[name] }

    func ensure(_ name: String) {
        if cache[name] != nil { return }
        Task { await compute(name) }
    }

    @MainActor private func compute(_ name: String) async {
        guard cache[name] == nil, let raw = ResourceLoader.image(name) else { return }
        if let cut = await PetImager.segment(raw) {
            cache[name] = cut
        }
    }
}

enum PetImager {
    /// 用 GenerateForegroundInstanceMaskRequest 抠出前景主体（猫咪），返回透明底图像
    static func segment(_ image: NSImage) async -> NSImage? {
        guard #available(macOS 15.0, *) else { return nil }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let request = GenerateForegroundInstanceMaskRequest()
        let handler = ImageRequestHandler(cg)
        do {
            guard let obs = try await handler.perform(request) else { return nil }
            let buffer = try obs.generateMaskedImage(for: obs.allInstances,
                                                     imageFrom: handler,
                                                     croppedToInstancesExtent: false)
            let ci = CIImage(cvPixelBuffer: buffer)
            let ctx = CIContext()
            guard let cg2 = ctx.createCGImage(ci, from: ci.extent) else { return nil }
            return NSImage(cgImage: cg2, size: image.size)
        } catch {
            return nil
        }
    }
}
