//! A sample-free string section with independent tuning and vibrato per desk.
use std::f32::consts::TAU;

const VOICES: usize = 32;
const PARTIALS: usize = 12;
const DETUNE: [f32; 3] = [0.9968, 1.0, 1.0036];
const PAN: [[f32; 2]; 3] = [[0.82, 0.29], [0.60, 0.60], [0.29, 0.82]];
const VIBRATO_HZ: [f32; 3] = [4.7, 5.3, 5.9];

#[derive(Clone, Copy, PartialEq)]
enum Gate {
    Held,
    Pedal,
    Released,
}

#[derive(Clone, Copy)]
struct Voice {
    note: u32,
    gate: Gate,
    pizzicato: bool,
    level: f32,
    peak: f32,
    frequency: f32,
    phase: [f32; 3],
    vibrato: [f32; 3],
    weights: [f32; PARTIALS],
    partials: usize,
    attack: f32,
    pluck_decay: f32,
    age: f32,
    bow_noise: f32,
}

impl Voice {
    const SILENT: Self = Self {
        note: 0,
        gate: Gate::Released,
        pizzicato: false,
        level: 0.0,
        peak: 0.0,
        frequency: 0.0,
        phase: [0.0; 3],
        vibrato: [0.0; 3],
        weights: [0.0; PARTIALS],
        partials: 0,
        attack: 0.0,
        pluck_decay: 0.0,
        age: 0.0,
        bow_noise: 0.0,
    };

    fn new(note: u32, velocity: f32, pizzicato: bool, rate: f32) -> Self {
        let frequency = 440.0 * 2.0_f32.powf((note as f32 - 69.0) / 12.0);
        let mut voice = Self {
            note,
            pizzicato,
            gate: Gate::Held,
            peak: (0.19 + 0.81 * velocity.sqrt()) * if pizzicato { 0.19 } else { 0.145 },
            frequency,
            phase: [0.0, 0.21, 0.47],
            vibrato: [0.0, 0.29, 0.64],
            attack: smoothing(
                rate,
                if pizzicato {
                    0.003
                } else {
                    0.11 - 0.084 * velocity
                },
            ),
            pluck_decay: smoothing(rate, 0.38 - 0.20 * note as f32 / 127.0),
            ..Self::SILENT
        };
        for (index, weight) in voice.weights.iter_mut().enumerate() {
            let harmonic = (index + 1) as f32;
            let hz = frequency * harmonic;
            if hz >= rate * 0.46 {
                break;
            }
            let wood = 1.0 + 0.66 / (1.0 + ((hz - 510.0) / 290.0).powi(2));
            let bridge = 1.0 + 0.44 / (1.0 + ((hz - 2450.0) / 860.0).powi(2));
            let excitation = if pizzicato {
                (harmonic * 0.17 * std::f32::consts::PI).sin() / harmonic.powf(1.15)
            } else {
                (0.7 + 0.3 * velocity).powf(harmonic - 1.0) / harmonic.powf(0.92)
            };
            *weight = excitation * wood * bridge;
            voice.partials += 1;
        }
        voice
    }

    fn active(&self) -> bool {
        self.gate == Gate::Held || self.gate == Gate::Pedal || self.level > 0.000015
    }

    fn sample(
        &mut self,
        inverse_rate: f32,
        brightness: f32,
        fast_release: f32,
        noise: f32,
    ) -> [f32; 2] {
        self.age += inverse_rate;
        if self.gate == Gate::Released {
            self.level *= fast_release;
        } else if self.pizzicato {
            // Plucking supplies a brief excitation followed by passive decay.
            let target = if self.age < 0.009 { self.peak } else { 0.0 };
            self.level += (target - self.level)
                * if target > 0.0 {
                    self.attack
                } else {
                    self.pluck_decay
                };
            if self.age > 0.009 && self.level <= 0.000015 {
                self.gate = Gate::Released;
            }
        } else {
            self.level += (self.peak - self.level) * self.attack;
        }

        let tilt = 0.67 + 0.31 * brightness;
        let vibrato_depth = ((self.age - 0.045) * 4.0).clamp(0.0, 1.0) * 0.0034;
        let mut out = [0.0; 2];
        let desks = if self.pizzicato { 1..2 } else { 0..3 };
        for desk in desks {
            let modulation = if self.pizzicato {
                0.0
            } else {
                (self.vibrato[desk] * TAU).sin() * vibrato_depth
            };
            let (sine, cosine) = (self.phase[desk] * TAU).sin_cos();
            let (mut partial_sine, mut partial_cosine) = (sine, cosine);
            let mut amplitude = 1.0;
            let mut signal = 0.0;
            for weight in &self.weights[..self.partials] {
                signal += partial_sine * weight * amplitude;
                (partial_sine, partial_cosine) = (
                    partial_sine * cosine + partial_cosine * sine,
                    partial_cosine * cosine - partial_sine * sine,
                );
                amplitude *= tilt;
            }
            self.phase[desk] += self.frequency * DETUNE[desk] * (1.0 + modulation) * inverse_rate;
            self.phase[desk] -= self.phase[desk].trunc();
            self.vibrato[desk] += VIBRATO_HZ[desk] * inverse_rate;
            self.vibrato[desk] -= self.vibrato[desk].trunc();
            out[0] += signal * PAN[desk][0];
            out[1] += signal * PAN[desk][1];
        }
        let air = if self.pizzicato {
            noise * 0.095 * (1.0 - 35.0 * self.age).max(0.0)
        } else {
            self.bow_noise += (noise - self.bow_noise) * (4000.0 * inverse_rate);
            (noise - self.bow_noise) * (0.025 + 0.035 * brightness)
        };
        let scale = self.level * if self.pizzicato { 1.25 } else { 0.56 };
        [(out[0] + air) * scale, (out[1] + air) * scale]
    }
}

fn smoothing(rate: f32, seconds: f32) -> f32 {
    1.0 - (-1.0 / (rate * seconds)).exp()
}

struct Delay {
    samples: Vec<f32>,
    index: usize,
    filtered: f32,
}

impl Delay {
    fn new(rate: f32, seconds: f32) -> Self {
        Self {
            samples: vec![0.0; (rate * seconds).round() as usize],
            index: 0,
            filtered: 0.0,
        }
    }

    fn tap(&mut self, damping: f32) -> f32 {
        self.filtered += (self.samples[self.index] - self.filtered) * damping;
        self.filtered
    }

    fn push(&mut self, sample: f32) {
        self.samples[self.index] = sample;
        self.index += 1;
        if self.index == self.samples.len() {
            self.index = 0;
        }
    }

    fn clear(&mut self) {
        self.samples.fill(0.0);
        self.filtered = 0.0;
        self.index = 0;
    }
}

pub struct StringsDSP {
    voices: [Voice; VOICES],
    rate: f32,
    sustain: bool,
    brightness: f32,
    brightness_target: f32,
    reverb: f32,
    reverb_target: f32,
    expression: f32,
    expression_target: f32,
    control_smoothing: f32,
    fast_release: f32,
    room_damping: f32,
    room: [Delay; 4],
    noise: u32,
}

impl StringsDSP {
    fn new(rate: f64) -> Self {
        let rate = if rate.is_finite() {
            rate.clamp(44_100.0, 96_000.0) as f32
        } else {
            44_100.0
        };
        Self {
            voices: [Voice::SILENT; VOICES],
            rate,
            sustain: false,
            brightness: 0.45,
            brightness_target: 0.45,
            reverb: 0.30,
            reverb_target: 0.30,
            expression: 1.0,
            expression_target: 1.0,
            control_smoothing: smoothing(rate, 0.018),
            fast_release: 1.0 - smoothing(rate, 0.009),
            room_damping: smoothing(rate, 0.00013),
            room: [0.0271, 0.0337, 0.0419, 0.0533].map(|seconds| Delay::new(rate, seconds)),
            noise: 0x792a_641b,
        }
    }

    fn note_on(&mut self, note: u32, velocity: f32, pizzicato: bool) {
        if note > 127 || !velocity.is_finite() || velocity <= 0.0 {
            return;
        }
        let available = self.voices.iter().position(|voice| !voice.active());
        for voice in &mut self.voices {
            if voice.active() && voice.note == note && (!voice.pizzicato || !pizzicato) {
                voice.gate = Gate::Released;
            }
        }
        let slot = available.unwrap_or_else(|| {
            self.voices
                .iter()
                .enumerate()
                .min_by(|(_, a), (_, b)| {
                    let priority = |voice: &Voice| {
                        voice.level
                            + if !voice.pizzicato && voice.gate == Gate::Held {
                                1.0
                            } else {
                                0.0
                            }
                    };
                    priority(a).total_cmp(&priority(b))
                })
                .unwrap()
                .0
        });
        self.voices[slot] = Voice::new(note, velocity.min(1.0), pizzicato, self.rate);
    }

    fn note_off(&mut self, note: u32) {
        for voice in &mut self.voices {
            if voice.note == note && voice.gate == Gate::Held {
                voice.gate = if self.sustain {
                    Gate::Pedal
                } else {
                    Gate::Released
                };
            }
        }
    }

    fn sustain(&mut self, amount: f32) {
        self.sustain = amount >= 0.5;
        if !self.sustain {
            for voice in &mut self.voices {
                if voice.gate == Gate::Pedal {
                    voice.gate = Gate::Released;
                }
            }
        }
    }

    fn all_off(&mut self) {
        self.sustain = false;
        self.expression_target = 1.0;
        self.voices.fill(Voice::SILENT);
        for delay in &mut self.room {
            delay.clear();
        }
    }

    fn render_frame(&mut self) -> [f32; 2] {
        self.brightness += (self.brightness_target - self.brightness) * self.control_smoothing;
        self.reverb += (self.reverb_target - self.reverb) * self.control_smoothing;
        self.expression += (self.expression_target - self.expression) * self.control_smoothing;

        let mut mix = [0.0; 2];
        let inverse_rate = self.rate.recip();
        for voice in &mut self.voices {
            if voice.active() {
                self.noise ^= self.noise << 13;
                self.noise ^= self.noise >> 17;
                self.noise ^= self.noise << 5;
                let noise = self.noise as i32 as f32 * (1.0 / 2_147_483_648.0);
                let [left, right] =
                    voice.sample(inverse_rate, self.brightness, self.fast_release, noise);
                let gain = if voice.pizzicato {
                    self.expression
                } else {
                    self.expression.powi(2)
                };
                mix[0] += left * gain;
                mix[1] += right * gain;
            }
        }

        let [a, b, c, d] = self
            .room
            .each_mut()
            .map(|delay| delay.tap(self.room_damping));
        let [left, right] = mix;
        self.room[0].push(left + (a + b + c + d) * 0.34);
        self.room[1].push(right + (a - b + c - d) * 0.34);
        self.room[2].push(left + (a + b - c - d) * 0.34);
        self.room[3].push(right + (a - b - c + d) * 0.34);
        let wet = self.reverb * 0.26;
        let limit = |sample: f32| sample / (1.0 + 0.65 * sample.abs());
        [limit(left + (a + d) * wet), limit(right + (b + c) * wet)]
    }
}

#[no_mangle]
pub extern "C" fn strings_dsp_create(rate: f64) -> *mut StringsDSP {
    Box::into_raw(Box::new(StringsDSP::new(rate)))
}

// The Swift owner keeps one live, exclusively accessed handle per render callback.
#[no_mangle]
pub unsafe extern "C" fn strings_dsp_destroy(dsp: *mut StringsDSP) {
    drop(Box::from_raw(dsp));
}

#[no_mangle]
pub unsafe extern "C" fn strings_dsp_note_on(
    dsp: *mut StringsDSP,
    note: u32,
    velocity: f32,
    pizzicato: bool,
) {
    (*dsp).note_on(note, velocity, pizzicato);
}

#[no_mangle]
pub unsafe extern "C" fn strings_dsp_note_off(dsp: *mut StringsDSP, note: u32) {
    (*dsp).note_off(note);
}

#[no_mangle]
pub unsafe extern "C" fn strings_dsp_sustain(dsp: *mut StringsDSP, amount: f32) {
    (*dsp).sustain(amount);
}

#[no_mangle]
pub unsafe extern "C" fn strings_dsp_all_off(dsp: *mut StringsDSP) {
    (*dsp).all_off();
}

#[no_mangle]
pub unsafe extern "C" fn strings_dsp_set_brightness(dsp: *mut StringsDSP, amount: f32) {
    (*dsp).brightness_target = amount.clamp(0.0, 1.0);
}

#[no_mangle]
pub unsafe extern "C" fn strings_dsp_set_reverb(dsp: *mut StringsDSP, amount: f32) {
    (*dsp).reverb_target = amount.clamp(0.0, 1.0);
}

#[no_mangle]
pub unsafe extern "C" fn strings_dsp_set_expression(dsp: *mut StringsDSP, amount: f32) {
    (*dsp).expression_target = amount.clamp(0.0, 1.0);
}

#[no_mangle]
pub unsafe extern "C" fn strings_dsp_render(
    dsp: *mut StringsDSP,
    left: *mut f32,
    right: *mut f32,
    frames: u32,
) {
    let dsp = &mut *dsp;
    for frame in 0..frames as usize {
        let [l, r] = dsp.render_frame();
        left.add(frame).write(l);
        right.add(frame).write(r);
    }
}
