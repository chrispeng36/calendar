import AppKit
import CoreGraphics
import SwiftUI

@main
struct MyCalendarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 无默认窗口；UI 由 AppDelegate 用 NSStatusItem（菜单栏）承载
        Settings { EmptyView() }
    }
}

// 可成为 key 的无边框面板，用于接收点击
final class DesktopPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

enum DesktopWindowPlacer {
    /// 尽力将窗口放到「壁纸之上、图标之下」；结果受系统版本影响，需 M0 真机验证。
    static func apply(to win: NSWindow, pin: Bool) {
        if pin {
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

    private(set) var desktopWindow: NSWindow?
    private(set) var petWindow: NSWindow?
    private(set) var settingsWindow: NSWindow?

    func makeDesktopWindow() {
        LogStore.shared.log("[窗口] 创建桌面日历窗口…")
        let root = CalendarView().environmentObject(AppModel.shared)
        let host = NSHostingController(rootView: root)
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
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.title = "桌面日历"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.contentViewController = host
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
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
        applyCalendarLock()
        LogStore.shared.log("[窗口] 桌面日历窗口已创建/显示")
    }

    func makePetWindow() {
        LogStore.shared.log("[窗口] 创建宠物悬浮球…")
        let root = PetView().accentColor(ConfigStore.shared.customAccent()).environmentObject(AppModel.shared)
        let host = NSHostingController(rootView: root)
        let size = Self.petBallSize
        // NSPanel + nonactivatingPanel：不抢焦点但可点可拖（NSWindow 用该 mask 会拖拽异常）
        let win = DesktopPanel(contentRect: NSRect(origin: .zero, size: size),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        win.contentViewController = host
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.isMovableByWindowBackground = true
        // 浮动在最上层，可点击、可拖动（不再是贴桌面层，否则会被所有窗口盖住）
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces]
        if let screen = NSScreen.screens.first ?? NSScreen.main {
            let f = screen.visibleFrame
            win.setFrame(NSRect(x: f.maxX - size.width - 40, y: f.minY + 40,
                                width: size.width, height: size.height), display: true)
        }
        win.orderFront(nil)
        LogStore.shared.log("[窗口] 宠物悬浮球已创建/显示（默认收起）")
        petWindow = win
        applyPetLock()
    }

    /// 展开/收起宠物悬浮球（动态调整窗口尺寸，保持中心不动）
    func setPetExpanded(_ e: Bool) {
        guard let win = petWindow else { return }
        petExpanded = e
        let target = e ? Self.petCardSize : Self.petBallSize
        let old = win.frame
        win.setFrame(NSRect(x: old.midX - target.width / 2, y: old.midY - target.height / 2,
                            width: target.width, height: target.height),
                     display: true, animate: true)
        LogStore.shared.log("[宠物] 悬浮球\(e ? "展开" : "收起")")
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
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: CGSize(width: 840, height: 620)),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "设置"
        win.contentViewController = host
        win.isReleasedWhenClosed = false
        win.center()
        // makeKeyAndOrderFront：让设置窗真正成为 key，文本框的 ⌘A/⌘C/⌘V/⌘X 编辑快捷键才能路由生效
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = win
    }

    func toggleDesktop() {
        guard let win = desktopWindow else { return }
        if win.isVisible { win.orderOut(nil) } else { win.orderFront(nil) }
        desktopVisible = win.isVisible
    }

    func togglePet() {
        guard let win = petWindow else { return }
        LogStore.shared.log("[窗口] 切换宠物窗口可见性（当前 \(win.isVisible)）")
        if win.isVisible {
            win.orderOut(nil)
            // 宠物窗隐藏后若它曾是 key，需把主日历窗重新设为 key 并激活，避免主窗失去交互/点不动
            if let d = desktopWindow { d.makeKeyAndOrderFront(nil) }
            NSApp.activate(ignoringOtherApps: true)
        } else {
            win.orderFront(nil)
        }
        petVisible = win.isVisible
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
        let host = NSHostingController(rootView: root)
        let size = CGSize(width: 320, height: 200)
        let win = DesktopPanel(contentRect: NSRect(origin: .zero, size: size),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        win.contentViewController = host
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces]
        if let screen = NSScreen.screens.first ?? NSScreen.main {
            let f = screen.visibleFrame
            win.setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height - 24,
                                width: size.width, height: size.height), display: true)
        }
        win.orderFront(nil)
        reminderWindow = win
    }

    func hideReminderPopup() {
        reminderWindow?.orderOut(nil)
        reminderWindow = nil
    }

    // MARK: - 悬浮时钟（右上角常驻）+ 今日待办面板（悬停弹出）

    private(set) var clockWindow: NSWindow?
    private(set) var todoPanelWindow: NSWindow?
    static let clockSize = CGSize(width: 160, height: 160)
    static let todoPanelSize = CGSize(width: 280, height: 184)
    // hover 去抖（移植 notice-clock：OPEN_DELAY 220ms / CLOSE_DELAY 450ms）
    private var showPanelWork: DispatchWorkItem?
    private var hidePanelWork: DispatchWorkItem?

    func makeClockWindow() {
        LogStore.shared.log("[窗口] 创建悬浮时钟…")
        let root = ClockWidgetView()
            .environmentObject(AppModel.shared)
            .environmentObject(ConfigStore.shared)
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []
        let size = Self.clockSize
        // 与宠物窗一致：NSPanel + nonactivatingPanel，不抢焦点但可点可拖
        let win = DesktopPanel(contentRect: NSRect(origin: .zero, size: size),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        win.contentViewController = host
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces]
        win.isMovableByWindowBackground = true
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
            hideTodoPanel()
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

    /// 在时钟正下方弹出今日待办面板（右对齐，紧贴圆盘）
    func showTodoPanel() {
        guard let clock = clockWindow else { return }
        if todoPanelWindow == nil {
            let root = TodayPanelView()
                .environmentObject(AppModel.shared)
                .environmentObject(ConfigStore.shared)
            let host = NSHostingController(rootView: root)
            host.sizingOptions = []
            let size = Self.todoPanelSize
            let win = DesktopPanel(contentRect: NSRect(origin: .zero, size: size),
                                   styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
            win.contentViewController = host
            win.isOpaque = false
            win.backgroundColor = .clear
            win.hasShadow = false
            win.level = .floating
            win.collectionBehavior = [.canJoinAllSpaces]
            todoPanelWindow = win
        }
        guard let win = todoPanelWindow else { return }
        let size = Self.todoPanelSize
        let cf = clock.frame
        win.setFrame(NSRect(x: cf.maxX - size.width, y: cf.minY - size.height - 6,
                            width: size.width, height: size.height), display: true)
        win.orderFront(nil)
    }

    func hideTodoPanel() {
        showPanelWork?.cancel(); showPanelWork = nil
        hidePanelWork?.cancel(); hidePanelWork = nil
        todoPanelWindow?.orderOut(nil)
    }

    /// 徽标点击：立即切换面板显隐
    func toggleTodoPanel() {
        if let w = todoPanelWindow, w.isVisible { hideTodoPanel() } else {
            hidePanelWork?.cancel(); showPanelWork?.cancel(); showTodoPanel()
        }
    }

    /// 时钟圆盘 hover：进入→延时弹出面板；离开→延时收起
    func clockHoverChanged(_ inside: Bool) {
        if inside {
            hidePanelWork?.cancel(); hidePanelWork = nil
            if todoPanelWindow?.isVisible != true, showPanelWork == nil {
                let work = DispatchWorkItem { self.showTodoPanel(); self.showPanelWork = nil }
                showPanelWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
            }
        } else {
            showPanelWork?.cancel(); showPanelWork = nil
            scheduleHidePanel()
        }
    }

    /// 面板 hover：进入→取消收起；离开→延时收起
    func panelHoverChanged(_ inside: Bool) {
        if inside {
            hidePanelWork?.cancel(); hidePanelWork = nil
        } else {
            scheduleHidePanel()
        }
    }

    private func scheduleHidePanel() {
        hidePanelWork?.cancel()
        let work = DispatchWorkItem { self.hideTodoPanel() }
        hidePanelWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
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
        win.isMovableByWindowBackground = !locked
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let bundleID = "com.mycalendar.app"

    func applicationDidFinishLaunching(_ notification: Notification) {
        LogStore.shared.log("===== 应用启动 applicationDidFinishLaunching =====")
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
        ReminderScheduler.shared.start()
        WindowManager.shared.makeDesktopWindow()
        WindowManager.shared.makePetWindow()
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
            alert.informativeText = "桌面日历可以用大模型生成个性化提醒文案。\n请选择模型供应商并输入 API Key（也可随时从菜单栏日历图标 →「AI 模型与秘钥…」进入）。\n不配置也不影响使用，会自动使用内置台词。"
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

        // 编辑菜单：target=nil 走响应链，文本框自动获得全选/剪切/拷贝/粘贴/撤销
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
            button.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "桌面日历")
        }
        let menu = NSMenu()
        menu.addItem(makeItem("打开设置…", #selector(openSettings), key: ",", mods: .command))
        menu.addItem(makeItem("AI 模型与秘钥…", #selector(openAISettings), key: "", mods: []))
        menu.addItem(.separator())
        menu.addItem(makeItem("显示/隐藏 桌面日历", #selector(toggleDesktop), key: "", mods: []))
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
