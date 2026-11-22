import Foundation
import Synchronization

/// The declaration order matches the Rust performance control array.
enum PerformanceParameter: UInt32, CaseIterable {
    case expression, vibrato, bowBite, legatoTransition, bowPressure
    case body, ensemble, volume, bowTravel, tuning, bowSpeed

    var identifier: String {
        switch self {
        case .expression: "expression"
        case .vibrato: "vibrato"
        case .bowBite: "bowBite"
        case .legatoTransition: "legatoTransition"
        case .bowPressure: "bowPressure"
        case .body: "body"
        case .ensemble: "ensemble"
        case .volume: "volume"
        case .bowTravel: "bowTravel"
        case .tuning: "tuning"
        case .bowSpeed: "bowSpeed"
        }
    }

    var label: String {
        switch self {
        case .expression: "Expression"
        case .vibrato: "Vibrato"
        case .bowBite: "Bow bite"
        case .legatoTransition: "Legato transition"
        case .bowPressure: "Bow pressure"
        case .body: "Body resonance"
        case .ensemble: "Ensemble width"
        case .volume: "Master volume"
        case .bowTravel: "Bow stroke position"
        case .tuning: "Master tuning"
        case .bowSpeed: "Bow speed"
        }
    }

    var range: ClosedRange<Float> { self == .tuning ? 430...450 : 0...100 }

    var defaultValue: Float {
        switch self {
        case .expression, .vibrato, .body, .ensemble, .volume: 100
        case .tuning: 440
        default: 50
        }
    }

    var preferencesKey: String { "performance." + identifier }

    func clamped(_ value: Float) -> Float {
        guard value.isFinite else { return defaultValue }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}

/// Allocated once per instrument. UI and host writes do not lock the render thread.
final class PerformanceSettings: Sendable {
    private final class Slot: Sendable {
        let value: Atomic<Float>
        init(_ value: Float) { self.value = Atomic(value) }
    }
    private let slots = PerformanceParameter.allCases.map { Slot($0.defaultValue) }

    subscript(parameter: PerformanceParameter) -> Float {
        get { slots[Int(parameter.rawValue)].value.load(ordering: .relaxed) }
        set { slots[Int(parameter.rawValue)].value.store(parameter.clamped(newValue), ordering: .relaxed) }
    }

    func apply(to model: StringsModel) {
        for parameter in PerformanceParameter.allCases {
            model.setPerformance(parameter, value: self[parameter])
        }
    }
}
