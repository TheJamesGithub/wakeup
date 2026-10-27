import SwiftUI

struct HomeView: View {
    @EnvironmentObject var engine: AlarmEngine

    @State private var showAddItem = false
    @State private var showEarlyScan = false
    @State private var showVolumeTip = false

    /// Monday-first, as Calendar weekday indexes (0 = Sunday).
    private let weekOrder = [1, 2, 3, 4, 5, 6, 0]
    private let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    var body: some View {
        NavigationStack {
            List {
                statusSection
                if let early = engine.earlyScanCandidate {
                    Section {
                        Button {
                            showEarlyScan = true
                        } label: {
                            Label("Up early? Scan \(early.itemName) now to skip the alarm",
                                  systemImage: "barcode.viewfinder")
                        }
                    }
                    .sheet(isPresented: $showEarlyScan) {
                        MissionView(session: early, early: true)
                            .environmentObject(engine)
                    }
                }
                timesSection
                itemsSection
                upcomingSection
                Section("Sounds") {
                    NavigationLink {
                        SoundsView()
                    } label: {
                        Label("Alarm sounds", systemImage: "speaker.wave.3.fill")
                    }
                    Stepper(value: Binding(
                        get: { engine.settings.checkDelayMinutes },
                        set: { engine.setCheckDelay($0) }
                    ), in: 1...30) {
                        Text("Wake check \(engine.settings.checkDelayMinutes) min after scanning")
                    }
                }
                testSection
                tipsSection
            }
            .navigationTitle("WakeUp")
            .sheet(isPresented: $showAddItem) {
                ItemEditorView()
                    .environmentObject(engine)
            }
        }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section {
            if let err = engine.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if let next = engine.upcoming.first {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Next alarm").font(.caption).foregroundStyle(.secondary)
                    Text(next.wakeDate.formatted(.dateTime.weekday(.wide).hour().minute()))
                        .font(.title2.bold())
                    Text("Scan: \(next.itemName)").foregroundStyle(.secondary)
                }
            } else {
                Text("No alarms set. Turn on a day below.")
                    .foregroundStyle(.secondary)
            }
            if let exp = ProvisionInfo.expiryDate {
                let days = exp.timeIntervalSinceNow / 86400
                Label {
                    Text("App expires \(exp.formatted(.dateTime.weekday(.abbreviated).day().month().hour().minute())). Re-sideload before then.")
                } icon: {
                    Image(systemName: "clock.badge.exclamationmark")
                }
                .foregroundStyle(days < 2 ? Color.red : Color.secondary)
                .font(days < 2 ? Font.body.bold() : Font.footnote)
            }
        }
    }

    private var timesSection: some View {
        Section("Alarm times") {
            ForEach(weekOrder, id: \.self) { idx in
                let day = engine.settings.days[idx]
                HStack {
                    Toggle(isOn: Binding(
                        get: { day.enabled },
                        set: { on in
                            var d = day
                            d.enabled = on
                            engine.setDay(idx, d)
                        }
                    )) {
                        Text(dayNames[idx])
                    }
                    DatePicker("", selection: Binding(
                        get: { date(hour: day.hour, minute: day.minute) },
                        set: { newDate in
                            let c = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                            var d = day
                            d.hour = c.hour ?? 7
                            d.minute = c.minute ?? 0
                            engine.setDay(idx, d)
                        }
                    ), displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .opacity(day.enabled ? 1 : 0.4)
                }
            }
        }
    }

    private var itemsSection: some View {
        Section {
            if engine.settings.items.isEmpty {
                Text("Add at least one thing with a barcode that lives far from your bed (toothpaste, deodorant, a cereal box).")
                    .foregroundStyle(.secondary)
            }
            ForEach(engine.settings.items) { item in
                VStack(alignment: .leading) {
                    Text(item.name).font(.headline)
                    Text(item.code).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            .onDelete { engine.removeItems(at: $0) }
            Button {
                showAddItem = true
            } label: {
                Label("Add barcode item", systemImage: "plus.viewfinder")
            }
        } header: {
            Text("Barcode items")
        } footer: {
            Text("Each morning one of these is picked at random. Register 2 or 3 so you can't just keep one next to your bed.")
        }
    }

    private var upcomingSection: some View {
        Section("Upcoming") {
            if engine.upcoming.isEmpty {
                Text("Nothing scheduled.").foregroundStyle(.secondary)
            }
            ForEach(engine.upcoming) { s in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.wakeDate.formatted(.dateTime.weekday(.abbreviated).day().month().hour().minute()))
                            .font(.headline)
                        Text("\(s.itemName) · \(SoundLibrary.displayName(s.mainSound))\(s.isTest ? " · TEST" : "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !s.isTest {
                        Button("Skip") { engine.skip(s) }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private var testSection: some View {
        Section {
            Button {
                Task { await engine.startTest() }
            } label: {
                Label("Test the full routine (alarm in 1 min)", systemImage: "alarm.waves.left.and.right")
            }
            if engine.upcoming.contains(where: { $0.isTest }) {
                Button("Cancel test", role: .destructive) {
                    Task { await engine.cancelTest() }
                }
            }
        } footer: {
            Text("Lock your phone after tapping. It runs exactly like a real morning: alarm, scan, wake check.")
        }
    }

    private var tipsSection: some View {
        Section("Make sure it can wake you") {
            Label("Turn your alarm/ringer volume all the way up: Settings > Sounds & Haptics. The app can't change it while your phone is locked.",
                  systemImage: "speaker.wave.3")
            Label("Stopping an alarm on the lock screen only buys you a minute. Scanning is the only way to end it.",
                  systemImage: "hand.raised")
            Label("Keep your phone charged overnight. A dead phone can't ring.",
                  systemImage: "battery.100.bolt")
        }
        .font(.footnote)
    }

    private func date(hour: Int, minute: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }
}

/// Register a new item by scanning it.
struct ItemEditorView: View {
    @EnvironmentObject var engine: AlarmEngine
    @Environment(\.dismiss) private var dismiss

    @State private var code: String?
    @State private var name = ""
    @State private var torch = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let code {
                    Form {
                        Section("Barcode") {
                            Text(code).font(.body.monospaced())
                        }
                        Section("What is it?") {
                            TextField("e.g. Toothpaste", text: $name)
                        }
                        Section {
                            Button("Save") {
                                engine.addItem(name: name, code: code)
                                dismiss()
                            }
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                            Button("Scan again") { self.code = nil }
                        }
                    }
                } else {
                    Text("Point the camera at the barcode")
                        .font(.headline)
                        .padding(.top)
                    BarcodeScannerView(torchOn: torch) { scanned in
                        code = scanned
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .padding(.horizontal)
                    Button(torch ? "Torch off" : "Torch on") { torch.toggle() }
                        .buttonStyle(.bordered)
                        .padding(.bottom)
                }
            }
            .navigationTitle("Add item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
