import AlarmKit
import AppIntents
import Foundation

/// Runs when you hit Stop on the lock screen. Stopping doesn't end anything:
/// it just makes sure the next alarm is lined up.
struct NagStopIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop alarm"

    @Parameter(title: "Session")
    var sessionID: String

    init() {
        self.sessionID = ""
    }

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        await AlarmEngine.shared.refresh()
        return .result()
    }
}

/// "Scan" button on the alarm: opens the app straight to the scanner.
struct OpenScanIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Scan to stop"
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Session")
    var sessionID: String

    init() {
        self.sessionID = ""
    }

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        await AlarmEngine.shared.silenceRinging(sessionIDString: sessionID)
        return .result()
    }
}

/// "I'm up" button on the wake check: opens the app to the I'M UP screen.
/// It doesn't confirm by itself, you still have to tap the button in the app.
struct OpenConfirmIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "I'm up"
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Session")
    var sessionID: String

    init() {
        self.sessionID = ""
    }

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        await AlarmEngine.shared.silenceRinging(sessionIDString: sessionID)
        return .result()
    }
}
