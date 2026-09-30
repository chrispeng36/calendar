import AppKit
import CoreGraphics
import SwiftUI

@main
struct MyCalendarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 无默认窗口；UI 由 AppDelegate 用 NSStatusItem（菜单栏）承载
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .systemServices) {}
                CommandGroup(replacing: .appSettings) {
                    Button("设置…") { WindowManager.shared.showSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}

// 可成为 key 的无边框面板，用于接收点击
class DesktopPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 带文本编辑的窗口：拦截 ⌘Z/X/C/V/A 直接发给 firstResponder（字段编辑器），
/// 绕过主菜单 key-equivalent 校验失效的问题；并用自建快照栈实现 ⌘Z/⌘Z 撤销/重做
/// （AppKit 字段编辑器的 undo 注册链在此环境不可靠，故不依赖 NSUndoManager）
class EditingWindow: NSWindow {
    private var undoStack: [String] = []
    private var redoStack: [String] = []
    private var lastSnap = Date.distantPast

    private var editorTextView: NSTextView? { firstResponder as? NSTextView }
    private func currentString() -> String? {
        if let tv = editorTextView { return tv.string }
        if let tf = firstResponder as? NSTextField { return tf.stringValue }
        return nil
    }

    /// 写入文本并手动触发 controlTextDidChange，让 SwiftUI Binding 同步
    private func setString(_ s: String) {
        let tf: NSTextField?
        if let tv = editorTextView { tf = tv.delegate as? NSTextField } else { tf = firstResponder as? NSTextField }
        guard let field = tf else { return }
        editorTextView?.string = s
        field.stringValue = s
        (field.delegate as? NSTextFieldDelegate)?.controlTextDidChange?(
            Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    /// 记录快照：forced（粘贴/剪切前）必记；普通输入按 0.8s 停顿分组
    private func snapshot(forced: Bool) {
        guard let cur = currentString() else { return }
        let now = Date()
        if forced || now.timeIntervalSince(lastSnap) > 0.8 {
            if undoStack.last != cur {
                undoStack.append(cur)
                redoStack.removeAll()
            }
        }
        lastSnap = now
    }

    private func doUndo() {
        guard let cur = currentString(), let prev = undoStack.popLast() else { return }
        redoStack.append(cur)
        setString(prev)
        lastSnap = Date()
    }

    private func doRedo() {
        guard let cur = currentString(), let next = redoStack.popLast() else { return }
        undoStack.append(cur)
        setString(next)
        lastSnap = Date()
    }

    override func keyDown(with event: NSEvent) {
        snapshot(forced: false)
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.control),
           let ch = event.charactersIgnoringModifiers?.lowercased() {
            switch ch {
            case "z":
                if currentString() != nil {
                    if event.modifierFlags.contains(.shift) { doRedo() } else { doUndo() }
                    return true
                }
            case "v", "x":
                snapshot(forced: true)
                let sel = ch == "v" ? #selector(NSText.paste(_:)) : #selector(NSText.cut(_:))
                if let fr = firstResponder, fr.responds(to: sel) {
                    fr.perform(sel, with: nil)
                    return true
                }
            case "c":
                if let fr = firstResponder, fr.responds(to: #selector(NSText.copy(_:))) {
                    fr.perform(#selector(NSText.copy(_:)), with: nil)
                    return true
                }
            case "a":
                if let fr = firstResponder, fr.responds(to: #selector(NSText.selectAll(_:))) {
                    fr.perform(#selector(NSText.selectAll(_:)), with: nil)
                    return true
                }
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class CalendarWindow: EditingWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            level = .normal
            NSApp.activate(ignoringOtherApps: true)
            makeKeyAndOrderFront(nil)
        }
        super.sendEvent(event)
    }
    override func performClose(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.closeCalendarAndCompanions()
    }
}

final class CalendarHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

enum DesktopWindowPlacer {
    /// 尽力将窗口放到「壁纸之上、图标之下」；结果受系统版本影响，需 M0 真机验证。
    static func apply(to win: NSWindow, pin: Bool) {
        if pin && !NSApp.isActive {
            // 置于桌面层：位于桌面图标层之上、普通窗口之下（此时窗口会退居所有窗口之后，交通灯也会被盖住）
            let icon = CGWindowLevelForKey(.desktopIconWindow)
            win.level = NSWindow.Level(rawValue: Int(icon))
        } else {
            win.level = .normal
        }
    }
}

final class WindowManager: ObservableObject {
    static let shared = WindowManager()
    @Published var desktopVisible = true
    @Published var petVisible = true
    @Published var petExpanded = false   // 宠物悬浮球默认收起，点击展开成卡片

    // 宠物悬浮球/卡片尺寸
    static let petBallSize = CGSize(width: 88, height: 88)
    static let petCardSize = CGSize(width: 268, height: 428)
    /// The photo cat gets a transparent landscape canvas, with room for its ears and paws.
    @Published private var customPetSize: CGSize? = {
        let c = ConfigStore.shared
        return c.petWidth >= 160 && c.petHeight >= 160
            ? CGSize(width: c.petWidth, height: c.petHeight) : nil
    }()
    var petWindowSize: CGSize {
        if let customPetSize { return customPetSize }
        if ConfigStore.shared.petRenderMode == "rig" {
            if ConfigStore.shared.petSkin == "fenda" {
                if ConfigStore.shared.petActivity == .wander {
                    // A square transparent canvas contains the complete cat
                    // on vertical edges and throughout corner rotations.
                    return petExpanded ? CGSize(width: 500, height: 500) : CGSize(width: 420, height: 420)
                }
                if ConfigStore.shared.petActivity == .toy {
                    return petExpanded ? CGSize(width: 455, height: 300) : CGSize(width: 375, height: 245)
                }
                return petExpanded ? CGSize(width: 325, height: 355) : CGSize(width: 245, height: 270)
            }
            if ConfigStore.shared.petActivity == .toy {
                return petExpanded ? CGSize(width:520,height:410) : CGSize(width:420,height:330)
            }
            return petExpanded ? CGSize(width: 330, height: 270) : CGSize(width: 230, height: 190)
        }
        return petExpanded ? CGSize(width:360,height:360) : CGSize(width:260,height:260)
    }


    private(set) var desktopWindow: NSWindow?
    private(set) var petWindow: NSWindow?
    private(set) var settingsWindow: NSWindow?

    func makeDesktopWindow() {
        LogStore.shared.log("[窗口] 创建宠物日历窗口…")
        let root = CalendarView().environmentObject(AppModel.shared)
        let host = NSHostingController(rootView: root)
        host.view = CalendarHostingView(rootView: root)
        // 不要让 SwiftUI 理想尺寸约束窗口，否则纵向/斜向缩放被锁死
        host.sizingOptions = []
        // 默认铺满屏幕（参考 DesktopCal 全屏网格形态），仍可缩放/拖动/关闭
        let size: CGSize
        let screen = NSScreen.screens.first ?? NSScreen.main
        if let screen {
            let f = screen.visibleFrame
            size = CGSize(width: f.width - 48, height: f.height - 40)
        } else {
            size = CGSize(width: 1440, height: 860)
        }
        // 常规、可缩放、带红/黄/绿交通灯（关闭/最小化/缩放）的窗口，标题栏透明让内容铺满
        let win = CalendarWindow(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                backing: .buffered, defer: false)
        win.title = "宠物日历"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.contentViewController = host
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.isMovableByWindowBackground = true
        win.minSize = NSSize(width: 760, height: 520)
        win.contentMinSize = NSSize(width: 760, height: 520)
        if ConfigStore.shared.desktopPin {
            win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        }
        DesktopWindowPlacer.apply(to: win, pin: ConfigStore.shared.desktopPin)
        if let screen {
            let f = screen.visibleFrame
            win.setFrame(NSRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2,
                                width: size.width, height: size.height), display: true)
        }
        // makeKeyAndOrderFront：让主窗口真正成为 key 才能可靠接收鼠标点击（修复偶发“点不动”）
        win.makeKeyAndOrderFront(nil)
        desktopWindow = win
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: NSApp, queue: .main) { [weak win] _ in
                guard let win else { return }
                DesktopWindowPlacer.apply(to: win, pin: ConfigStore.shared.desktopPin)
            }
        }
        applyCalendarLock()
        LogStore.shared.log("[窗口] 宠物日历窗口已创建/显示")
    }

    func makePetWindow() {
        guard ConfigStore.shared.petShown else {
            petVisible = false
            PetBrain.shared.setEnabled(false)
            return
        }
        LogStore.shared.log("[窗口] 创建宠物悬浮球…")
        let root = PetView().accentColor(ConfigStore.shared.customAccent()).environmentObject(AppModel.shared)
            .font(.appBody)
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []
        let size = petWindowSize
        // The whole pet frame accepts clicks, so it remains easy to grab while walking.
        let win = PetInteractionPanel(contentRect: NSRect(origin: .zero, size: size),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        win.contentViewController = host
        let resizeView = PetResizeView(frame: NSRect(origin: .zero, size: size))
        resizeView.autoresizingMask = [.width, .height]
        host.view.addSubview(resizeView)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.isMovableByWindowBackground = false
        win.ignoresMouseEvents = false
        win.level = .floating
        win.hidesOnDeactivate = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 位置记忆：优先恢复上次中心点（校验仍在某块屏幕内，防拔显示器后猫消失在屏外）
        let cfg = ConfigStore.shared
        var restored = false
        if cfg.petPosX > ConfigStore.petPosNone, cfg.petPosY > ConfigStore.petPosNone {
            let rect = NSRect(x: cfg.petPosX - size.width / 2, y: cfg.petPosY - size.height / 2,
                              width: size.width, height: size.height)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) {
                win.setFrame(visiblePetFrame(rect), display: true)
                restored = true
            }
        }
        if !restored, let screen = NSScreen.screens.first ?? NSScreen.main {
            let f = screen.visibleFrame
            win.setFrame(NSRect(x: f.maxX - size.width - 40, y: f.minY + 40,
                                width: size.width, height: size.height), display: true)
        }
        // 拖动结束去抖 1s 落盘位置（展开/收起改尺寸但保中心，重复保存无害）
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                               object: win, queue: .main) { [weak self] _ in
            self?.schedulePetPositionSave()
        }
        win.orderFront(nil)
        PetBrain.shared.setEnabled(true)   // 启动鼠标跟随状态机
        LogStore.shared.log("[窗口] 宠物悬浮球已创建/显示（默认收起）")
        petWindow = win
        applyPetLock()
    }

    /// 展开/收起宠物悬浮球（动态调整窗口尺寸，保持中心不动）
    func setPetExpanded(_ e: Bool) {
        guard let win = petWindow else { return }
        customPetSize = nil
        ConfigStore.shared.petWidth = 0
        ConfigStore.shared.petHeight = 0
        ConfigStore.shared.save()
        petExpanded = e
        let target = petWindowSize
        let old = win.frame
        win.setFrame(visiblePetFrame(NSRect(x: old.midX - target.width / 2, y: old.midY - target.height / 2,
                            width: target.width, height: target.height)),
                     display: true, animate: true)
        LogStore.shared.log("[宠物] 悬浮球\(e ? "展开" : "收起")")
    }

    func movePetManually(to origin: NSPoint, finished: Bool) {
        guard let win = petWindow else { return }
        win.setFrame(visiblePetFrame(NSRect(origin: origin, size: win.frame.size)), display: true)
        if finished {
            let cfg = ConfigStore.shared
            cfg.petPosX = win.frame.midX
            cfg.petPosY = win.frame.midY
            cfg.save()
            NotificationCenter.default.post(name: .petManualMoveFinished, object: nil)
        }
    }

    func refreshPetSize() {
        guard let win = petWindow else { return }
        let size = petWindowSize
        let frame = NSRect(x: win.frame.midX - size.width / 2,
                           y: win.frame.midY - size.height / 2,
                           width: size.width, height: size.height)
        win.setFrame(visiblePetFrame(frame), display: true)
    }

    func selectPetSkin(_ skin: String) {
        let config = ConfigStore.shared
        let selected = skin == "fenda" ? "fenda" : "default"
        guard config.petSkin != selected else { return }
        if selected == "fenda" {
            if config.petName == "咪咪" { config.petName = "芬达" }
            config.petActivity = .follow
            config.petRenderMode = "rig"
            config.petTrackingEnabled = true
        } else if config.petName == "芬达" {
            config.petName = "咪咪"
        }
        config.petSkin = selected
        customPetSize = nil
        config.petWidth = 0
        config.petHeight = 0
        config.save()
        refreshPetSize()
    }

    func resizePet(to frame: NSRect, finished: Bool = false) {
        customPetSize = frame.size
        petWindow?.setFrame(visiblePetFrame(frame), display: true)
        if finished {
            let cfg = ConfigStore.shared
            let actual = petWindow?.frame ?? frame
            cfg.petWidth = actual.width
            cfg.petHeight = actual.height
            cfg.petPosX = actual.midX
            cfg.petPosY = actual.midY
            cfg.save()
            NotificationCenter.default.post(name: .petManualMoveFinished, object: nil)
        }
    }

    /// Resizing the frameless cat must not put its head or paws off-screen.
    private func visiblePetFrame(_ rect: NSRect) -> NSRect {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(center) })
                ?? NSScreen.screens.first(where: { $0.visibleFrame.intersects(rect) })
                ?? NSScreen.main else { return rect }
        let visible = screen.visibleFrame
        var result = rect
        result.origin.x = min(max(rect.minX, visible.minX), max(visible.minX, visible.maxX - rect.width))
        result.origin.y = min(max(rect.minY, visible.minY), max(visible.minY, visible.maxY - rect.height))
        return result
    }

    func showSettings(tab: Int = 0) {
        SettingsRouter.shared.tab = tab
        if let w = settingsWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = SettingsView().environmentObject(AppModel.shared)
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []
        let win = EditingWindow(contentRect: NSRect(origin: .zero, size: CGSize(width: 840, height: 620)),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                backing: .buffered, defer: false)
        win.title = "设置"
        win.contentViewController = host
        win.contentMinSize = NSSize(width: 720, height: 460)
        win.isMovableByWindowBackground = false
        win.setFrameAutosaveName("PetCalendarSettingsWindow")
        win.isReleasedWhenClosed = false
        if !win.setFrameUsingName("PetCalendarSettingsWindow") { win.center() }
        // makeKeyAndOrderFront：让设置窗真正成为 key，文本框的 ⌘A/⌘C/⌘V/⌘X 编辑快捷键才能路由生效
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = win
    }

    func toggleDesktop() {
        guard let win = desktopWindow else { makeDesktopWindow(); return }
        if win.isVisible {
            closeCalendarAndCompanions()
        } else {
            reopenCalendar()
        }
    }

    func closeCalendarAndCompanions() {
        desktopWindow?.orderOut(nil)
        petWindow?.orderOut(nil)
        petVisible = false
        PetBrain.shared.setEnabled(false)
        clockWindow?.orderOut(nil)
        setClockPanelOpen(false)
        desktopVisible = false
        LogStore.shared.log("[窗口] 日历关闭：一并隐藏日历、宠物和时钟；Dock 点击可恢复")
    }

    func reopenCalendar() {
        if desktopWindow == nil { makeDesktopWindow() }
        guard let win = desktopWindow else { return }
        DesktopWindowPlacer.apply(to:win,pin:ConfigStore.shared.desktopPin)
        win.makeKeyAndOrderFront(nil)
        desktopVisible = true
        if ConfigStore.shared.petShown { setPetVisible(true) }
        if ConfigStore.shared.countdownEnabled { setClockVisible(true) }
        NSApp.activate(ignoringOtherApps:true)
    }

    func setPetVisible(_ visible: Bool) {
        let cfg = ConfigStore.shared
        cfg.petShown = visible
        cfg.save()
        if visible {
            if petWindow == nil { makePetWindow() }
            petWindow?.orderFront(nil)
            petVisible = petWindow != nil
            PetBrain.shared.setEnabled(petVisible)
        } else {
            petWindow?.orderOut(nil)
            petVisible = false
            PetBrain.shared.setEnabled(false)
        }
    }

    func togglePet() { setPetVisible(!ConfigStore.shared.petShown) }

    /// 宠物窗拖动后去抖 1s 记忆中心点位置
    private var petPosWork: DispatchWorkItem?
    var isPetInteracting = false
    private var movingPetAutomatically = false
    func movePetAutomatically(to origin: NSPoint) {
        guard !isPetInteracting else { return }
        movingPetAutomatically = true
        petWindow?.setFrameOrigin(origin)
        movingPetAutomatically = false
    }
    private func schedulePetPositionSave() {
        guard !movingPetAutomatically else { return }
        petPosWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let win = self.petWindow else { return }
            let cfg = ConfigStore.shared
            cfg.petPosX = win.frame.midX
            cfg.petPosY = win.frame.midY
            cfg.save()
            LogStore.shared.log("[宠物] 位置已记忆 (\(Int(cfg.petPosX)), \(Int(cfg.petPosY)))")
        }
        petPosWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private(set) var reminderWindow: NSWindow?

    /// 事项到点弹窗提醒（独立 floating 面板，非模态，不会 modalize 主窗）
    func showReminderPopup(event: EventItem, remaining: Int) {
        LogStore.shared.log("[提醒] 弹窗：\(event.title)（剩 \(remaining) 分钟）")
        hideReminderPopup()
        let detail = remaining == 0 ? "现在开始 / 截止" : "还有 \(remaining) 分钟"
        let root = ReminderPopupView(
            title: event.title,
            detail: detail,
            onDismiss: { self.hideReminderPopup() },
            onDone: { AppModel.shared.toggleDone(event.id); self.hideReminderPopup() })
            .font(.appBody)
        let host = NSHostingController(rootView: root)
        let popupScale = max(1, ConfigStore.shared.fontScale)
        let size = CGSize(width: 320 * popupScale, height: 200 * popupScale)
        let win = DesktopPanel(contentRect: NSRect(origin: .zero, size: size),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        win.contentViewController = host
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = .floating
        win.hidesOnDeactivate = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 与悬浮时钟「在一起」：优先贴在时钟正下方（右对齐）；时钟未显示时退到屏幕右上角
        var origin: CGPoint? = nil
        if let clock = clockWindow, clock.isVisible {
            let cf = clock.frame
            origin = CGPoint(x: cf.maxX - size.width, y: cf.minY - size.height - 12)
        } else if let screen = NSScreen.screens.first ?? NSScreen.main {
            let f = screen.visibleFrame
            origin = CGPoint(x: f.maxX - size.width - 16, y: f.maxY - size.height - 16)
        }
        if let o = origin {
            win.setFrame(NSRect(origin: o, size: size), display: true)
        }
        win.orderFront(nil)
        reminderWindow = win
    }

    func hideReminderPopup() {
        reminderWindow?.orderOut(nil)
        reminderWindow = nil
    }

    // MARK: - 悬浮时钟（右上角常驻）+ 今日待办面板（点击红点展开）

    private(set) var clockWindow: NSWindow?
    /// 待办面板是否展开（与时钟同一窗体，展开时窗口变大）
    @Published var clockPanelOpen = false
    var clockWindowSize: CGSize {
        let diameter = 160 * ConfigStore.shared.clockScale
        return clockPanelOpen ? CGSize(width: max(300,diameter), height: diameter+190)
            : CGSize(width:diameter,height:diameter)
    }

    func resizeClock(scale: Double, finished: Bool = false) {
        ConfigStore.shared.clockScale = min(2.5,max(0.75,scale))
        updateClockFrame()
        if finished { ConfigStore.shared.save() }
    }

    func moveClock(to origin: NSPoint) {
        guard let win = clockWindow else { return }
        win.setFrame(visiblePetFrame(NSRect(origin: origin, size: win.frame.size)), display: true)
    }

    private func updateClockFrame() {
        guard let win = clockWindow else { return }
        let target = clockWindowSize
        let old = win.frame
        win.setFrame(visiblePetFrame(NSRect(x:old.maxX-target.width,y:old.maxY-target.height,
            width:target.width,height:target.height)),display:true)
    }

    func makeClockWindow() {
        LogStore.shared.log("[窗口] 创建悬浮时钟…")
        let root = ClockWidgetView()
            .environmentObject(AppModel.shared)
            .environmentObject(ConfigStore.shared)
            .font(.appBody)
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []
        let size = clockWindowSize
        // 与宠物窗一致：NSPanel + nonactivatingPanel，不抢焦点但可点可拖
        let win = ClockInteractionPanel(contentRect: NSRect(origin: .zero, size: size),
                                        styleMask: [.borderless, .nonactivatingPanel],
                                        backing: .buffered, defer: false)
        win.contentViewController = host
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.level = .floating
        win.hidesOnDeactivate = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isMovableByWindowBackground = false
        if let screen = NSScreen.screens.first ?? NSScreen.main {
            let f = screen.visibleFrame
            win.setFrame(NSRect(x: f.maxX - size.width - 16, y: f.maxY - size.height - 16,
                                width: size.width, height: size.height), display: true)
        }
        win.orderFront(nil)
        clockWindow = win
        LogStore.shared.log("[窗口] 悬浮时钟已创建/显示")
    }

    /// 显示/隐藏悬浮时钟（设置开关与菜单栏共用，实时生效）
    func setClockVisible(_ on: Bool) {
        if on {
            if clockWindow == nil { makeClockWindow() } else { clockWindow?.orderFront(nil) }
        } else {
            setClockPanelOpen(false)
            clockWindow?.orderOut(nil)
        }
        LogStore.shared.log("[窗口] 悬浮时钟 \(on ? "显示" : "隐藏")")
    }

    /// 菜单栏切换：翻转配置并持久化，再应用可见性
    func toggleClock() {
        let cfg = ConfigStore.shared
        cfg.countdownEnabled.toggle()
        cfg.save()
        setClockVisible(cfg.countdownEnabled)
    }

    /// 展开/收起待办面板：同一窗口内改尺寸（保持右上角不动），面板与时钟一体、可整体拖动
    func setClockPanelOpen(_ open: Bool) {
        clockPanelOpen = open
        updateClockFrame()
        if ConfigStore.shared.petShown, petWindow?.isVisible == true {
            PetBrain.shared.setEnabled(true)
        }
    }

    /// Only the red badge toggles the task panel; hovering never changes it.
    func toggleClockPanel() {
        setClockPanelOpen(!clockPanelOpen)
    }

    /// 卡死时的逃生口：强制激活主日历 + 宠物窗口
    func reactivate() {
        LogStore.shared.log("[窗口] 手动重新激活主日历 + 宠物窗口")
        desktopWindow?.makeKeyAndOrderFront(nil)
        petWindow?.orderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 应用到主日历窗口的「锁定」状态（只在启动/切换时调用）
    func applyCalendarLock() {
        guard let win = desktopWindow else { return }
        let locked = ConfigStore.shared.calendarLocked
        win.isMovable = !locked
        win.isMovableByWindowBackground = !locked
    }

    /// 应用到宠物窗口的「锁定」状态（与日历独立）
    func applyPetLock() {
        guard let win = petWindow else { return }
        let locked = ConfigStore.shared.petLocked
        win.isMovable = !locked
        // Manual dragging is handled in PetInteractionPanel; locking disables it.
        win.isMovableByWindowBackground = false
        win.ignoresMouseEvents = false
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let bundleID = "com.mycalendar.app"
    /// App Nap 豁免令牌（必须持有，释放即失效）
    private var activityToken: NSObjectProtocol?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowManager.shared.reopenCalendar()
        return true
    }

    func closeCalendarAndCompanions() {
        WindowManager.shared.closeCalendarAndCompanions()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LogStore.shared.log("===== 应用启动 applicationDidFinishLaunching =====")
        // 防 App Nap：浮窗应用长期无焦点时，系统会把全部定时器限流节流
        //（实测打包版 30Hz 鼠标采样被降到 ~0.6Hz，宠物跟随冻结、倒计时时钟卡顿、提醒轮询延迟；
        // debug 从终端启动不触发 App Nap，故开发期无法复现）。
        // beginActivity + Info.plist NSAppSleepDisabled 双保险；仍允许系统空闲休眠，不耗电。
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "桌面宠物鼠标跟随、倒计时时钟与提醒调度需要定时器持续运行")
        BeatWatcher.shared.start()
        // 常规 App：Dock 图标可见，⌘⌥Esc 强制退出列表、Dock 右键退出都可用
        NSApp.setActivationPolicy(.regular)

        // 单实例：若已有相同 bundle id 的实例在跑，新实例直接退出，避免重复图标/窗口
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if running.count > 1 {
            let me = NSRunningApplication.current
            if let eldest = running.sorted(by: { $0.processIdentifier < $1.processIdentifier }).first,
               eldest.processIdentifier != me.processIdentifier {
                print("[MyCalendar] 已有实例在运行，退出自身")
                NSApp.terminate(nil)
                return
            }
        }

        setupMainMenu()
        setupStatusItem()
        HolidayCalendar.shared.startAutomaticUpdates()
        ReminderScheduler.shared.start()
        WindowManager.shared.makeDesktopWindow()
        if ConfigStore.shared.petShown { WindowManager.shared.makePetWindow() }
        if ConfigStore.shared.countdownEnabled {
            WindowManager.shared.makeClockWindow()
        }
        promptAISetupIfNeeded()
    }

    /// 首次启动且未配置 AI 时，显式引导用户选择模型并输入秘钥
    private func promptAISetupIfNeeded() {
        let cfg = ConfigStore.shared
        guard !cfg.aiPromptShown, cfg.apiKey.isEmpty, !cfg.llm.enabled else { return }
        cfg.aiPromptShown = true
        cfg.save()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            let alert = NSAlert()
            alert.messageText = "配置 AI 助理"
            alert.informativeText = "宠物日历可以用大模型生成个性化提醒文案。\n请选择模型供应商并输入 API Key（也可随时从菜单栏日历图标 →「AI 模型与秘钥…」进入）。\n不配置也不影响使用，会自动使用内置台词。"
            alert.addButton(withTitle: "去配置")
            alert.addButton(withTitle: "稍后")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                WindowManager.shared.showSettings(tab: 4)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        LogStore.shared.log("===== 应用退出 applicationWillTerminate =====")
        VoiceService.shared.stop()
    }

    /// Cmd+Q 全局退出入口（吸附到主菜单）+ 标准编辑菜单（让输入框支持 ⌘A/⌘C/⌘V/⌘X/⌘Z）
    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu

        // 编辑菜单：target=nil 走标准响应链。输入框已改为真 NSTextField（AppKitTextField），
        // 聚焦时 firstResponder 为字段编辑器，⌘Z/X/C/V/A 由系统原生处理
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    /// 菜单栏常驻图标 + 完整菜单（可靠退路）
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "宠物日历")
        }
        let menu = NSMenu()
        menu.addItem(makeItem("打开设置…", #selector(openSettings), key: ",", mods: .command))
        menu.addItem(makeItem("AI 模型与秘钥…", #selector(openAISettings), key: "", mods: []))
        menu.addItem(.separator())
        menu.addItem(makeItem("显示/隐藏 宠物日历", #selector(toggleDesktop), key: "", mods: []))
        menu.addItem(makeItem("显示/隐藏 桌面宠物", #selector(togglePet), key: "", mods: []))
        menu.addItem(makeItem("显示/隐藏 悬浮时钟", #selector(toggleClock), key: "", mods: []))
        menu.addItem(makeItem("恢复主日历 × 宠物", #selector(reactivateMain), key: "", mods: []))
        menu.addItem(.separator())
        menu.addItem(makeItem("测试语音播报", #selector(testVoice), key: "", mods: []))
        menu.addItem(.separator())
        menu.addItem(makeItem("退出", #selector(quit), key: "q", mods: .command))
        item.menu = menu
        statusItem = item
    }

    private func makeItem(_ title: String, _ action: Selector, key: String, mods: NSEvent.ModifierFlags) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = self
        return i
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        WindowManager.shared.showSettings()
    }
    @objc private func openAISettings() {
        NSApp.activate(ignoringOtherApps: true)
        WindowManager.shared.showSettings(tab: 4)
    }
    @objc private func toggleDesktop() { WindowManager.shared.toggleDesktop() }
    @objc private func togglePet() { WindowManager.shared.togglePet() }
    @objc private func toggleClock() { WindowManager.shared.toggleClock() }
    @objc private func reactivateMain() { WindowManager.shared.reactivate() }
    @objc private func testVoice() {
        let cfg = ConfigStore.shared
        let kind = cfg.effectivePersonality()
        let text = Personality(kind: kind).baseLine(title: "交周报", remaining: 30)
        VoiceService.shared.speakPersonality(text, kind: kind)
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
