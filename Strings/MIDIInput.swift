import CoreMIDI

@MainActor
final class MIDIInput {
    private var client = MIDIClientRef(0)
    private var port = MIDIPortRef(0)
    private var sources: Set<MIDIEndpointRef> = []

    func start(receive: @escaping @MainActor (MIDIEndpointRef, StringsMIDI) -> Void,
               disconnected: @escaping @MainActor (MIDIEndpointRef) -> Void) {
        guard client == 0 else { return }
        let status = MIDIClientCreateWithBlock("Strings" as CFString, &client) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh(disconnected: disconnected) }
        }
        guard status == noErr else { return }
        let inputStatus = MIDIInputPortCreateWithProtocol(client, "Strings Input" as CFString,
                                                         ._1_0, &port) { [weak self] events, context in
            let source = MIDIEndpointRef(UInt(bitPattern: context))
            var messages: [StringsMIDI] = []
            withUnsafeMutablePointer(to: &messages) { storage in
                MIDIEventListForEachEvent(events, { context, _, message in
                    guard let context, let event = StringsMIDI(ump: message) else { return }
                    context.assumingMemoryBound(to: [StringsMIDI].self).pointee.append(event)
                }, UnsafeMutableRawPointer(storage))
            }
            guard !messages.isEmpty else { return }
            let received = messages
            DispatchQueue.main.async {
                guard self?.sources.contains(source) == true else { return }
                for event in received { receive(source, event) }
            }
        }
        guard inputStatus == noErr else { stop(); return }
        refresh(disconnected: disconnected)
    }

    func stop() {
        if port != 0 { MIDIPortDispose(port) }
        if client != 0 { MIDIClientDispose(client) }
        sources = []
        port = 0
        client = 0
    }

    private func refresh(disconnected: (MIDIEndpointRef) -> Void) {
        guard port != 0 else { return }
        let available = Set((0..<MIDIGetNumberOfSources()).map { MIDIGetSource($0) }).subtracting([0])
        for endpoint in sources.subtracting(available) {
            MIDIPortDisconnectSource(port, endpoint)
            sources.remove(endpoint)
            disconnected(endpoint)
        }
        for endpoint in available.subtracting(sources) {
            if MIDIPortConnectSource(port, endpoint, UnsafeMutableRawPointer(bitPattern: UInt(endpoint))) == noErr {
                sources.insert(endpoint)
            }
        }
    }
}
