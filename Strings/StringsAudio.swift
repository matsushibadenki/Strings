import AVFoundation
import Synchronization

/// Single producer (UI), single consumer (audio callback).
private final class NoteQueue: @unchecked Sendable {
    // The two low 7-bit fields hold the MIDI note and velocity percentage.
    private static let pizzicatoFlag = 1 << 14
    private static let midiFlag = 1 << 15
    private let capacity = 256
    private let commands = UnsafeMutablePointer<Int>.allocate(capacity: 256)
    private let read = Atomic<Int>(0)
    private let write = Atomic<Int>(0)
    private let reset = Atomic<Bool>(false)

    deinit { commands.deallocate() }

    func push(_ command: Int) {
        let tail = write.load(ordering: .relaxed)
        let next = (tail + 1) % capacity
        if next == read.load(ordering: .acquiring) {
            reset.store(true, ordering: .releasing)
            return
        }
        commands[tail] = command
        write.store(next, ordering: .releasing)
    }

    func noteOn(_ note: Int, velocity: Int, pizzicato: Bool, midi: Bool = false) {
        push(note + velocity * 128 + (pizzicato ? Self.pizzicatoFlag : 0) + (midi ? Self.midiFlag : 0))
    }

    func drain(into model: StringsModel) {
        var head = read.load(ordering: .relaxed)
        if reset.exchange(false, ordering: .acquiringAndReleasing) {
            read.store(write.load(ordering: .acquiring), ordering: .releasing)
            model.releaseAll()
            return
        }
        let tail = write.load(ordering: .acquiring)
        while head != tail {
            let command = commands[head]
            switch command {
            case -1: model.releaseAll()
            case -131 ... -4: model.setExpression(Float(-command - 4) / 127)
            case -2, -3: model.sustain(command == -3 ? 1 : 0)
            case 0..<128: model.noteOff(command)
            default:
                let velocity = (command / 128) % 128
                let maximum: Float = command & Self.midiFlag == 0 ? 100 : 127
                model.noteOn(command % 128, velocity: Float(velocity) / maximum, pizzicato: command & Self.pizzicatoFlag != 0)
            }
            head = (head + 1) % capacity
        }
        read.store(head, ordering: .releasing)
    }
}

@MainActor
final class StringsAudio: ObservableObject {
    @Published private(set) var unavailable = false
    private let worker = AudioEngineWorker()
    private var queue = NoteQueue()
    private var generation = 0
    private var starting = false
    private var pedalCommand = -2
    private var expressionCommand = -131

    func start() {
        guard !starting else { return }
        starting = true
        let request = generation
        worker.start { [weak self] result in
            guard let self, self.generation == request else { return }
            self.starting = false
            self.unavailable = result == nil
            if let result, self.queue !== result {
                self.queue = result
                result.push(self.pedalCommand)
                result.push(self.expressionCommand)
            }
        }
    }

    func stop() {
        generation += 1
        starting = false
        queue = NoteQueue()
        worker.stop()
    }

    func noteOn(_ note: Int, velocity: Int, pizzicato: Bool) { queue.noteOn(note, velocity: velocity, pizzicato: pizzicato) }
    func midiNoteOn(_ note: Int, velocity: Int, pizzicato: Bool) { queue.noteOn(note, velocity: velocity, pizzicato: pizzicato, midi: true) }
    func noteOff(_ note: Int) { queue.push(note) }
    func sustain(_ down: Bool) {
        pedalCommand = down ? -3 : -2
        queue.push(pedalCommand)
    }

    func midiExpression(_ value: Int) {
        expressionCommand = -4 - min(127, max(0, value))
        queue.push(expressionCommand)
    }

    func releaseAll() {
        pedalCommand = -2
        expressionCommand = -131
        queue.push(-1)
    }
    func setBowArticulation(legato: Bool, spiccato: Bool) {
        worker.bowArticulation.store(spiccato ? 2 : (legato ? 1 : 0), ordering: .relaxed)
    }
    func setBowPosition(_ percent: Int) { worker.bowPosition.store(percent, ordering: .relaxed) }
    func setReverb(_ percent: Int) { worker.setReverb(percent) }
    func setBrightness(_ percent: Int) { worker.setBrightness(percent) }
}

/// Serializes engine and session lifecycle work away from the UI and render threads.
private final class AudioEngineWorker: @unchecked Sendable {
    private let lifecycle = DispatchQueue(label: "com.local.BowedStrings.audio", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var notes: NoteQueue?
    let bowArticulation = Atomic<Int>(0)
    let bowPosition = Atomic<Int>(75)
    private let reverb = Atomic<Int>(30)
    private let body = Atomic<Int>(45)

    func setBrightness(_ percent: Int) {
        body.store(percent, ordering: .relaxed)
    }

    func setReverb(_ percent: Int) {
        reverb.store(percent, ordering: .relaxed)
    }

    func start(completion: @escaping @MainActor @Sendable (NoteQueue?) -> Void) {
        lifecycle.async {
            let result = try? self.startEngine()
            DispatchQueue.main.async { completion(result) }
        }
    }

    func stop() {
        lifecycle.async {
            self.engine?.stop()
            self.engine = nil
            self.notes = nil
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
        }
    }

    private func startEngine() throws -> NoteQueue? {
        if engine?.isRunning == true { return notes }
        engine = nil
        notes = nil
        let newEngine = AVAudioEngine()
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)
        let deviceRate = session.sampleRate
        #else
        let deviceRate = newEngine.outputNode.outputFormat(forBus: 0).sampleRate
        #endif
        guard let format = AVAudioFormat(standardFormatWithSampleRate: min(48_000, max(44_100, deviceRate)), channels: 2) else {
            return nil
        }
        let newQueue = NoteQueue()
        let model = StringsModel(sampleRate: format.sampleRate)
        let source = AVAudioSourceNode(format: format) { [weak self] _, _, count, data in
            let buffers = UnsafeMutableAudioBufferListPointer(data)
            guard buffers.count == 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
                return kAudio_ParamError
            }
            if let self {
                let articulation = self.bowArticulation.load(ordering: .relaxed)
                model.setLegato(articulation == 1)
                model.setSpiccato(articulation == 2)
                model.setBowPosition(Float(self.bowPosition.load(ordering: .relaxed)) / 100)
                model.setReverb(Float(self.reverb.load(ordering: .relaxed)) / 100)
                model.setBrightness(Float(self.body.load(ordering: .relaxed)) / 100)
            }
            newQueue.drain(into: model)
            model.render(left, right, frames: count)
            return noErr
        }
        newEngine.attach(source)
        newEngine.connect(source, to: newEngine.mainMixerNode, format: format)
        try newEngine.start()
        engine = newEngine
        notes = newQueue
        return newQueue
    }
}
