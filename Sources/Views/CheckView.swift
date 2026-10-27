import SwiftUI

/// After scanning: wait for the wake check, then tap I'M UP.
struct CheckView: View {
    @EnvironmentObject var engine: AlarmEngine
    let session: WakeSession
    let now: Date

    @State private var busy = false

    var body: some View {
        let phase = session.phase(at: now)
        ZStack {
            (phase == .confirm ? Color.green : Color.black).ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()
                if phase == .waitingCheck, let check = session.checkDate {
                    Text("Nice. Now stay up.")
                        .font(.system(size: 36, weight: .black))
                    Text("Wake check in")
                        .font(.title2.weight(.semibold))
                    Text(timeLeft(until: check))
                        .font(.system(size: 72, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                    Text("When it goes off, open WakeUp and tap I'M UP. Ignore it and the full alarm comes back.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 32)
                } else {
                    Text("You still up?")
                        .font(.system(size: 40, weight: .black))
                        .foregroundStyle(.black)
                    Button {
                        guard !busy else { return }
                        busy = true
                        Task {
                            await engine.confirmAwake(sessionID: session.id)
                            busy = false
                        }
                    } label: {
                        Text("I'M UP")
                            .font(.system(size: 48, weight: .black))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                            .background(.white, in: RoundedRectangle(cornerRadius: 28))
                            .foregroundStyle(.green)
                    }
                    .padding(.horizontal, 24)
                }
                Spacer()
            }
            .foregroundStyle(.white)
        }
        .onAppear {
            LoudPlayer.shared.stop()
            Task { await engine.silenceRinging(sessionID: session.id) }
        }
    }

    private func timeLeft(until date: Date) -> String {
        let s = max(0, Int(date.timeIntervalSince(now).rounded(.up)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
