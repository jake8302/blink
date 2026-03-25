import AVFoundation
import WhisperKit

class DictationManager {
    enum State: Equatable {
        case idle
        case downloading(progress: Double)
        case recording
        case transcribing
    }

    private(set) var state: State = .idle
    var onTranscription: ((String) -> Void)?
    var onStateChange: ((State) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    var onError: ((String) -> Void)?

    private var whisperKit: WhisperKit?
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?
    private var previousAudioCategory: AVAudioSession.Category?
    private var previousAudioOptions: AVAudioSession.CategoryOptions?
    private var previousAudioMode: AVAudioSession.Mode?
    private var transcriptionTask: Task<Void, Never>?

    // MARK: - Public API

    func toggle() {
        switch state {
        case .idle:
            startRecording()
        case .recording:
            stopRecordingAndTranscribe()
        case .downloading, .transcribing:
            break
        }
    }

    func cancel() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        stopAudioEngine()
        restoreAudioSession()
        cleanupRecordingFile()
        setState(.idle)
    }

    private func cleanupRecordingFile() {
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
        }
        audioFile = nil
    }

    // MARK: - State

    private func setState(_ newState: State) {
        state = newState
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onStateChange?(self.state)
        }
    }

    // MARK: - Recording

    private func startRecording() {
        ensureMicPermission { [weak self] in
            guard let self else { return }
            if self.whisperKit == nil {
                self.downloadModelThenRecord()
            } else {
                self.beginAudioCapture()
            }
        }
    }

    private func ensureMicPermission(then completion: @escaping () -> Void) {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .denied:
            onError?("Microphone access denied. Enable in Settings > Blink > Microphone.")
            return
        case .undetermined:
            session.requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        completion()
                    } else {
                        self?.onError?("Microphone permission required for dictation.")
                    }
                }
            }
        case .granted:
            completion()
        @unknown default:
            completion()
        }
    }

    private func downloadModelThenRecord() {
        setState(.downloading(progress: 0))

        Task { [weak self] in
            do {
                let config = WhisperKitConfig(
                    model: "large-v3-v20240930_turbo_632MB",
                    verbose: true,
                    prewarm: true
                )
                let pipe = try await WhisperKit(config)
                print("[Dictation] Model loaded: \(pipe.modelVariant) from \(pipe.modelFolder?.lastPathComponent ?? "unknown")")
                await MainActor.run {
                    self?.whisperKit = pipe
                    self?.setState(.idle)
                    self?.beginAudioCapture()
                }
            } catch {
                await MainActor.run {
                    print("[Dictation] Download/load failed: \(error)")
                    self?.onError?("Model download failed: \(error.localizedDescription)")
                    self?.setState(.idle)
                }
            }
        }
    }

    private func beginAudioCapture() {
        let session = AVAudioSession.sharedInstance()

        do {
            previousAudioCategory = session.category
            previousAudioOptions = session.categoryOptions
            previousAudioMode = session.mode

            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
        } catch {
            onError?("Audio session setup failed: \(error.localizedDescription)")
            setState(.idle)
            return
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        // Write to temp file — WhisperKit handles resampling from any format
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictation_\(UUID().uuidString).wav")
        recordingURL = url
        do {
            audioFile = try AVAudioFile(forWriting: url, settings: nativeFormat.settings)
        } catch {
            onError?("Failed to create recording file: \(error.localizedDescription)")
            setState(.idle)
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) {
            [weak self] buffer, _ in
            try? self?.audioFile?.write(from: buffer)

            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frames = Int(buffer.frameLength)
            var sumSquares: Float = 0
            for i in 0..<frames { sumSquares += channelData[i] * channelData[i] }
            let rms = sqrtf(sumSquares / Float(max(frames, 1)))
            let level = max(0, min(1, rms * 5))
            DispatchQueue.main.async { self?.onAudioLevel?(level) }
        }

        do {
            try engine.start()
            audioEngine = engine
            setState(.recording)
        } catch {
            onError?("Audio engine start failed: \(error.localizedDescription)")
            restoreAudioSession()
            setState(.idle)
        }
    }

    // MARK: - Transcription

    private func stopRecordingAndTranscribe() {
        stopAudioEngine()
        restoreAudioSession()
        audioFile = nil  // close the file for reading

        guard let url = recordingURL else {
            onTranscription?("")
            setState(.idle)
            return
        }

        setState(.transcribing)

        transcriptionTask = Task { [weak self] in
            guard let self, let pipe = self.whisperKit else { return }
            do {
                print("[Dictation] Starting transcription of \(url.lastPathComponent)")

                // Tokenize technical vocabulary prompt for better accuracy on coding terms
                let promptTokens = pipe.tokenizer?.encode(
                    text: Self.technicalPrompt
                ).filter { $0 < 51865 }  // keep only non-special tokens

                let options = DecodingOptions(
                    language: "en",
                    temperature: 0.0,
                    skipSpecialTokens: true,
                    promptTokens: promptTokens,
                    firstTokenLogProbThreshold: nil  // required when using promptTokens (Issue #372)
                )
                let results: [TranscriptionResult] = try await pipe.transcribe(
                    audioPath: url.path,
                    decodeOptions: options
                )
                print("[Dictation] Transcription complete: \(results.count) result(s)")
                let rawText = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                let text = Self.cleanTranscription(Self.stripHallucinations(rawText))
                print("[Dictation] Text: \(text)")
                await MainActor.run {
                    self.cleanupRecordingFile()
                    self.onTranscription?(text)
                    self.setState(.idle)
                }
            } catch {
                await MainActor.run {
                    print("[Dictation] Transcription failed: \(error)")
                    self.cleanupRecordingFile()
                    self.onError?("Transcription failed: \(error.localizedDescription)")
                    self.setState(.idle)
                }
            }
        }
    }

    // MARK: - Cleanup

    private func stopAudioEngine() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
    }

    private func restoreAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            let category = previousAudioCategory ?? .soloAmbient
            let options = previousAudioOptions ?? []
            let mode = previousAudioMode ?? .default
            try session.setCategory(category, mode: mode, options: options)
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // Best-effort restoration
        }
        previousAudioCategory = nil
        previousAudioOptions = nil
        previousAudioMode = nil
    }

    // MARK: - Transcription Processing

    private static let technicalPrompt = """
        Claude Code, git commit, npm install, TypeScript, Python, async await, \
        function, variable, refactor, API endpoint, database, migration, \
        pull request, merge conflict, terminal, SSH, Mosh, tmux session, \
        fix the bug in, add a new feature to, remove the unused, update the \
        configuration for, can you help me with, please refactor this to use
        """

    private static func stripHallucinations(_ text: String) -> String {
        let hallucinations = [
            "thank you for watching",
            "thanks for watching",
            "thank you for listening",
            "thanks for listening",
            "please subscribe",
            "please like and subscribe",
            "see you next time",
            "see you in the next",
            "goodbye",
            "bye bye",
            "thank you",
        ]

        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = result.lowercased()

        for phrase in hallucinations {
            if lower.hasSuffix(phrase) {
                result = String(result.dropLast(phrase.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))
            }
        }

        return result
    }

    private static func cleanTranscription(_ text: String) -> String {
        var result = text

        result = result.replacingOccurrences(
            of: "\\b(um|uh|hmm|mm|mhm|mmm|ah|oh|er)\\b,?",
            with: "",
            options: .regularExpression
        )

        result = result.replacingOccurrences(
            of: "\\s{2,}",
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)

        return result
    }
}
