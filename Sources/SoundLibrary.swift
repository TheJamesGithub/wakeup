import AVFoundation
import Foundation

/// Bundled sounds live in the app bundle. Imported sounds are converted to
/// .caf and saved in Library/Sounds, which is where AlarmKit looks for them.
enum SoundLibrary {
    static let maxSeconds: Double = 29

    static var soundsDir: URL {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let dir = lib.appendingPathComponent("Sounds", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static func bundled(prefix: String) -> [String] {
        let urls = Bundle.main.urls(forResourcesWithExtension: "caf", subdirectory: nil) ?? []
        return urls.map { $0.lastPathComponent }.filter { $0.hasPrefix(prefix) }.sorted()
    }

    static var bundledAlarms: [String] { bundled(prefix: "alarm_") }
    static var checkSounds: [String] { bundled(prefix: "check_") }

    static var importedAlarms: [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: soundsDir.path)) ?? []
        return files.filter { $0.hasSuffix(".caf") }.sorted()
    }

    static func pool(includeImported: Bool) -> [String] {
        includeImported ? bundledAlarms + importedAlarms : bundledAlarms
    }

    static func url(for name: String) -> URL? {
        if let u = Bundle.main.url(forResource: name, withExtension: nil) { return u }
        let u = soundsDir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    static func isImported(_ name: String) -> Bool { importedAlarms.contains(name) }

    static func displayName(_ name: String) -> String {
        var s = name
        if s.hasSuffix(".caf") { s = String(s.dropLast(4)) }
        for p in ["alarm_", "check_", "my_"] where s.hasPrefix(p) { s = String(s.dropFirst(p.count)) }
        return s.replacingOccurrences(of: "_", with: " ").capitalized
    }

    enum ImportError: LocalizedError {
        case unreadable
        case empty
        var errorDescription: String? {
            switch self {
            case .unreadable: return "Couldn't read that audio file."
            case .empty: return "That file has no sound in it."
            }
        }
    }

    /// Converts any audio file iOS can read into a loud mono .caf under 30 s.
    @discardableResult
    static func importSound(from url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let input = try AVAudioFile(forReading: url)
        let format = input.processingFormat
        let maxFrames = AVAudioFrameCount(min(Double(input.length), format.sampleRate * maxSeconds))
        guard maxFrames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maxFrames) else {
            throw ImportError.empty
        }
        try input.read(into: buffer, frameCount: maxFrames)
        guard let channels = buffer.floatChannelData else { throw ImportError.unreadable }

        let n = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: n)
        for c in 0..<channelCount {
            let p = channels[c]
            for i in 0..<n { mono[i] += p[i] / Float(channelCount) }
        }

        // Make it as loud as possible: normalise, then soft-limit.
        var peak: Float = 0
        for v in mono { peak = max(peak, abs(v)) }
        guard peak > 0.0001 else { throw ImportError.empty }
        let drive: Float = 2.5
        let norm = tanh(drive)
        for i in 0..<n { mono[i] = 0.97 * tanh(drive * mono[i] / peak) / norm }
        let fade = min(n / 2, Int(format.sampleRate * 0.005))
        if fade > 0 {
            for i in 0..<fade {
                let g = Float(i) / Float(fade)
                mono[i] *= g
                mono[n - 1 - i] *= g
            }
        }

        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                            channels: 1, interleaved: false),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(n)),
              let out = outBuffer.floatChannelData else {
            throw ImportError.unreadable
        }
        outBuffer.frameLength = AVAudioFrameCount(n)
        for i in 0..<n { out[0][i] = mono[i] }

        let base = url.deletingPathExtension().lastPathComponent
        let safe = base.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
        let name = "my_" + String(safe.prefix(40)) + ".caf"
        let dest = soundsDir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        do {
            let file = try AVAudioFile(forWriting: dest, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: outBuffer)
        }
        return name
    }

    static func deleteImported(_ name: String) {
        try? FileManager.default.removeItem(at: soundsDir.appendingPathComponent(name))
    }
}

/// Plays alarm audio inside the app at full app volume, looping, and keeps
/// restarting it if something (like a system alarm) interrupts it.
final class LoudPlayer {
    static let shared = LoudPlayer()

    private var player: AVAudioPlayer?
    private var currentName: String?
    private var wantsLoop = false
    private var watchdog: Timer?
    private var startedAt = Date()

    private init() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.resumeIfNeeded()
        }
    }

    var isPlaying: Bool { player?.isPlaying ?? false }

    func play(_ name: String, loop: Bool = true) {
        guard let url = SoundLibrary.url(for: name) else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            let p = try AVAudioPlayer(contentsOf: url)
            p.numberOfLoops = loop ? -1 : 0
            p.volume = 1.0
            p.prepareToPlay()
            p.play()
            player = p
            currentName = name
            wantsLoop = loop
            startedAt = Date()
            watchdog?.invalidate()
            if loop {
                watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    self?.resumeIfNeeded()
                }
            }
        } catch {
            print("LoudPlayer error: \(error)")
        }
    }

    private func resumeIfNeeded() {
        guard wantsLoop, let p = player else { return }
        // Safety net: never blast for more than an hour.
        if Date().timeIntervalSince(startedAt) > 3600 { stop(); return }
        if !p.isPlaying {
            try? AVAudioSession.sharedInstance().setActive(true)
            p.play()
        }
    }

    func stop() {
        wantsLoop = false
        watchdog?.invalidate()
        watchdog = nil
        player?.stop()
        player = nil
        currentName = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
