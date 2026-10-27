import SwiftUI

@main
struct WakeUpApp: App {
    @StateObject private var engine = AlarmEngine.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
                .preferredColorScheme(.dark)
                .task { await engine.refresh() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { engine.requestRefresh() }
                }
        }
    }
}

/// Picks the screen based on what the morning is doing right now.
struct RootView: View {
    @EnvironmentObject var engine: AlarmEngine

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if let s = engine.activeSession {
            switch s.phase(at: now) {
            case .mission:
                MissionView(session: s, early: false)
            case .waitingCheck, .confirm:
                CheckView(session: s, now: now)
            default:
                HomeView()
            }
        } else {
            HomeView()
        }
    }
}
