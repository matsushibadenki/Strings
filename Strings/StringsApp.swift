import CoreMIDI
import SwiftUI

#if os(macOS)
private let instrumentHeight: CGFloat = 370
#endif

@main
struct StringsApp: App {
    var body: some Scene {
        #if os(macOS)
        Window("", id: "instrument") {
            StringsView()
                .frame(minWidth: 560)
                .frame(height: instrumentHeight)
        }
        .defaultSize(width: 900, height: instrumentHeight)
        .windowResizability(.contentSize)
        #else
        WindowGroup { StringsView() }
        #endif
    }
}

struct StringsView: View {
    @StateObject private var audio = StringsAudio()
    @Environment(\.scenePhase) private var phase
    #if os(macOS)
    @Environment(\.appearsActive) private var windowIsActive
    #endif
    @State private var midi = MIDIInput()
    @State private var midiKeys: Set<MIDIKey> = []
    @State private var midiSustainSources: Set<MIDIEndpointRef> = []
    @State private var midiExpressionSource: MIDIEndpointRef?
    @State private var midiPizzicatoSources: Set<MIDIEndpointRef> = []
    @State private var octave = 4
    @State private var velocity = 60.0
    @State private var sustain = false
    @State private var pizzicato = false
    @State private var touches: Set<Int> = []
    @State private var keyboardGeneration = 0
    @State private var accessibilityNotes: [Int: UUID] = [:]
    @State private var info = false
    @State private var showSound = false
    @State private var soundSection = SoundSection.bow
    @State private var performanceValues = Dictionary(uniqueKeysWithValues: PerformanceParameter.allCases.map { control in
        let saved = UserDefaults.standard.object(forKey: control.preferencesKey) as? NSNumber
        return (control, control.clamped(saved?.floatValue ?? control.defaultValue))
    })
    @AppStorage("waveguide") private var waveguide = false
    @AppStorage("legato") private var legato = false
    @AppStorage("spiccato") private var spiccato = false
    @AppStorage("bowPositionPercent") private var bowPositionPercent = 75
    @AppStorage("brightnessPercent") private var brightnessPercent = 45
    @AppStorage("roomReverbPercent") private var reverbPercent = 30
    @State private var visibleNotes = 14
    var playsAudio = true

    private let accent = Color(red: 0.81, green: 0.77, blue: 1)

    private let playingHelp: LocalizedStringKey = "Play chords on the keyboard or connect a MIDI controller. Switch to pizzicato to pluck the next notes."

    var body: some View {
        GeometryReader { proxy in
            #if os(macOS)
            VStack(alignment: .leading, spacing: 10) {
                instrumentKnobs
                controls
                keyboard(.full, labels: true, miniature: true)
                    .frame(height: 108)
                    .id(keyboardGeneration)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            #else
            let wide = proxy.size.width >= 580
            let compact = proxy.size.height < 450
            VStack(spacing: compact ? 12 : 24) {
                HStack {
                    Spacer()
                    utilityControls
                }
                audioRetry
                controls
                keyboard(KeyboardLayout(octave: octave, whiteCount: wide ? 14 : 7), labels: !compact)
                    .frame(maxHeight: 460)
                    .id(KeyWindow(octave: octave, wide: wide, generation: keyboardGeneration))
            }
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, compact ? 8 : 26)
            .onChange(of: wide, initial: true) { _, newValue in
                releaseKeys()
                visibleNotes = newValue ? 14 : 7
                octave = min(octave, maximumOctave)
            }
            #endif
        }
        .background {
            LinearGradient(colors: [Color(red: 0.16, green: 0.13, blue: 0.22), Color(red: 0.075, green: 0.065, blue: 0.10)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
        .tint(accent)
        .task {
            guard playsAudio else { return }
            for (parameter, value) in performanceValues {
                audio.setPerformance(parameter, value: value)
            }
            midi.start(receive: receiveMIDI, disconnected: disconnectMIDI)
            if phase == .active { audio.start() }
        }
        .onDisappear {
            midi.stop()
            audio.stop()
        }
        .onChange(of: waveguide, initial: true) { _, enabled in
            audio.setWaveguide(enabled)
        }
        .onChange(of: bowArticulation.wrappedValue, initial: true) { _, value in
            audio.setBowArticulation(legato: value == .legato, spiccato: value == .spiccato)
        }
        .onChange(of: bowPositionPercent, initial: true) { _, value in
            audio.setBowPosition(min(100, max(0, value)))
        }
        .onChange(of: brightnessPercent, initial: true) { _, value in
            audio.setBrightness(min(100, max(0, value)))
        }
        .onChange(of: reverbPercent, initial: true) { _, value in
            audio.setReverb(min(100, max(0, value)))
        }
        #if os(macOS)
        .onChange(of: windowIsActive) { _, active in
            if !active { releaseKeys() }
        }
        #endif
        .onChange(of: phase) { _, value in
            if value == .active {
                if playsAudio { audio.start() }
            } else {
                releaseKeys()
                #if os(iOS)
                if value == .background {
                    stopAllSound()
                    audio.stop()
                }
                #endif
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVAudioEngineConfigurationChange)
            .receive(on: RunLoop.main)) { _ in
            guard playsAudio else { return }
            #if os(iOS)
            guard phase == .active else { return }
            #endif
            stopAllSound()
            audio.start()
        }
        .alert("Playing Strings", isPresented: $info) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(playingHelp)
        }
    }

    @ViewBuilder
    private var audioRetry: some View {
        if audio.unavailable {
            Button("Retry audio", systemImage: "speaker.slash") { audio.start() }
                .font(.callout)
        }
    }

    private func keyboard(_ layout: KeyboardLayout, labels: Bool, miniature: Bool = false) -> some View {
        KeyboardView(
            layout: layout,
            pressed: touches.union(accessibilityNotes.keys).union(midiKeys.map(\.note)),
            showLabels: labels,
            miniature: miniature,
            onTouches: updateTouches,
            onAccessibilityPlay: playAccessibleNote
        )
    }

    private var utilityControls: some View {
        HStack(spacing: 0) {
            pedalToggle("waveform.path", label: "Sustain pedal", isOn: sustainToggle)
            #if os(macOS)
            pedalToggle("waveform", label: "Waveguide (experimental)", isOn: $waveguide)
                .help(Text("Waveguide for sustained bowing, starting with the next note."))
            #endif
            #if os(iOS)
            iconButton("slider.horizontal.3", label: "Sound controls") { showSound.toggle() }
                .popover(isPresented: $showSound) {
                    soundControls
                        .presentationCompactAdaptation(.sheet)
                }
            #endif
            iconButton("info.circle", label: "Playing Strings", help: playingHelp) { info = true }
        }
    }

    #if os(macOS)
    private var instrumentKnobs: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                performanceKnob("Volume", parameter: .volume)
                    .padding(.trailing, 6)
                performanceKnob("Body", parameter: .body)
                performanceKnob("Width", parameter: .ensemble)
                RotaryKnob(title: "Brightness", label: "Brightness",
                           value: percentBinding($brightnessPercent), defaultValue: 45)
                RotaryKnob(title: "Reverb", label: "Room reverb",
                           value: percentBinding($reverbPercent), defaultValue: 30)
                bowingKnob
                    .padding(.leading, 6)
                RotaryKnob(title: "Velocity", label: "Velocity", value: $velocity,
                           defaultValue: 60, range: 5...100)
                performanceKnob("Tuning", parameter: .tuning)
            }
            HStack(spacing: 4) {
                performanceKnob("Expr.", parameter: .expression)
                performanceKnob("Vibrato", parameter: .vibrato)
                performanceKnob("Bite", parameter: .bowBite)
                performanceKnob("Pressure", parameter: .bowPressure)
                performanceKnob("Transition", parameter: .legatoTransition)
                RotaryKnob(title: "Contact", label: "Bow position (fingerboard to bridge)",
                           value: percentBinding($bowPositionPercent), defaultValue: 75)
                performanceKnob("Bow stroke", parameter: .bowTravel)
                performanceKnob("Bow speed", parameter: .bowSpeed)
                    .disabled(!waveguide || bowArticulation.wrappedValue != .sustained)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }

    private var bowingKnob: some View {
        let articulation = bowArticulation
        let choice = Binding<Double>(
            get: { Double(articulation.wrappedValue.rawValue) },
            set: { value in
                if let option = BowArticulation(rawValue: Int(value)) {
                    articulation.wrappedValue = option
                }
            }
        )
        return RotaryKnob(title: "Bowing", label: "Bowing", value: choice, defaultValue: 0,
                          range: 0...2, dragDistance: 60, adjustmentStep: 1,
                          choice: articulation.wrappedValue.label)
    }

    private func performanceKnob(_ title: LocalizedStringKey, parameter: PerformanceParameter) -> some View {
        let tuning = parameter == .tuning
        return RotaryKnob(title: title, label: LocalizedStringKey(parameter.label),
                          value: performanceBinding(parameter), defaultValue: Double(parameter.defaultValue),
                          range: Double(parameter.range.lowerBound)...Double(parameter.range.upperBound),
                          step: tuning ? 0.1 : 1, adjustmentStep: tuning ? 0.1 : 2, showsHertz: tuning)
    }
    #endif

    private var bowArticulation: Binding<BowArticulation> {
        Binding(
            get: {
                if spiccato { return .spiccato }
                return legato ? .legato : .sustained
            },
            set: { option in
                legato = option == .legato
                spiccato = option == .spiccato
            }
        )
    }

    #if os(iOS)
    private var soundControls: some View {
        VStack(spacing: 12) {
            Picker("Sound controls", selection: $soundSection) {
                Text("Bow and expression").tag(SoundSection.bow)
                Text("Body and space").tag(SoundSection.space)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if soundSection == .bow {
                        bowControls
                    } else {
                        performanceSlider(.body)
                        performanceSlider(.ensemble)
                        soundSlider("Brightness", percent: $brightnessPercent)
                        soundSlider("Room reverb", percent: $reverbPercent)
                        performanceSlider(.volume)
                        performanceSlider(.tuning)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 400)
        }
        .padding(16)
        .frame(maxWidth: 380)
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var bowControls: some View {
        Picker("Bowing", selection: bowArticulation) {
            ForEach(BowArticulation.allCases, id: \.self) { option in
                Text(option.label).tag(option)
            }
        }
        .pickerStyle(.menu)
        performanceSlider(.expression)
        performanceSlider(.vibrato)
        performanceSlider(.bowBite)
        Toggle("Waveguide (experimental)", isOn: $waveguide)
        performanceSlider(.bowSpeed)
            .disabled(!waveguide || bowArticulation.wrappedValue != .sustained)
        performanceSlider(.bowPressure)
        performanceSlider(.legatoTransition)
        soundSlider("Bow position", percent: $bowPositionPercent)
        sliderEndpoints("Fingerboard", "Bridge")
        performanceSlider(.bowTravel)
        sliderEndpoints("Frog", "Tip")
    }

    private func sliderEndpoints(_ from: LocalizedStringKey, _ to: LocalizedStringKey) -> some View {
        HStack {
            Text(from)
            Spacer()
            Text(to)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, -9)
    }

    #endif

    private func performanceBinding(_ parameter: PerformanceParameter) -> Binding<Double> {
        Binding(
            get: { Double(performanceValues[parameter] ?? parameter.defaultValue) },
            set: { value in
                let value = parameter.clamped(Float(value))
                performanceValues[parameter] = value
                UserDefaults.standard.set(value, forKey: parameter.preferencesKey)
                audio.setPerformance(parameter, value: value)
            }
        )
    }

    #if os(iOS)
    private func performanceSlider(_ parameter: PerformanceParameter) -> some View {
        let amount = performanceBinding(parameter)
        let range = Double(parameter.range.lowerBound)...Double(parameter.range.upperBound)
        let tuning = parameter == .tuning
        let value = tuning
            ? amount.wrappedValue.formatted(.number.precision(.fractionLength(1))) + " Hz"
            : amount.wrappedValue.formatted(.percent.scale(1).precision(.fractionLength(0)))
        return soundSlider(LocalizedStringKey(parameter.label), amount: amount, range: range,
                           step: tuning ? 0.1 : 1, display: value)
    }

    #endif

    private func percentBinding(_ percent: Binding<Int>) -> Binding<Double> {
        Binding(
            get: { Double(min(100, max(0, percent.wrappedValue))) },
            set: { percent.wrappedValue = Int($0.rounded()) }
        )
    }

    #if os(iOS)
    private func soundSlider(_ label: LocalizedStringKey, percent: Binding<Int>) -> some View {
        let amount = percentBinding(percent)
        let value = amount.wrappedValue.formatted(.percent.scale(1))
        return soundSlider(label, amount: amount, range: 0...100, step: 1, display: value)
    }

    private func soundSlider(_ label: LocalizedStringKey, amount: Binding<Double>,
                             range: ClosedRange<Double>, step: Double, display: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(.headline)
                Spacer(minLength: 16)
                Text(display).monospacedDigit().foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Slider(value: amount, in: range, step: step) { Text(label) }
                .labelsHidden()
                .accessibilityLabel(Text(label))
                .accessibilityValue(Text(display))
        }
    }

    #endif

    private var maximumOctave: Int { visibleNotes == 14 ? 6 : 7 }

    private var controls: some View {
        HStack(spacing: 8) {
            #if os(iOS)
            HStack(spacing: 0) {
                iconButton("chevron.left", label: "Lower octave") { shift(-1) }
                    .disabled(octave == 0)
                Group {
                    if octave == 0 {
                        Text("Bass")
                    } else if octave == maximumOctave {
                        Text("Treble")
                    } else {
                        Text(verbatim: "C\(octave)")
                    }
                }
                    .font(.subheadline.monospacedDigit().weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .frame(minWidth: 30)
                    .accessibilityLabel(Text("Octave range"))
                    .accessibilityValue(Text(verbatim: rangeDescription))
                iconButton("chevron.right", label: "Higher octave") { shift(1) }
                    .disabled(octave == maximumOctave)
            }
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 5) {
                Image(systemName: "speedometer")
                    .font(.footnote)
                    .foregroundStyle(accent)
                    .accessibilityHidden(true)
                Slider(value: $velocity, in: 5...100, step: 1) {
                    Text("Velocity")
                }
                .accessibilityValue(Text(verbatim: "\(Int((velocity * 1.27).rounded()))"))
            }

            #else
            audioRetry
            Spacer(minLength: 0)
            #endif

            pedalToggle("hand.tap", label: "Pizzicato", isOn: $pizzicato)
            iconButton("stop.circle", label: "Stop all sound", action: stopAllSound)
                #if os(macOS)
                .keyboardShortcut(.escape, modifiers: [])
                #endif
            #if os(macOS)
            utilityControls
            #endif
        }
    }

    private func pedalToggle(_ symbol: String, label: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label(label, systemImage: symbol)
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
                .foregroundStyle(isOn.wrappedValue ? Color.black : accent)
                .background(isOn.wrappedValue ? accent : .white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        }
        .toggleStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .help(Text(label))
    }

    private var rangeDescription: String {
        let layout = KeyboardLayout(octave: octave, whiteCount: visibleNotes)
        return "\(noteName(layout.white.first ?? 21)) – \(noteName(layout.white.last ?? 108))"
    }

    private func iconButton(_ symbol: String, label: LocalizedStringKey,
                            help: LocalizedStringKey? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(accent)
        .accessibilityLabel(Text(label))
        .help(Text(help ?? label))
    }

    private func shift(_ direction: Int) {
        releaseKeys()
        octave = min(maximumOctave, max(0, octave + direction))
    }

    private func updateTouches(_ notes: Set<Int>) {
        // A dragged finger can leave one key and enter another in the same update.
        let releases = touches.subtracting(notes).filter { accessibilityNotes[$0] == nil && !hasMIDIKey($0) }
        let presses = notes.subtracting(touches).sorted()
        let plucked = pizzicato || !midiPizzicatoSources.isEmpty
        let connect = bowArticulation.wrappedValue == .legato && !plucked
        if !connect { releases.forEach(audio.noteOff) }
        for note in presses { audio.noteOn(note, velocity: Int(velocity), pizzicato: plucked) }
        if connect { releases.forEach(audio.noteOff) }
        touches = notes
    }

    private func releaseKeys() {
        for note in touches.union(accessibilityNotes.keys) where !hasMIDIKey(note) { audio.noteOff(note) }
        touches = []
        accessibilityNotes = [:]
        keyboardGeneration += 1
    }

    private func stopAllSound() {
        touches.removeAll()
        accessibilityNotes.removeAll()
        midiKeys.removeAll()
        midiSustainSources.removeAll()
        midiPizzicatoSources.removeAll()
        midiExpressionSource = nil
        sustain = false
        keyboardGeneration += 1
        audio.releaseAll()
    }

    private var sustainToggle: Binding<Bool> {
        Binding(
            get: { sustain || !midiSustainSources.isEmpty },
            set: { enabled in
                sustain = enabled
                if !enabled { midiSustainSources.removeAll() }
                updateSustain()
            }
        )
    }

    private func updateSustain() {
        audio.sustain(sustain || !midiSustainSources.isEmpty)
    }

    private func hasMIDIKey(_ note: Int) -> Bool { midiKeys.contains { $0.note == note } }

    private func receiveMIDI(_ source: MIDIEndpointRef, _ event: StringsMIDI) {
        #if os(iOS)
        guard phase != .background else { return }
        #endif
        switch event {
        case let .press(channel, note, velocity):
            midiKeys.insert(MIDIKey(source: source, channel: channel, note: note))
            audio.midiNoteOn(note, velocity: velocity, pizzicato: pizzicato || !midiPizzicatoSources.isEmpty)
        case let .release(channel, note):
            midiKeys.remove(MIDIKey(source: source, channel: channel, note: note))
            releaseMIDINote(note)
        case let .sustain(value):
            if value >= 64 { midiSustainSources.insert(source) } else { midiSustainSources.remove(source) }
            updateSustain()
        case let .expression(value):
            midiExpressionSource = source
            audio.midiExpression(value)
        case let .pizzicato(down):
            if down { midiPizzicatoSources.insert(source) } else { midiPizzicatoSources.remove(source) }
        case .panic:
            stopAllSound()
        }
    }

    private func disconnectMIDI(_ source: MIDIEndpointRef) {
        let released = midiKeys.filter { $0.source == source }
        midiKeys.subtract(released)
        for note in Set(released.map(\.note)) { releaseMIDINote(note) }
        midiSustainSources.remove(source)
        if midiExpressionSource == source {
            midiExpressionSource = nil
            audio.midiExpression(127)
        }
        midiPizzicatoSources.remove(source)
        updateSustain()
    }

    private func releaseMIDINote(_ note: Int) {
        guard !hasMIDIKey(note), !touches.contains(note), accessibilityNotes[note] == nil else { return }
        audio.noteOff(note)
    }

    private func playAccessibleNote(_ note: Int) {
        let token = UUID()
        accessibilityNotes[note] = token
        audio.noteOn(note, velocity: Int(velocity), pizzicato: pizzicato || !midiPizzicatoSources.isEmpty)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(340))
            guard accessibilityNotes[note] == token else { return }
            accessibilityNotes[note] = nil
            if !touches.contains(note) && !hasMIDIKey(note) { audio.noteOff(note) }
        }
    }
}

#if os(macOS)
private struct RotaryKnob: View {
    let title: LocalizedStringKey
    let label: LocalizedStringKey
    @Binding var value: Double
    let defaultValue: Double
    var range: ClosedRange<Double> = 0...100
    var dragDistance: Double = 180
    var step: Double = 1
    var adjustmentStep: Double = 2
    var showsHertz = false
    var choice: LocalizedStringKey?
    @State private var dragStart: Double?

    private var span: Double { range.upperBound - range.lowerBound }

    private var readout: Text {
        if let choice { return Text(choice) }
        if showsHertz {
            let frequency = value.formatted(.number.precision(.fractionLength(1)))
            return Text(verbatim: frequency + " Hz")
        }
        return Text(verbatim: value.formatted(.percent.scale(1).precision(.fractionLength(0))))
    }

    var body: some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
            knob
            readout
                .lineLimit(1)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(width: 58)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(readout)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(to: value + adjustmentStep)
            case .decrement: adjust(to: value - adjustmentStep)
            @unknown default: break
            }
        }
        .help(Text("Drag vertically to adjust. Double-click to reset."))
    }

    private var knob: some View {
        ZStack {
            ForEach(0..<11) { tick in
                Capsule()
                    .fill(.white.opacity(tick.isMultiple(of: 5) ? 0.56 : 0.29))
                    .frame(width: 1, height: tick.isMultiple(of: 5) ? 4 : 2)
                    .offset(y: -22)
                    .rotationEffect(.degrees(-135 + Double(tick) * 27))
            }
            Circle()
                .fill(LinearGradient(colors: [Color(white: 0.32), Color(white: 0.11), Color(white: 0.05)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay { Circle().strokeBorder(.white.opacity(0.20), lineWidth: 1) }
                .frame(width: 36, height: 36)
                .shadow(color: .black.opacity(0.55), radius: 2, y: 2)
            Capsule()
                .fill(.white.opacity(0.95))
                .frame(width: 2, height: 8)
                .offset(y: -11)
                .rotationEffect(.degrees(-135 + (value - range.lowerBound) / span * 270))
        }
        .frame(width: 50, height: 50)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { event in
                if dragStart == nil { dragStart = value }
                adjust(to: (dragStart ?? value) - event.translation.height * (span / dragDistance))
            }
            .onEnded { _ in dragStart = nil })
        .onTapGesture(count: 2) {
            adjust(to: defaultValue)
        }
    }

    private func adjust(to value: Double) {
        let rounded = range.lowerBound + ((value - range.lowerBound) / step).rounded() * step
        self.value = min(range.upperBound, max(range.lowerBound, rounded))
    }
}
#endif

private enum SoundSection: Hashable {
    case bow, space
}

private enum BowArticulation: Int, CaseIterable {
    case sustained, legato, spiccato

    var label: LocalizedStringKey {
        switch self {
        case .sustained: "Sustained"
        case .legato: "Legato"
        case .spiccato: "Spiccato"
        }
    }
}

private struct MIDIKey: Hashable {
    let source: MIDIEndpointRef
    let channel: Int
    let note: Int
}

private struct KeyWindow: Hashable {
    let octave: Int
    let wide: Bool
    let generation: Int
}

struct StringsView_Previews: PreviewProvider {
    static var previews: some View {
        #if os(macOS)
        StringsView(playsAudio: false).frame(width: 900, height: instrumentHeight)
        #else
        Group {
            StringsView(playsAudio: false)
                .previewDevice("iPhone SE (3rd generation)")
            StringsView(playsAudio: false)
                .previewDevice("iPhone 16 Pro Max")
        }
        #endif
    }
}
