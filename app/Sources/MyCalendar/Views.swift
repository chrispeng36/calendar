import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

enum ExportKind { case ics, csv }

// MARK: - 月历网格计算

enum CalendarEngine {
    /// 返回填满整网格的日期（含上月末/下月初补位），保证 7 的倍数
    static func gridded(_ month: Date, firstWeekday: Int = 1) -> [Date] {
        let cal = Calendar.current
        guard let interval = cal.dateInterval(of: .month, for: month) else { return [] }
        let firstOfMonth = interval.start
        let wd = cal.component(.weekday, from: firstOfMonth)
        let offset = (wd - firstWeekday + 7) % 7
        var cells: [Date] = []
        for i in 0..<offset {
            if let d = cal.date(byAdding: .day, value: i - offset, to: firstOfMonth) { cells.append(d) }
        }
        let days = cal.range(of: .day, in: .month, for: month)?.count ?? 30
        for d in 0..<days {
            if let date = cal.date(byAdding: .day, value: d, to: firstOfMonth) { cells.append(date) }
        }
        while cells.count % 7 != 0, let last = cells.last,
              let next = cal.date(byAdding: .day, value: 1, to: last) {
            cells.append(next)
        }
        return cells
    }
}

// MARK: - 视图模式（日 / 周 / 月 / 年）

enum CalendarViewMode: String, CaseIterable {
    case day, week, month, year
    var label: String {
        switch self {
        case .day: return "日"
        case .week: return "周"
        case .month: return "月"
        case .year: return "年"
        }
    }
}

// MARK: - 主日历视图

/// 窗口级编辑器上下文：统一承载「新建/编辑」，避免在格子/详情上挂 popover/sheet 导致模态卡死（主窗口点不动）
struct EventEditorContext: Identifiable {
    let id = UUID()
    let date: Date
    var existing: EventItem?
}

struct CalendarView: View {
    @ObservedObject var model = AppModel.shared
    @ObservedObject var config = ConfigStore.shared
    @State private var currentMonth = Date()
    @State private var selected: Date?
    @State private var editorContext: EventEditorContext?   // 窗口级编辑器（新建/编辑）
    @State private var mode: CalendarViewMode = .month
    @State private var selectedEventID: UUID?   // 右侧详情面板选中的事项

    var selectedEvent: EventItem? {
        selectedEventID.flatMap { id in model.events.first { $0.id == id && !$0.isDeleted } }
    }

    private let weekdays = ["日", "一", "二", "三", "四", "五", "六"]

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 6) {
                header
                if !config.llm.enabled || config.apiKey.isEmpty {
                    aiBanner
                }
                switch mode {
                case .month:
                    weekdayRow
                    grid
                    legend
                case .day, .week:
                    CalendarTimelineView(dates: timelineDates,
                                         onSelect: { selected = $0 },
                                         onSelectEvent: { selectedEventID = $0.id },
                                         onCompose: { d, ex in openCompose(d, editing: ex) })
                case .year:
                    YearView(year: currentMonth) { m in
                        mode = .month
                        currentMonth = m
                        selected = Calendar.current.date(
                            from: Calendar.current.dateComponents([.year, .month], from: m))
                    }
                }
            }
            .padding(.init(top: 18, leading: 12, bottom: 8, trailing: 12))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            // 右侧详情面板：作为界面一部分常驻，非弹出框
            if let ev = selectedEvent {
                Rectangle().fill(hairline).frame(width: 0.5)
                EventDetailPanel(eventID: ev.id,
                                 onEdit: { e in openCompose(e.startDate, editing: e) }) {
                    selectedEventID = nil
                }
                .frame(width: 292)
            }
        }
        .foregroundStyle(foregroundTone)
        .background(fxBackground.ignoresSafeArea())
        // 窗口内联编辑器：不再用 .sheet。macOS 的 sheet 是独立模态窗口，会把同为 NSWindow 的
        // 主日历窗连带 modalize，一旦 sheet 生命周期不同步（关窗/切视图/缩放期间被重建），
        // 日历窗就永久"点不动"——宠物窗之所以从不卡，正因为它是独立 .floating 面板、从不挂模态。
        // 改为在窗口内容之上画一张 overlay 卡片，彻底消除"父窗口被模态化"这条路径。
        .overlay { editorOverlay }
        .accentColor(config.customAccent())
    }

    @ViewBuilder
    var editorOverlay: some View {
        if let ctx = editorContext {
            ZStack {
                // 不响应「点击外部关闭」：macOS 原本的 sheet 也是模态、点外部不关闭，避免误触丢失未保存编辑
                Color.black.opacity(0.45).ignoresSafeArea()
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: ctx.existing == nil ? "plus.circle.fill" : "pencil.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(config.customAccent())
                        Text(ctx.existing == nil ? "新建事项" : "编辑事项")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                        Button { editorContext = nil } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("关闭")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    Divider()
                    EventEditorView(date: ctx.date, existing: ctx.existing) { editorContext = nil }
                }
                .frame(width: 340)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(LinearGradient(colors: [config.customAccent().opacity(0.6), config.customAccent().opacity(0.08)],
                                           startPoint: .top, endPoint: .bottom), lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 22, y: 10)
            }
            .zIndex(10)
            .transition(.opacity)
        }
    }

    func openCompose(_ day: Date, editing: EventItem? = nil) {
        LogStore.shared.log("[编辑] 打开事项编辑器（\(editing == nil ? "新建" : "编辑")）")
        editorContext = EventEditorContext(date: day, existing: editing)
    }

    /// 未配置 AI 时的显式入口横幅（配置完成自动消失）
    var aiBanner: some View {
        Button { WindowManager.shared.showSettings(tab: 4) } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                Text("AI 助理未配置 — 点击选择模型、填写接口地址与 API Key")
                    .font(.caption)
                Spacer()
                Image(systemName: "chevron.right").font(.caption2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.accentColor.opacity(0.18))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.5), lineWidth: 1))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    var foregroundTone: Color {
        config.textTone(for: config.theme)
    }

    var fxBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        // 背景墙优先级：用户图片 > 预设渐变 > 自定义背景色；都未设则用主题默认
        if let img = config.wallpaperImage() {
            return AnyView(
                shape.background(
                    Image(nsImage: img).resizable().scaledToFill()
                )
                .clipShape(shape)
                .overlay(shape.stroke(hairline, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.3), radius: 18, y: 8))
        }
        if let grad = config.presetGradient() {
            return AnyView(
                shape.fill(grad)
                    .overlay(shape.stroke(.white.opacity(0.25), lineWidth: 1))
                    .shadow(color: .black.opacity(0.32), radius: 20, y: 8))
        }
        if !config.customBgHex.isEmpty, let nc = HexColor.nsColor(fromHex: config.customBgHex) {
            return AnyView(
                shape.fill(Color(nsColor: nc))
                    .overlay(shape.stroke(hairline, lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.32), radius: 22, y: 10))
        }
        if config.theme == .aurora {
            return AnyView(TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
                auroraBackdrop(angle: (context.date.timeIntervalSinceReferenceDate * 18)
                    .truncatingRemainder(dividingBy: 360))
            })
        } else {
            return AnyView(staticBackdrop)
        }
    }

    var staticBackdrop: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        switch config.theme {
        case .glass:
            return AnyView(
                shape.fill(.ultraThinMaterial)
                    .overlay(shape.fill(
                        LinearGradient(colors: [.white.opacity(0.20), .clear],
                                       startPoint: .top, endPoint: .center)))
                    .overlay(shape.stroke(
                        LinearGradient(colors: [.white.opacity(0.40), .white.opacity(0.08)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1))
                    .shadow(color: .black.opacity(0.32), radius: 22, y: 10))
        case .minimal:
            return AnyView(
                shape.fill(.ultraThinMaterial.opacity(0.20))
                    .overlay(shape.stroke(LinearGradient(colors: [.white.opacity(0.20), .white.opacity(0.05)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing),
                                          lineWidth: 1)))
        case .neon:
            return AnyView(
                shape.fill(Color.black.opacity(0.62))
                    .overlay(shape.fill(
                        LinearGradient(colors: [.cyan.opacity(0.16), .purple.opacity(0.16)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .overlay(shape.stroke(
                        LinearGradient(colors: [.cyan, .purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1.8))
                    .shadow(color: .cyan.opacity(0.5), radius: 20)
                    .shadow(color: .purple.opacity(0.35), radius: 6))
        case .aurora:
            return AnyView(shape.fill(.ultraThinMaterial.opacity(0.5)))
        }
    }

    func auroraBackdrop(angle: Double) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return ZStack {
            shape.fill(LinearGradient(colors: [.blue, .purple, .pink, .orange],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
                .hueRotation(.degrees(angle))
            Circle().fill(Color.cyan)
                .frame(width: 360, height: 360).blur(radius: 90)
                .offset(x: 220, y: -140).opacity(0.7).hueRotation(.degrees(angle))
            Circle().fill(Color.pink)
                .frame(width: 320, height: 320).blur(radius: 90)
                .offset(x: -200, y: 150).opacity(0.7).hueRotation(.degrees(angle))
            shape.fill(Color.black.opacity(0.14))
        }
        .clipShape(shape)
        .overlay(shape.stroke(.white.opacity(0.25), lineWidth: 1))
        .shadow(color: .purple.opacity(0.4), radius: 20)
    }

    var header: some View {
        HStack(alignment: .center, spacing: 10) {
            // 左侧：今天
            Button {
                currentMonth = Date()
                selected = Date()
            } label: {
                Text("今天")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                    .overlay(Capsule().stroke(Color.accentColor.opacity(0.55), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)

            Spacer()

            // 中间：月份/年份大字标题（明显大于任意一天的数字）
            Button { step(-1) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(iconChip)
            }
            .buttonStyle(.plain)

            Text(titleString)
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(titleForeground)
                .minimumScaleFactor(0.55)
                .lineLimit(1)
                .frame(minWidth: 150)

            Button { step(1) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(iconChip)
            }
            .buttonStyle(.plain)

            Spacer()

            // 右侧：视图切换（日/周/月/年）+ 设置
            Picker("", selection: $mode) {
                ForEach(CalendarViewMode.allCases, id: \.self) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 148)

            Button { WindowManager.shared.showSettings() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(iconChip)
            }
            .buttonStyle(.plain)
            .help("设置")
            Button { toggleCalendarLock() } label: {
                Image(systemName: config.calendarLocked ? "lock.fill" : "lock.open")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(iconChip)
                    .foregroundStyle(config.calendarLocked ? Color.accentColor : foregroundTone)
            }
            .buttonStyle(.plain)
            .help(config.calendarLocked ? "已锁定日历窗口（禁止拖拽）" : "锁定日历窗口，禁止拖拽")
        }
        .foregroundStyle(foregroundTone)
        .padding(.horizontal, 2)
        .padding(.bottom, 8)
    }

    func toggleCalendarLock() {
        config.calendarLocked.toggle()
        config.save()
        WindowManager.shared.applyCalendarLock()
    }

    var iconChip: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.white.opacity(0.3), lineWidth: 0.8))
            .shadow(color: Color.black.opacity(0.25), radius: 3, y: 1)
    }

    var titleForeground: AnyShapeStyle {
        switch config.theme {
        case .aurora, .neon:
            return AnyShapeStyle(LinearGradient(colors: [.cyan, .purple, .pink],
                                                startPoint: .leading, endPoint: .trailing))
        case .glass, .minimal:
            return AnyShapeStyle(foregroundTone)
        }
    }

    var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(weekdays.enumerated()), id: \.offset) { i, w in
                Text(w)
                    .frame(maxWidth: .infinity)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(2)
                    .foregroundStyle(i >= 5 ? weekendTone : foregroundTone.opacity(0.6))
            }
        }
        .padding(.vertical, 5)
        .background(alignment: .bottom) { Rectangle().fill(hairline).frame(height: 0.5) }
    }

    var grid: some View {
        let cells = CalendarEngine.gridded(currentMonth)
        let gap: CGFloat = 6   // 瓷砖缝：格子之间的留白
        return GeometryReader { geo in
            let rows = max(1, cells.count / 7)
            let cellH = max(0, (geo.size.height - CGFloat(rows - 1) * gap) / CGFloat(rows))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gap), count: 7), spacing: gap) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                    dayCell(day, height: cellH)
                }
            }
        }
    }

    func dayCell(_ day: Date, height: CGFloat) -> some View {
        let events = model.events(on: day)
        let isToday = Calendar.current.isDateInToday(day)
        let inMonth = Calendar.current.isDate(day, equalTo: currentMonth, toGranularity: .month)
        let isSelected = selected.map { Calendar.current.isDate($0, inSameDayAs: day) } ?? false
        let weekend = Calendar.current.isDateInWeekend(day)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 4) {
                Text(fmtDay(day))
                    .font(.system(size: 22, weight: isToday || isSelected ? .bold : .regular, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(numberTextColor(isSelected: isSelected, isToday: isToday, inMonth: inMonth, weekend: weekend))
                    .frame(width: 30, height: 30)
                    .background {
                        if isSelected {
                            Circle().fill(selectionCircle).shadow(color: Color.cyan.opacity(0.6), radius: 6)
                        } else if isToday {
                            Circle().fill(todayCircle).shadow(color: Color.orange.opacity(0.55), radius: 6)
                        }
                    }
                Spacer(minLength: 0)
                Text(LunarService.text(for: day))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(inMonth ? Color.secondary : Color.secondary.opacity(0.45))
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .padding(.top, 6)
            ForEach(Array(events.prefix(3))) { e in
                eventChip(e)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedEventID = e.id }
            }
            if events.count > 3 {
                Text("还有 \(events.count - 3) 条…")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .top)
        .background(cellBackground(inMonth: inMonth, isSelected: isSelected))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .simultaneousGesture(TapGesture().onEnded { selected = day })
        .simultaneousGesture(TapGesture(count: 2).onEnded { openCompose(day) })
        .contextMenu { dayContextMenu(day, events: events) }
    }

    @ViewBuilder
    func dayContextMenu(_ day: Date, events: [EventItem]) -> some View {
        Button("添加事项到 \(friendlyDay(day))…") { openCompose(day) }
        if !events.isEmpty {
            Divider()
            ForEach(events) { e in
                Button("编辑：\(e.title)") { openCompose(day, editing: e) }
                Button(e.isDone ? "取消完成：\(e.title)" : "标记完成：\(e.title)") {
                    model.toggleDone(e.id)
                }
            }
            Divider()
            Button("删除当天全部事项", role: .destructive) {
                for e in events { model.remove(e.id) }
            }
        }
    }

    func friendlyDay(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f.string(from: d)
    }

    func numberTextColor(isSelected: Bool, isToday: Bool, inMonth: Bool, weekend: Bool) -> Color {
        if isSelected || isToday { return .white }
        if !inMonth { return foregroundTone.opacity(0.35) }
        if weekend { return weekendTone }
        return foregroundTone
    }

    var todayCircle: LinearGradient {
        LinearGradient(colors: [.red, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    var selectionCircle: LinearGradient {
        LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    var weekendTone: Color { Color(red: 0.98, green: 0.60, blue: 0.42) }

    var hairline: Color {
        switch config.theme {
        case .neon, .aurora: return Color.white.opacity(0.14)
        case .glass, .minimal: return Color.black.opacity(0.16)
        }
    }

    /// 瓷砖质感：圆角 + 半透明材质 + 细描边 + 轻投影（立体感），缝隙由 grid spacing 提供
    func cellBackground(inMonth: Bool, isSelected: Bool) -> some View {
        let tile = RoundedRectangle(cornerRadius: 10, style: .continuous)
        if isSelected {
            return AnyView(
                tile.fill(.ultraThinMaterial)
                    .overlay(tile.fill(LinearGradient(colors: [Color.cyan.opacity(0.20), Color.blue.opacity(0.16)],
                                                      startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .overlay(tile.stroke(Color.cyan.opacity(0.55), lineWidth: 1))
                    .shadow(color: Color.black.opacity(0.28), radius: 5, y: 2))
        }
        let base: Color = inMonth ? Color.white.opacity(0.07) : Color.white.opacity(0.02)
        return AnyView(
            tile.fill(.ultraThinMaterial)
                .overlay(tile.fill(base))
                .overlay(tile.stroke(hairline, lineWidth: 0.5))
                .shadow(color: Color.black.opacity(0.18), radius: 3, y: 1.5))
    }

    func eventChip(_ e: EventItem) -> some View {
        let c = config.categoryFor(e)
        return Text(e.title)
            .font(.system(size: 9, weight: .medium))
            .lineLimit(1)
            .strikethrough(e.isDone)
            .foregroundStyle(e.isDone ? Color.secondary : foregroundTone)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 3).fill(c.color.opacity(e.isDone ? 0.14 : 0.4)))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(c.color.opacity(0.55), lineWidth: 0.5))
            .padding(.horizontal, 5)
    }

    var legend: some View {
        HStack(spacing: 14) {
            ForEach(config.visibleBuiltIn, id: \.self) { c in
                legendItem(config.categoryColor(c), config.label(for: c))
            }
            ForEach(config.customCategories) { cc in
                legendItem(cc.color, cc.label)
            }
            Spacer()
            Button("＋ 今天记一笔") { currentMonth = Date(); openCompose(Date()) }
        }
        .font(.caption2)
    }

    func legendItem(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 3) { Circle().fill(c).frame(width: 6, height: 6); Text(t) }
    }

    func step(_ n: Int) {
        let cal = Calendar.current
        switch mode {
        case .day:
            selected = cal.date(byAdding: .day, value: n, to: selected ?? Date())
        case .week:
            selected = cal.date(byAdding: .day, value: n * 7, to: selected ?? Date())
        case .month:
            currentMonth = cal.date(byAdding: .month, value: n, to: currentMonth) ?? currentMonth
        case .year:
            currentMonth = cal.date(byAdding: .year, value: n, to: currentMonth) ?? currentMonth
        }
    }

    var timelineDates: [Date] {
        switch mode {
        case .day: return [selected ?? Date()]
        case .week: return weekDates(selected ?? Date())
        default: return []
        }
    }

    func weekDates(_ anchor: Date) -> [Date] {
        let cal = Calendar.current
        let start = cal.dateInterval(of: .weekOfYear, for: anchor)?.start ?? anchor
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    var titleString: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        switch mode {
        case .month:
            f.dateFormat = "yyyy年M月"
            return f.string(from: currentMonth)
        case .day:
            // 用 ISO yyyy-MM-dd（+ 星期），避免「9月9日」中式混排
            f.dateFormat = "yyyy-MM-dd EEEE"
            return f.string(from: selected ?? Date())
        case .week:
            let days = weekDates(selected ?? Date())
            guard let a = days.first, let b = days.last else { return "" }
            f.dateFormat = "yyyy-MM-dd"
            return "\(f.string(from: a)) – \(f.string(from: b))"
        case .year:
            f.dateFormat = "yyyy年"
            return f.string(from: currentMonth)
        }
    }

    func fmtDay(_ d: Date) -> String {
        "\(Calendar.current.component(.day, from: d))"
    }
}

// MARK: - 事项详情面板（右侧常驻，界面的一部分，非弹出框）

struct EventDetailPanel: View {
    @ObservedObject var model = AppModel.shared
    @ObservedObject var config = ConfigStore.shared
    let eventID: UUID
    var onEdit: (EventItem) -> Void = { _ in }
    var onClose: () -> Void = {}

    var foregroundTone: Color {
        config.textTone(for: config.theme)
    }
    var hairline: Color {
        switch config.theme {
        case .neon, .aurora: return Color.white.opacity(0.14)
        case .glass, .minimal: return Color.black.opacity(0.16)
        }
    }

    /// 实时从模型取值：编辑 / 标记完成 / 删除后面板即时刷新
    var liveEvent: EventItem? {
        model.events.first { $0.id == eventID && !$0.isDeleted }
    }

    var body: some View {
        Group {
            if let e = liveEvent {
                detail(e)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(14)
        .background(config.theme == .neon || config.theme == .aurora
                    ? AnyView(Color.white.opacity(0.04))
                    : AnyView(Color.white.opacity(0.03)))
    }

    func detail(_ e: EventItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶栏：分类色 + 标题 + 关闭
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Circle().fill(catColor(e)).frame(width: 12, height: 12)
                        Text(e.title)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(foregroundTone)
                            .lineLimit(2)
                    }
                    HStack(spacing: 8) {
                        Text(e.isDone ? "已完成" : "进行中")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(e.isDone ? Color.secondary : Color.cyan)
                        if e.isAllDay {
                            Text("全天").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
                Button { onClose() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("关闭详情")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    detailRow(icon: "calendar", label: "日期", value: fullDay(e.startDate))
                    detailRow(icon: "clock", label: "时间", value: e.isAllDay ? "全天" : timeRange(e))
                    detailRow(icon: "tag", label: "分类", value: categoryLabel(e), color: catColor(e))
                    if !e.reminders.isEmpty {
                        detailRow(icon: "bell", label: "提醒", value: reminderText(e))
                    }
                    if let body = e.body, !body.isEmpty {
                        detailRow(icon: "note.text", label: "备注", value: body)
                    }
                }
                .padding(.top, 14)
            }

            Divider().overlay(hairline)

            // 底部操作
            HStack(spacing: 10) {
                Button { model.toggleDone(e.id) } label: {
                    Label(e.isDone ? "取消完成" : "标记完成",
                          systemImage: e.isDone ? "arrow.uturn.backward" : "checkmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
                Button { onEdit(e) } label: {
                    Label("编辑", systemImage: "pencil")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button(role: .destructive) { model.remove(e.id) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.top, 12)
        }
    }

    func detailRow(icon: String, label: String, value: String, color: Color? = nil) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            HStack(spacing: 5) {
                if let color { Circle().fill(color).frame(width: 8, height: 8) }
                Text(value)
                    .foregroundStyle(foregroundTone)
                    .lineLimit(nil)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(hairline).frame(height: 0.5) }
    }

    func catColor(_ e: EventItem) -> Color { config.categoryFor(e).color }
    func categoryLabel(_ e: EventItem) -> String { config.categoryFor(e).label }

    func fullDay(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日 EEEE"
        return f.string(from: d)
    }

    func timeRange(_ e: EventItem) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        var s = f.string(from: e.startDate)
        if let end = e.endDate {
            s += " – \(f.string(from: end))"
        }
        return s
    }

    func reminderText(_ e: EventItem) -> String {
        e.reminders.map { $0.humanOffset }.joined(separator: "、")
    }
}

// MARK: - 日 / 周时间线视图（小时网格 + 按时间定位事件）

struct CalendarTimelineView: View {
    let dates: [Date]                              // 日视图=1 个，周视图=7 个
    var onSelect: (Date) -> Void = { _ in }
    var onSelectEvent: (EventItem) -> Void = { _ in }
    var onCompose: (Date, EventItem?) -> Void = { _, _ in }

    @ObservedObject var model = AppModel.shared
    @ObservedObject var config = ConfigStore.shared

    private let gutter: CGFloat = 64          // 小时栏宽度（加宽，0-24 点标签更易读）
    private let hourHeight: CGFloat = 58       // 每小时行的固定高度（可纵向滚动浏览全天）

    var foregroundTone: Color {
        config.textTone(for: config.theme)
    }
    var hairline: Color {
        switch config.theme {
        case .neon, .aurora: return Color.white.opacity(0.14)
        case .glass, .minimal: return Color.black.opacity(0.16)
        }
    }
    var todayGrad: LinearGradient {
        LinearGradient(colors: [.red, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var hasAnyEvent: Bool {
        dates.contains { !model.events(on: $0).isEmpty }
    }

    var body: some View {
        // 始终渲染时间线网格（即使当天无事项），否则空日无法双击/右键新建
        timelineContent
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 半透明材质：让背景壁纸/色系透出来，整体偏透明
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(hairline, lineWidth: 0.5))
    }

    var timelineContent: some View {
        let range = hourRange()
        let gridHeight = CGFloat(range.end - range.start + 1) * hourHeight
        return VStack(spacing: 0) {
            // 顶部：星期表头 + 全天事项行 固定不滚动
            headerRow
            allDayRow
            Rectangle().fill(hairline).frame(height: 0.5)
            // 小时网格放进可滚动容器：固定每小时行高，0–24 点纵向滚动浏览
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    hourGrid(colH: hourHeight, range: range)
                        .frame(height: gridHeight, alignment: .top)
                }
                // 打开时定位到当前小时，避免顶部一大段空白夜时段
                .onAppear {
                    let h = min(max(Calendar.current.component(.hour, from: Date()), range.start), range.end)
                    proxy.scrollTo(h, anchor: .top)
                }
            }
        }
    }

    var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.system(size: 36))
                .foregroundStyle(foregroundTone.opacity(0.4))
            Text("当天没有事项")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(foregroundTone.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var headerRow: some View {
        HStack(spacing: 0) {
            // 固定高度的占位，避免 Rectangle 纵向贪婪撑开整行
            Color.clear.frame(width: gutter, height: 1)
            ForEach(dates, id: \.self) { d in
                dayHeader(d).frame(maxWidth: .infinity)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    func dayHeader(_ d: Date) -> some View {
        let isToday = Calendar.current.isDateInToday(d)
        let lunar = LunarService.text(for: d)
        return VStack(spacing: 1) {
            // 主行：ISO 日期 yyyy-MM-dd
            Text(isoDate(d))
                .font(.system(size: 15, weight: isToday ? .bold : .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(isToday ? Color.white : foregroundTone)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            // 次行：星期 + 农历/节气/农历节日
            Text("周\(weekdayShort(d)) · \(lunar)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isToday ? Color.white.opacity(0.85) : foregroundTone.opacity(0.5))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity)
        .background {
            if isToday {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(todayGrad)
                    .shadow(color: Color.orange.opacity(0.35), radius: 3)
                    .padding(.horizontal, 8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect(d) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { onCompose(d, nil) })
    }

    var allDayRow: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutter, height: 1)
            ForEach(dates, id: \.self) { d in
                allDayColumn(d).frame(maxWidth: .infinity)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    func allDayColumn(_ d: Date) -> some View {
        let allDay = model.events(on: d).filter { !$0.isDeleted && $0.isAllDay }
        if allDay.isEmpty {
            // 无全天事项时收起为一条细线，不再占用 34pt
            Rectangle().fill(Color.clear)
                .frame(maxWidth: .infinity, minHeight: 1, maxHeight: 1)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(allDay.prefix(3))) { e in
                    tappable(e)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, 3)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture(count: 2).onEnded { onCompose(d, nil) })
        }
    }

    func hourGrid(colH: CGFloat, range: (start: Int, end: Int)) -> some View {
        HStack(spacing: 6) {   // 瓷砖缝：小时栏与每日列之间留缝
            hourLabels(colH: colH, range: range)
            ForEach(dates, id: \.self) { d in
                dayColumn(d, colH: colH, range: range)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(hairline, lineWidth: 0.5)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    func hourLabels(colH: CGFloat, range: (start: Int, end: Int)) -> some View {
        VStack(spacing: 0) {
            ForEach(range.start...range.end, id: \.self) { h in
                Text(String(format: "%02d:00", h))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(foregroundTone.opacity(0.55))
                    .frame(height: colH, alignment: .topTrailing)
                    .padding(.trailing, 7)
                    .id(h)
            }
        }
        .frame(width: gutter)
    }

    func dayColumn(_ d: Date, colH: CGFloat, range: (start: Int, end: Int)) -> some View {
        let timed = model.events(on: d)
            .filter { !$0.isDeleted && !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
        let colHeight = CGFloat(range.end - range.start + 1) * colH
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(range.start...range.end, id: \.self) { h in
                    Rectangle().fill(Color.clear)
                        .frame(maxWidth: .infinity)
                        .frame(height: colH)
                        .overlay(alignment: .top) {
                            Rectangle().fill(hairline).frame(height: 0.5)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(d) }
                        .simultaneousGesture(TapGesture(count: 2).onEnded { onCompose(timeDate(h, of: d), nil) })
                        .contextMenu {
                            Button("添加事项到 \(String(format: "%02d:00", h))…") { onCompose(timeDate(h, of: d), nil) }
                        }
                }
            }
            ForEach(timed) { e in
                tappable(e)
                    .frame(height: max(14, chipHeight(e, colH: colH)), alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 3)
                    .offset(y: topOffset(e, on: d, colH: colH, range: range))
            }
        }
        .frame(maxWidth: .infinity, minHeight: colHeight, maxHeight: colHeight, alignment: .topLeading)
    }

    func tappable(_ e: EventItem) -> some View {
        timelineChip(e)
            .contentShape(Rectangle())
            .onTapGesture { onSelectEvent(e) }
    }

    func timelineChip(_ e: EventItem) -> some View {
        let c = config.categoryFor(e)
        return HStack(spacing: 3) {
            Circle().fill(c.color).frame(width: 6, height: 6)
            Text(e.title)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(e.isDone ? Color.secondary : foregroundTone)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 3).fill(c.color.opacity(e.isDone ? 0.14 : 0.4)))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(c.color.opacity(0.55), lineWidth: 0.5))
    }

    /// 由时间线某小时的空白格构造 Date（该日该小时 0 分），用于双击新建时定位到该时间点
    func timeDate(_ h: Int, of d: Date) -> Date {
        Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: d) ?? d
    }

    func hourRange() -> (start: Int, end: Int) {
        // 展示全天 0–24 点所有小时（00:00 ~ 24:00），保证完整覆盖
        (0, 24)
    }

    func chipHeight(_ e: EventItem, colH: CGFloat) -> CGFloat {
        let cal = Calendar.current
        guard let end = e.endDate else { return max(16, colH * 0.55) }
        let mins = max(30, cal.dateComponents([.minute], from: e.startDate, to: end).minute ?? 30)
        return max(14, CGFloat(mins) / 60 * colH)
    }

    func topOffset(_ e: EventItem, on d: Date, colH: CGFloat, range: (start: Int, end: Int)) -> CGFloat {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: d)
        let mins = max(0, cal.dateComponents([.minute], from: dayStart, to: e.startDate).minute ?? 0)
        let rel = CGFloat(mins) - CGFloat(range.start) * 60
        return max(1, rel / 60 * colH + 1)
    }

    func weekdayShort(_ d: Date) -> String {
        let names = ["日", "一", "二", "三", "四", "五", "六"]
        let idx = Calendar.current.component(.weekday, from: d) - 1
        return names[(idx + 7) % 7]
    }

    func fmtNum(_ d: Date) -> String {
        "\(Calendar.current.component(.day, from: d))"
    }

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func isoDate(_ d: Date) -> String {
        Self.isoFormatter.string(from: d)
    }
}

// MARK: - 年视图（12 个迷你月）

struct YearView: View {
    let year: Date
    var onOpen: (Date) -> Void = { _ in }

    @ObservedObject var model = AppModel.shared
    @ObservedObject var config = ConfigStore.shared

    private let shortWeekdays = ["日", "一", "二", "三", "四", "五", "六"]

    var foregroundTone: Color {
        config.textTone(for: config.theme)
    }
    var hairline: Color {
        switch config.theme {
        case .neon, .aurora: return Color.white.opacity(0.14)
        case .glass, .minimal: return Color.black.opacity(0.16)
        }
    }
    var todayGrad: LinearGradient {
        LinearGradient(colors: [.red, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        GeometryReader { geo in
            let c = bestColumns(width: geo.size.width, height: geo.size.height)
            let r = (12 + c - 1) / c
            let gap: CGFloat = 12
            let cellW = (geo.size.width - CGFloat(c - 1) * gap) / CGFloat(c)
            let cellH = (geo.size.height - CGFloat(r - 1) * gap) / CGFloat(r)
            VStack(spacing: gap) {
                ForEach(0..<r, id: \.self) { row in
                    HStack(spacing: gap) {
                        ForEach(0..<c, id: \.self) { col in
                            let idx = row * c + col
                            if idx < 12 {
                                miniMonth(idx, cellW: cellW, cellH: cellH)
                                    .onTapGesture { onOpen(monthDate(idx)) }
                            } else {
                                Color.clear.frame(width: cellW, height: cellH)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(config.theme == .neon || config.theme == .aurora
                    ? AnyView(Color.white.opacity(0.04))
                    : AnyView(Color.white.opacity(0.045)))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(hairline, lineWidth: 0.5))
    }

    /// 选能把 12 个月铺满、且格子尽量接近方形的列数（避免大窗口下大量留白）
    func bestColumns(width: CGFloat, height: CGFloat) -> Int {
        var best = 4
        var bestErr = CGFloat.greatestFiniteMagnitude
        for c in [3, 4, 6] {
            let r = (12 + c - 1) / c
            let gap: CGFloat = 12
            let cellW = (width - CGFloat(c - 1) * gap) / CGFloat(c)
            let cellH = (height - CGFloat(r - 1) * gap) / CGFloat(r)
            guard cellW > 40, cellH > 40 else { continue }
            let err = abs(cellW / cellH - 1.0)
            if err < bestErr { bestErr = err; best = c }
        }
        return best
    }

    func miniMonth(_ m: Int, cellW: CGFloat, cellH: CGFloat) -> some View {
        let month = monthDate(m)
        let cells = CalendarEngine.gridded(month)
        let rows = max(1, cells.count / 7)
        return VStack(spacing: 3) {
            Text("\(m + 1)月")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(foregroundTone)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 0) {
                ForEach(shortWeekdays, id: \.self) { w in
                    Text(w)
                        .frame(maxWidth: .infinity)
                        .font(.system(size: 8))
                        .foregroundStyle(foregroundTone.opacity(0.5))
                }
            }
            GeometryReader { g in
                let dayH = (g.size.height) / CGFloat(rows)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                    ForEach(cells, id: \.self) { d in
                        miniDay(d, month: month, height: dayH)
                    }
                }
            }
        }
        .padding(9)
        .frame(width: cellW, height: cellH)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white.opacity(0.04))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(hairline, lineWidth: 0.5)))
    }

    func miniDay(_ d: Date, month: Date, height: CGFloat) -> some View {
        let isToday = Calendar.current.isDateInToday(d)
        let inMonth = Calendar.current.isDate(d, equalTo: month, toGranularity: .month)
        let hasEvents = !model.events(on: d).isEmpty
        let dot = min(18, max(8, height - 3))
        return Text(fmtNum(d))
            .font(.system(size: 10, weight: isToday ? .bold : .regular))
            .foregroundStyle(inMonth
                             ? (isToday ? Color.white : foregroundTone)
                             : foregroundTone.opacity(0.35))
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .background {
                if isToday {
                    Circle().fill(todayGrad).frame(width: dot, height: dot)
                }
            }
            .overlay(alignment: .bottom) {
                if hasEvents && !isToday {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(config.categoryColor(.blue))
                        .frame(width: 10, height: 2)
                }
            }
    }

    func monthDate(_ m: Int) -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year], from: year)
        var c = DateComponents()
        c.year = comps.year
        c.month = m + 1
        c.day = 1
        return cal.date(from: c) ?? year
    }

    func fmtNum(_ d: Date) -> String {
        "\(Calendar.current.component(.day, from: d))"
    }
}

// MARK: - 事项编辑器（仿 macOS 原生日历 popover）

struct EventEditorView: View {
    @ObservedObject var model = AppModel.shared
    let date: Date
    var existing: EventItem?
    var onClose: () -> Void

    @State private var title: String
    @State private var isAllDay: Bool
    @State private var start: Date
    @State private var end: Date
    @State private var repeatRule: EventItem.RepeatRule
    @State private var remind: Int        // Int.max = 无
    @State private var popup: Bool        // 到点是否弹窗提醒
    @State private var categoryKey: String   // 内置=rawValue；自定义="custom:<id>"（按类别名选择，非颜色）
    @State private var note: String
    @FocusState private var titleFocused: Bool

    init(date: Date, existing: EventItem? = nil, onClose: @escaping () -> Void) {
        self.date = date
        self.existing = existing
        self.onClose = onClose
        _title = State(initialValue: existing?.title ?? "")
        // 新建默认「非全天」，让开始/结束可精确到分（编辑沿用原值）
        _isAllDay = State(initialValue: existing?.isAllDay ?? false)
        let nine = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: date) ?? date
        // 双击时间线某小时新建：用该小时当默认开始时间；列头/全天双击（date 为午夜 0 分）落回 9:00
        let isMidnight = Calendar.current.isDate(date, equalTo: Calendar.current.startOfDay(for: date), toGranularity: .minute)
        let initialStart = existing?.startDate ?? (isMidnight ? nine : date)
        _start = State(initialValue: initialStart)
        _end = State(initialValue: existing?.endDate
                     ?? Calendar.current.date(byAdding: .hour, value: 1, to: initialStart) ?? initialStart)
        _repeatRule = State(initialValue: existing?.repeatRule ?? .none)
        _remind = State(initialValue: existing?.reminders.first?.offsetMinutes ?? -30)
        _popup = State(initialValue: existing?.popupReminder ?? true)
        _categoryKey = State(initialValue: existing?.categoryID.map { "custom:\($0)" }
                             ?? (existing?.categoryColor.rawValue ?? "blue"))
        _note = State(initialValue: existing?.body ?? "")
    }

    /// 类别选项：内置（未隐藏）+ 自定义，按名称展示
    var categoryOptions: [(key: String, label: String, color: Color)] {
        let cfg = ConfigStore.shared
        var list: [(key: String, label: String, color: Color)] =
            cfg.visibleBuiltIn.map { (key: $0.rawValue, label: cfg.label(for: $0), color: cfg.categoryColor($0)) }
        list += cfg.customCategories.map { (key: "custom:\($0.id)", label: $0.label, color: $0.color) }
        return list
    }

    /// 当前应显示的色圆颜色：由所选类别解析
    var effectiveColor: Color {
        categoryOptions.first { $0.key == categoryKey }?.color ?? .blue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题行（色点 + 大标题输入框，同 macOS 日历）
            HStack(spacing: 8) {
                Circle().fill(effectiveColor).frame(width: 10, height: 10)
                TextField(existing == nil ? "新建事项" : "事项标题", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                    .focused($titleFocused)
            }
            .padding(.bottom, 10)

            Divider()
            // 仿 macOS 日历：全天 / 开始 / 结束 / 重复 / 提醒
            row(icon: "sun.max", label: "全天") {
                Toggle("", isOn: $isAllDay).toggleStyle(.checkbox).labelsHidden()
                Spacer()
            }
            Divider()
            row(icon: "clock", label: "开始") {
                DatePicker("", selection: $start,
                           displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute])
                    .labelsHidden()
                Spacer()
            }
            Divider()
            row(icon: "clock.arrow.circlepath", label: "结束") {
                DatePicker("", selection: $end, in: start...,
                           displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute])
                    .labelsHidden()
                Spacer()
            }
            Divider()
            row(icon: "repeat", label: "重复") {
                Picker("", selection: $repeatRule) {
                    ForEach(EventItem.RepeatRule.allCases, id: \.self) { r in
                        Text(r.label).tag(r)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
                Spacer()
            }
            Divider()
            row(icon: "bell", label: "提醒") {
                Picker("", selection: $remind) {
                    Text("无").tag(Int.max)
                    Text("准点").tag(0)
                    Text("提前 10 分钟").tag(-10)
                    Text("提前 30 分钟").tag(-30)
                    Text("提前 1 小时").tag(-60)
                    Text("提前 1 天").tag(-1440)
                }
                .labelsHidden()
                .frame(width: 140)
                Spacer()
            }
            Divider()
            // 到点是否弹窗提醒（用户按事项配置）
            row(icon: "rectangle.badge.checkmark", label: "弹窗") {
                Toggle("", isOn: $popup).toggleStyle(.checkbox).labelsHidden()
                Text(popup ? "到点弹窗提醒" : "不弹窗（仅语音/通知）")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
            Divider()
            // 选「类别名称」而非颜色：用户不必记住每个颜色代表什么
            row(icon: "tag", label: "类别") {
                Circle().fill(effectiveColor).frame(width: 10, height: 10)
                Picker("", selection: $categoryKey) {
                    ForEach(categoryOptions, id: \.key) { opt in
                        Text(opt.label).tag(opt.key)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                Spacer()
            }
            Divider()

            // 备注
            ZStack(alignment: .topLeading) {
                TextEditor(text: $note)
                    .font(.system(size: 12))
                    .frame(height: 56)
                    .scrollContentBackground(.hidden)
                if note.isEmpty {
                    Text("添加备注…").font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8).padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(.vertical, 8)

            HStack {
                if let e = existing {
                    Button("删除", role: .destructive) { model.remove(e.id); onClose() }
                }
                Spacer()
                Button("取消") { onClose() }
                Button(existing == nil ? "添加" : "完成") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { titleFocused = true }
    }

    func row<Content: View>(icon: String, label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            content()
        }
        .font(.system(size: 12))
        .padding(.vertical, 7)
    }

    func save() {
        let rems = remind == Int.max ? [] : [Reminder(offsetMinutes: remind, scope: .both)]
        let finalEnd = isAllDay ? nil : (end > start ? end : start)
        // 类别 key → 存储字段：自定义分类存 categoryID，内置存 categoryColor
        let isCustom = categoryKey.hasPrefix("custom:")
        let customID = isCustom ? String(categoryKey.dropFirst("custom:".count)) : nil
        let builtIn = EventItem.CategoryColor(rawValue: categoryKey) ?? .blue
        if var e = existing {
            e.title = title
            e.startDate = start
            e.endDate = finalEnd
            e.isAllDay = isAllDay
            e.repeatRule = repeatRule
            e.categoryColor = isCustom ? (e.categoryColor) : builtIn
            e.categoryID = customID
            e.reminders = rems
            e.body = note.isEmpty ? nil : note
            e.popupReminder = popup
            model.update(e)
        } else {
            model.add(EventItem(title: title, body: note.isEmpty ? nil : note,
                                startDate: start, endDate: finalEnd, isAllDay: isAllDay,
                                categoryColor: builtIn, categoryID: customID, reminders: rems,
                                repeatRule: repeatRule, popupReminder: popup))
        }
        onClose()
    }

    func fullDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEEE"
        return f.string(from: d)
    }
}

// MARK: - 宠物视图

enum PetMood { case idle, reminding, speaking, happy, sleeping }

/// 宠物表演动作（招手/打滚/跳），由 PetView 触发，PetPhotoView 按进度做关键帧动画
enum PetAction: String, CaseIterable {
    case wave, roll, jump
    var duration: TimeInterval {
        switch self {
        case .wave: return 1.4
        case .roll: return 1.6
        case .jump: return 1.0
        }
    }
    var label: String {
        switch self {
        case .wave: return "招手"
        case .roll: return "打滚"
        case .jump: return "跳一跳"
        }
    }
}

struct PetView: View {
    @ObservedObject var config = ConfigStore.shared
    @ObservedObject var wm = WindowManager.shared
    @State private var reaction: String?
    @State private var mood: PetMood = .idle
    @State private var action: PetAction?
    @State private var actionStart = Date()

    private let cardW: CGFloat = 230
    private let cardH: CGFloat = 320

    var body: some View {
        Group {
            if wm.petExpanded { expandedCard }
            else { petBall }
        }
        .frame(width: wm.petExpanded ? WindowManager.petCardSize.width : WindowManager.petBallSize.width,
               height: wm.petExpanded ? WindowManager.petCardSize.height : WindowManager.petBallSize.height)
        .onReceive(NotificationCenter.default.publisher(for: .petRemind)) { _ in
            withAnimation(.easeInOut(duration: 0.25)) { mood = .reminding }
            trick(.wave)
        }
        .onReceive(NotificationCenter.default.publisher(for: .petSpeak)) { note in
            let text = note.object as? String ?? ""
            withAnimation { reaction = text; mood = .speaking }
        }
    }

    /// 悬浮球：小型圆球默认收起，悬浮屏幕边缘，点击展开为完整卡片
    var petBall: some View {
        ZStack {
            let videos = PetMedia.videoURLs()
            if !videos.isEmpty {
                PetVideoView(urls: videos)
                    .frame(width: WindowManager.petBallSize.width, height: WindowManager.petBallSize.height)
                    .clipShape(Circle())
            } else {
                PetFallbackPhotoView(mood: mood, action: action, actionStart: actionStart)
                    .frame(width: WindowManager.petBallSize.width, height: WindowManager.petBallSize.height)
                    .clipShape(Circle())
            }
            if mood != .idle {
                Circle().fill(cardGradient)
                    .frame(width: 22, height: 22)
                    .overlay(Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(.white))
                    .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                    .offset(x: WindowManager.petBallSize.width * 0.30, y: WindowManager.petBallSize.height * 0.30)
            }
        }
        .contentShape(Circle())
        .onTapGesture { wm.setPetExpanded(true) }
        .overlay(Circle().stroke(cardGradient, lineWidth: 2))
        .overlay(Circle().stroke(Color.black.opacity(0.2), lineWidth: 1))
        .clipShape(Circle())
        .shadow(color: cardGlow.opacity(0.45), radius: 16, y: 6)
        .help("点击展开宠物卡片")
    }

    /// 展开卡片：完整视频卡 + 性格配饰 + 互动按钮 + 收起/设锁
    var expandedCard: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 10) {
                Text(config.petName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.8))

                ZStack {
                    let videos = PetMedia.videoURLs()
                    if !videos.isEmpty {
                        PetVideoView(urls: videos)
                            .frame(width: cardW, height: cardH)
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    } else {
                        PetFallbackPhotoView(mood: mood, action: action, actionStart: actionStart)
                            .frame(width: cardW, height: cardH)
                    }
                    PersonalityAccessoryView(kind: config.effectivePersonality())
                        .allowsHitTesting(false)
                }
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(cardGradient, lineWidth: 2))
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.black.opacity(0.18), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: cardGlow.opacity(0.4), radius: 22, y: 8)
                .shadow(color: Color.black.opacity(0.4), radius: 6, y: 3)
                .contentShape(Rectangle())
                .onTapGesture { trick() }
                .overlay(alignment: .bottom) {
                    if let r = reaction {
                        Text(r)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(3)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(.ultraThinMaterial.opacity(0.9)))
                            .padding(10)
                            .transition(.opacity)
                    }
                }
                .overlay(alignment: .top) {
                    if let dp = config.effectiveDayPersonality {
                        HStack(spacing: 4) {
                            Image(systemName: dp.source == .ai ? "sparkles" : "person.fill")
                            Text(dp.source == .ai ? "AI·\(dp.kind.label)" : "用户·\(dp.kind.label)")
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.ultraThinMaterial.opacity(0.85)))
                        .padding(10)
                    }
                }

                HStack(spacing: 8) {
                    actionChip("表演一下", "wand.and.stars") { trick() }
                    actionChip("摸摸头", "hand.raised.fill") { pet() }
                    actionChip("试提醒", "bell.fill") { remind() }
                }
            }
            .padding(12)

            Button { wm.setPetExpanded(false) } label: {
                Image(systemName: "chevron.down.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.9))
                    .background(Circle().fill(.black.opacity(0.32)).frame(width: 24, height: 24))
            }
            .buttonStyle(.plain)
            .padding(8)
            .help("收起为悬浮球")
        }
        .overlay(alignment: .topLeading) {
            Button { togglePetLock() } label: {
                Image(systemName: config.petLocked ? "lock.fill" : "lock.open")
                    .font(.system(size: 13))
                    .foregroundStyle(config.petLocked ? Color.accentColor : .primary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.ultraThinMaterial))
                    .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 0.8))
            }
            .buttonStyle(.plain)
            .padding(8)
            .help(config.petLocked ? "已锁定宠物窗口（禁止拖拽）" : "锁定宠物窗口，禁止拖拽")
        }
    }

    func togglePetLock() {
        config.petLocked.toggle()
        config.save()
        WindowManager.shared.applyPetLock()
    }

    var cardGradient: LinearGradient {
        switch config.theme {
        case .neon:
            return LinearGradient(colors: [.cyan, .purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .aurora:
            return LinearGradient(colors: [.blue, .purple, .pink, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .glass, .minimal:
            return LinearGradient(colors: [Color.white.opacity(0.7), Color.white.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    var cardGlow: Color {
        switch config.theme {
        case .neon: return .cyan
        case .aurora: return .purple
        case .glass, .minimal: return .white
        }
    }

    func actionChip(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().stroke(Color.white.opacity(0.28), lineWidth: 0.8))
        .foregroundStyle(.primary)
    }

    func remind() {
        let kind = config.effectivePersonality()
        let text = Personality(kind: kind).baseLine(title: "测试事项", remaining: 30)
        VoiceService.shared.speakPersonality(text, kind: kind)
        withAnimation { reaction = text; mood = .reminding }
        trick(.wave)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation { reaction = nil; mood = .idle }
        }
    }

    func trick(_ a: PetAction? = PetAction.allCases.randomElement()) {
        guard let a else { return }
        action = a
        actionStart = Date()
        withAnimation { mood = .happy }
        DispatchQueue.main.asyncAfter(deadline: .now() + a.duration + 0.1) {
            action = nil
            withAnimation { mood = .idle }
        }
    }

    func pet() {
        withAnimation { reaction = "喵～（蹭蹭你）"; mood = .happy }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { reaction = nil; mood = .idle }
        }
    }
}

// MARK: - 宠物形象：真实猫咪（视频优先，照片回退）+ 性格配饰

/// 宠物视频来源：用户自选 > App 内置 pet.mp4/mov
enum PetMedia {
    /// 宠物视频来源：用户自选 > 内置 pet1/pet2/pet（可多段循环轮播）；无视频时照片回退
    static func videoURLs() -> [URL] {
        var urls: [URL] = []
        let path = ConfigStore.shared.petVideoPath
        if !path.isEmpty, FileManager.default.fileExists(atPath: path) {
            urls.append(URL(fileURLWithPath: path))
        }
        for name in ["pet1", "pet2", "pet"] {
            for ext in ["mp4", "mov", "m4v"] {
                if let u = Bundle.main.url(forResource: name, withExtension: ext) {
                    urls.append(u)
                } else if let d = devVideoURL(name, ext) {
                    urls.append(d)
                }
            }
        }
        return urls
    }

    /// 开发回退：仓库 video/ 目录
    private static func devVideoURL(_ name: String, _ ext: String) -> URL? {
        let cwd = FileManager.default.currentDirectoryPath
        for base in [cwd, (cwd as NSString).deletingLastPathComponent] {
            let u = URL(fileURLWithPath: base).appendingPathComponent("video/\(name).\(ext)")
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }
}

/// 循环播放宠物视频（静音、等比缩放、透明底）
struct PetVideoView: NSViewRepresentable {
    let urls: [URL]

    func makeNSView(context: Context) -> PetPlayerView {
        let v = PetPlayerView()
        v.load(urls)
        return v
    }

    func updateNSView(_ nsView: PetPlayerView, context: Context) {
        if nsView.urls != urls { nsView.load(urls) }
    }
}

final class PetPlayerView: NSView {
    let player = AVPlayer()
    let playerLayer = AVPlayerLayer()
    private(set) var urls: [URL] = []
    private var idx = 0
    private var endToken: NSObjectProtocol?
    private var visibleToken: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(playerLayer)
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.35).cgColor
        player.isMuted = true
        player.actionAtItemEnd = .none
        // 每段视频播完切到下一段，形成多段轮播/单段循环
        endToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] _ in self?.advance() }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let endToken { NotificationCenter.default.removeObserver(endToken) }
        if let visibleToken { NotificationCenter.default.removeObserver(visibleToken) }
    }

    /// 窗口可见性感知：隐藏（orderOut）时暂停解码以省 CPU，显示时恢复播放。
    /// 否则宠物窗被「显示/隐藏」关掉后 AVPlayer 仍在后台解码视频，占满 CPU 导致卡死。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let w = window {
            if visibleToken == nil {
                // 窗口被 orderOut/遮挡时暂停视频解码，恢复显示时继续播放
                visibleToken = NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main
                ) { [weak self] _ in
                    guard let self = self else { return }
                    if self.window?.occlusionState.contains(.visible) == true { self.resumePlayback() }
                    else { self.pausePlayback() }
                }
            }
        } else if let t = visibleToken {
            NotificationCenter.default.removeObserver(t)
            visibleToken = nil
        }
    }

    func pausePlayback() { player.pause() }
    func resumePlayback() { guard !urls.isEmpty else { return }; player.play() }

    func load(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        self.urls = urls
        idx = 0
        playCurrent()
    }

    private func advance() {
        guard !urls.isEmpty else { return }
        idx = (idx + 1) % urls.count
        playCurrent()
    }

    private func playCurrent() {
        guard !urls.isEmpty else { return }
        player.replaceCurrentItem(with: AVPlayerItem(url: urls[idx]))
        player.play()
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}

/// 照片回退形象：真实抠图猫咪 + 呼吸/浮动/心情换图 + 表演动作关键帧
struct PetFallbackPhotoView: View {
    var mood: PetMood = .idle
    var action: PetAction?
    var actionStart: Date = Date()

    static func imageName(for mood: PetMood) -> String {
        switch mood {
        case .idle: return "img_2"       // 坐姿抬头
        case .reminding: return "img_3"  // 揣手盯着你看
        case .speaking: return "img_8"   // 大脸特写
        case .happy: return "img_6"      // 躺平伸爪
        case .sleeping: return "img_7"   // 眯眼趴窝
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { ctx in
            let pose = pose(at: ctx.date)
            if let img = ResourceLoader.image(pose.name) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(pose.breathe)
                    .rotationEffect(.degrees(pose.tilt))
                    .offset(x: pose.dx, y: pose.bob)
                    .shadow(color: .black.opacity(0.28), radius: 6, y: 3)
                    .id(pose.name)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                Text("🐱").font(.system(size: 80))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: mood)
    }

    /// 整体姿态：待机呼吸/浮动/摆头；表演动作时按进度覆盖为关键帧
    func pose(at date: Date) -> (name: String, bob: Double, breathe: Double, tilt: Double, dx: Double) {
        let t = date.timeIntervalSinceReferenceDate
        let excitable = mood == .happy || mood == .reminding || mood == .speaking
        var bob = (excitable ? 4.0 : 2.5) * sin(t * 1.6)
        var breathe = 1 + (mood == .sleeping ? 0.035 : 0.02) * sin(t * 2.0)
        var tilt = excitable ? 2.5 * sin(t * 3.2) : 0.8 * sin(t * 0.9)
        var dx = 0.0
        var name = PetFallbackPhotoView.imageName(for: mood)

        if let action {
            let p = min(1, max(0, date.timeIntervalSince(actionStart) / action.duration))
            switch action {
            case .wave:
                name = "img_6"                       // 伸爪照，身体摇摆=招手
                tilt = 12 * sin(p * .pi * 4)
                bob = -6 * sin(p * .pi)
                breathe = 1
            case .roll:
                name = "img"                         // 蜷团背影，整圈翻滚
                tilt = 360 * p
                dx = 56 * sin(p * .pi)
                bob = -12 * sin(p * .pi * 2)
                breathe = 1
            case .jump:
                name = "img_2"
                bob = -64 * 4 * p * (1 - p)          // 抛物线跳跃
                tilt = 10 * sin(p * .pi)
                breathe = 1 + 0.06 * sin(p * .pi)
            }
        }
        return (name, bob, breathe, tilt, dx)
    }
}

/// 性格配饰（叠加在宠物头顶/脸上，性格切换即换装）
struct PersonalityAccessoryView: View {
    var kind: Personality.Kind

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let bob = 1.5 * sin(t * 1.6)
                switch kind {
                case .energetic: drawBow(context: &context, size: size, dy: bob)
                case .lazy: drawNightcap(context: &context, size: size, dy: bob, t: t)
                case .tsundere: drawCrown(context: &context, size: size, dy: bob)
                case .aloof: drawSunglasses(context: &context, size: size, dy: bob)
                }
            }
        }
    }

    /// 元气：头顶蝴蝶结
    func drawBow(context: inout GraphicsContext, size: CGSize, dy: Double) {
        let cx = size.width * 0.5, cy = 14.0 + dy
        let red = Color(red: 0.92, green: 0.30, blue: 0.38)
        var left = Path()
        left.move(to: CGPoint(x: cx, y: cy))
        left.addQuadCurve(to: CGPoint(x: cx - 24, y: cy - 10), control: CGPoint(x: cx - 22, y: cy - 14))
        left.addQuadCurve(to: CGPoint(x: cx, y: cy), control: CGPoint(x: cx - 22, y: cy + 12))
        var right = Path()
        right.move(to: CGPoint(x: cx, y: cy))
        right.addQuadCurve(to: CGPoint(x: cx + 24, y: cy - 10), control: CGPoint(x: cx + 22, y: cy - 14))
        right.addQuadCurve(to: CGPoint(x: cx, y: cy), control: CGPoint(x: cx + 22, y: cy + 12))
        context.fill(left, with: .color(red))
        context.fill(right, with: .color(red))
        context.fill(Path(ellipseIn: CGRect(x: cx - 5, y: cy - 5, width: 10, height: 10)),
                     with: .color(Color(red: 0.78, green: 0.2, blue: 0.3)))
    }

    /// 慵懒：歪戴睡帽（帽尖随呼吸晃动）
    func drawNightcap(context: inout GraphicsContext, size: CGSize, dy: Double, t: Double) {
        let cx = size.width * 0.52, cy = 10.0 + dy
        let purple = Color(red: 0.55, green: 0.45, blue: 0.85)
        let sway = 4 * sin(t * 1.4)
        var cap = Path()
        cap.move(to: CGPoint(x: cx - 20, y: cy + 6))
        cap.addQuadCurve(to: CGPoint(x: cx + 30 + sway, y: cy - 6),
                         control: CGPoint(x: cx + 6, y: cy - 22))
        cap.addQuadCurve(to: CGPoint(x: cx + 16, y: cy + 8),
                         control: CGPoint(x: cx + 22 + sway * 0.5, y: cy + 2))
        cap.closeSubpath()
        context.fill(cap, with: .color(purple))
        context.fill(Path(roundedRect: CGRect(x: cx - 22, y: cy + 4, width: 42, height: 8), cornerRadius: 4),
                     with: .color(.white))
        context.fill(Path(ellipseIn: CGRect(x: cx + 26 + sway, y: cy - 12, width: 10, height: 10)),
                     with: .color(.white))
    }

    /// 傲娇：小皇冠
    func drawCrown(context: inout GraphicsContext, size: CGSize, dy: Double) {
        let cx = size.width * 0.5, cy = 16.0 + dy
        let gold = Color(red: 0.98, green: 0.78, blue: 0.25)
        var c = Path()
        c.move(to: CGPoint(x: cx - 16, y: cy + 6))
        c.addLine(to: CGPoint(x: cx - 14, y: cy - 8))
        c.addLine(to: CGPoint(x: cx - 7, y: cy))
        c.addLine(to: CGPoint(x: cx, y: cy - 12))
        c.addLine(to: CGPoint(x: cx + 7, y: cy))
        c.addLine(to: CGPoint(x: cx + 14, y: cy - 8))
        c.addLine(to: CGPoint(x: cx + 16, y: cy + 6))
        c.closeSubpath()
        context.fill(c, with: .color(gold))
        context.fill(Path(ellipseIn: CGRect(x: cx - 3, y: cy - 2, width: 6, height: 6)),
                     with: .color(Color(red: 0.9, green: 0.25, blue: 0.3)))
    }

    /// 高冷：墨镜
    func drawSunglasses(context: inout GraphicsContext, size: CGSize, dy: Double) {
        let cx = size.width * 0.5, cy = size.height * 0.42 + dy
        let black = Color.black.opacity(0.88)
        for side: CGFloat in [-1, 1] {
            let rect = CGRect(x: cx + side * 20 - 15, y: cy - 8, width: 30, height: 16)
            context.fill(Path(roundedRect: rect, cornerRadius: 6), with: .color(black))
        }
        var bridge = Path()
        bridge.move(to: CGPoint(x: cx - 6, y: cy - 3))
        bridge.addLine(to: CGPoint(x: cx + 6, y: cy - 3))
        context.stroke(bridge, with: .color(black), lineWidth: 3)
        for side: CGFloat in [-1, 1] {
            var leg = Path()
            leg.move(to: CGPoint(x: cx + side * 35, y: cy - 4))
            leg.addLine(to: CGPoint(x: cx + side * 52, y: cy - 10))
            context.stroke(leg, with: .color(black), lineWidth: 3)
        }
    }
}

// MARK: - 设置

/// 设置页 Tab 路由：菜单栏「AI 模型与秘钥…」等入口可直达指定页
final class SettingsRouter: ObservableObject {
    static let shared = SettingsRouter()
    @Published var tab = 0
}

/// 事项到点弹窗提醒卡片（由 WindowManager 挂在独立 floating 面板里）
struct ReminderPopupView: View {
    let title: String
    let detail: String
    var onDismiss: () -> Void
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "bell.badge.fill").foregroundStyle(.orange)
                Text("事项提醒").font(.headline)
                Spacer()
                Button { onDismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(detail).font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("知道了") { onDismiss() }.buttonStyle(.bordered)
                Button("标记完成") { onDone() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 320, height: 200)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.2), lineWidth: 0.8))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
    }
}

// MARK: - 悬浮时钟（照搬 notice-clock 霓虹钟）+ 今日待办面板

private extension Color {
    static let neonCyan = Color(red: 0, green: 0.898, blue: 1)        // #00e5ff
    static let neonMagenta = Color(red: 1, green: 0, blue: 0.898)     // #ff00e5
    static let neonYellow = Color(red: 1, green: 0.902, blue: 0)      // #ffe600
    static let neonUrgent = Color(red: 1, green: 0.231, blue: 0.361)  // #ff3b5c
    static let neonTime = Color(red: 0.918, green: 0.988, blue: 1)    // #eafcff
}

/// 待办紧迫判定（移植 notice-clock utils.js）：全天/进行中不紧迫；今日已过期未办 或 1 小时内 → 紧迫
func isTaskUrgent(_ e: EventItem, _ d: Date, now: Date) -> Bool {
    if e.isAllDay { return false }
    if let end = e.endDate, d <= now, now <= end { return false } // 进行中
    let diff = d.timeIntervalSince(now)
    if diff < 0 { return true }                                    // 今日已过期
    return diff <= 3600
}

/// 待办时间标签（移植 utils.js）：非今日显示日期；全天/进行中/HH:mm 开始/已到期
func taskTimeLabel(_ e: EventItem, _ d: Date, now: Date) -> String {
    let cal = Calendar.current
    if !cal.isDate(d, inSameDayAs: now) {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = e.isAllDay ? "M/d 全天" : "M/d HH:mm"
        return f.string(from: d)
    }
    let hm: (Date) -> String = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: $0) }
    if e.isAllDay { return "全天" }
    if let end = e.endDate, d <= now, now <= end { return "进行中" }
    if d < now { return hm(d) + " 已到期" }
    return hm(d) + " 开始"
}

/// 霓虹圆盘时钟（放进 160×160 时钟窗）：秒针弧/旋转环/刻度/时间日期/徽标/⋮菜单
struct ClockWidgetView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var config: ConfigStore
    @State private var now = Date()
    @State private var cardHovered = false
    private let ticker = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    var body: some View {
        let tasks = model.todayTasks(limit: 5, now: now)
        let urgentCount = tasks.filter { isTaskUrgent($0.0, $0.1, now: now) }.count
        return clockFace
            .frame(width: 160, height: 160)
            .overlay(alignment: .topLeading) { badgeView(count: tasks.count, urgent: urgentCount).padding(8) }
            .overlay(alignment: .top) { menuView.padding(.top, 6) }
            .onReceive(ticker) { now = $0 }
            .onHover { inside in
                cardHovered = inside
                WindowManager.shared.clockHoverChanged(inside)
            }
    }

    var clockFace: some View {
        ZStack {
            Circle().fill(.ultraThinMaterial)
            Circle().fill(RadialGradient(
                colors: [Color(red: 0.11, green: 0.149, blue: 0.227).opacity(0.55),
                         Color(red: 0.035, green: 0.043, blue: 0.075).opacity(0.68)],
                center: UnitPoint(x: 0.5, y: 0.35), startRadius: 0, endRadius: 74))
            // 环+刻度+秒针弧全部在一个 Canvas 里画，几何固定居中，旋转/进度由时间驱动（无 repeatForever，不会抖动游移）
            faceCanvas
            // 中心时间
            VStack(spacing: 6) {
                timeRow
                Text(dateString)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(Color(red: 0.92, green: 0.96, blue: 1).opacity(0.55))
            }
        }
        .frame(width: 148, height: 148)
        .overlay(Circle().stroke(Color.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .neonCyan.opacity(0.18), radius: 16)
        .shadow(color: .neonMagenta.opacity(0.09), radius: 28)
    }

    var faceCanvas: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let R = size.width / 2

            // 旋转 conic 外环（10s 一圈）：细线 2pt 贴边，更精致的科技感
            let ringR = R - 2
            var ring = Path()
            ring.addArc(center: c, radius: ringR, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
            var ringCtx = ctx
            ringCtx.opacity = 0.9
            ringCtx.stroke(ring,
                           with: .conicGradient(Gradient(colors: [.neonCyan, .neonMagenta, .neonYellow, .neonCyan]),
                                                center: c, angle: .degrees(ringRotation)),
                           style: StrokeStyle(lineWidth: 2))

            // 60 刻度（每 5 加粗）：细线，位于秒针弧内侧
            let tickOuter = R - 14
            for i in 0..<60 {
                let major = i % 5 == 0
                let inner = tickOuter - (major ? 5.0 : 2.5)
                let angle = Double(i) / 60 * 2 * .pi - .pi / 2
                var p = Path()
                p.move(to: CGPoint(x: c.x + tickOuter * cos(angle), y: c.y + tickOuter * sin(angle)))
                p.addLine(to: CGPoint(x: c.x + inner * cos(angle), y: c.y + inner * sin(angle)))
                ctx.stroke(p, with: .color(.white.opacity(major ? 0.5 : 0.15)),
                           style: StrokeStyle(lineWidth: major ? 1.8 : 0.9, lineCap: .round))
            }

            // 秒针进度弧（从顶部顺时针，细线 3.5pt 带发光）
            var arc = Path()
            arc.addArc(center: c, radius: R - 8,
                       startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * Double(secondFraction)),
                       clockwise: false)
            var glow = ctx
            glow.addFilter(.shadow(color: .neonCyan.opacity(0.8), radius: 5))
            glow.stroke(arc,
                        with: .linearGradient(Gradient(colors: [.neonCyan, .neonMagenta]),
                                              startPoint: CGPoint(x: 0, y: 0),
                                              endPoint: CGPoint(x: size.width, y: size.height)),
                        style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
        }
        .frame(width: 148, height: 148)
        .allowsHitTesting(false)
    }

    var timeRow: some View {
        let f = Font.system(size: 23, weight: .medium, design: .monospaced)
        let cf = Font.system(size: 16, weight: .medium, design: .monospaced)
        return HStack(spacing: 2) {
            Text(pad(hour)).font(f)
            Text(":").font(cf).opacity(colonOpacity)
            Text(pad(minute)).font(f)
            Text(":").font(cf).opacity(colonOpacity)
            Text(pad(second)).font(f)
        }
        .monospacedDigit()
        .foregroundColor(.neonTime)
        .shadow(color: .neonCyan.opacity(0.9), radius: 3)
        .shadow(color: .neonCyan.opacity(0.45), radius: 8)
    }

    /// conic 环旋转角（10s 一圈），由时间驱动
    var ringRotation: Double {
        now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10) / 10 * 360
    }
    /// 冒号脉动（约 1s 一个周期），由时间驱动
    var colonOpacity: Double {
        0.4 + 0.6 * (0.5 + 0.5 * sin(now.timeIntervalSinceReferenceDate * 2 * .pi))
    }

    func badgeView(count: Int, urgent: Int) -> some View {
        Group {
            if count > 0 {
                Button { WindowManager.shared.toggleTodoPanel() } label: {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(urgent > 0 ? .white : Color(red: 0.81, green: 0.94, blue: 1))
                        .frame(minWidth: 18, minHeight: 18)
                        .padding(.horizontal, 5)
                        .background(Capsule().fill(urgent > 0 ? Color.neonUrgent : Color.white.opacity(0.12)))
                        .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
                        .shadow(color: urgent > 0 ? Color.neonUrgent.opacity(0.8) : .clear, radius: 6)
                }
                .buttonStyle(.plain)
                .help("今日待办")
            }
        }
    }

    var menuView: some View {
        Menu {
            Button("打开设置…") { WindowManager.shared.showSettings() }
            Button("隐藏悬浮时钟") {
                config.countdownEnabled = false
                config.save()
                WindowManager.shared.setClockVisible(false)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white.opacity(0.6))
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.white.opacity(0.08)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .opacity(cardHovered ? 1 : 0)
    }

    func pad(_ n: Int) -> String { String(format: "%02d", n) }
    var hour: Int { Calendar.current.component(.hour, from: now) }
    var minute: Int { Calendar.current.component(.minute, from: now) }
    var second: Int { Calendar.current.component(.second, from: now) }
    var secondFraction: CGFloat {
        let t = now.timeIntervalSince1970
        let s = t - floor(t / 60) * 60   // 当前分钟内的秒（含毫秒）
        return CGFloat(min(max(s / 60, 0), 1))
    }
    var dateString: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "yyyy年M月d日"
        let week = ["日", "一", "二", "三", "四", "五", "六"][Calendar.current.component(.weekday, from: now) - 1]
        return f.string(from: now) + " · 周" + week
    }
}

/// 今日待办面板（280 宽，放进独立 todoPanelWindow，悬停时钟时弹出）
struct TodayPanelView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var config: ConfigStore
    @State private var now = Date()
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        let tasks = model.todayTasks(limit: 5, now: now)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("今日待办").font(.system(size: 12, weight: .semibold))
                    .tracking(2)
                    .foregroundColor(Color(red: 0.9, green: 0.956, blue: 1).opacity(0.85))
                if !tasks.isEmpty {
                    Text("\(tasks.count)").font(.system(size: 10))
                        .foregroundColor(Color(red: 0.75, green: 0.91, blue: 1))
                        .frame(minWidth: 16, minHeight: 16).padding(.horizontal, 4)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                }
                Spacer()
                Button { AppModel.shared.load(); now = Date() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12))
                        .foregroundColor(Color.white.opacity(0.6))
                }.buttonStyle(.plain).help("刷新")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .overlay(Divider().opacity(0.25), alignment: .bottom)

            VStack(alignment: .leading, spacing: 0) {
                if tasks.isEmpty {
                    Text("今天没有待办事项").font(.system(size: 12))
                        .foregroundColor(Color.white.opacity(0.5))
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                } else {
                    ForEach(Array(tasks.enumerated()), id: \.offset) { _, pair in
                        taskRow(pair.0, pair.1)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(width: 280, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.07, green: 0.094, blue: 0.14).opacity(0.72)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
        .frame(maxHeight: .infinity, alignment: .top)
        .onReceive(ticker) { now = $0 }
        .onHover { WindowManager.shared.panelHoverChanged($0) }
    }

    func taskRow(_ e: EventItem, _ d: Date) -> some View {
        let urgent = isTaskUrgent(e, d, now: now)
        let cat = config.categoryFor(e)
        return HStack(spacing: 8) {
            Circle().fill(cat.color).frame(width: 6, height: 6)
                .shadow(color: cat.color.opacity(0.8), radius: 3)
            Text(e.title).font(.system(size: 12))
                .foregroundColor(urgent ? Color(red: 1, green: 0.56, blue: 0.65) : Color(red: 0.91, green: 0.96, blue: 1))
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            Text(taskTimeLabel(e, d, now: now))
                .font(.system(size: 11, weight: urgent ? .bold : .regular))
                .foregroundColor(urgent ? Color(red: 1, green: 0.36, blue: 0.47) : Color.white.opacity(0.55))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(urgent ? Color.neonUrgent.opacity(0.14) : Color.clear)
        .overlay(Rectangle().frame(width: 2).foregroundColor(urgent ? Color.neonUrgent : .clear), alignment: .leading)
    }
}

/// 系统调色面板的桥接（NSColorPanel 需要 NSObject target）
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    var onPick: ((NSColor) -> Void)?
    @objc func colorChanged(_ sender: NSColorPanel) { onPick?(sender.color) }
}

/// 单一圆盘取色控件：点圆盘弹出系统调色盘，只保留一个圆点（不显示多余色块/标签）
struct ColorDisc: View {
    @Binding var color: Color
    var diameter: CGFloat = 18

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .overlay(Circle().stroke(Color.white.opacity(0.65), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 1)
            .contentShape(Circle())
            .onTapGesture {
                ColorPanelBridge.shared.onPick = { nc in color = Color(nsColor: nc) }
                let p = NSColorPanel.shared
                p.showsAlpha = false
                p.color = NSColor(color)
                p.setTarget(ColorPanelBridge.shared)
                p.setAction(#selector(ColorPanelBridge.colorChanged(_:)))
                p.orderFront(nil)
            }
            .help("选择颜色")
    }
}

/// 工作量折线图（手工绘制，避免引入 Charts 依赖）：折线体现变化 + 明确横坐标
struct WorkloadChartView: View {
    let points: [WorkloadPoint]

    func px(_ i: Int, _ w: CGFloat) -> CGFloat {
        (CGFloat(i) + 0.5) / CGFloat(max(1, points.count)) * w
    }
    func py(_ v: Double, _ h: CGFloat, _ maxV: Double) -> CGFloat {
        h - 4 - CGFloat(v / maxV) * (h - 8)
    }

    var body: some View {
        let maxV = max(1, points.map(\.value).max() ?? 1)
        let step = max(1, points.count / 8)
        let n = max(1, points.count)
        return VStack(spacing: 2) {
            HStack(alignment: .top, spacing: 4) {
                // 纵轴刻度（最大值）
                Text(WorkloadEngine.fmt(maxV))
                    .font(.system(size: 8)).foregroundStyle(.secondary)
                GeometryReader { geo in
                    let w = geo.size.width
                    let h = geo.size.height
                    ZStack(alignment: .topLeading) {
                        // 横向参考线
                        ForEach([0.0, 0.5, 1.0], id: \.self) { t in
                            Rectangle().fill(Color.secondary.opacity(0.15))
                                .frame(height: 0.5)
                                .offset(y: h - 4 - CGFloat(t) * (h - 8))
                        }
                        // 折线
                        Path { p in
                            for (i, pt) in points.enumerated() {
                                let pt2 = CGPoint(x: px(i, w), y: py(pt.value, h, maxV))
                                if i == 0 { p.move(to: pt2) } else { p.addLine(to: pt2) }
                            }
                        }
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                        // 数据点
                        ForEach(Array(points.enumerated()), id: \.offset) { i, pt in
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 5, height: 5)
                                .position(x: px(i, w), y: py(pt.value, h, maxV))
                        }
                    }
                }
            }
            .frame(height: 150)
            // 横坐标轴线
            Rectangle().fill(Color.secondary.opacity(0.5)).frame(height: 0.8)
            // 横坐标标签
            HStack(spacing: 0) {
                ForEach(Array(points.enumerated()), id: \.offset) { i, p in
                    Text(i % step == 0 || i == n - 1 ? p.label : "")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var config = ConfigStore.shared
    @ObservedObject var router = SettingsRouter.shared
    @ObservedObject var voice = VoiceService.shared
    @State private var apiKeyText: String = ""
    @State private var testResult: String = ""
    @State private var importMessage: String = ""
    @State private var manualKind: Personality.Kind = .energetic    // 当日手动性格暂存
    @State private var aiEvaluating = false
    @State private var aiError: String?
    @State private var showReason = false
    @State private var workloadRange: WorkloadRange = .week
    @State private var analyzing = false
    @State private var analysisText = ""
    @State private var analysisError: String?
    @State private var stagedColors: [String: Color] = [:]   // 待「确定」的调色结果
    @State private var keyRevealed = true                    // API Key 明文显示（可复制）
    @State private var showingDraft = false                  // 新建分类草稿行
    @State private var draftLabel = ""
    @State private var draftColor: Color = .blue

    /// 设置分类（左侧栏条目）
    struct SettingsCategory: Identifiable {
        let id: Int; let title: String; let icon: String
    }
    static let categories: [SettingsCategory] = [
        .init(id: 0, title: "通用", icon: "gearshape"),
        .init(id: 1, title: "外观", icon: "paintpalette"),
        .init(id: 2, title: "提醒 & 语音", icon: "bell"),
        .init(id: 3, title: "宠物", icon: "cat"),
        .init(id: 4, title: "AI 助理", icon: "sparkles"),
        .init(id: 5, title: "数据", icon: "square.and.arrow.up"),
        .init(id: 6, title: "工作量", icon: "chart.bar.xaxis"),
    ]

    // 仿 macOS 系统设置：左侧栏选分类，右侧显示对应细节
    var body: some View {
        HStack(spacing: 0) {
            List(selection: $router.tab) {
                ForEach(Self.categories) { c in
                    Label(c.title, systemImage: c.icon).tag(c.id)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 178)

            Divider()

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 840, height: 620)
        .accentColor(config.customAccent())
        .onAppear {
            apiKeyText = ConfigStore.shared.apiKey
        }
    }

    @ViewBuilder
    var detail: some View {
        switch router.tab {
        case 0: ScrollView { generalTab }
        case 1: appearanceTab
        case 2: reminderTab
        case 3: ScrollView { petTab }
        case 4: aiTab
        case 6: ScrollView { workloadTab }
        default: dataTab
        }
    }

    /// 分类行：调色先暂存，点「确定」才写入；内置可重置色/隐藏，自定义可删除
    func categoryRow(key: String,
                     label: Binding<String>,
                     committed: Color,
                     onCommitColor: @escaping (Color) -> Void,
                     onResetColor: (() -> Void)?,
                     onDelete: (() -> Void)?,
                     deleteHelp: String) -> some View {
        let staged = stagedColors[key]
        return HStack(spacing: 8) {
            TextField("标签", text: label)
                .textFieldStyle(.roundedBorder)
            // 单一圆盘取色（暂存，点「确定」才写入）
            ColorDisc(color: Binding(
                get: { staged ?? committed },
                set: { v in stagedColors[key] = v }))
            if let staged {
                Button("确定") {
                    onCommitColor(staged)
                    stagedColors[key] = nil
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("取消") { stagedColors[key] = nil }
                    .controlSize(.small)
            } else if let onResetColor {
                Button { onResetColor() } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.plain)
                .help("恢复默认颜色")
            }
            if let onDelete {
                Button { onDelete() } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .help(deleteHelp)
            }
        }
    }

    var generalTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("颜色分类（标签 + 调色盘）").bold()
            ForEach(config.visibleBuiltIn, id: \.self) { c in
                categoryRow(
                    key: c.rawValue,
                    label: Binding(
                        get: { ConfigStore.shared.categoryLabels[c.rawValue] ?? c.defaultLabel },
                        set: { v in
                            var cfg = ConfigStore.shared
                            cfg.categoryLabels[c.rawValue] = v
                            cfg.save()
                        }),
                    committed: config.categoryColor(c),
                    onCommitColor: { newColor in
                        var cfg = ConfigStore.shared
                        cfg.categoryColors[c.rawValue] = HexColor.hexString(from: NSColor(newColor))
                        cfg.save()
                    },
                    onResetColor: {
                        var cfg = ConfigStore.shared
                        cfg.categoryColors.removeValue(forKey: c.rawValue)
                        cfg.save()
                    },
                    onDelete: {
                        var cfg = ConfigStore.shared
                        cfg.hiddenCategories[c.rawValue] = true
                        cfg.save()
                    },
                    deleteHelp: "隐藏该内置分类")
            }
            // 自定义（含新添加的）分类紧跟在内置颜色分类下面
            ForEach($config.customCategories, id: \.id) { item in
                categoryRow(
                    key: "custom:\(item.wrappedValue.id)",
                    label: Binding(
                        get: { item.wrappedValue.label },
                        set: { v in item.wrappedValue.label = v; config.save() }),
                    committed: item.wrappedValue.color,
                    onCommitColor: { newColor in
                        item.wrappedValue.hex = HexColor.hexString(from: NSColor(newColor))
                        config.save()
                    },
                    onResetColor: nil,
                    onDelete: { config.removeCategory(id: item.wrappedValue.id) },
                    deleteHelp: "删除该分类")
            }
            if config.visibleBuiltIn.count < EventItem.CategoryColor.allCases.count {
                HStack {
                    Text("存在已隐藏的内置分类。").font(.caption).foregroundStyle(.secondary)
                    Button("恢复全部内置分类") {
                        var cfg = ConfigStore.shared
                        cfg.hiddenCategories = [:]
                        cfg.save()
                    }
                    .controlSize(.small)
                }
            }
            Text("左下角图例会按这里配置的颜色分类与色值显示；隐藏的内置分类不再出现在图例与事项颜色选择中。")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                if !showingDraft {
                    Button {
                        showingDraft = true
                        draftLabel = ""
                        draftColor = .blue
                    } label: {
                        Label("添加分类", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Spacer()
            }
            if showingDraft {
                HStack(spacing: 8) {
                    TextField("新分类名称", text: $draftLabel)
                        .textFieldStyle(.roundedBorder)
                    ColorDisc(color: $draftColor)
                    Button("确定") {
                        config.addCategory(label: draftLabel.isEmpty ? "新分类" : draftLabel,
                                           hex: HexColor.hexString(from: NSColor(draftColor)))
                        showingDraft = false
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button("取消") { showingDraft = false }
                        .controlSize(.small)
                }
            }
            Divider()
            Text("运行日志").bold()
            Text("日志每天一个文件，保存在：\(LogStore.shared.directory.path)")
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Button("打开日志目录") { LogStore.shared.openInFinder() }
                Button("查看今天日志") { LogStore.shared.openTodayLog() }
                Button("查看 AI 日志") { AILogStore.shared.openTodayLog() }
            }
            Text("若日历窗口卡死/点不动，重启 app 后从「查看今天日志」可读取卡死前最后记录（约 8 秒无响应会记预警）。")
                .font(.caption).foregroundStyle(.secondary)

            Spacer()
        }
        .padding()
    }

    /// 背景墙预设（id 与 ConfigStore.presetGradient() 对应）
    struct WallpaperPreset: Identifiable {
        let id: String; let label: String; let swatch: Color
    }
    static let wallpaperPresets: [WallpaperPreset] = [
        .init(id: "theme", label: "主题", swatch: Color(nsColor: .underPageBackgroundColor)),
        .init(id: "sunset", label: "落日", swatch: Color(red: 0.98, green: 0.55, blue: 0.45)),
        .init(id: "ocean", label: "海洋", swatch: Color(red: 0.15, green: 0.5, blue: 0.7)),
        .init(id: "forest", label: "森林", swatch: Color(red: 0.25, green: 0.55, blue: 0.35)),
        .init(id: "midnight", label: "午夜", swatch: Color(red: 0.12, green: 0.16, blue: 0.3)),
        .init(id: "sakura", label: "樱花", swatch: Color(red: 0.96, green: 0.7, blue: 0.8)),
    ]

    var appearanceTab: some View {
        Form {
            Section("主题") {
                Picker("主题", selection: $config.theme) {
                    ForEach(Theme.allCases, id: \.self) { t in
                        Text("\(t.label) — \(t.tagline)").tag(t)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: config.theme) { _ in config.save() }
                // 主题颜色也可直接用调色盘（圆盘）自定义
                paletteRow("背景色", keyPath: \.customBgHex)
                paletteRow("文本色", keyPath: \.customFgHex)
                paletteRow("强调色", keyPath: \.customAccentHex)
                Text("用圆盘可直接改主题的背景/文本/强调色；点「清除」回落到所选主题默认。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("恢复默认外观") { config.resetAppearance() }
            }
            Section("背景墙") {
                HStack(spacing: 8) {
                    ForEach(Self.wallpaperPresets) { p in
                        Button { config.presetWallpaper = p.id; config.save() } label: {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(p.swatch)
                                .frame(width: 42, height: 42)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(
                                    config.presetWallpaper == p.id ? config.customAccent() : .primary.opacity(0.2),
                                    lineWidth: config.presetWallpaper == p.id ? 2 : 1))
                        }
                        .buttonStyle(.plain)
                        .help(p.label)
                    }
                }
                HStack {
                    Button(config.wallpaperPath.isEmpty ? "选择背景图片…" : "更换背景图片…") { chooseWallpaper() }
                    if !config.wallpaperPath.isEmpty {
                        Button("移除图片") { config.wallpaperPath = ""; config.save() }
                            .buttonStyle(.plain).foregroundStyle(.secondary).font(.caption)
                    }
                }
                Text("生效优先级：背景图片 > 预设颜色 > 自定义色；都不设则用上方主题。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("窗口") {
                Toggle("贴到桌面层（壁纸之上、图标之下）", isOn: $config.desktopPin).onChange(of: config.desktopPin) { _ in config.save() }
                Toggle("透明磨砂背景", isOn: $config.desktopTransparent).onChange(of: config.desktopTransparent) { _ in config.save() }
                Text("桌面层使用未公开窗口层级，若在你的系统上被遮挡/异常，可关闭「贴到桌面层」改为悬浮窗口。").font(.caption)
            }
        }
        .padding()
    }

    /// 主题调色行：标签 + 单一圆盘 + 清除
    func paletteRow(_ title: String, keyPath: WritableKeyPath<ConfigStore, String>) -> some View {
        HStack {
            Text(title)
            ColorDisc(color: colorBinding(keyPath))
            if !ConfigStore.shared[keyPath: keyPath].isEmpty {
                Button("清除") {
                    var cfg = ConfigStore.shared
                    cfg[keyPath: keyPath] = ""
                    cfg.save()
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).font(.caption)
            }
            Spacer()
        }
    }

    /// 将 hex 字符串属性包装成 Color 可用的 binding
    func colorBinding(_ keyPath: WritableKeyPath<ConfigStore, String>) -> Binding<Color> {
        Binding(
            get: {
                let hex = config[keyPath: keyPath]
                guard !hex.isEmpty, let nc = HexColor.nsColor(fromHex: hex) else {
                    return config.customAccent()   // 空值占位：用强调色便于辨识
                }
                return Color(nsColor: nc)
            },
            set: { c in
                let nc = NSColor(c).usingColorSpace(.sRGB) ?? .black
                let hex = HexColor.hexString(from: nc)
                var cfg = ConfigStore.shared
                cfg[keyPath: keyPath] = hex
                cfg.save()
            })
    }

    /// 选择一张本地图片作为背景墙（复制到 Application Support，避免原图被移动/删除后失效）
    func chooseWallpaper() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "选择一张背景墙图片"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MyCalendar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("wallpaper.\(url.pathExtension)")
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            config.wallpaperPath = dest.path
        } catch {
            config.wallpaperPath = url.path
        }
        config.save()
    }

    // MARK: 工作量评估（权重 + 趋势图 + AI 分析）

    var workloadTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("分类权重").bold()
            Text("每个事项按其分类的权重计入当日工作量；权重越高代表越重要/越耗时。默认 1.0。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(config.visibleBuiltIn, id: \.self) { c in
                weightRow(key: c.rawValue,
                          label: config.categoryLabels[c.rawValue] ?? c.defaultLabel,
                          color: config.categoryColor(c))
            }
            ForEach(config.customCategories) { c in
                weightRow(key: "custom:\(c.id)", label: c.label, color: c.color)
            }

            Divider()

            HStack {
                Text("工作量趋势").bold()
                Spacer()
                Picker("区间", selection: $workloadRange) {
                    ForEach(WorkloadRange.allCases) { r in Text(r.rawValue).tag(r) }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
            }
            WorkloadChartView(points: WorkloadEngine.series(workloadRange))
                .padding(.vertical, 6)

            // 当天已完成 / 未完成
            let ts = WorkloadEngine.todaySplit()
            HStack(spacing: 16) {
                Label("今天已完成 \(ts.doneCount) 件（权重 \(WorkloadEngine.fmt(ts.doneWeight))）",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Label("未完成 \(ts.undoneCount) 件（权重 \(WorkloadEngine.fmt(ts.undoneWeight))）",
                      systemImage: "circle.dashed")
                    .foregroundStyle(.orange)
            }
            .font(.callout)

            let bd = WorkloadEngine.breakdown(workloadRange)
            if !bd.isEmpty {
                Text("工作重心（按加权占比）").bold()
                ForEach(Array(bd.prefix(5)), id: \.key) { item in
                    HStack {
                        Text(item.label)
                        Spacer()
                        Text(WorkloadEngine.fmt(item.value)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }

            Divider()

            HStack {
                Button(analyzing ? "分析中…" : "AI 分析近期工作") {
                    analyzing = true
                    analysisError = nil
                    Task { @MainActor in
                        defer { analyzing = false }
                        do {
                            analysisText = try await ConfigStore.shared.analyzeWorkload(workloadRange)
                        } catch {
                            analysisError = error.localizedDescription
                            // AI 不可用时兜底：本地规则摘要，保证有输出
                            analysisText = "（AI 不可用，以下为本地规则摘要）\n"
                                + WorkloadEngine.localAnalysis(workloadRange)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(analyzing)
                Button("查看 AI 日志") { AILogStore.shared.openTodayLog() }
                .buttonStyle(.bordered)
                // 播报 AI 分析结果（在线声线优先、本地兜底）；再点停止
                Button {
                    if voice.isSpeaking {
                        voice.stop()
                    } else {
                        voice.speakPersonality(analysisText, kind: config.effectivePersonality())
                    }
                } label: {
                    Label(voice.isSpeaking ? "停止播报" : "播报分析",
                          systemImage: voice.isSpeaking ? "stop.circle.fill" : "speaker.wave.2.fill")
                }
                .buttonStyle(.bordered)
                .disabled(analysisText.isEmpty)
                Spacer()
            }
            if let e = analysisError {
                Text(e).font(.caption).foregroundStyle(.red)
            }
            if !analysisText.isEmpty {
                Text(analysisText)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
            }
            Text("AI 会读取所选区间的加权工作量与分类占比，给出【总结】与【建议】；未启用 AI 时会提示先去「AI 助理」配置。")
                .font(.caption).foregroundStyle(.secondary)

            Spacer()
        }
        .padding()
    }

    func weightRow(key: String, label: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 12, height: 12)
            Text(label)
            Spacer()
            Stepper(value: weightBinding(key), in: 0...10, step: 0.5) {
                Text(WorkloadEngine.fmt(weightBinding(key).wrappedValue))
                    .monospacedDigit()
                    .frame(width: 34, alignment: .trailing)
            }
            .frame(width: 150)
        }
    }

    func weightBinding(_ key: String) -> Binding<Double> {
        Binding(
            get: { ConfigStore.shared.categoryWeights[key] ?? 1.0 },
            set: { v in
                var cfg = ConfigStore.shared
                cfg.categoryWeights[key] = v
                cfg.save()
            })
    }

    var dataTab: some View {
        Form {
            Text("导出事项").bold()
            HStack {
                Button("导出 ICS") { export(.ics) }
                Button("导出 CSV") { export(.csv) }
            }
            Text("ICS 可导入系统日历 / Google / Outlook；CSV 适合表格软件。").font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("导入").bold()
            HStack {
                Button("导入 ICS…") { importICS() }
                if !importMessage.isEmpty {
                    Text(importMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("导入系统日历 / Google / Outlook 导出的 .ics 文件。").font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("云同步").bold()
            Text("已移除 CloudKit 云同步（需开发者签名）。数据仅保存在本机，可用于导出/导入备份。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }

    func importICS() {
        importMessage = ""
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.text]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.message = "选择要导入的 .ics 日历文件"
        if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
            let events = EventImporter.parse(data)
            for e in events { AppModel.shared.add(e) }
            importMessage = events.isEmpty ? "未找到可导入的事件" : "已导入 \(events.count) 条"
        }
    }

    func export(_ kind: ExportKind) {
        let panel = NSSavePanel()
        let content: String
        switch kind {
        case .ics:
            panel.nameFieldStringValue = "桌面日历.ics"
            panel.allowedContentTypes = [.text]
            content = EventExporter.ics(AppModel.shared.events)
        case .csv:
            panel.nameFieldStringValue = "桌面日历.csv"
            panel.allowedContentTypes = [.commaSeparatedText]
            content = EventExporter.csv(AppModel.shared.events)
        }
        if panel.runModal() == .OK, let url = panel.url {
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    var reminderTab: some View {
        Form {
            Toggle("开启语音播报", isOn: $config.voiceEnabled).onChange(of: config.voiceEnabled) { _ in config.save() }
            Toggle("在线声线（Edge TTS，每个性格一条真声线，需联网）", isOn: $config.onlineTTS)
                .onChange(of: config.onlineTTS) { _ in config.save() }
            Text("在线声线（全女声）：元气=晓晓 / 慵懒=晓妮（软糯慢调）/ 傲娇=晓伊（清亮）/ 高冷=小北（低稳）；断网或失败自动回退本地语音。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("播报语速")
                Slider(value: $config.voiceRate, in: 0.3...0.7).frame(width: 200)
                Text(String(format: "%.2f", config.voiceRate))
            }
            Text("默认提醒点（对所有事项生效，可被单条覆盖）:")
            HStack {
                toggleDefault(-60, "提前1小时")
                toggleDefault(-30, "提前30分钟")
                toggleDefault(-10, "提前10分钟")
                toggleDefault(0, "准点")
            }
            Button("试听语音") { testVoice() }

            Divider()
            Text("悬浮时钟（常驻屏幕右上角；鼠标悬停圆盘弹出今日待办，今日不足 5 条自动用之后的待办补齐）:")
            Toggle("显示悬浮时钟", isOn: $config.countdownEnabled)
                .onChange(of: config.countdownEnabled) { _ in
                    config.save()
                    WindowManager.shared.setClockVisible(config.countdownEnabled)
                }
        }
        .padding()
    }

    func toggleDefault(_ off: Int, _ label: String) -> some View {
        let on = config.reminderDefaults.contains(off)
        return Toggle(isOn: Binding(get: { on },
                                    set: { adding in
                                        var set = Set(config.reminderDefaults)
                                        if adding { set.insert(off) } else { set.remove(off) }
                                        config.reminderDefaults = Array(set).sorted()
                                        config.save()
                                    })) { Text(label) }
            .toggleStyle(.checkbox)
    }

    var petTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    PetFallbackPhotoView(mood: .idle)
                    PersonalityAccessoryView(kind: config.personalityKind)
                }
                .frame(width: 100, height: 90)
                VStack(alignment: .leading, spacing: 6) {
                    Text(config.petName.isEmpty ? "咪咪" : config.petName).font(.headline)
                    TextField("猫咪名字", text: $config.petName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 180)
                        .onChange(of: config.petName) { _ in config.save() }
                    Text("真实猫咪视频形象（内置你的 pet1/pet2 视频轮播），也可换成自选视频")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("性格（决定语音语速、提醒文案与外观配饰）")
            Picker("性格", selection: $config.personalityKind) {
                ForEach(Personality.Kind.all, id: \.self) { k in Text(k.label).tag(k) }
            }
            .pickerStyle(.segmented)
            .onChange(of: config.personalityKind) { _ in config.save() }
            Text("元气=蝴蝶结 / 慵懒=睡帽 / 傲娇=皇冠 / 高冷=墨镜").font(.caption).foregroundStyle(.secondary)
            Divider()
            dayPersonalitySection
            Divider()
            Text("宠物视频")
            Text("已内置 pet1.mp4 / pet2.mp4 两段猫咪视频，自动循环轮播。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("选择自定义视频…") { pickVideo() }
                if !config.petVideoPath.isEmpty {
                    Button("移除视频") { config.petVideoPath = ""; config.save() }
                    Text(URL(fileURLWithPath: config.petVideoPath).lastPathComponent)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Text("自定义视频（mp4/mov）优先于内置视频，会循环播放；建议竖屏、纯色或透明背景。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Toggle("锁定宠物窗口（禁止拖拽；与日历独立）", isOn: Binding(
                get: { config.petLocked },
                set: { v in config.petLocked = v; config.save(); WindowManager.shared.applyPetLock() }))
            Text("锁定后仍可点击/交互，只是不能拖动。右上角 ✕ 关闭宠物；菜单栏 📅 图标可随时重新显示。")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
        .onAppear { manualKind = config.effectiveDayPersonality?.kind ?? config.personalityKind }
        .onChange(of: config.personalityKind) { _ in config.save() }
    }

    /// 宠物「今日性格」：用户手动设置 或 AI 按当日工作量评估，并展示理由/来源
    var dayPersonalitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("今日性格").bold()
                Spacer()
                if config.effectiveDayPersonality != nil {
                    Button("取消今日设置") { config.clearDayPersonality() }
                        .buttonStyle(.plain).foregroundStyle(.secondary).font(.caption)
                }
            }
            if let dp = config.effectiveDayPersonality {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: dp.source == .ai ? "sparkles" : "person.fill")
                            .foregroundStyle(Color.accentColor)
                        Text("\(dp.source.label)：今日【\(dp.kind.label)】")
                            .font(.subheadline.weight(.semibold))
                    }
                    if dp.source == .ai {
                        if let s = dp.summary, !s.isEmpty {
                            Text("按今日工作量：\(s)").font(.caption).foregroundStyle(.secondary)
                        }
                        Button("查看理由") { showReason.toggle() }
                            .buttonStyle(.link).font(.caption)
                        if showReason {
                            Text(dp.reason ?? "（AI 未给出理由）")
                                .font(.caption).foregroundStyle(.secondary)
                                .padding(6)
                                .background(Color.white.opacity(0.05))
                                .cornerRadius(6)
                        }
                    } else {
                        Text("已手动指定今日性格。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.5), lineWidth: 0.8))
            } else {
                Text("未单独设置今日性格，沿用上方全局性格：\(config.personalityKind.label)。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Picker("方式", selection: dayModeBinding) {
                Text("沿用全局").tag(0)
                Text("手动设置").tag(1)
                Text("AI 评估").tag(2)
            }
            .pickerStyle(.segmented)

            switch currentDayMode {
            case 1:
                Picker("今日性格", selection: manualKindBinding) {
                    ForEach(Personality.Kind.all, id: \.self) { k in Text(k.label).tag(k) }
                }
                .pickerStyle(.segmented)
            case 2:
                VStack(alignment: .leading, spacing: 8) {
                    let w = config.todayWorkload()
                    Text("今日工作量：\(w.total) 个事项（定时 \(w.timed) / 全天 \(w.allDay)）" +
                         (w.nextMinutes.map { "；最近定时还剩约 \($0) 分钟" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                    if aiEvaluating {
                        ProgressView().controlSize(.small)
                        Text("正在评估…").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button(config.effectiveDayPersonality?.source == .ai ? "重新评估" : "AI 评估今日性格") {
                            Task { await runAI() }
                        }
                        .buttonStyle(.bordered)
                    }
                    if let err = aiError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }
            default:
                EmptyView()
            }
        }
    }

    var currentDayMode: Int {
        if let dp = config.effectiveDayPersonality { return dp.source == .user ? 1 : 2 }
        return 0
    }
    var dayModeBinding: Binding<Int> {
        Binding(
            get: { currentDayMode },
            set: { m in
                switch m {
                case 0: config.clearDayPersonality()
                case 1:
                    config.setDayPersonality(manualKind, source: .user)
                case 2:
                    Task { await runAI() }
                default: break
                }
            })
    }
    var manualKindBinding: Binding<Personality.Kind> {
        Binding(
            get: { config.effectiveDayPersonality?.kind ?? manualKind },
            set: { manualKind = $0; config.setDayPersonality($0, source: .user) })
    }

    @MainActor func runAI() async {
        aiEvaluating = true
        aiError = nil
        showReason = false
        let ok = await config.evaluateDayPersonality()
        aiEvaluating = false
        if ok {
            showReason = false
        } else {
            aiError = "无法评估：请在「AI 助理」页配置模型与 API Key，并确认已开启 AI 与隐私开关。"
        }
    }

    func pickVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.message = "选择一段猫咪视频（将循环播放）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MyCalendar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("pet_video.\(url.pathExtension)")
        try? FileManager.default.removeItem(at: dest)
        if (try? FileManager.default.copyItem(at: url, to: dest)) != nil {
            config.petVideoPath = dest.path
            config.save()
        }
    }

    var aiTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                aiCard {
                    Toggle("启用 AI 生成提醒文案（关闭则用内置台词）", isOn: $config.llm.enabled)
                        .onChange(of: config.llm.enabled) { _ in config.save() }
                }
                aiCard {
                    aiLabel("模型供应商", icon: "server.rack")
                    Picker("供应商", selection: $config.llm.provider) {
                        ForEach(LLMProvider.allCases, id: \.self) { p in Text(p.label).tag(p) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: config.llm.provider) { _ in config.save() }
                }
                aiCard {
                    aiLabel("接入信息", icon: "link")
                    aiField(icon: "globe", placeholder: "接口地址（如 https://api.deepseek.com/v1）", text: $config.llm.baseURL)
                    aiField(icon: "cube", placeholder: "模型名称（如 deepseek-chat）", text: $config.llm.modelName)
                    // API Key 用普通 TextField（支持 ⌘A/⌘C/⌘X/⌘V），可点眼睛临时隐藏
                    HStack(spacing: 8) {
                        Image(systemName: "key").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
                        if keyRevealed {
                            TextField("API Key（sk-…）", text: $apiKeyText).textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("API Key（sk-…）", text: $apiKeyText).textFieldStyle(.roundedBorder)
                        }
                        Button { keyRevealed.toggle() } label: {
                            Image(systemName: keyRevealed ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                        .help(keyRevealed ? "隐藏（隐藏后不可复制）" : "显示明文")
                    }
                    Text("支持 Command+A 全选、Command+C/V 复制粘贴、Command+X 剪切；API Key 存本机偏好文件，不再弹钥匙串鉴权。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                aiCard {
                    aiLabel("生成参数", icon: "slider.horizontal.3")
                    HStack {
                        Text("温度").font(.system(size: 12))
                        Slider(value: $config.llm.temperature, in: 0.0...1.0)
                        Text(String(format: "%.1f", config.llm.temperature)).font(.system(size: 12)).monospacedDigit()
                    }
                    Toggle("确认：把事件标题/剩余时间发送给所配模型", isOn: $config.llm.privacyOK)
                        .font(.system(size: 12))
                }
                HStack(spacing: 10) {
                    Button("保存配置") { saveAI() }.buttonStyle(.borderedProminent)
                    Button("测试连接") { testAI() }.buttonStyle(.bordered)
                    if !testResult.isEmpty {
                        Text(testResult).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .padding()
        }
    }

    func aiCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.secondary.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.secondary.opacity(0.18), lineWidth: 0.8))
    }

    func aiLabel(_ s: String, icon: String) -> some View {
        Label(s, systemImage: icon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    func aiField(icon: String, placeholder: String, text: Binding<String>, secure: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
            if secure {
                SecureField(placeholder, text: text).textFieldStyle(.roundedBorder)
            } else {
                TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
            }
        }
    }

    func saveAI() {
        ConfigStore.shared.apiKey = apiKeyText
        config.save()
        testResult = "已保存"
    }

    func testAI() {
        testResult = "测试中…"
        ConfigStore.shared.apiKey = apiKeyText.isEmpty ? ConfigStore.shared.apiKey : apiKeyText
        config.save()
        Task {
            let cfg = config.llm
            do {
                let text = try await makeClient(for: cfg).complete(
                    system: "你是一只猫咪日历助理，请用一句话回复。",
                    user: "说一句简短问候。", config: cfg)
                await MainActor.run { testResult = "连接成功: " + text.prefix(20) }
            } catch {
                await MainActor.run { testResult = "失败: \(error.localizedDescription)" }
            }
        }
    }

    func testVoice() {
        let kind = config.personalityKind
        let text = Personality(kind: kind).baseLine(title: "交周报", remaining: 30)
        VoiceService.shared.speakPersonality(text, kind: kind)
    }
}
