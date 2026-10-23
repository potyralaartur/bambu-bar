import SwiftUI

enum Format {
    /// "2h 05m", "45m", "<1m".
    static func duration(minutes: Int) -> String {
        if minutes <= 0 { return "<1m" }
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)m" }
        if h >= 24 { return "\(h / 24)d \(h % 24)h" }
        return String(format: "%dh %02dm", h, m)
    }

    static func duration(seconds: TimeInterval) -> String {
        duration(minutes: Int((seconds / 60).rounded()))
    }

    /// "Done 14:32", "Done tomorrow 08:10".
    static func finish(_ date: Date, now: Date = Date()) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return time }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow \(time)"
        }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    static func temperature(_ value: Double) -> String { "\(Int(value.rounded()))°" }

    /// "≈ 810 g", "1 kg"; `approximate` for measured amounts (the AMS estimates what's left).
    static func grams(_ value: Int, approximate: Bool = true) -> String {
        let text = value >= 1000 && value % 1000 == 0 ? "\(value / 1000) kg"
            : value >= 1000 ? String(format: "%.2f kg", Double(value) / 1000) : "\(value) g"
        return approximate ? "≈\u{2009}" + text : text
    }
}

extension Color {
    /// `RRGGBB` or `RRGGBBAA`. Fully transparent colours (unset slots) come back nil.
    init?(bambuHex hex: String) {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard clean.count == 6 || clean.count == 8, let value = UInt64(clean, radix: 16) else { return nil }
        let r, g, b, a: Double
        if clean.count == 8 {
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        } else {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        }
        if a == 0 { return nil }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: max(a, 0.35))
    }
}

/// Perceived brightness of a `RRGGBBAA` colour, 0-1, for picking legible text on a swatch.
func bambuLuminance(_ hex: String) -> Double {
    let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    guard clean.count >= 6, let value = UInt64(clean.prefix(6), radix: 16) else { return 0.5 }
    let r = Double((value >> 16) & 0xFF) / 255, g = Double((value >> 8) & 0xFF) / 255, b = Double(value & 0xFF) / 255
    return 0.299 * r + 0.587 * g + 0.114 * b
}

/// Colours shared by the app and the widget.
enum Palette {
    /// Bambu-ish green, a touch brighter so it reads on dark glass.
    static let accent = Color(red: 0.13, green: 0.80, blue: 0.42)
    static let accentDeep = Color(red: 0.00, green: 0.60, blue: 0.29)
    static let printing = accent
    static let preparing = Color(red: 0.36, green: 0.66, blue: 1.00)
    static let paused = Color(red: 1.00, green: 0.72, blue: 0.24)
    static let failed = Color(red: 1.00, green: 0.36, blue: 0.36)
    static let finished = Color(red: 0.42, green: 0.86, blue: 0.62)
    static let idle = Color.secondary
    static let nozzle = Color(red: 1.00, green: 0.48, blue: 0.30)
    static let bed = Color(red: 1.00, green: 0.72, blue: 0.30)
    static let chamber = Color(red: 0.55, green: 0.70, blue: 1.00)

    static func color(for state: JobState) -> Color {
        switch state {
        case .idle: return Color(red: 0.62, green: 0.66, blue: 0.70)
        case .preparing: return preparing
        case .printing: return printing
        case .paused: return paused
        case .finished: return finished
        case .failed: return failed
        }
    }

    static func color(for status: PrinterStatus) -> Color {
        status.state == .failed && status.canceled ? color(for: .idle) : color(for: status.state)
    }

    static func symbol(for state: JobState) -> String {
        switch state {
        case .idle: return "checkmark.circle.fill"
        case .preparing: return "flame.fill"
        case .printing: return "play.circle.fill"
        case .paused: return "pause.circle.fill"
        case .finished: return "checkmark.seal.fill"
        case .failed: return "exclamationmark.octagon.fill"
        }
    }
}
