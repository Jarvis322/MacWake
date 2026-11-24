import Foundation

/// Screen-on time on battery, split by calendar day.
///
/// Kept apart from session history, which holds only the last few sessions and stores one
/// total per session — neither can answer "how much today / this week / this month" once a
/// session crosses midnight or the period spans more sessions than history keeps.
struct ScreenTimeLedger: Codable, Equatable {
    struct Day: Codable, Equatable {
        /// Start of the calendar day, in the calendar the time was recorded with.
        var start: Date
        var seconds: TimeInterval
    }

    /// Sorted by `start`, at most one entry per day.
    private(set) var days: [Day] = []

    /// Long enough for a full calendar month plus a year of look-back.
    static let retentionDays = 400

    /// Credits `start..<end`, splitting it at every midnight it crosses.
    mutating func add(from start: Date, to end: Date, calendar: Calendar = .current) {
        var cursor = start
        while cursor < end {
            let dayStart = calendar.startOfDay(for: cursor)
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return }
            let chunkEnd = min(end, nextDay)
            credit(chunkEnd.timeIntervalSince(cursor), toDayStarting: dayStart)
            cursor = chunkEnd
        }
    }

    /// Spreads `seconds` over `intervals` in proportion to their lengths. Used to backfill from
    /// sessions recorded before the ledger existed: their total is exact, but only the event
    /// timeline says when it happened, and that timeline also covers time the app wasn't running.
    mutating func add(seconds: TimeInterval, spreadOver intervals: [DateInterval], calendar: Calendar = .current) {
        let span = intervals.reduce(0) { $0 + $1.duration }
        guard seconds > 0, span > 0 else { return }
        let scale = seconds / span
        for interval in intervals {
            var scaled = ScreenTimeLedger()
            scaled.add(from: interval.start, to: interval.end, calendar: calendar)
            for day in scaled.days {
                credit(day.seconds * scale, toDayStarting: day.start)
            }
        }
    }

    /// Total for the days that start at or after `periodStart`.
    func total(since periodStart: Date) -> TimeInterval {
        days.reduce(0) { $1.start >= periodStart ? $0 + $1.seconds : $0 }
    }

    mutating func prune(before cutoff: Date) {
        days.removeAll { $0.start < cutoff }
    }

    private mutating func credit(_ seconds: TimeInterval, toDayStarting dayStart: Date) {
        guard seconds > 0 else { return }
        if let index = days.lastIndex(where: { $0.start == dayStart }) {
            days[index].seconds += seconds
        } else {
            let insertAt = days.firstIndex(where: { $0.start > dayStart }) ?? days.endIndex
            days.insert(Day(start: dayStart, seconds: seconds), at: insertAt)
        }
    }
}

/// Screen-on goals for the current day, week and month.
enum ScreenTimeGoal: String, CaseIterable, Identifiable {
    case daily, weekly, monthly

    var id: String { rawValue }

    var defaultsKey: String { "screenGoal\(rawValue.capitalized)Hours" }

    var defaultHours: Int {
        switch self {
        case .daily: return 4
        case .weekly: return 25
        case .monthly: return 100
        }
    }

    var hourRange: ClosedRange<Int> {
        switch self {
        case .daily: return 1...24
        case .weekly: return 1...168
        case .monthly: return 5...740
        }
    }

    var hourStep: Int { self == .monthly ? 5 : 1 }

    func clampedHours(_ hours: Int) -> Int {
        min(hourRange.upperBound, max(hourRange.lowerBound, hours))
    }

    /// Localization key of the period shown next to the progress.
    var periodTitle: String { "GOAL_PERIOD_\(rawValue.uppercased())" }

    /// Localization key of the goal's setting.
    var settingTitle: String { "GOAL_SETTING_\(rawValue.uppercased())" }

    var icon: String {
        switch self {
        case .daily: return "sun.max.fill"
        case .weekly: return "calendar"
        case .monthly: return "calendar.badge.clock"
        }
    }

    func periodStart(containing date: Date, calendar: Calendar = .current) -> Date {
        let component: Calendar.Component
        switch self {
        case .daily: return calendar.startOfDay(for: date)
        case .weekly: component = .weekOfYear
        case .monthly: component = .month
        }
        return calendar.dateInterval(of: component, for: date)?.start ?? calendar.startOfDay(for: date)
    }
}
