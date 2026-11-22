import AVFoundation
import AudioToolbox
import CoreMIDI
import Synchronization

@objc(StringsAUFactory)
final class StringsAUFactory: NSObject, AUAudioUnitFactory {
    func beginRequest(with context: NSExtensionContext) {}

    func createAudioUnit(with description: AudioComponentDescription) throws -> AUAudioUnit {
        try StringsAudioUnit(componentDescription: description, options: [])
    }
}

final class StringsAudioUnit: AUAudioUnit {
    private let output: AUAudioUnitBus
    private var outputs: AUAudioUnitBusArray!
    private var inputs: AUAudioUnitBusArray!
    private var renderer: InstrumentRender?
    private let reverbPercent = Atomic<Float>(30)
    private let brightnessPercent = Atomic<Float>(45)
    private let bowPositionPercent = Atomic<Float>(75)
    private let legato = Atomic<Bool>(false)
    private let spiccato = Atomic<Bool>(false)
    private let performance = PerformanceSettings()

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        output = try AUAudioUnitBus(format: format)
        try super.init(componentDescription: componentDescription, options: options)
        output.maximumChannelCount = 2
        outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [output])
        inputs = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [])

        let bundle = Bundle(for: StringsAUFactory.self)
        func makeParameter(_ identifier: String, label: String,
                              address: AUParameterAddress, initial: AUValue,
                              unit: AudioUnitParameterUnit = .percent) -> AUParameter {
            let parameter = AUParameterTree.createParameter(
                withIdentifier: identifier, name: NSLocalizedString(label, bundle: bundle, comment: ""),
                address: address, min: 0, max: unit == .boolean ? 1 : 100, unit: unit, unitName: nil,
                flags: [.flag_IsReadable, .flag_IsWritable], valueStrings: nil, dependentParameters: nil
            )
            parameter.value = initial
            return parameter
        }
        let existingParameters = [
            makeParameter("roomReverb", label: "Room reverb", address: 0, initial: 30),
            makeParameter("brightness", label: "Brightness", address: 1, initial: 45),
            makeParameter("bowPosition", label: "Bow position", address: 2, initial: 75),
            makeParameter("legato", label: "Legato", address: 3, initial: 0, unit: .boolean),
            makeParameter("spiccato", label: "Spiccato", address: 4, initial: 0, unit: .boolean),
        ]
        let addedParameters = PerformanceParameter.allCases.map { control in
            let parameter = AUParameterTree.createParameter(
                withIdentifier: control.identifier,
                name: NSLocalizedString(control.label, bundle: bundle, comment: ""),
                address: AUParameterAddress(control.rawValue) + 5,
                min: control.range.lowerBound, max: control.range.upperBound,
                unit: control == .tuning ? .hertz : .percent, unitName: nil,
                flags: [.flag_IsReadable, .flag_IsWritable], valueStrings: nil, dependentParameters: nil
            )
            parameter.value = control.defaultValue
            return parameter
        }
        let tree = AUParameterTree.createTree(withChildren: existingParameters + addedParameters)
        tree.implementorValueObserver = { [weak self] parameter, value in
            self?.setParameter(parameter.address, value)
        }
        tree.implementorValueProvider = { [weak self] parameter in
            switch parameter.address {
            case 1: return self?.brightnessPercent.load(ordering: .relaxed) ?? 45
            case 2: return self?.bowPositionPercent.load(ordering: .relaxed) ?? 75
            case 3: return self?.legato.load(ordering: .relaxed) == true ? 1 : 0
            case 4: return self?.spiccato.load(ordering: .relaxed) == true ? 1 : 0
            case 0: return self?.reverbPercent.load(ordering: .relaxed) ?? 30
            default:
                guard let control = Self.performanceParameter(at: parameter.address) else { return 0 }
                return self?.performance[control] ?? control.defaultValue
            }
        }
        parameterTree = tree
    }

    override var inputBusses: AUAudioUnitBusArray { inputs }
    override var outputBusses: AUAudioUnitBusArray { outputs }
    override var channelCapabilities: [NSNumber]? { [0, 1, 0, 2] }

    override func shouldChange(to format: AVAudioFormat, for bus: AUAudioUnitBus) -> Bool {
        bus === output && Self.supports(format)
    }

    override func allocateRenderResources() throws {
        guard Self.supports(output.format), maximumFramesToRender > 0 else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        try super.allocateRenderResources()
        renderer = InstrumentRender(sampleRate: output.format.sampleRate, capacity: maximumFramesToRender)
    }

    override func deallocateRenderResources() {
        renderer = nil
        super.deallocateRenderResources()
    }

    override func reset() {
        super.reset()
        renderer?.clear()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        { [weak self] flags, timestamp, count, bus, output, events, _ in
            guard let self, let renderer = self.renderer else { return kAudioUnitErr_Uninitialized }
            guard bus == 0 else { return kAudioUnitErr_InvalidElement }
            guard count <= renderer.capacity else { return kAudioUnitErr_TooManyFramesToProcess }
            flags.pointee.remove(.unitRenderAction_OutputIsSilence)
            self.performance.apply(to: renderer.model)
            renderer.model.setReverb(self.reverbPercent.load(ordering: .relaxed) / 100)
            renderer.model.setBrightness(self.brightnessPercent.load(ordering: .relaxed) / 100)
            renderer.model.setBowPosition(self.bowPositionPercent.load(ordering: .relaxed) / 100)
            renderer.model.setLegato(self.legato.load(ordering: .relaxed))
            renderer.model.setSpiccato(self.spiccato.load(ordering: .relaxed))
            return renderer.render(frames: count, time: timestamp.pointee.mSampleTime, output: output,
                                   events: events, setParameter: self.setParameter)
        }
    }

    private func setParameter(_ address: AUParameterAddress, _ percent: Float) {
        guard percent.isFinite else { return }
        let clamped = min(100, max(0, percent))
        switch address {
        case 0: reverbPercent.store(clamped, ordering: .relaxed)
        case 1: brightnessPercent.store(clamped, ordering: .relaxed)
        case 2: bowPositionPercent.store(clamped, ordering: .relaxed)
        case 3: legato.store(percent >= 0.5, ordering: .relaxed)
        case 4: spiccato.store(percent >= 0.5, ordering: .relaxed)
        default:
            if let control = Self.performanceParameter(at: address) { performance[control] = percent }
        }
    }

    fileprivate static func performanceParameter(at address: AUParameterAddress) -> PerformanceParameter? {
        guard address >= 5, let index = UInt32(exactly: address - 5) else { return nil }
        return PerformanceParameter(rawValue: index)
    }

    private static func supports(_ format: AVAudioFormat) -> Bool {
        (44_100...96_000).contains(format.sampleRate) &&
            (1...2).contains(format.channelCount) &&
            format.commonFormat == .pcmFormatFloat32 && !format.isInterleaved
    }
}

/// Per-instance render state. The host serializes render and resource lifecycle calls.
private final class InstrumentRender {
    let model: StringsModel
    let capacity: AUAudioFrameCount
    private let scratchLeft: UnsafeMutablePointer<Float>
    private let scratchRight: UnsafeMutablePointer<Float>
    private var keys = [UInt16](repeating: 0, count: 128)
    private var pizzicato = false

    init(sampleRate: Double, capacity: AUAudioFrameCount) {
        self.capacity = capacity
        model = StringsModel(sampleRate: sampleRate)
        scratchLeft = .allocate(capacity: Int(capacity))
        scratchRight = .allocate(capacity: Int(capacity))
    }

    deinit {
        scratchLeft.deallocate()
        scratchRight.deallocate()
    }

    func clear() {
        model.releaseAll()
        for note in keys.indices { keys[note] = 0 }
        pizzicato = false
    }

    func render(frames: AUAudioFrameCount, time: Float64, output: UnsafeMutablePointer<AudioBufferList>,
                events: UnsafePointer<AURenderEvent>?, setParameter: (AUParameterAddress, Float) -> Void) -> AUAudioUnitStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(output)
        guard (1...2).contains(buffers.count) else { return kAudioUnitErr_FormatNotSupported }
        let size = frames * UInt32(MemoryLayout<Float>.stride)
        for index in buffers.indices {
            if buffers[index].mData == nil {
                buffers[index].mData = UnsafeMutableRawPointer(index == 0 ? scratchLeft : scratchRight)
            } else if buffers[index].mDataByteSize < size {
                return kAudio_ParamError
            }
            buffers[index].mDataByteSize = size
        }
        let left = buffers[0].mData!.assumingMemoryBound(to: Float.self)
        let right = buffers.count == 2 ? buffers[1].mData!.assumingMemoryBound(to: Float.self) : scratchRight

        var rendered = 0
        var event = events
        while let current = event {
            let head = current.pointee.head
            let timeOffset = Double(head.eventSampleTime) - time
            if timeOffset.isFinite && timeOffset >= Double(frames) { break }
            let offset = max(rendered, timeOffset > 0 && timeOffset.isFinite ? Int(timeOffset) : 0)
            if offset > rendered {
                model.render(left + rendered, right + rendered, frames: UInt32(offset - rendered))
                rendered = offset
            }
            switch head.eventType {
            case .MIDI:
                let midi = current.pointee.MIDI
                if midi.length == 3, let message = StringsMIDI(status: midi.data.0, first: midi.data.1, second: midi.data.2) {
                    handle(message)
                }
            case .parameter, .parameterRamp:
                let parameter = current.pointee.parameter
                if parameter.value.isFinite {
                    setParameter(parameter.parameterAddress, parameter.value)
                    let amount = min(100, max(0, parameter.value)) / 100
                    switch parameter.parameterAddress {
                    case 0: model.setReverb(amount)
                    case 1: model.setBrightness(amount)
                    case 2: model.setBowPosition(amount)
                    case 3: model.setLegato(parameter.value >= 0.5)
                    case 4: model.setSpiccato(parameter.value >= 0.5)
                    default:
                        if let control = StringsAudioUnit.performanceParameter(at: parameter.parameterAddress) {
                            model.setPerformance(control, value: parameter.value)
                        }
                    }
                }
            default:
                break
            }
            event = head.next.map { UnsafePointer($0) }
        }
        model.render(left + rendered, right + rendered, frames: frames - UInt32(rendered))
        if buffers.count == 1 {
            for index in 0..<Int(frames) { left[index] = (left[index] + right[index]) * 0.5 }
        }
        return noErr
    }

    private func handle(_ event: StringsMIDI) {
        switch event {
        case let .press(channel, note, velocity):
            keys[note] |= UInt16(1) << channel
            model.noteOn(note, velocity: Float(velocity) / 127, pizzicato: pizzicato)
        case let .release(channel, note):
            keys[note] &= ~(UInt16(1) << channel)
            if keys[note] == 0 { model.noteOff(note) }
        case let .expression(value):
            model.setExpression(Float(value) / 127)
        case let .sustain(value):
            model.sustain(Float(value) / 127)
        case let .pizzicato(down):
            pizzicato = down
        case .panic:
            clear()
        }
    }
}
