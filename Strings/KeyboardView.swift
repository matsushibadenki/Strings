import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

func noteName(_ note: Int) -> String {
    let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    return "\(names[note % 12])\(note / 12 - 1)"
}

struct KeyboardLayout {
    struct Accidental {
        let note: Int
        let boundary: Int
    }

    let white: [Int]
    let black: [Accidental]

    init(octave: Int, whiteCount: Int) {
        let naturals = (21...108).filter { [0, 2, 4, 5, 7, 9, 11].contains($0 % 12) }
        let requested = naturals.firstIndex { $0 >= (octave + 1) * 12 } ?? 0
        let start = octave == 0 ? 0 : requested
        let end = min(naturals.count, start + whiteCount + (octave == 0 ? 2 : 0)
                      + (octave == (whiteCount == 14 ? 6 : 7) ? 1 : 0))
        white = Array(naturals[start..<end])
        black = zip(white, white.dropFirst()).enumerated().compactMap { index, pair in
            pair.1 - pair.0 == 2 ? Accidental(note: pair.0 + 1, boundary: index + 1) : nil
        }
    }

    func blackFrame(_ key: Accidental, size: CGSize) -> CGRect {
        let step = size.width / CGFloat(white.count)
        let width = step * 0.59
        return CGRect(x: CGFloat(key.boundary) * step - width / 2, y: 0,
                      width: width, height: size.height * 0.63)
    }

    func note(at point: CGPoint, size: CGSize) -> Int? {
        guard CGRect(origin: .zero, size: size).contains(point) else { return nil }
        if let key = black.first(where: { blackFrame($0, size: size).contains(point) }) { return key.note }
        return white[min(white.count - 1, Int(point.x / size.width * CGFloat(white.count)))]
    }
}

struct KeyboardView: View {
    let layout: KeyboardLayout
    let pressed: Set<Int>
    let showLabels: Bool
    let onTouches: (Set<Int>) -> Void
    let onAccessibilityPlay: (Int) -> Void

    var body: some View {
        GeometryReader { proxy in
            let step = proxy.size.width / CGFloat(layout.white.count)
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(layout.white, id: \.self) { note in
                        key(note, black: false)
                            .frame(width: step, height: proxy.size.height)
                    }
                }
                ForEach(layout.black, id: \.note) { accidental in
                    let rect = layout.blackFrame(accidental, size: proxy.size)
                    key(accidental.note, black: true)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX)
                }
                TouchSurface(layout: layout, onTouches: onTouches)
                    .accessibilityHidden(true)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .top) {
                Rectangle().fill(.black.opacity(0.24)).frame(height: 2).allowsHitTesting(false)
            }
        }
    }

    private func key(_ note: Int, black: Bool) -> some View {
        let down = pressed.contains(note)
        let accent = Color(red: 0.68, green: 0.60, blue: 0.94)
        return UnevenRoundedRectangle(bottomLeadingRadius: black ? 5 : 7, bottomTrailingRadius: black ? 5 : 7)
            .fill(LinearGradient(
                colors: down ? [accent.opacity(0.75), accent] : black
                    ? [Color(white: 0.11), Color(white: 0.23)]
                    : [Color(red: 0.85, green: 0.82, blue: 0.76), Color(red: 0.99, green: 0.97, blue: 0.92)],
                startPoint: .top, endPoint: .bottom
            ))
            .padding(.horizontal, black ? 0 : 0.6)
            .shadow(color: .black.opacity(black ? 0.4 : 0), radius: 3, y: 3)
            .overlay(alignment: .bottom) {
                if showLabels && !black {
                    Text(verbatim: noteName(note))
                        .font(.caption2.monospaced().weight(note % 12 == 0 ? .bold : .regular))
                        .foregroundStyle(Color(white: 0.28))
                        .padding(.bottom, 13)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: noteName(note)))
            .accessibilityAddTraits(.isButton)
            .accessibilitySortPriority(Double(109 - note))
            .accessibilityAction { onAccessibilityPlay(note) }
    }
}

#if os(macOS)
private struct TouchSurface: NSViewRepresentable {
    let layout: KeyboardLayout
    let onTouches: (Set<Int>) -> Void

    func makeNSView(context: Context) -> MouseView { MouseView() }

    func updateNSView(_ view: MouseView, context: Context) {
        view.layout = layout
        view.onTouches = onTouches
    }

    static func dismantleNSView(_ view: MouseView, coordinator: ()) {
        view.onTouches = nil
    }

    final class MouseView: NSView {
        var layout: KeyboardLayout?
        var onTouches: ((Set<Int>) -> Void)?
        private var trackingPress = false
        override var isFlipped: Bool { true }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            trackingPress = true
            play(event)
        }

        override func mouseDragged(with event: NSEvent) {
            if trackingPress { play(event) }
        }

        override func mouseUp(with event: NSEvent) {
            guard trackingPress else { return }
            trackingPress = false
            onTouches?([])
        }

        private func play(_ event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if let note = layout?.note(at: point, size: bounds.size) {
                onTouches?([note])
            } else {
                onTouches?([])
            }
        }
    }
}
#else
private struct TouchSurface: UIViewRepresentable {
    let layout: KeyboardLayout
    let onTouches: (Set<Int>) -> Void

    func makeUIView(context: Context) -> TouchView {
        let view = TouchView()
        view.isMultipleTouchEnabled = true
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: TouchView, context: Context) {
        view.layout = layout
        view.onTouches = onTouches
    }

    static func dismantleUIView(_ view: TouchView, coordinator: ()) {
        view.onTouches = nil
    }

    final class TouchView: UIView {
        var layout: KeyboardLayout?
        var onTouches: ((Set<Int>) -> Void)?
        private var notes: [ObjectIdentifier: Int] = [:]

        private var activeTouches: Set<ObjectIdentifier> = []

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            activeTouches.formUnion(touches.map(ObjectIdentifier.init))
            update(touches)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { update(touches) }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { remove(touches) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { remove(touches) }

        private func update(_ touches: Set<UITouch>) {
            for touch in touches {
                let id = ObjectIdentifier(touch)
                guard activeTouches.contains(id) else { continue }
                notes[id] = layout?.note(at: touch.location(in: self), size: bounds.size)
            }
            onTouches?(Set(notes.values))
        }

        private func remove(_ touches: Set<UITouch>) {
            for touch in touches {
                let id = ObjectIdentifier(touch)
                activeTouches.remove(id)
                notes[id] = nil
            }
            onTouches?(Set(notes.values))
        }
    }
}
#endif
