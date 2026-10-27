import SwiftUI
import UniformTypeIdentifiers

struct SoundsView: View {
    @EnvironmentObject var engine: AlarmEngine

    @State private var showImporter = false
    @State private var playing: String?
    @State private var message: String?
    @State private var imported: [String] = SoundLibrary.importedAlarms

    var body: some View {
        List {
            Section {
                Button {
                    showImporter = true
                } label: {
                    Label("Add your own sounds", systemImage: "plus.circle.fill")
                }
                Toggle("Use my sounds in the rotation", isOn: Binding(
                    get: { engine.settings.useImportedSounds },
                    set: { engine.setUseImported($0) }
                ))
                if let message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Any audio file works (mp3, m4a, wav...). It gets trimmed to 29 seconds and boosted to max loudness. A different sound plays every morning so your brain can't get used to one.")
            }

            Section("My sounds") {
                if imported.isEmpty {
                    Text("None yet.").foregroundStyle(.secondary)
                }
                ForEach(imported, id: \.self) { name in
                    row(name)
                }
                .onDelete { offsets in
                    for i in offsets { SoundLibrary.deleteImported(imported[i]) }
                    imported = SoundLibrary.importedAlarms
                    engine.soundsChanged()
                }
            }

            Section("Built in") {
                ForEach(SoundLibrary.bundledAlarms, id: \.self) { name in
                    row(name)
                }
            }

            Section("Wake check (bing bing)") {
                ForEach(SoundLibrary.checkSounds, id: \.self) { name in
                    row(name)
                }
            }
        }
        .navigationTitle("Sounds")
        .onDisappear {
            LoudPlayer.shared.stop()
            playing = nil
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                var ok = 0
                var failed: [String] = []
                for url in urls {
                    do {
                        try SoundLibrary.importSound(from: url)
                        ok += 1
                    } catch {
                        failed.append(url.lastPathComponent)
                    }
                }
                imported = SoundLibrary.importedAlarms
                engine.soundsChanged()
                message = "Added \(ok) sound\(ok == 1 ? "" : "s")."
                    + (failed.isEmpty ? "" : " Couldn't read: \(failed.joined(separator: ", ")).")
            case .failure(let error):
                message = error.localizedDescription
            }
        }
    }

    private func row(_ name: String) -> some View {
        Button {
            if playing == name {
                LoudPlayer.shared.stop()
                playing = nil
            } else {
                LoudPlayer.shared.play(name, loop: false)
                playing = name
            }
        } label: {
            HStack {
                Image(systemName: playing == name ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title2)
                Text(SoundLibrary.displayName(name))
                    .foregroundStyle(.primary)
            }
        }
    }
}
