import SwiftUI

/// The "get out of bed and scan it" screen.
struct MissionView: View {
    @EnvironmentObject var engine: AlarmEngine
    @Environment(\.dismiss) private var dismiss

    let session: WakeSession
    /// Scanning before the alarm (woke up early). No sound in this mode.
    let early: Bool

    @State private var torch = false
    @State private var wrongFlash = false
    @State private var showEmergency = false
    @State private var busy = false

    var body: some View {
        ZStack {
            (early ? Color.black : Color.red).ignoresSafeArea()

            VStack(spacing: 16) {
                Text(early ? "UP EARLY?" : "WAKE UP")
                    .font(.system(size: 44, weight: .black))
                    .foregroundStyle(.white)
                    .padding(.top, 24)

                VStack(spacing: 4) {
                    Text("Go scan the barcode on")
                        .font(.title3.weight(.semibold))
                    Text(session.itemName.uppercased())
                        .font(.system(size: 34, weight: .heavy))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white)

                BarcodeScannerView(torchOn: torch) { code in
                    handle(code)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(wrongFlash ? Color.yellow : Color.white, lineWidth: wrongFlash ? 6 : 2)
                )
                .padding(.horizontal, 16)

                if wrongFlash {
                    Text("Wrong item. Scan the \(session.itemName).")
                        .font(.headline)
                        .foregroundStyle(.yellow)
                }

                Button {
                    torch.toggle()
                } label: {
                    Label(torch ? "Torch off" : "Torch on", systemImage: torch ? "flashlight.on.fill" : "flashlight.off.fill")
                        .font(.headline)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(.white.opacity(0.2), in: Capsule())
                        .foregroundStyle(.white)
                }

                Spacer()

                Button("Can't scan? Emergency off") { showEmergency = true }
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.bottom, 12)
            }

            if !early {
                VolumeMaxer().frame(width: 1, height: 1).allowsHitTesting(false)
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            if !early {
                Task { await engine.silenceRinging(sessionID: session.id) }
                LoudPlayer.shared.play(session.mainSound)
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            torch = false
            if !early { LoudPlayer.shared.stop() }
        }
        .sheet(isPresented: $showEmergency) {
            EmergencyView(session: session) {
                showEmergency = false
                if early { dismiss() }
            }
        }
    }

    private func handle(_ code: String) {
        guard !busy else { return }
        busy = true
        Task {
            let result = await engine.handleScan(code, sessionID: session.id)
            busy = false
            switch result {
            case .ok:
                if early { dismiss() }
            case .wrongItem:
                wrongFlash = true
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                wrongFlash = false
            case .nothingToScan:
                if early { dismiss() }
            }
        }
    }
}

/// Typing a long sentence correctly is its own wake-up test.
struct EmergencyView: View {
    @EnvironmentObject var engine: AlarmEngine
    let session: WakeSession
    let onDone: () -> Void

    @State private var typed = ""
    private let phrase = "I am out of bed and I will not go back to sleep"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Only for when you can't get to your item (e.g. you're not home). Type this exactly:")
                    Text(phrase).font(.headline)
                    TextField("Type it here", text: $typed, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    Button("Turn off this morning's alarms", role: .destructive) {
                        Task {
                            await engine.emergencyOff(sessionID: session.id)
                            onDone()
                        }
                    }
                    .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != phrase.lowercased())
                }
            }
            .navigationTitle("Emergency off")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDone() }
                }
            }
        }
    }
}
