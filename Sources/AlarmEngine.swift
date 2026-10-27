import ActivityKit
import AlarmKit
import Foundation
import SwiftUI
import UIKit
import UserNotifications

struct WakeMeta: AlarmMetadata {
    var role: String
}

enum Tuning {
    /// Chase alarms after the main alarm, in seconds: every minute for 15 min,
    /// then every 3 min up to 45 min. Topped up further while you keep ignoring it.
    static let chaseOffsets: [TimeInterval] =
        (1...15).map { Double($0) * 60 } + stride(from: 18, through: 45, by: 3).map { Double($0) * 60 }
    /// Lighter backup chain for mornings further ahead (the app fills them in later).
    static let lightChaseOffsets: [TimeInterval] = [60, 120, 180, 240, 300, 420, 600]
    /// Full-blast alarms after an ignored wake check, in seconds after the check.
    static let blastOffsets: [TimeInterval] =
        (1...10).map { Double($0) * 60 } + stride(from: 12, through: 30, by: 2).map { Double($0) * 60 }
    static let fullChainSessions = 2
    static let horizonDays = 7
    static let earlyScanWindow: TimeInterval = 30 * 60
    static let maxNagSpan: TimeInterval = 2 * 3600
    static let sessionLifetime: TimeInterval = 4 * 3600
}

@MainActor
final class AlarmEngine: ObservableObject {
    static let shared = AlarmEngine()

    @Published private(set) var settings: AppSettings
    @Published private(set) var sessions: [WakeSession]
    @Published var lastError: String?
    @Published private(set) var authorized = false

    private var history: [String]
    private var refreshing = false
    private var refreshAgain = false

    private let defaults = UserDefaults.standard
    private let settingsKey = "settings.v1"
    private let sessionsKey = "sessions.v1"
    private let historyKey = "soundHistory.v1"

    private init() {
        let dec = JSONDecoder()
        if let d = defaults.data(forKey: settingsKey), let s = try? dec.decode(AppSettings.self, from: d) {
            settings = s
        } else {
            settings = .default
        }
        if let d = defaults.data(forKey: sessionsKey), let s = try? dec.decode([WakeSession].self, from: d) {
            sessions = s
        } else {
            sessions = []
        }
        history = defaults.stringArray(forKey: historyKey) ?? []
    }

    private func save() {
        let enc = JSONEncoder()
        if let d = try? enc.encode(settings) { defaults.set(d, forKey: settingsKey) }
        if let d = try? enc.encode(sessions) { defaults.set(d, forKey: sessionsKey) }
        defaults.set(history, forKey: historyKey)
    }

    // MARK: - What's happening now

    /// The morning currently in progress (alarm ringing, or waiting for the wake check).
    var activeSession: WakeSession? {
        let now = Date()
        return sessions
            .filter { s in
                let p = s.phase(at: now)
                return (p == .mission || p == .waitingCheck || p == .confirm)
                    && now.timeIntervalSince(s.wakeDate) < Tuning.sessionLifetime
            }
            .sorted { $0.wakeDate < $1.wakeDate }
            .last
    }

    var upcoming: [WakeSession] {
        let now = Date()
        return sessions.filter { $0.phase(at: now) == .upcoming }.sorted { $0.wakeDate < $1.wakeDate }
    }

    /// Next morning if it's close enough that scanning early should count.
    var earlyScanCandidate: WakeSession? {
        guard let next = upcoming.first else { return nil }
        return next.wakeDate.timeIntervalSinceNow <= Tuning.earlyScanWindow ? next : nil
    }

    // MARK: - Settings changes

    func setDay(_ index: Int, _ day: DaySetting) {
        settings.days[index] = day
        save()
        requestRefresh()
    }

    func addItem(name: String, code: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !settings.items.contains(where: { $0.code == code }) else {
            lastError = "That barcode is already registered."
            return
        }
        settings.items.append(ScanItem(id: UUID(), name: trimmed.isEmpty ? "Item" : trimmed, code: code))
        save()
        requestRefresh()
    }

    func removeItems(at offsets: IndexSet) {
        let removedCodes = offsets.map { settings.items[$0].code }
        settings.items.remove(atOffsets: offsets)
        // Re-pick the item for upcoming mornings that used a removed one.
        for i in sessions.indices where sessions[i].phase() == .upcoming && removedCodes.contains(sessions[i].itemCode) {
            if let item = settings.items.randomElement() {
                sessions[i].itemName = item.name
                sessions[i].itemCode = item.code
                sessions[i].alarms = [] // titles changed, reschedule
            }
        }
        save()
        requestRefresh()
    }

    func setUseImported(_ on: Bool) {
        settings.useImportedSounds = on
        save()
    }

    func setCheckDelay(_ minutes: Int) {
        settings.checkDelayMinutes = max(1, min(30, minutes))
        save()
    }

    func skip(_ session: WakeSession) {
        settings.skipped.append(session.plannedFor)
        save()
        requestRefresh()
    }

    func soundsChanged() {
        // Drop deleted sounds from upcoming mornings.
        let pool = Set(SoundLibrary.pool(includeImported: true))
        for i in sessions.indices where sessions[i].phase() == .upcoming {
            if !pool.contains(sessions[i].mainSound) || !pool.contains(sessions[i].chaseSound)
                || !pool.contains(sessions[i].blastSound) {
                assignSounds(&sessions[i])
                sessions[i].alarms = []
            }
        }
        save()
        requestRefresh()
    }

    // MARK: - Sound rotation

    /// Picks a sound you haven't heard recently, so your brain never gets used to one.
    private func nextSound(excluding: Set<String>) -> String {
        let pool = SoundLibrary.pool(includeImported: settings.useImportedSounds)
        guard !pool.isEmpty else { return "default" }
        let recentCount = max(0, min(pool.count - 3, 12))
        let recent = Set(history.suffix(recentCount))
        var candidates = pool.filter { !recent.contains($0) && !excluding.contains($0) }
        if candidates.isEmpty { candidates = pool.filter { !excluding.contains($0) } }
        if candidates.isEmpty { candidates = pool }
        let pick = candidates.randomElement()!
        history.append(pick)
        if history.count > 60 { history.removeFirst(history.count - 60) }
        return pick
    }

    private func assignSounds(_ s: inout WakeSession) {
        let main = nextSound(excluding: [])
        let chase = nextSound(excluding: [main])
        let blast = nextSound(excluding: [main, chase])
        s.mainSound = main
        s.chaseSound = chase
        s.blastSound = blast
        s.checkSound = SoundLibrary.checkSounds.randomElement() ?? "default"
    }

    private func makeSession(wake: Date, isTest: Bool) -> WakeSession? {
        guard let item = settings.items.randomElement() else { return nil }
        var s = WakeSession(
            id: UUID(), plannedFor: wake, wakeDate: wake,
            itemName: item.name, itemCode: item.code,
            mainSound: "", chaseSound: "", blastSound: "", checkSound: "",
            isTest: isTest, scannedAt: nil, checkDate: nil, confirmedAt: nil, alarms: []
        )
        assignSounds(&s)
        return s
    }

    // MARK: - Planning

    private func desiredWakeDates(now: Date) -> [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        var out: [Date] = []
        for offset in 0...Tuning.horizonDays {
            guard let day = cal.date(byAdding: .day, value: offset, to: today) else { continue }
            let setting = settings.days[cal.component(.weekday, from: day) - 1]
            guard setting.enabled,
                  let d = cal.date(bySettingHour: setting.hour, minute: setting.minute, second: 0, of: day),
                  d > now.addingTimeInterval(20),
                  !settings.skipped.contains(where: { $0.isSameMinute(as: d) }) else { continue }
            out.append(d)
        }
        return out
    }

    private func planChain(_ s: inout WakeSession, full: Bool) {
        if !s.alarms.contains(where: { $0.role == .main }) {
            s.alarms.append(PlannedAlarm(id: UUID(), role: .main, fireDate: s.wakeDate))
        }
        for off in (full ? Tuning.chaseOffsets : Tuning.lightChaseOffsets) {
            let date = s.wakeDate.addingTimeInterval(off)
            if !s.alarms.contains(where: { $0.role == .chase && $0.fireDate.isSameMinute(as: date) }) {
                s.alarms.append(PlannedAlarm(id: UUID(), role: .chase, fireDate: date))
            }
        }
    }

    /// Keeps the alarms coming while you keep ignoring them.
    private func topUp(_ s: inout WakeSession, now: Date) {
        let phase = s.phase(at: now)
        let role: AlarmRole
        let anchor: Date
        switch phase {
        case .mission:
            role = .chase
            anchor = s.wakeDate
        case .waitingCheck, .confirm:
            role = .blast
            anchor = s.checkDate ?? now
        default:
            return
        }
        guard now < anchor.addingTimeInterval(Tuning.maxNagSpan) else { return }
        let future = s.alarms.filter { $0.role == role && $0.fireDate > now }
        guard future.count < 5 else { return }
        var last = max(now, future.map(\.fireDate).max() ?? now)
        for _ in 0..<10 {
            last = last.addingTimeInterval(60)
            if last > anchor.addingTimeInterval(Tuning.maxNagSpan) { break }
            s.alarms.append(PlannedAlarm(id: UUID(), role: role, fireDate: last))
        }
    }

    private func prune(now: Date) {
        sessions.removeAll { s in
            if let c = s.confirmedAt { return now.timeIntervalSince(c) > 24 * 3600 }
            return now.timeIntervalSince(s.wakeDate) > Tuning.sessionLifetime + 3600
        }
        settings.skipped.removeAll { $0 < now.addingTimeInterval(-24 * 3600) }
    }

    // MARK: - Refresh (serialised)

    func requestRefresh() {
        Task { await refresh() }
    }

    func refresh() async {
        if refreshing { refreshAgain = true; return }
        refreshing = true
        repeat {
            refreshAgain = false
            await doRefresh()
        } while refreshAgain
        refreshing = false
    }

    private func doRefresh() async {
        await ensureAuthorization()
        let now = Date()
        prune(now: now)

        // Remove future mornings that are no longer wanted.
        let desired = desiredWakeDates(now: now)
        var toCancel: [UUID] = []
        sessions.removeAll { s in
            guard s.phase(at: now) == .upcoming, !s.isTest else { return false }
            if desired.contains(where: { $0.isSameMinute(as: s.plannedFor) }) { return false }
            toCancel += s.alarms.map(\.id)
            return true
        }

        // Add new mornings.
        for d in desired where !sessions.contains(where: { $0.plannedFor.isSameMinute(as: d) }) {
            if let s = makeSession(wake: d, isTest: false) { sessions.append(s) }
        }
        if !desired.isEmpty && settings.items.isEmpty {
            lastError = "Register a barcode item first, or your alarms can't be set."
        }

        // Plan alarm chains.
        let upcomingIDs = sessions.filter { $0.phase(at: now) == .upcoming }
            .sorted { $0.wakeDate < $1.wakeDate }.map(\.id)
        for i in sessions.indices {
            switch sessions[i].phase(at: now) {
            case .upcoming:
                let rank = upcomingIDs.firstIndex(of: sessions[i].id) ?? 99
                planChain(&sessions[i], full: rank < Tuning.fullChainSessions)
            case .mission, .waitingCheck, .confirm:
                topUp(&sessions[i], now: now)
            case .done:
                break
            }
        }
        save()

        for id in toCancel { await kill(id) }
        await syncWithSystem(now: now)
        await scheduleExpiryWarnings()
    }

    private func ensureAuthorization() async {
        let manager = AlarmManager.shared
        if manager.authorizationState == .notDetermined && UIApplication.shared.applicationState == .active {
            _ = try? await manager.requestAuthorization()
        }
        authorized = manager.authorizationState == .authorized
        if !authorized {
            lastError = "Alarms aren't allowed. Turn them on in Settings > Apps > WakeUp."
        }
    }

    private func kill(_ id: UUID) async {
        try? await AlarmManager.shared.stop(id: id)
        try? await AlarmManager.shared.cancel(id: id)
    }

    /// Makes the system's alarm list match the plan.
    private func syncWithSystem(now: Date) async {
        guard authorized else { return }
        let system: [Alarm] = (try? await AlarmManager.shared.alarms) ?? []
        let systemIDs = Set(system.map(\.id))
        let known = Set(sessions.flatMap { $0.alarms.map(\.id) })

        // Cancel anything we no longer want (but never something ringing right now).
        for alarm in system where !known.contains(alarm.id) && alarm.state != .alerting {
            try? await AlarmManager.shared.cancel(id: alarm.id)
        }

        // Schedule what's missing. Main alarms first, nearest mornings first,
        // so if iOS caps the number of alarms the important ones still exist.
        var pending: [(WakeSession, PlannedAlarm)] = []
        for s in sessions {
            for a in s.alarms where a.fireDate > now.addingTimeInterval(2) && !systemIDs.contains(a.id) {
                pending.append((s, a))
            }
        }
        pending.sort { lhs, rhs in
            let lm = lhs.1.role == .main || lhs.1.role == .check
            let rm = rhs.1.role == .main || rhs.1.role == .check
            if lm != rm { return lm }
            return lhs.1.fireDate < rhs.1.fireDate
        }

        var failures = 0
        for (s, a) in pending {
            // The plan may have changed while we were awaiting (e.g. you just scanned).
            guard sessions.contains(where: { sess in sess.alarms.contains { $0.id == a.id } }) else { continue }
            do {
                try await schedule(a, in: s)
            } catch {
                failures += 1
                if failures >= 3 {
                    lastError = "iOS refused some alarms (\(error.localizedDescription)). The main ones were set first."
                    break
                }
            }
        }
        if failures == 0 && authorized && !(lastError?.hasPrefix("Register") ?? false) {
            lastError = nil
        }
    }

    private func schedule(_ a: PlannedAlarm, in s: WakeSession) async throws {
        let title: String
        let sound: String
        let secondaryText: String
        let secondaryIcon: String
        let secondaryIntent: any LiveActivityIntent

        switch a.role {
        case .main, .chase:
            title = "WAKE UP. Go scan: \(s.itemName)"
            sound = a.role == .main ? s.mainSound : s.chaseSound
            secondaryText = "Scan"
            secondaryIcon = "barcode.viewfinder"
            secondaryIntent = OpenScanIntent(sessionID: s.id.uuidString)
        case .check:
            title = "Still up? Open WakeUp and tap I'M UP"
            sound = s.checkSound
            secondaryText = "I'm up"
            secondaryIcon = "checkmark.circle.fill"
            secondaryIntent = OpenConfirmIntent(sessionID: s.id.uuidString)
        case .blast:
            title = "You fell back asleep. GET UP."
            sound = s.blastSound
            secondaryText = "I'm up"
            secondaryIcon = "checkmark.circle.fill"
            secondaryIntent = OpenConfirmIntent(sessionID: s.id.uuidString)
        }

        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource("\(title)"),
            stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.fill"),
            secondaryButton: AlarmButton(text: LocalizedStringResource("\(secondaryText)"),
                                         textColor: .white, systemImageName: secondaryIcon),
            secondaryButtonBehavior: .custom
        )
        let attributes = AlarmAttributes<WakeMeta>(
            presentation: AlarmPresentation(alert: alert),
            metadata: WakeMeta(role: a.role.rawValue),
            tintColor: .red
        )
        let alertSound: AlertConfiguration.AlertSound = sound == "default" ? .default : .named(sound)
        let config = AlarmManager.AlarmConfiguration<WakeMeta>.alarm(
            schedule: .fixed(a.fireDate),
            attributes: attributes,
            stopIntent: NagStopIntent(sessionID: s.id.uuidString),
            secondaryIntent: secondaryIntent,
            sound: alertSound
        )
        _ = try await AlarmManager.shared.schedule(id: a.id, configuration: config)
    }

    // MARK: - Morning actions

    enum ScanResult { case ok, wrongItem, nothingToScan }

    /// Silences whatever is ringing for this morning (the app plays its own sound instead).
    func silenceRinging(sessionID: UUID) async {
        guard let s = sessions.first(where: { $0.id == sessionID }) else { return }
        let now = Date()
        for a in s.alarms where a.fireDate <= now.addingTimeInterval(1) {
            try? await AlarmManager.shared.stop(id: a.id)
        }
    }

    func silenceRinging(sessionIDString: String) async {
        guard let id = UUID(uuidString: sessionIDString) else { return }
        await silenceRinging(sessionID: id)
    }

    func handleScan(_ code: String, sessionID: UUID) async -> ScanResult {
        guard let i = sessions.firstIndex(where: { $0.id == sessionID }) else { return .nothingToScan }
        guard code == sessions[i].itemCode else { return .wrongItem }
        let now = Date()
        var s = sessions[i]
        let old = s.alarms.filter { $0.role == .main || $0.role == .chase }.map(\.id)
        s.alarms.removeAll { old.contains($0.id) }
        if s.wakeDate > now { s.wakeDate = now } // scanned early
        s.scannedAt = now
        let check = now.addingTimeInterval(Double(settings.checkDelayMinutes) * 60)
        s.checkDate = check
        s.alarms.append(PlannedAlarm(id: UUID(), role: .check, fireDate: check))
        for off in Tuning.blastOffsets {
            s.alarms.append(PlannedAlarm(id: UUID(), role: .blast, fireDate: check.addingTimeInterval(off)))
        }
        sessions[i] = s
        save()
        LoudPlayer.shared.stop()
        for id in old { await kill(id) }
        await refresh()
        return .ok
    }

    func confirmAwake(sessionID: UUID) async {
        guard let i = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let ids = sessions[i].alarms.map(\.id)
        sessions[i].confirmedAt = Date()
        sessions[i].alarms = []
        save()
        LoudPlayer.shared.stop()
        for id in ids { await kill(id) }
        await refresh()
    }

    /// For when you genuinely can't get to the item (e.g. not at home).
    func emergencyOff(sessionID: UUID) async {
        guard let i = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let now = Date()
        if sessions[i].scannedAt == nil { sessions[i].scannedAt = now }
        if sessions[i].checkDate == nil { sessions[i].checkDate = now }
        await confirmAwake(sessionID: sessionID)
    }

    func startTest() async {
        guard let s = makeSession(wake: Date().addingTimeInterval(60), isTest: true) else {
            lastError = "Register a barcode item first."
            return
        }
        var t = s
        planChain(&t, full: true)
        sessions.append(t)
        save()
        await refresh()
    }

    func cancelTest() async {
        let tests = sessions.filter { $0.isTest && $0.confirmedAt == nil }
        for s in tests { await confirmAwake(sessionID: s.id) }
    }

    // MARK: - Signing expiry warnings

    private var expiryScheduledFor: Date?

    private func scheduleExpiryWarnings() async {
        guard let exp = ProvisionInfo.expiryDate, expiryScheduledFor != exp else { return }
        expiryScheduledFor = exp
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        var granted = status == .authorized || status == .provisional
        if status == .notDetermined && UIApplication.shared.applicationState == .active {
            granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        }
        guard granted else { expiryScheduledFor = nil; return }
        center.removePendingNotificationRequests(withIdentifiers: ["expiry-1", "expiry-2", "expiry-3"])
        let warnings: [(String, TimeInterval, String)] = [
            ("expiry-1", 48 * 3600, "WakeUp expires in 2 days. Re-sideload it with Sideloadly soon."),
            ("expiry-2", 24 * 3600, "WakeUp expires tomorrow. Re-sideload it today or your alarms may stop."),
            ("expiry-3", 3 * 3600, "WakeUp expires in 3 hours. Re-sideload it NOW."),
        ]
        for (id, before, body) in warnings {
            let interval = exp.addingTimeInterval(-before).timeIntervalSinceNow
            guard interval > 5 else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Re-sideload WakeUp"
            content.body = body
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
    }
}
