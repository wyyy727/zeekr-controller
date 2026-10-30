import SwiftUI

/// 本地时间文本 ↔ `Date`。
///
/// 与后端的约定是 `YYYY-MM-DD HH:mm`（`server/app/api/charges.py` 的 400 文案
/// 就是「paidAt 格式应为 YYYY-MM-DD HH:mm」）；而 OCR / 上游还会给 `...:ss`、
/// `T` 分隔、`/` 分隔这些变体（同后端的 `bills/matching.py:parse_time`）。
/// 所以格式化统一走这里，解析时把变体都试一遍 —— 免得用户选完时间还要自己补格式。
enum V2DateTimeText {

    /// `YYYY-MM-DD HH:mm`，本地时区、不做任何换算。
    static func text(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// 解析后端/OCR 可能给出的各种写法；解析不出来返回 nil。
    static func date(from text: String) -> Date? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        var variants = [raw]
        if raw.contains("/") {
            variants.append(raw.replacingOccurrences(of: "/", with: "-"))
        }

        let formats = [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm",
            "yyyy/MM/dd HH:mm:ss",
            "yyyy/MM/dd HH:mm",
            "yyyy-MM-dd",
            "yyyy/MM/dd",
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for variant in variants {
            for format in formats {
                formatter.dateFormat = format
                if let date = formatter.date(from: variant) { return date }
            }
        }
        return nil
    }
}

// MARK: - 自绘「年 / 月 / 日 / 时 / 分」选择面板

/// 自绘五列滚轮：**年 · 月 · 日 · 时 · 分**。
///
/// ### 为什么换掉系统 `DatePicker`（2026-10-30）
///
/// 原来用 `.graphical` 的 `DatePicker`，两个绕不开的毛病：
/// 1. **选不了时间**：`.graphical` 只渲染日历，没有时分滚轮，
///    而这两个字段的值是 `yyyy-MM-dd HH:mm` —— 用户改完日期，时分纹丝不动，
///    看起来就是「选完不回显」；
/// 2. 系统日历是纯白卡片 + 系统蓝，放进这套自绘白紫面板里不搭。
///
/// ### 为什么是「年/月/日」三列而不是一个日期列（2026-10-30 二次改）
///
/// 第一版把日期做成**一条连续的天列表**（往前 120 天），滚起来能选，但
/// ① 看得出「几号」、看不出「哪年哪月」，跨度之外完全选不到；
/// ② 用户要补录上个月、去年的账单时直接卡住。
/// 现在拆成年 / 月 / 日三列，**任意年月的任意一天都能选**，日的天数按月自动变。
///
/// ### 配色（沿用背景那支紫）
/// - 面板底：白 **0.62** 微透（`.presentationBackground(.clear)` 之后自己画底，
///   页面背景的白紫渐变能透出来）
/// - 选中数字：`V2Color.accent`（`#6742E8`，与月份胶囊 / 图表选中环同一支紫）
/// - 选中衬底：`V2Color.auraViolet`（`#C4B5FD`，**就是背景那团紫**）低透明度
///
/// ⚠️ 选中数字**没有**直接用 `auraViolet`：`#C4B5FD` 压在近白底上对比度不到 1.5，
/// 数字会糊成一片。背景那支紫退到「选中衬底」，文字的紫用同色系的 accent ——
/// 两者同属 v2 的紫，观感是一套。
struct V2DateTimePickerSheet: View {

    let title: String
    @Binding var text: String

    @Environment(\.dismiss) private var dismiss

    /// 可选年份：今年往回 5 年。充电账单只会是过去的，不需要未来。
    private static let pastYears = 4
    private static let rowHeight: CGFloat = 44
    private static let wheelHeight: CGFloat = 220   // 5 行
    private static let columnTitles = ["年", "月", "日", "时", "分"]

    /// 三个日期列的**下标**（不是数值）：年列存 `years` 的下标，月列 0..11，日列 0..30。
    /// 用下标是因为 `scrollPosition(id:)` 要求 id 在数据里唯一且稳定，
    /// 而「日」那列的长度会随年月变，用数值当 id 反而更绕。
    @State private var yearIndex: Int = 0
    @State private var monthIndex: Int = 0
    @State private var dayIndex: Int = 0
    @State private var hour: Int = 0
    @State private var minute: Int = 0

    init(title: String, text: Binding<String>) {
        self.title = title
        _text = text

        /* 首帧就要摆到正确的位置（年/月/日/时/分五项都是），
           否则会先显示「最早那天 00:00」再跳回来 —— 时间列那一闪特别明显。
           `onAppear` 里还会再同步一次 —— 那是给「换一行 / 二次打开」用的：
           `@State` 的初始值只在首次创建生效，再次呈现时靠它纠正。 */
        let parts = Self.parts(from: text.wrappedValue)
        _yearIndex = State(initialValue: parts.yearIndex)
        _monthIndex = State(initialValue: parts.monthIndex)
        _dayIndex = State(initialValue: parts.dayIndex)
        _hour = State(initialValue: parts.hour)
        _minute = State(initialValue: parts.minute)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            wheels
            Spacer(minLength: 0)
        }
        .background(Color.white.opacity(0.62))
        /* `.presentationBackground(.clear)` 之后系统不再帮内容裁圆角，
           自绘的白底会露出方角 —— 和 `V2BottomSheet` 一样自己裁上圆角。 */
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 24,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 24,
                style: .continuous
            )
        )
        .presentationBackground(.clear)
        .presentationDetents([.height(352)])
        .presentationDragIndicator(.hidden)
        .onAppear(perform: syncFromText)
        /* 任意一列跨一行，震一下（iOS 17+，与系统 `UIDatePicker` 是同一类 selection 触感）。
           trigger 用五列下标组成的数组：数组元素相等即不触发，所以只有真的换行才震。
           用 `dayIndex`（原始值）而不是 `effectiveDayIndex`：切月份把 31 号收敛到 28 号
           时不该震，那不是用户滚出来的。 */
        .sensoryFeedback(.selection, trigger: [yearIndex, monthIndex, dayIndex, hour, minute])
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                dismiss()
            } label: {
                Text("取消")
                    .v2Text(.label12, color: V2Color.text3)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            Text(title)
                .v2Text(.title14)

            Spacer(minLength: 8)

            Button {
                text = V2DateTimeText.text(composed)
                dismiss()
            } label: {
                Text("完成")
                    .v2Text(.title14, color: V2Color.accent)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    // MARK: 滚轮

    private var wheels: some View {
        VStack(spacing: 0) {
            /* 列名。五列并排时「哪列是年、哪列是日」光看数字容易混，
               给一行 10pt 的小标签最省事（系统滚轮是靠列间分隔线，这里不画线）。 */
            HStack(spacing: 0) {
                ForEach(Self.columnTitles, id: \.self) { name in
                    Text(name)
                        .v2Text(.note11b, color: V2Color.text3)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 2)

            ZStack {
                // 选中行衬底：背景那团紫的低透明度版本
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(V2Color.auraViolet.opacity(0.22))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(V2Color.accent.opacity(0.20), lineWidth: 1)
                    )
                    .frame(height: Self.rowHeight - 4)
                    .padding(.horizontal, 12)
                    .allowsHitTesting(false)

                HStack(spacing: 0) {
                    wheel(items: yearItems, selection: $yearIndex)
                    wheel(items: monthItems, selection: $monthIndex)
                    // 日列的长度随年月变，用 clamped 绑定读，越界自动收敛
                    wheel(items: dayItems, selection: daySelection)
                    wheel(items: hourItems, selection: $hour)
                    wheel(items: minuteItems, selection: $minute)
                }
            }
            .frame(height: Self.wheelHeight)
            .padding(.top, 4)
        }
    }

    /// 一列滚轮。数字列用等宽数字，否则 11→12 的位数变化会让整列左右抖。
    private func wheel(items: [WheelItem], selection: Binding<Int>) -> some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    let isOn = item.id == selection.wrappedValue
                    Text(item.text)
                        .font(.custom(isOn ? V2Font.semiBold : V2Font.regular,
                                      size: isOn ? 19 : 16))
                        .monospacedDigit()
                        .foregroundStyle(isOn ? V2Color.accent : V2Color.text3)
                        .lineLimit(1)
                        .frame(height: Self.rowHeight)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .id(item.id)
                        // 点一行也能选中：滚轮之外多一条路，也便于辅助功能
                        .onTapGesture { selection.wrappedValue = item.id }
                }
            }
            .scrollTargetLayout()
        }
        // 首尾两行也要能滚到正中间，否则第一项永远停在顶部、选不中
        .contentMargins(.vertical, (Self.wheelHeight - Self.rowHeight) / 2, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(
            id: Binding(
                get: { Optional(selection.wrappedValue) },
                set: { new in if let new { selection.wrappedValue = new } }
            ),
            anchor: .center
        )
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity)
        .frame(height: Self.wheelHeight)
        // 上下两端淡出，「转」的感觉才出来
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.18),
                    .init(color: .black, location: 0.82),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: 数据

    private struct WheelItem: Identifiable {
        let id: Int
        let text: String
    }

    /// 可选年份（升序）。做成计算属性：跨年那一刻打开也不会拿到去年的列表。
    private var years: [Int] {
        let current = Calendar.current.component(.year, from: Date())
        return Array((current - Self.pastYears)...current)
    }

    /// 年下标收敛到合法范围 —— 解析出来的年份可能早于可选范围。
    private var safeYearIndex: Int {
        min(max(0, yearIndex), years.count - 1)
    }

    private var selectedYear: Int { years[safeYearIndex] }

    /// 当月天数：2 月随闰年变 28/29，小月 30。
    private var daysInSelectedMonth: Int {
        let calendar = Calendar.current
        var comps = DateComponents()
        comps.year = selectedYear
        comps.month = monthIndex + 1
        comps.day = 1
        guard let first = calendar.date(from: comps),
              let range = calendar.range(of: .day, in: .month, for: first)
        else { return 30 }
        return range.count
    }

    /// 日下标收敛：从 1 月 31 日切到 2 月时，31 号要自动落到 28/29。
    private var effectiveDayIndex: Int {
        min(max(0, dayIndex), daysInSelectedMonth - 1)
    }

    /// 日列的绑定：读的时候给收敛值，写的时候照实存 ——
    /// 这样「月份变短」不需要 `onChange` 去纠正，显示与取值天然一致。
    private var daySelection: Binding<Int> {
        Binding(
            get: { effectiveDayIndex },
            set: { dayIndex = $0 }
        )
    }

    private var yearItems: [WheelItem] {
        years.enumerated().map { WheelItem(id: $0.offset, text: String($0.element)) }
    }

    private var monthItems: [WheelItem] {
        (1...12).map { WheelItem(id: $0 - 1, text: String($0)) }
    }

    private var dayItems: [WheelItem] {
        (1...daysInSelectedMonth).map { WheelItem(id: $0 - 1, text: String($0)) }
    }

    private var hourItems: [WheelItem] {
        (0...23).map { WheelItem(id: $0, text: String(format: "%02d", $0)) }
    }

    private var minuteItems: [WheelItem] {
        (0...59).map { WheelItem(id: $0, text: String(format: "%02d", $0)) }
    }

    // MARK: 同步与取值

    /// 把 `yyyy-MM-dd HH:mm` 拆成五列各自的下标。解析不出来就落在「现在」。
    private static func parts(from text: String) -> (yearIndex: Int, monthIndex: Int, dayIndex: Int, hour: Int, minute: Int) {
        let calendar = Calendar.current
        let now = Date()
        let current = calendar.component(.year, from: now)
        let parsed = V2DateTimeText.date(from: text) ?? now
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: parsed)

        // 年份超出可选范围就夹到最近的一端（不静默换成今年，免得看起来"没选上"）
        let offset = (comps.year ?? current) - (current - pastYears)
        let yearIndex = min(max(0, offset), pastYears)

        return (
            yearIndex,
            min(max(0, (comps.month ?? 1) - 1), 11),
            min(max(0, (comps.day ?? 1) - 1), 30),
            min(max(0, comps.hour ?? 0), 23),
            min(max(0, comps.minute ?? 0), 59)
        )
    }

    /// ⚠️ 必须放 `onAppear` 而不是只靠 `init`：`@State` 的初始值只在**首次**创建生效，
    /// 换一行（OCR 多笔）或二次打开时会拿着上一次的日期 ——
    /// 那正是「打开第二行显示第一行的日期」这类串味的根源。
    private func syncFromText() {
        let parts = Self.parts(from: text)
        yearIndex = parts.yearIndex
        monthIndex = parts.monthIndex
        dayIndex = parts.dayIndex
        hour = parts.hour
        minute = parts.minute
    }

    /// 把五列的选择拼回一个 `Date`。
    private var composed: Date {
        let calendar = Calendar.current
        var comps = DateComponents()
        comps.year = selectedYear
        comps.month = monthIndex + 1
        comps.day = effectiveDayIndex + 1
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        return calendar.date(from: comps) ?? Date()
    }
}
