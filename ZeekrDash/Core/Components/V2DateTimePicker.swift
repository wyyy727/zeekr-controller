import SwiftUI

/// 本地时间文本 ↔ `Date`。
///
/// 与后端的约定是 `YYYY-MM-DD HH:mm`（`server/app/api/charges.py:666` 的 400 文案
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
        } else if raw.contains("-") {
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

/// 系统原生的「日期 + 时间」选择面板（日历 `.graphical` + 时间滚轮）。
///
/// 为什么需要它（2026-10-28 修）：手写录入的「时间」和 OCR 核对的「开始时间」
/// 此前都是 `TextField`，点下去弹的是数字键盘 —— 用户得手敲 `2026-10-27 14:30`，
/// 少一位、用了中文冒号、忘记补零都会被后端 400，而且根本没法学系统日历那样
/// 「点今天」。改成点一下弹原生选择器，选完回填同一份 `text`。
///
/// 用 `.graphical` 而不是 `compact`：面板本身是自绘的 bottom sheet，
/// `compact` 在自绘容器里弹出的浮层位置不可控；整块 sheet 里放日历最稳。
struct V2DateTimePickerSheet: View {

    let title: String
    @Binding var text: String

    @Environment(\.dismiss) private var dismiss
    @State private var value: Date

    init(title: String, text: Binding<String>) {
        self.title = title
        _text = text
        // 已有文本解析失败（比如 OCR 只认出半截）就先落在「现在」，用户改起来也快
        _value = State(initialValue: V2DateTimeText.date(from: text.wrappedValue) ?? Date())
    }

    var body: some View {
        VStack(spacing: 0) {
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
                    text = V2DateTimeText.text(value)
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

            DatePicker("", selection: $value)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .tint(V2Color.accent)
                .padding(.horizontal, 4)
                .padding(.bottom, 8)

            Spacer(minLength: 0)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
