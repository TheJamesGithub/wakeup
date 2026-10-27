import Foundation

/// Something with a barcode you have to walk to (toothpaste, deodorant...).
struct ScanItem: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var code: String
}

/// Alarm time for one weekday.
struct DaySetting: Codable, Hashable {
    var enabled: Bool
    var hour: Int
    var minute: Int
}

struct AppSettings: Codable {
    /// Index = Calendar weekday - 1 (0 = Sunday ... 6 = Saturday).
    var days: [DaySetting]
    var items: [ScanItem]
    var useImportedSounds: Bool
    var checkDelayMinutes: Int
    /// Wake times the user chose to skip (days off).
    var skipped: [Date]

    static let `default` = AppSettings(
        days: Array(repeating: DaySetting(enabled: false, hour: 7, minute: 0), count: 7),
        items: [],
        useImportedSounds: true,
        checkDelayMinutes: 5,
        skipped: []
    )
}

enum AlarmRole: String, Codable {
    case main    // the wake-up alarm
    case chase   // re-rings every minute until the barcode is scanned
    case check   // short "bing bing" a few minutes after scanning
    case blast   // full alarm if the check is ignored
}

struct PlannedAlarm: Codable, Hashable {
    var id: UUID
    var role: AlarmRole
    var fireDate: Date
}

/// One morning's wake-up, from first alarm to "I'M UP".
struct WakeSession: Codable, Identifiable {
    var id: UUID
    /// The wake time from settings. Used to avoid creating the same morning twice.
    var plannedFor: Date
    /// When the routine actually started (moved earlier if you scan early).
    var wakeDate: Date
    var itemName: String
    var itemCode: String
    var mainSound: String
    var chaseSound: String
    var blastSound: String
    var checkSound: String
    var isTest: Bool
    var scannedAt: Date?
    var checkDate: Date?
    var confirmedAt: Date?
    var alarms: [PlannedAlarm]

    enum Phase {
        case upcoming
        case mission      // alarm going, scan the barcode
        case waitingCheck // scanned, wake check pending
        case confirm      // wake check fired, tap I'M UP
        case done
    }

    func phase(at now: Date = Date()) -> Phase {
        if confirmedAt != nil { return .done }
        if scannedAt == nil { return wakeDate > now ? .upcoming : .mission }
        if let check = checkDate, now < check { return .waitingCheck }
        return .confirm
    }
}

extension Date {
    func isSameMinute(as other: Date) -> Bool { abs(timeIntervalSince(other)) < 1 }
}
