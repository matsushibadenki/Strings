import CoreMIDI
import SwiftUI

@main
struct StringsApp: App {
    var body: some Scene {
        #if os(macOS)
        Window("Strings", id: "instrument") {
            StringsView()
                .frame(minWidth: 560, minHeight: 360)
        }
        .defaultSize(width: 900, height: 650)
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
    @AppStorage("legato") private var legato = false
    @AppStorage("spiccato") private var spiccato = false
    @AppStorage("bowPositionPercent") private var bowPositionPercent = 75
    @AppStorage("brightnessPercent") private var brightnessPercent = 45
    @AppStorage("roomReverbPercent") private var reverbPercent = 30
    @State private var visibleNotes = 14
    var playsAudio = true

    private let accent = Color(red: 0.81, green: 0.77, blue: 1)

    private let playingHelp: LocalizedStringKey = "Play chords on the keyboard or connect a MIDI controller. Switch to pizzicato to pluck the next notes. Adjust brightness and room reverb in sound controls."

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= 580
            let compact = proxy.size.height < 450
            VStack(spacing: compact ? 12 : 24) {
                header
                if audio.unavailable {
                    Button("Retry audio", systemImage: "speaker.slash") { audio.start() }
                        .font(.callout)
                }
                controls
                KeyboardView(
                    layout: KeyboardLayout(octave: octave, whiteCount: wide ? 14 : 7),
                    pressed: touches.union(accessibilityNotes.keys).union(midiKeys.map(\.note)),
                    showLabels: !compact,
                    onTouches: updateTouches,
                    onAccessibilityPlay: playAccessibleNote
                )
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
            midi.start(receive: receiveMIDI, disconnected: disconnectMIDI)
            if phase == .active { audio.start() }
        }
        .onDisappear {
            midi.stop()
            audio.stop()
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

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("String Ensemble")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(accent)
                Text("Strings")
                    .font(.system(.largeTitle, design: .serif, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer()
            HStack(spacing: 0) {
                pedalToggle("waveform.path", label: "Sustain pedal", isOn: sustainToggle)
                iconButton("slider.horizontal.3", label: "Sound controls") { showSound.toggle() }
                    .popover(isPresented: $showSound) {
                        soundControls
                        #if os(iOS)
                            .presentationCompactAdaptation(.popover)
                        #endif
                    }
                iconButton("info.circle", label: "Playing Strings", help: playingHelp) { info = true }
            }
        }
    }

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

    private var soundControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Bowing", selection: bowArticulation) {
                Text("Sustained").tag(BowArticulation.sustained)
                Text("Legato").tag(BowArticulation.legato)
                Text("Spiccato").tag(BowArticulation.spiccato)
            }
            .pickerStyle(.menu)
            soundSlider("Bow position", percent: $bowPositionPercent)
            HStack {
                Text("Fingerboard")
                Spacer()
                Text("Bridge")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, -12)
            soundSlider("Brightness", percent: $brightnessPercent)
            soundSlider("Room reverb", percent: $reverbPercent)
        }
        .frame(width: 230)
        .padding(16)
    }

    private func soundSlider(_ label: LocalizedStringKey, percent: Binding<Int>) -> some View {
        let amount = Binding(
            get: { Double(min(100, max(0, percent.wrappedValue))) },
            set: { percent.wrappedValue = Int($0.rounded()) }
        )
        let value = amount.wrappedValue.formatted(.percent.scale(1))
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label).font(.headline)
                Spacer(minLength: 16)
                Text(value).monospacedDigit().foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Slider(value: amount, in: 0...100, step: 1) { Text(label) }
                .accessibilityValue(Text(value))
        }
    }

    private var maximumOctave: Int { visibleNotes == 14 ? 6 : 7 }

    private var controls: some View {
        HStack(spacing: 8) {
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

            pedalToggle("hand.tap", label: "Pizzicato", isOn: $pizzicato)
            iconButton("stop.circle", label: "Stop all sound", action: stopAllSound)
                #if os(macOS)
                .keyboardShortcut(.escape, modifiers: [])
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

private enum BowArticulation: Hashable {
    case sustained, legato, spiccato
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
        StringsView(playsAudio: false).frame(width: 900, height: 650)
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
