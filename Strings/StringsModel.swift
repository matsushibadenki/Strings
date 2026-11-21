/// Owns one instance of the strings DSP. Events and rendering run on
/// the same Core Audio callback, after construction on the audio worker.
final class StringsModel {
    private let handle: OpaquePointer

    init(sampleRate: Double) {
        handle = strings_dsp_create(sampleRate)
    }

    deinit {
        strings_dsp_destroy(handle)
    }

    func noteOn(_ note: Int, velocity: Float, pizzicato: Bool = false) {
        strings_dsp_note_on(handle, UInt32(note), velocity, pizzicato)
    }

    func noteOff(_ note: Int) {
        strings_dsp_note_off(handle, UInt32(note))
    }

    func sustain(_ value: Float) {
        strings_dsp_sustain(handle, value)
    }

    func releaseAll() {
        strings_dsp_all_off(handle)
    }

    func setBrightness(_ amount: Float) {
        strings_dsp_set_brightness(handle, amount)
    }

    func setExpression(_ amount: Float) {
        strings_dsp_set_expression(handle, amount)
    }

    func setReverb(_ amount: Float) {
        strings_dsp_set_reverb(handle, amount)
    }

    func render(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, frames: UInt32) {
        strings_dsp_render(handle, left, right, frames)
    }
}
