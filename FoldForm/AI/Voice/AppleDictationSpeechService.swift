import AVFoundation
import Foundation
import Speech

/// Apple's on-device dictation recognizer, segmented at a pause so every finished sentence can be
/// interpreted while the microphone remains on. Audio is held only in memory and the request is
/// explicitly configured to refuse server recognition.
@MainActor
final class AppleDictationSpeechService: SpeechService {
    nonisolated let events: AsyncStream<SpeechEvent>
    private nonisolated let continuation: AsyncStream<SpeechEvent>.Continuation

    private var recognizer: SFSpeechRecognizer?
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var pauseTask: Task<Void, Never>?
    private var router = AppleSpeechResultRouter()
    private var generation = 0
    private var segment = 0
    private var tapInstalled = false
    private var running = false
    private var stopping = false

    init() {
        (events, continuation) = AsyncStream.makeStream(of: SpeechEvent.self, bufferingPolicy: .unbounded)
    }

    func start() async {
        guard !running else { return }
        generation += 1
        let current = generation
        let permission = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard current == generation else { return }
        guard permission == .authorized else {
            continuation.yield(.state(.unavailable("Speech recognition access is off. Turn it on in Settings.")))
            return
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            continuation.yield(.state(.unavailable("Microphone access is off. Turn it on in Settings.")))
            return
        }
        guard current == generation else { return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en_US")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            continuation.yield(.state(.unavailable("On-device Apple Dictation isn't available for English on this device.")))
            return
        }
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try audioSession.setActive(true)
            self.recognizer = recognizer
            engine = AVAudioEngine()
            running = true
            stopping = false
            try beginSegment()
            continuation.yield(.state(.listening))
        } catch {
            finishSession()
            continuation.yield(.state(.unavailable("Apple Dictation couldn't start: \(error.localizedDescription)")))
        }
    }

    /// Ends the current phrase and waits for Apple's final transcription before reporting idle.
    func stop() async {
        guard running else { return }
        stopping = true
        continuation.yield(.state(.finalizing))
        finishSegment(segment)
        for _ in 0..<200 where stopping {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if stopping {
            finishSession()
            continuation.yield(.state(.idle))
        }
    }

    /// Drops pending partial speech. Only a result marked final by Apple may become a command.
    func cancel() async {
        generation += 1
        finishSession()
        continuation.yield(.state(.idle))
    }

    private func beginSegment() throws {
        guard running, let recognizer, let engine else { return }
        segment += 1
        let currentSegment = segment
        let currentGeneration = generation
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        request.contextualStrings = [
            "FoldForm", "cube", "cuboid", "cylinder", "extrude", "fillet", "chamfer",
            "millimeters", "centimeters", "sketch", "Imagine",
        ]
        self.request = request
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failure = error?.localizedDescription
            Task { @MainActor [weak self] in
                self?.receive(text: text, isFinal: isFinal, error: failure,
                              segment: currentSegment, generation: currentGeneration)
            }
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
    }

    private func receive(text: String?, isFinal: Bool, error: String?, segment received: Int, generation receivedGeneration: Int) {
        guard receivedGeneration == generation, received == segment, running else { return }
        if let text, let event = router.accept(text, isFinal: isFinal, segment: received) {
            continuation.yield(event)
            if isFinal {
                pauseTask?.cancel()
                if stopping {
                    finishSession()
                    continuation.yield(.state(.idle))
                } else {
                    stopCapture()
                    recognitionTask?.cancel()
                    recognitionTask = nil
                    request = nil
                    do { try beginSegment() }
                    catch {
                        finishSession()
                        continuation.yield(.state(.unavailable("Apple Dictation couldn't continue: \(error.localizedDescription)")))
                    }
                }
            } else if !stopping {
                schedulePhraseEnd(for: received)
            }
            return
        }
        if let error {
            if stopping {
                finishSession()
                continuation.yield(.state(.idle))
            } else {
                finishSession()
                continuation.yield(.state(.unavailable("Apple Dictation stopped: \(error)")))
            }
        }
    }

    private func schedulePhraseEnd(for currentSegment: Int) {
        pauseTask?.cancel()
        pauseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.finishSegment(currentSegment)
        }
    }

    private func finishSegment(_ expected: Int) {
        guard running, expected == segment, router.beginFinishing(segment: expected) else { return }
        pauseTask?.cancel()
        stopCapture()
        request?.endAudio()
        recognitionTask?.finish()
    }

    private func stopCapture() {
        guard let engine else { return }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }
    }

    private func finishSession() {
        running = false
        stopping = false
        pauseTask?.cancel()
        pauseTask = nil
        stopCapture()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        recognizer = nil
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}
