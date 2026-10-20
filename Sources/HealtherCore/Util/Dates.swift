import Foundation

/// Calendar helpers. "Day" means the user's local calendar day.
public struct DayClock: Sendable {
    public var calendar: Calendar
    public var timeZone: TimeZone { calendar.timeZone }

    public init(timeZone: TimeZone = .current) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        cal.firstWeekday = 2
        calendar = cal
    }

    public func startOfDay(_ date: Date) -> Date { calendar.startOfDay(for: date) }

    public func endOfDay(_ date: Date) -> Date {
        calendar.date(byAdding: .day, value: 1, to: startOfDay(date))!
    }

    public func addDays(_ n: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: n, to: date)!
    }

    /// "2026-10-20"
    public func dayKey(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    public func date(fromDayKey key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// "14:05"
    public func timeString(_ date: Date) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour!, c.minute!)
    }

    /// "2026-10-20 14:05"
    public func stamp(_ date: Date) -> String { dayKey(date) + " " + timeString(date) }

    public func weekdayName(_ date: Date) -> String {
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        return names[calendar.component(.weekday, from: date) - 1]
    }

    public func hour(_ date: Date) -> Int { calendar.component(.hour, from: date) }

    /// Parses model-supplied times: ISO-8601, "YYYY-MM-DD HH:mm", "YYYY-MM-DD", or "HH:mm" (today).
    public func parse(_ text: String?, relativeTo now: Date) -> Date? {
        guard var s = text?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        s = s.replacingOccurrences(of: "T", with: " ")
        let parts = s.split(separator: " ")
        var day = startOfDay(now)
        var timePart: Substring?
        if parts.count == 2 {
            guard let d = date(fromDayKey: String(parts[0])) else { return nil }
            day = d
            timePart = parts[1]
        } else if parts.count == 1 {
            if parts[0].contains("-") { return date(fromDayKey: String(parts[0])) }
            timePart = parts[0]
        }
        guard let tp = timePart else { return nil }
        let hm = tp.split(separator: ":").compactMap { Int($0) }
        guard hm.count >= 2 else { return nil }
        return calendar.date(bySettingHour: hm[0], minute: hm[1], second: 0, of: day)
    }

    public func utcOffsetString(_ date: Date) -> String {
        let secs = timeZone.secondsFromGMT(for: date)
        let sign = secs >= 0 ? "+" : "-"
        return String(format: "UTC%@%02d:%02d", sign, abs(secs) / 3600, abs(secs) % 3600 / 60)
    }
}
