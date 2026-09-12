import AppKit
import AVFoundation
import CryptoKit
import Foundation
import UserNotifications

// MARK: - Edge TTS（微软在线声线，免费无需 key；每性格一条真声线）

enum EdgeTTS {
    /// 性格 → 在线声线 + 韵律（猫咪是女生，只用女声线）
    static func style(for kind: Personality.Kind) -> (voice: String, rate: String, pitch: String) {
        switch kind {
        case .energetic: return ("zh-CN-XiaoxiaoNeural", "+12%", "+15%")        // 晓晓：明亮活泼
        case .lazy: return ("zh-CN-shaanxi-XiaoniNeural", "-15%", "-5%")        // 晓妮：软糯慢吞吞
        case .tsundere: return ("zh-CN-XiaoyiNeural", "+4%", "+10%")            // 晓伊：清亮带刺
        case .aloof: return ("zh-CN-liaoning-XiaobeiNeural", "-10%", "-15%")    // 小北：压低放稳，冷静利落
        }
    }

    static func synthesize(text: String, kind: Personality.Kind) async throws -> Data {
        let style = style(for: kind)
        let connId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        // Sec-MS-GEC 令牌：Windows ticks（300s 取整）+ TrustedClientToken 的 SHA256 大写 hex
        let ticks = UInt64((Date().timeIntervalSince1970 + 11_644_473_600) * 10_000_000)
        let rounded = ticks - (ticks % 3_000_000_000)
        let gec = SHA256.hash(data: Data("\(rounded)6A5AA1D4EAFF4E9FB37E23D68491D6F4".utf8))
            .map { String(format: "%02X", $0) }.joined()
        // 与 edge-tts 最新版对齐的握手参数（微软会拒绝过旧的版本号）
        let urlStr = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1"
            + "?TrustedClientToken=6A5AA1D4EAFF4E9FB37E23D68491D6F4"
            + "&Sec-MS-GEC=\(gec)&Sec-MS-GEC-Version=1-143.0.3650.75&ConnectionId=\(connId)"
        guard let url = URL(string: urlStr) else { throw TTSError.badURL }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0",
                     forHTTPHeaderField: "User-Agent")
        req.setValue("chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold", forHTTPHeaderField: "Origin")
        req.setValue("no-cache", forHTTPHeaderField: "Pragma")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        req.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let muid = UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
        req.setValue("muid=\(muid);", forHTTPHeaderField: "Cookie")

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForResource = 12
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }
        let ws = session.webSocketTask(with: req)
        ws.resume()

        let config = "X-Timestamp:\(isoNow())\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n"
            + "{\"context\":{\"synthesis\":{\"audio\":{\"metadataoptions\":{\"sentenceBoundaryEnabled\":\"false\",\"wordBoundaryEnabled\":\"false\"},\"outputFormat\":\"audio-24khz-48kbitrate-mono-mp3\"}}}}"
        try await ws.send(.string(config))

        let reqId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let ssml = "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='zh-CN'>"
            + "<voice name='\(style.voice)'><prosody pitch='\(style.pitch)' rate='\(style.rate)' volume='+0%'>"
            + xmlEscape(text) + "</prosody></voice></speak>"
        let ssmlMsg = "X-RequestId:\(reqId)\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:\(isoNow())\r\nPath:ssml\r\n\r\n\(ssml)"
        try await ws.send(.string(ssmlMsg))

        var audio = Data()
        while true {
            let msg = try await ws.receive()
            switch msg {
            case .string(let s):
                if s.contains("Path:turn.end") {
                    ws.cancel(with: .normalClosure, reason: nil)
                    if audio.isEmpty { throw TTSError.emptyAudio }
                    return audio
                }
            case .data(let d):
                // 二进制帧：前 2 字节大端头部长度，头部含 Path:audio 才是音频
                if d.count > 2 {
                    let headerLen = Int(d[d.startIndex]) << 8 | Int(d[d.startIndex + 1])
                    if d.count >= 2 + headerLen {
                        let header = String(data: d.subdata(in: 2..<2 + headerLen), encoding: .utf8) ?? ""
                        if header.contains("Path:audio") {
                            audio.append(d.subdata(in: 2 + headerLen..<d.count))
                        }
                    }
                }
            @unknown default:
                break
            }
        }
    }

    enum TTSError: Error { case badURL, emptyAudio }

    static func isoNow() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f.string(from: Date())
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

// MARK: - 语音播报（在线 Edge TTS 优先，本地 TTS 兜底）

final class VoiceService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    static let shared = VoiceService()
    private let synth = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private struct Job {
        let text: String
        let kind: Personality.Kind
    }
    private var queue: [Job] = []
    @Published var isSpeaking = false

    override init() {
        super.init()
        synth.delegate = self
    }

    /// 按性格播报：在线 TTS（真声线）优先，失败回退本地语音（语速/音调/嗓音）
    func speakPersonality(_ text: String, kind: Personality.Kind) {
        let job = Job(text: text, kind: kind)
        if isSpeaking {
            queue.append(job)
            return
        }
        run(job)
    }

    private func run(_ job: Job) {
        isSpeaking = true
        guard ConfigStore.shared.onlineTTS else {
            playLocal(job)
            return
        }
        Task {
            do {
                let data = try await EdgeTTS.synthesize(text: job.text, kind: job.kind)
                await MainActor.run { self.playOnline(data, fallback: job) }
            } catch {
                await MainActor.run { self.playLocal(job) }
            }
        }
    }

    private func playLocal(_ job: Job) {
        let u = AVSpeechUtterance(string: job.text)
        u.voice = pickVoice(job.kind.voiceIdentifiers) ?? AVSpeechSynthesisVoice(language: "zh-CN")
        u.rate = job.kind.rate
        u.pitchMultiplier = job.kind.pitch
        synth.speak(u)
    }

    private func playOnline(_ data: Data, fallback: Job) {
        do {
            let p = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.mp3.rawValue)
            p.delegate = self
            player = p
            p.play()
        } catch {
            playLocal(fallback)
        }
    }

    private func pickVoice(_ ids: [String]) -> AVSpeechSynthesisVoice? {
        let installed = AVSpeechSynthesisVoice.speechVoices().map { $0.identifier }
        for id in ids where installed.contains(id) {
            return AVSpeechSynthesisVoice(identifier: id)
        }
        return nil
    }

    private func finish() {
        isSpeaking = false
        if !queue.isEmpty {
            run(queue.removeFirst())
        }
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        player?.stop()
        queue.removeAll()
        isSpeaking = false
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { finish() }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        isSpeaking = false
        queue.removeAll()
    }
    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) { finish() }
    func audioPlayerDecodeErrorDidOccur(_ p: AVAudioPlayer, error: Error?) { finish() }
}

// MARK: - LLM 客户端

protocol LLMClient {
    func complete(system: String, user: String, config: LLMConfig) async throws -> String
}

struct OpenAICompatClient: LLMClient {
    func complete(system: String, user: String, config: LLMConfig) async throws -> String {
        // baseURL 已带 /v1 则直接拼，否则补 /v1（原写法两个分支相同，漏 /v1 会 404）
        let base = config.baseURL.hasSuffix("/v1") ? config.baseURL : config.baseURL + "/v1"
        let url = URL(string: base + "/chat/completions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = config.timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(ConfigStore.shared.apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": config.modelName,
            "temperature": config.temperature,
            "max_tokens": config.maxTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        AILogStore.shared.log("[入参] OpenAI兼容 POST \(url.absoluteString) model=\(config.modelName) maxTokens=\(config.maxTokens) temp=\(config.temperature) timeout=\(config.timeout)")
        AILogStore.shared.log("[入参] system=\(system)")
        AILogStore.shared.log("[入参] user=\(user)")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        AILogStore.shared.log("[原始响应] HTTP \(status) body=\(String(data: data, encoding: .utf8)?.prefix(2000) ?? "<非文本>")")
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "LLM", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any] else {
            throw NSError(domain: "LLM", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "响应格式异常"])
        }
        // 推理类模型（如 deepseek-reasoner）正文在 reasoning_content、content 可能为空 → 回退读取
        var content = msg["content"] as? String ?? ""
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let rc = msg["reasoning_content"] as? String {
            content = rc
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct AnthropicClient: LLMClient {
    func complete(system: String, user: String, config: LLMConfig) async throws -> String {
        let url = URL(string: config.baseURL.hasSuffix("/v1") ? config.baseURL + "/messages" : config.baseURL + "/v1/messages")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = config.timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(ConfigStore.shared.apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": config.modelName,
            "max_tokens": config.maxTokens,
            "temperature": config.temperature,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        AILogStore.shared.log("[入参] Anthropic POST \(url.absoluteString) model=\(config.modelName) maxTokens=\(config.maxTokens) temp=\(config.temperature) timeout=\(config.timeout)")
        AILogStore.shared.log("[入参] system=\(system)")
        AILogStore.shared.log("[入参] user=\(user)")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        AILogStore.shared.log("[原始响应] HTTP \(status) body=\(String(data: data, encoding: .utf8)?.prefix(2000) ?? "<非文本>")")
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "LLM", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else {
            throw NSError(domain: "LLM", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "响应格式异常"])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

func makeClient(for config: LLMConfig) -> LLMClient {
    switch config.provider {
    case .openAICompatible: return OpenAICompatClient()
    case .anthropic: return AnthropicClient()
    }
}

// MARK: - 文案生成（人设 base 台词 + AI 润色）

final class CopyGenerator {
    static let shared = CopyGenerator()

    /// 生成提醒文案。AI 可用则润色，否则回退人设 base 台词。
    func generate(event: EventItem, remainingMinutes: Int, config: LLMConfig,
                  kind: Personality.Kind, petName: String) async -> String {
        let cfg = config
        let apiKey = ConfigStore.shared.apiKey
        let base = Personality(kind: kind).baseLine(title: event.title, remaining: remainingMinutes)

        guard cfg.enabled, cfg.privacyOK, !apiKey.isEmpty else {
            AILogStore.shared.log("[宠物提醒] 跳过AI润色（enabled=\(cfg.enabled) privacyOK=\(cfg.privacyOK) hasKey=\(!apiKey.isEmpty)），用内置台词")
            return base
        }
        do {
            let system = """
            你是「\(petName)」，一只\(kind.label)的猫咪日历助理。请把下面这句提醒台词润色得自然、贴合性格。
            要求：只输出一句话，不超过30字，口语化，可用少量Emoji，不要输出与提醒无关的内容。
            性格：\(kind.promptTag)
            """
            let user = "原台词：\(base)\n事项：\(event.title)\n剩余：\(remainingMinutes) 分钟"
            let text = try await makeClient(for: cfg).complete(system: system, user: user, config: cfg)
            AILogStore.shared.log("[宠物提醒] AI 响应(\(text.count)字): \(text)")
            // 简单过滤：长度合理才用，否则用 base
            if text.count >= 2 && text.count <= 45 {
                return text
            }
            AILogStore.shared.log("[宠物提醒] 响应长度不合理，回退内置台词")
        } catch {
            AILogStore.shared.log("[宠物提醒] AI 失败: \(error.localizedDescription)，回退内置台词")
        }
        return base
    }
}

// MARK: - 提醒调度（本地通知 + 语音）

final class ReminderScheduler {
    static let shared = ReminderScheduler()
    private var timer: Timer?
    private var scheduled: [String] = []

    func start() {
        LogStore.shared.log("[提醒] 提醒调度器启动（每 15s 轮询）")
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        sync()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            Task { @MainActor in self.checkDue() }
        }
    }

    func sync() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        let config = ConfigStore.shared
        let enabled = config.reminderDefaults
        for e in AppModel.shared.events where !e.isDeleted && !e.isDone {
            let offsets = e.reminders.isEmpty ? enabled : e.reminders.map { $0.offsetMinutes }
            for off in offsets {
                guard let fireDate = Calendar.current.date(byAdding: .minute, value: off, to: e.startDate),
                      fireDate > Date() else { continue }
                let content = UNMutableNotificationContent()
                content.title = e.title
                content.body = "还有 \(abs(off)) 分钟" + (off < 0 ? "开始/截止" : "")
                content.sound = .default
                let comp = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
                let trigger = UNCalendarNotificationTrigger(dateMatching: comp, repeats: false)
                let req = UNNotificationRequest(identifier: e.id.uuidString, content: content, trigger: trigger)
                center.add(req)
            }
        }
    }

    /// 每个 15s 检查：恰好命中提醒点 → 语音播报（AI 文案）并唤醒宠物
    @MainActor func checkDue() {
        let config = ConfigStore.shared
        let now = Date()
        for e in AppModel.shared.events where !e.isDeleted && !e.isDone {
            let offsets = e.reminders.isEmpty ? config.reminderDefaults : e.reminders.map { $0.offsetMinutes }
            for off in offsets {
                guard let fireDate = Calendar.current.date(byAdding: .minute, value: off, to: e.startDate) else { continue }
                let gap = now.timeIntervalSince(fireDate)
                if gap >= 0 && gap < 15 {
                    let remaining = abs(off)
                    let token = "\(e.id.uuidString)-\(off)"
                    guard !scheduled.contains(token) else { continue }
                    scheduled.append(token)
                    // 弹窗提醒（用户在事项里配置是否弹窗，nil/true=弹）
                    if e.popupReminder != false {
                        WindowManager.shared.showReminderPopup(event: e, remaining: remaining)
                    }
                    triggerVoice(event: e, remaining: remaining, config: config)
                    NotificationCenter.default.post(name: .petRemind, object: nil)
                }
            }
        }
    }

    @MainActor func triggerVoice(event: EventItem, remaining: Int, config: ConfigStore) {
        guard config.voiceEnabled else { return }
        LogStore.shared.log("[提醒] 语音播报：\(event.title)（剩 \(remaining) 分钟）")
        let kind = config.effectivePersonality()
        Task {
            let text = await CopyGenerator.shared.generate(
                event: event, remainingMinutes: remaining, config: config.llm,
                kind: kind, petName: config.petName)
            VoiceService.shared.speakPersonality(text, kind: kind)
            await MainActor.run {
                NotificationCenter.default.post(name: .petSpeak, object: text)
            }
        }
    }
}

extension Notification.Name {
    static let petRemind = Notification.Name("petRemind")
    static let petSpeak = Notification.Name("petSpeak")
}

// MARK: - 运行日志（每天一个文件，自动保留 7 天；线程安全）

/// 运行日志：写入 Application Support/MyCalendar/logs/yyyy-MM-dd.log。
/// 所有写盘走串行队列，保证多线程安全；即使主线程卡死，后台/心跳线程仍能正常落盘。
final class LogStore {
    static let shared = LogStore()
    private let queue = DispatchQueue(label: "com.mycalendar.log", qos: .userInitiated)
    private let fm = FileManager.default
    let directory: URL

    private static let dateF: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let timeF: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    init() {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directory = base.appendingPathComponent("MyCalendar/logs", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        log("🟢 日志系统初始化 @ \(directory.path)")
    }

    var todayLogURL: URL {
        directory.appendingPathComponent(Self.dateF.string(from: Date()) + ".log")
    }

    func log(_ msg: String) {
        let line = "[\(Self.timeF.string(from: Date()))] \(msg)\n"
        queue.async {
            let file = self.directory.appendingPathComponent(Self.dateF.string(from: Date()) + ".log")
            if let h = try? FileHandle(forWritingTo: file) {
                h.seekToEndOfFile()
                h.write(line.data(using: .utf8)!)
                try? h.close()
            } else if let d = line.data(using: .utf8) {
                try? d.write(to: file)
            }
            self.cleanupIfNeeded()
        }
    }

    private var lastCleanup = Date.distantPast
    /// 每小时至多清理一次，删除 7 天前的日志文件
    func cleanupIfNeeded() {
        guard Date().timeIntervalSince(lastCleanup) > 3600 else { return }
        lastCleanup = Date()
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for f in files {
            let mdate = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture
            if mdate < cutoff { try? fm.removeItem(at: f) }
        }
    }

    /// 在访达中打开日志目录
    func openInFinder() { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory.path) }
    /// 打开今天的日志
    func openTodayLog() { NSWorkspace.shared.open(todayLogURL) }
}

/// AI 交互专用日志（独立目录 ai-logs / 文件 ai-yyyy-MM-dd.log）：
/// 宠物情绪评估、宠物提醒润色、工作量 AI 分析等全部记录在此，便于排查「AI 无输出」。
final class AILogStore {
    static let shared = AILogStore()
    private let queue = DispatchQueue(label: "com.mycalendar.ailog", qos: .userInitiated)
    private let fm = FileManager.default
    let directory: URL

    private static let dateF: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let timeF: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    init() {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directory = base.appendingPathComponent("MyCalendar/ai-logs", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        log("🟢 AI 日志初始化 @ \(directory.path)")
    }

    var todayLogURL: URL {
        directory.appendingPathComponent("ai-" + Self.dateF.string(from: Date()) + ".log")
    }

    func log(_ msg: String) {
        let line = "[\(Self.timeF.string(from: Date()))] \(msg)\n"
        queue.async {
            let file = self.directory.appendingPathComponent("ai-" + Self.dateF.string(from: Date()) + ".log")
            if let h = try? FileHandle(forWritingTo: file) {
                h.seekToEndOfFile()
                h.write(line.data(using: .utf8)!)
                try? h.close()
            } else if let d = line.data(using: .utf8) {
                try? d.write(to: file)
            }
            self.cleanupIfNeeded()
        }
    }

    private var lastCleanup = Date.distantPast
    func cleanupIfNeeded() {
        guard Date().timeIntervalSince(lastCleanup) > 3600 else { return }
        lastCleanup = Date()
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for f in files {
            let mdate = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture
            if mdate < cutoff { try? fm.removeItem(at: f) }
        }
    }

    func openInFinder() { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory.path) }
    func openTodayLog() { NSWorkspace.shared.open(todayLogURL) }
}

// MARK: - 主线程心跳看门狗（卡死排查）

/// 主线程每 2s 打一个心跳；后台线程检测若 >8s 无心跳，判定主线程疑似卡死并写日志。
/// 主线程被阻塞时心跳停更，但后台线程仍存活，因此卡死瞬间也能留下"最后一次活动"的时间与痕迹。
final class BeatWatcher {
    static let shared = BeatWatcher()
    private var lastBeat = Date()
    private var started = false
    /// 系统睡眠期间心跳停更属正常，不算卡死（否则每次唤醒都误报"无响应 xxx s"刷屏）
    private var systemSleeping = false
    private var sleepObservers: [NSObjectProtocol] = []

    func start() {
        guard !started else { return }
        started = true
        lastBeat = Date()
        LogStore.shared.log("🩰 心跳看门狗启动（检测主线程 >8s 无响应记为疑似卡死；系统睡眠期间不计）")

        let beater = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.lastBeat = Date()
        }
        // 手动加入 common mode，保证拖动/缩放窗口期间心跳不中断
        RunLoop.main.add(beater, forMode: .common)

        // 睡眠/唤醒感知：willSleep 置位，didWake 复位并重置心跳基线
        let ws = NSWorkspace.shared.notificationCenter
        sleepObservers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification,
                                             object: nil, queue: .main) { [weak self] _ in
            self?.systemSleeping = true
        })
        sleepObservers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification,
                                             object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.systemSleeping = false
            self.lastBeat = Date()
        })

        // 用较高 QoS，避免 CPU 已被占满时后台线程被饿死、写不出预警日志
        DispatchQueue.global(qos: .userInteractive).async {
            while true {
                Thread.sleep(forTimeInterval: 3)
                // 睡眠期间/刚唤醒（主线程 observer 尚未复位）不告警，滚动基线防跨睡眠累计
                if self.systemSleeping {
                    self.lastBeat = Date()
                    continue
                }
                let elapsed = Date().timeIntervalSince(self.lastBeat)
                if elapsed > 8 {
                    LogStore.shared.log("⚠️ 主线程疑似繁忙/卡死：已无响应 \(Int(elapsed))s，最后一次心跳在 \(elapsed)s 前")
                }
            }
        }
    }
}
