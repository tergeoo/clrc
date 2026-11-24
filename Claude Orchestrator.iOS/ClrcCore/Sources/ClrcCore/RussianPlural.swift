import Foundation

/// "<n> <form>" with the Russian plural form for `n`: one (1, 21, 31…),
/// few (2–4, 22–24…) or many (0, 5–20, 25…).
public func ru(_ n: Int, one: String, few: String, many: String) -> String {
    "\(n) \(ruForm(n, one: one, few: few, many: many))"
}

/// The Russian plural form for `n`, without the number.
public func ruForm(_ n: Int, one: String, few: String, many: String) -> String {
    let mod100 = abs(n) % 100
    let mod10 = abs(n) % 10
    if (11...14).contains(mod100) { return many }
    switch mod10 {
    case 1: return one
    case 2...4: return few
    default: return many
    }
}

private let secondsPerMinute: TimeInterval = 60
private let secondsPerHour: TimeInterval = 3_600
private let secondsPerDay: TimeInterval = 86_400

/// Short "time ago" text for inbox cards: «сейчас», «N мин», «N ч», «N д».
/// Dates in the future read as «сейчас».
public func agoText(from date: Date, now: Date) -> String {
    let elapsed = now.timeIntervalSince(date)
    if elapsed < secondsPerMinute { return "сейчас" }
    if elapsed < secondsPerHour { return "\(Int(elapsed / secondsPerMinute)) мин" }
    if elapsed < secondsPerDay { return "\(Int(elapsed / secondsPerHour)) ч" }
    return "\(Int(elapsed / secondsPerDay)) д"
}
