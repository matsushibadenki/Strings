//! A sample-free string section with independent tuning and vibrato per desk.
use std::f32::consts::TAU;

mod body;
mod waveguide;
use body::BodyResonance;
use waveguide::Waveguide;

const VOICES: usize = 32;
const PARTIALS: usize = 12;
const BOW_POSITIONS: usize = 33;
const DETUNE: [f32; 3] = [0.9968, 1.0, 1.0036];
const PAN: [[f32; 2]; 3] = [[0.82, 0.29], [0.60, 0.60], [0.29, 0.82]];
const VIBRATO_HZ: [f32; 3] = [4.7, 5.3, 5.9];
const VIBRATO_DEPTH: [f32; 3] = [0.0027, 0.0038, 0.0031];
const BOW_ENTRY_SECONDS: [f32; 3] = [0.004, 0.0, 0.009];

// Matches the order of PerformanceParameter in Swift.
const PERFORMANCE_DEFAULTS: [f32; 11] = [1.0, 1.0, 0.5, 0.5, 0.5, 1.0, 1.0, 1.0, 0.5, 0.5, 0.5];

struct BowPerformance {
    vibrato: f32,
    bite: f32,
    pressure: f32,
    spread: f32,
    travel: f32,
    tuning_ratio: f32,
}

#[derive(Clone, Copy, PartialEq)]
enum Gate {
    Held,
    Pedal,
    Released,
}

#[derive(Clone, Copy, PartialEq)]
enum Articulation {
    Bowed,
    Pizzicato,
    Spiccato,
}

#[derive(Clone, Copy)]
struct Voice {
    note: u32,
    gate: Gate,
    articulation: Articulation,
    level: f32,
    peak: f32,
    frequency: f32,
    target_frequency: f32,
    glide_step: f32,
    glide_frames: u32,
    phase: [f32; 3],
    vibrato: [f32; 3],
    variation: f32,
    excitation: [f32; PARTIALS],
    weights: [f32; PARTIALS],
    partials: usize,
    last_partial_gain: f32,
    attack: f32,
    natural_decay: f32,
    contact_time: f32,
    impact: f32,
    age: f32,
    friction_low: f32,
    friction_high: f32,
}

impl Voice {
    const SILENT: Self = Self {
        note: 0,
        gate: Gate::Released,
        articulation: Articulation::Bowed,
        level: 0.0,
        peak: 0.0,
        frequency: 0.0,
        target_frequency: 0.0,
        glide_step: 0.0,
        glide_frames: 0,
        phase: [0.0; 3],
        vibrato: [0.0; 3],
        variation: 0.0,
        excitation: [0.0; PARTIALS],
        weights: [0.0; PARTIALS],
        partials: 0,
        last_partial_gain: 0.0,
        attack: 0.0,
        natural_decay: 0.0,
        contact_time: 0.0,
        impact: 0.0,
        age: 0.0,
        friction_low: 0.0,
        friction_high: 0.0,
    };

    fn new(
        note: u32,
        velocity: f32,
        articulation: Articulation,
        rate: f32,
        variation: f32,
    ) -> Self {
        let frequency = note_frequency(note);
        let (peak, attack, natural_decay, contact_time) = match articulation {
            Articulation::Bowed => (
                0.145,
                (0.085 - 0.061 * velocity) * (1.0 + 0.14 * variation),
                0.0,
                0.0,
            ),
            Articulation::Pizzicato => (0.19, 0.003, 0.38 - 0.20 * note as f32 / 127.0, 0.009),
            Articulation::Spiccato => (
                0.10 + 0.095 * velocity,
                0.0055 - 0.0032 * velocity,
                0.012 + 0.014 * velocity,
                (0.015 + 0.026 * velocity) * (1.0 + 0.055 * variation),
            ),
        };
        let mut voice = Self {
            note,
            articulation,
            gate: Gate::Held,
            peak: (0.19 + 0.81 * velocity.sqrt()) * peak,
            frequency,
            target_frequency: frequency,
            phase: [0.0, 0.21, 0.47],
            vibrato: [
                0.16 + 0.13 * variation,
                0.39 - 0.17 * variation,
                0.75 + 0.18 * variation,
            ],
            variation,
            attack: smoothing(rate, attack),
            natural_decay: if natural_decay > 0.0 {
                smoothing(rate, natural_decay)
            } else {
                0.0
            },
            contact_time,
            impact: 0.28 + 0.82 * velocity,
            ..Self::SILENT
        };
        for (index, excitation) in voice.excitation.iter_mut().enumerate() {
            let harmonic = (index + 1) as f32;
            *excitation = if articulation == Articulation::Pizzicato {
                let position = 0.17 + 0.023 * variation;
                (harmonic * position * std::f32::consts::PI).sin() / harmonic.powf(1.15)
            } else {
                let phase = if index % 2 == 0 { 1.0 } else { -1.0 };
                phase * (0.83 + 0.17 * velocity).powf(harmonic - 1.0) / harmonic.powf(0.84)
            };
        }
        voice.update_harmonics(rate);
        voice
    }

    fn update_harmonics(&mut self, rate: f32) {
        self.partials = partial_count(self.frequency, rate);
        for index in 0..self.partials {
            let hz = self.frequency * (index + 1) as f32;
            let bridge = 1.0 + 0.32 / (1.0 + ((hz - 2550.0) / 900.0).powi(2));
            self.weights[index] = self.excitation[index] * bridge;
        }
        // Fade the final partial before it crosses the cutoff during a glide.
        let highest = self.frequency * self.partials as f32 / rate;
        let fade = ((0.46 - highest) / 0.03).clamp(0.0, 1.0);
        self.last_partial_gain = fade * fade * (3.0 - 2.0 * fade);
    }

    fn retune(&mut self, note: u32, rate: f32, transition: f32) {
        self.note = note;
        self.target_frequency = note_frequency(note);
        self.glide_frames = (rate * (0.004 + 0.048 * transition * transition)).round() as u32;
        self.glide_step = (self.target_frequency - self.frequency) / self.glide_frames as f32;
    }

    fn sample_waveguide(
        &mut self,
        guide: &mut Waveguide,
        rate: f32,
        fast_release: f32,
        brightness: f32,
        speed: f32,
        contact: f32,
        performance: &BowPerformance,
    ) -> [f32; 2] {
        let inverse_rate = rate.recip();
        self.age += inverse_rate;
        let driving = self.gate != Gate::Released;
        if driving {
            self.level += (self.peak - self.level) * self.attack;
        } else {
            self.level *= fast_release;
        }
        let vibrato = (self.vibrato[1] * TAU).sin();
        self.vibrato[1] += VIBRATO_HZ[1] * inverse_rate;
        self.vibrato[1] -= self.vibrato[1].trunc();
        let vibrato_entry = ((self.age - 0.065) * 3.3).clamp(0.0, 1.0);
        let modulation = 1.0 + vibrato * vibrato_entry * VIBRATO_DEPTH[1] * performance.vibrato;
        let frequency = self.frequency * performance.tuning_ratio * modulation;
        let acceleration = 1.0 + (self.age * 75.0).min(1.0) * (1.0 + performance.bite) * 3.0;
        let bow_velocity = if driving {
            (0.72 * speed) * (1.0 - acceleration.recip()) * (0.85 + 0.30 * self.impact)
        } else {
            0.0
        };
        let pressure = if driving { performance.pressure } else { 0.0 };
        let signal = guide.sample(
            rate / frequency,
            contact,
            bow_velocity,
            pressure,
            brightness,
            inverse_rate,
        );
        let out = signal * self.level * 1.35;
        [out, out]
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
        bow: &[f32; PARTIALS],
        performance: &BowPerformance,
    ) -> [f32; 2] {
        self.age += inverse_rate;
        let pizzicato = self.articulation == Articulation::Pizzicato;
        let spiccato = self.articulation == Articulation::Spiccato;
        if self.glide_frames > 0 {
            self.glide_frames -= 1;
            self.frequency = if self.glide_frames == 0 {
                self.target_frequency
            } else {
                self.frequency + self.glide_step
            };
            self.update_harmonics(inverse_rate.recip());
        }
        if self.gate == Gate::Released {
            self.level *= fast_release;
        } else if self.articulation != Articulation::Bowed {
            if self.age < self.contact_time {
                let progress = self.age / self.contact_time;
                let pressure = if spiccato {
                    1.0 - 0.73 * progress * progress
                } else {
                    1.0
                };
                self.level += (self.peak * pressure - self.level) * self.attack;
            } else {
                self.level *= 1.0 - self.natural_decay;
                if self.level <= 0.000015 {
                    self.gate = Gate::Released;
                }
            }
        } else {
            self.level += (self.peak - self.level) * self.attack;
        }

        let onset = (1.0 - self.age * 22.0).max(0.0);
        let tilt = if pizzicato {
            0.65 + 0.30 * brightness + 0.10 * (1.0 - self.age * 6.0).max(0.0)
        } else if spiccato {
            let contact = (1.0 - self.age / self.contact_time).max(0.0);
            0.66 + 0.23 * brightness + 0.08 * self.impact * contact
        } else {
            0.67 + 0.29 * brightness - 0.07 * onset
        };
        let vibrato_entry = ((self.age - 0.065) * 3.3).clamp(0.0, 1.0);
        let tilt = if pizzicato {
            tilt
        } else {
            (tilt
                + 0.14 * (performance.pressure - 0.5)
                + 0.06 * (0.5 - performance.travel)
                + 0.12 * (performance.bite - 0.5) * onset)
                .clamp(0.35, 1.0)
        };
        let mut amplitudes = [0.0; PARTIALS];
        let mut falloff = 1.0;
        for index in 0..self.partials {
            let contact = if pizzicato { 1.0 } else { bow[index] };
            amplitudes[index] = self.weights[index] * contact * falloff;
            falloff *= tilt;
        }
        if self.partials > 0 {
            amplitudes[self.partials - 1] *= self.last_partial_gain;
        }
        let mut out = [0.0; 2];
        let desks = if pizzicato { 1..2 } else { 0..3 };
        for desk in desks {
            let vibrato = if pizzicato || spiccato {
                0.0
            } else {
                (self.vibrato[desk] * TAU).sin()
            };
            let modulation = vibrato * vibrato_entry * VIBRATO_DEPTH[desk] * performance.vibrato;
            let (sine, cosine) = (self.phase[desk] * TAU).sin_cos();
            let (mut partial_sine, mut partial_cosine) = (sine, cosine);
            let mut signal = 0.0;
            for amplitude in &amplitudes[..self.partials] {
                signal += partial_sine * amplitude;
                (partial_sine, partial_cosine) = (
                    partial_sine * cosine + partial_cosine * sine,
                    partial_cosine * cosine - partial_sine * sine,
                );
            }
            let detune = 1.0 + (DETUNE[desk] - 1.0) * performance.spread;
            self.phase[desk] += self.frequency
                * performance.tuning_ratio
                * detune
                * (1.0 + modulation)
                * inverse_rate;
            self.phase[desk] -= self.phase[desk].trunc();
            if spiccato {
                let delay = 0.35 * BOW_ENTRY_SECONDS[desk];
                signal *= ((self.age - delay) * 350.0).clamp(0.0, 1.0);
            } else if !pizzicato {
                self.vibrato[desk] += (VIBRATO_HZ[desk] + 0.32 * self.variation) * inverse_rate;
                self.vibrato[desk] -= self.vibrato[desk].trunc();
                let delay = BOW_ENTRY_SECONDS[desk] * (1.0 + 0.32 * self.variation);
                let entry = ((self.age - delay) * 70.0).clamp(0.0, 1.0);
                signal *= entry * (1.0 + 0.041 * vibrato * vibrato_entry);
            }
            let [left, right] = PAN[desk];
            let center = (left + right) * 0.5;
            out[0] += signal * (center + (left - center) * performance.spread);
            out[1] += signal * (center + (right - center) * performance.spread);
        }
        // The broadband scrape is strongest before the bow has settled.
        self.friction_low += (noise - self.friction_low) * (4400.0 * inverse_rate);
        self.friction_high += (noise - self.friction_high) * (25_000.0 * inverse_rate);
        let friction = self.friction_high - self.friction_low;
        let air = if pizzicato {
            friction * 0.34 * (1.0 - 70.0 * self.age).max(0.0)
        } else if spiccato {
            let impact = (1.0 - self.age * 85.0).max(0.0);
            friction * self.impact * impact
        } else {
            friction * (0.044 + 0.048 * brightness + 0.55 * onset * onset)
        };
        let air = if pizzicato {
            air
        } else {
            air * (0.30 + 1.40 * performance.bite)
                * (0.75 + 0.50 * performance.pressure)
                * (1.20 - 0.40 * performance.travel)
        };
        let scale = self.level * if pizzicato { 1.44 } else { 0.64 };
        [(out[0] + air) * scale, (out[1] + air) * scale]
    }
}

fn note_frequency(note: u32) -> f32 {
    440.0 * 2.0_f32.powf((note as f32 - 69.0) / 12.0)
}

fn partial_count(frequency: f32, rate: f32) -> usize {
    ((rate * 0.46 / frequency) as usize).min(PARTIALS)
}

fn bow_response(position: f32) -> [f32; PARTIALS] {
    // Distance from the bridge, as a fraction of the vibrating length.
    let contact = 0.30 - 0.265 * position;
    std::array::from_fn(|index| {
        let angle = (index + 1) as f32 * std::f32::consts::PI * contact;
        0.35 + 0.65 * angle.sin() / angle
    })
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
    waveguides: [Waveguide; VOICES],
    waveguide_enabled: bool,
    rate: f32,
    sustain: bool,
    legato: bool,
    spiccato: bool,
    legato_voice: Option<usize>,
    legato_keys: [u8; 128],
    legato_count: usize,
    bow_position: f32,
    bow_target: f32,
    bow_table: [[f32; PARTIALS]; BOW_POSITIONS],
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
    body: BodyResonance,
    performance: [f32; PERFORMANCE_DEFAULTS.len()],
    performance_targets: [f32; PERFORMANCE_DEFAULTS.len()],
    strike: u32,
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
            waveguides: {
                let minimum_pitch = note_frequency(0) * 430.0 / 440.0 * 0.995;
                let length = ((rate / minimum_pitch).ceil() as usize + 2).next_power_of_two();
                std::array::from_fn(|_| Waveguide::new(length))
            },
            waveguide_enabled: false,
            rate,
            sustain: false,
            legato: false,
            spiccato: false,
            legato_voice: None,
            legato_keys: [0; 128],
            legato_count: 0,
            bow_position: 0.75,
            bow_target: 0.75,
            bow_table: std::array::from_fn(|index| {
                bow_response(index as f32 / (BOW_POSITIONS - 1) as f32)
            }),

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
            body: BodyResonance::new(rate),
            performance: PERFORMANCE_DEFAULTS,
            performance_targets: PERFORMANCE_DEFAULTS,
            strike: 0,
            noise: 0x792a_641b,
        }
    }

    fn note_on(&mut self, note: u32, velocity: f32, pizzicato: bool) {
        if note > 127 || !velocity.is_finite() || velocity <= 0.0 {
            return;
        }
        let articulation = if pizzicato {
            Articulation::Pizzicato
        } else if self.spiccato {
            Articulation::Spiccato
        } else {
            Articulation::Bowed
        };
        let is_legato = self.legato && articulation == Articulation::Bowed;
        if is_legato {
            self.remove_legato_key(note);
            self.legato_keys[self.legato_count] = note as u8;
            self.legato_count += 1;
            if let Some(slot) = self.legato_voice {
                self.voices[slot].retune(note, self.rate, self.performance_targets[3]);
                return;
            }
        }
        let available = self.voices.iter().position(|voice| !voice.active());
        for (index, voice) in self.voices.iter_mut().enumerate() {
            if self.legato_voice != Some(index)
                && voice.active()
                && voice.note == note
                && (voice.articulation == Articulation::Bowed || voice.articulation != articulation)
            {
                voice.gate = Gate::Released;
            }
        }
        let slot = available.unwrap_or_else(|| {
            self.voices
                .iter()
                .enumerate()
                .filter(|(index, _)| self.legato_voice != Some(*index))
                .min_by(|(_, a), (_, b)| {
                    let priority = |voice: &Voice| {
                        voice.level
                            + if voice.articulation == Articulation::Bowed
                                && voice.gate == Gate::Held
                            {
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
        if is_legato {
            self.legato_voice = Some(slot);
        }
        self.strike = self.strike.wrapping_add(1);
        let seed = self.strike.wrapping_mul(0x9e37_79b9) ^ note.wrapping_mul(0x85eb_ca6b);
        let variation = ((seed >> 16) as f32 / 32767.5) - 1.0;
        self.voices[slot] = Voice::new(note, velocity.min(1.0), articulation, self.rate, variation);
        self.waveguides[slot]
            .start(self.waveguide_enabled && articulation == Articulation::Bowed && !is_legato);
    }

    fn remove_legato_key(&mut self, note: u32) {
        let keys = &mut self.legato_keys[..self.legato_count];
        if let Some(index) = keys.iter().position(|key| u32::from(*key) == note) {
            keys.copy_within(index + 1.., index);
            self.legato_count -= 1;
        }
    }

    fn set_legato(&mut self, enabled: bool) {
        if self.legato != enabled {
            self.legato = enabled;
            self.legato_voice = None;
            self.legato_count = 0;
        }
    }

    fn set_spiccato(&mut self, enabled: bool) {
        if self.spiccato != enabled {
            self.spiccato = enabled;
            self.legato_voice = None;
            self.legato_count = 0;
        }
    }

    fn note_off(&mut self, note: u32) {
        self.remove_legato_key(note);
        if let Some(slot) = self.legato_voice {
            if self.voices[slot].note == note {
                if let Some(previous) = self.legato_keys[..self.legato_count].last() {
                    self.voices[slot].retune(
                        u32::from(*previous),
                        self.rate,
                        self.performance_targets[3],
                    );
                } else {
                    self.legato_voice = None;
                }
            }
        }
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
        self.legato_voice = None;
        self.legato_count = 0;
        self.expression_target = 1.0;
        self.voices.fill(Voice::SILENT);
        for delay in &mut self.room {
            delay.clear();
        }
        self.body.clear();
    }

    fn render_frame(&mut self) -> [f32; 2] {
        self.brightness += (self.brightness_target - self.brightness) * self.control_smoothing;
        self.reverb += (self.reverb_target - self.reverb) * self.control_smoothing;
        self.expression += (self.expression_target - self.expression) * self.control_smoothing;

        self.bow_position += (self.bow_target - self.bow_position) * self.control_smoothing;
        let lookup = self.bow_position * (BOW_POSITIONS - 1) as f32;
        let index = (lookup as usize).min(BOW_POSITIONS - 2);
        let fraction = lookup - index as f32;
        let bow = std::array::from_fn(|partial| {
            let a = self.bow_table[index][partial];
            a + (self.bow_table[index + 1][partial] - a) * fraction
        });

        for (value, target) in self.performance.iter_mut().zip(self.performance_targets) {
            *value += (target - *value) * self.control_smoothing;
        }
        let [expression, vibrato, bite, _, pressure, body_mix, spread, volume, travel, tuning, speed] =
            self.performance;
        let performance = BowPerformance {
            vibrato,
            bite,
            pressure,
            spread,
            travel,
            tuning_ratio: (430.0 + 20.0 * tuning) / 440.0,
        };

        let mut mix = [0.0; 2];
        let mut body_inputs = [[0.0; 2]; 3];
        let inverse_rate = self.rate.recip();
        let expression = expression * self.expression;
        let bow_gain = expression * expression;
        let bow_brightness = self.brightness * (0.68 + 0.32 * expression);
        let contact = 0.30 - 0.265 * self.bow_position;
        for (voice, guide) in self.voices.iter_mut().zip(&mut self.waveguides) {
            if voice.active() {
                self.noise ^= self.noise << 13;
                self.noise ^= self.noise >> 17;
                self.noise ^= self.noise << 5;
                let noise = self.noise as i32 as f32 * (1.0 / 2_147_483_648.0);
                let (brightness, gain) = if voice.articulation == Articulation::Pizzicato {
                    (self.brightness, expression)
                } else {
                    (bow_brightness, bow_gain)
                };
                let [left, right] = if guide.active {
                    voice.sample_waveguide(
                        guide,
                        self.rate,
                        self.fast_release,
                        brightness,
                        speed,
                        contact,
                        &performance,
                    )
                } else {
                    voice.sample(
                        inverse_rate,
                        brightness,
                        self.fast_release,
                        noise,
                        &bow,
                        &performance,
                    )
                };
                let [left, right] = [left * gain, right * gain];
                mix[0] += left;
                mix[1] += right;
                // Use the live frequency after stepping any legato pitch glide.
                let weights = BodyResonance::weights(voice.frequency * performance.tuning_ratio);
                for (input, weight) in body_inputs.iter_mut().zip(weights) {
                    input[0] += left * weight;
                    input[1] += right * weight;
                }
            }
        }

        let [a, b, c, d] = self
            .room
            .each_mut()
            .map(|delay| delay.tap(self.room_damping));
        for (direct, body) in mix.iter_mut().zip(self.body.render(body_inputs)) {
            *direct += body * body_mix;
        }
        let [left, right] = mix;
        self.room[0].push(left + (a + b + c + d) * 0.34);
        self.room[1].push(right + (a - b + c - d) * 0.34);
        self.room[2].push(left + (a + b - c - d) * 0.34);
        self.room[3].push(right + (a - b - c + d) * 0.34);
        let wet = self.reverb * 0.26;
        let limit = |sample: f32| sample / (1.0 + 0.65 * sample.abs());
        [
            limit(left + (a + d) * wet) * volume,
            limit(right + (b + c) * wet) * volume,
        ]
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
pub unsafe extern "C" fn strings_dsp_set_legato(dsp: *mut StringsDSP, enabled: bool) {
    (*dsp).set_legato(enabled);
}

#[no_mangle]
pub unsafe extern "C" fn strings_dsp_set_spiccato(dsp: *mut StringsDSP, enabled: bool) {
    (*dsp).set_spiccato(enabled);
}

#[no_mangle]
pub unsafe extern "C" fn strings_dsp_set_waveguide(dsp: *mut StringsDSP, enabled: bool) {
    (*dsp).waveguide_enabled = enabled;
}

#[no_mangle]
pub unsafe extern "C" fn strings_dsp_set_bow_position(dsp: *mut StringsDSP, position: f32) {
    if position.is_finite() {
        (*dsp).bow_target = position.clamp(0.0, 1.0);
    }
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
pub unsafe extern "C" fn strings_dsp_set_performance(dsp: *mut StringsDSP, index: u32, value: f32) {
    if value.is_finite() {
        if let Some(target) = (*dsp).performance_targets.get_mut(index as usize) {
            *target = value.clamp(0.0, 1.0);
        }
    }
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legato_retunes_the_live_voice_and_returns_to_the_previous_key() {
        let mut dsp = StringsDSP::new(48_000.0);
        dsp.set_legato(true);
        dsp.note_on(60, 0.75, false);
        for _ in 0..4800 {
            dsp.render_frame();
        }
        let slot = dsp.legato_voice.unwrap();
        let original = dsp.voices[slot];
        dsp.note_on(64, 0.75, false);
        let voice = dsp.voices[slot];
        assert_eq!(dsp.voices.iter().filter(|v| v.active()).count(), 1);
        assert_eq!(voice.age, original.age);
        assert_eq!(voice.phase, original.phase);
        assert_eq!(voice.level, original.level);
        assert_eq!(voice.frequency, original.frequency);
        for _ in 0..768 {
            dsp.render_frame();
        }
        assert_eq!(dsp.voices[slot].frequency, note_frequency(64));

        dsp.note_off(64);
        assert_eq!(dsp.voices[slot].note, 60);
        assert!(dsp.voices[slot].gate == Gate::Held);
        dsp.note_off(60);
        assert!(dsp.legato_voice.is_none());
        dsp.note_on(67, 0.7, false);
        let fresh = dsp.voices[dsp.legato_voice.unwrap()];
        assert_eq!(fresh.age, 0.0);
    }

    #[test]
    fn legato_harmonics_follow_instantaneous_pitch_even_when_redirected() {
        let rate = 48_000.0;
        let mut dsp = StringsDSP::new(f64::from(rate));
        dsp.set_legato(true);
        dsp.note_on(48, 0.8, false);
        for _ in 0..4800 {
            dsp.render_frame();
        }
        let slot = dsp.legato_voice.unwrap();
        let start = dsp.voices[slot];
        dsp.note_on(79, 0.65, false);
        assert_eq!(dsp.voices[slot].weights, start.weights);
        for _ in 0..384 {
            dsp.render_frame();
        }
        let midpoint = dsp.voices[slot];
        assert_ne!(midpoint.weights[4], start.weights[4]);
        assert!(midpoint.age > start.age && midpoint.level >= start.level);
        let expected = Voice::new(79, 0.8, Articulation::Bowed, rate, 0.0);
        assert_ne!(midpoint.weights[4], expected.weights[4]);

        dsp.note_on(60, 0.7, false);
        assert_eq!(dsp.voices[slot].weights, midpoint.weights);
        assert_eq!(dsp.voices[slot].phase, midpoint.phase);
        assert_eq!(dsp.voices[slot].level, midpoint.level);
        for _ in 0..768 {
            dsp.render_frame();
        }
        let expected = Voice::new(60, 0.8, Articulation::Bowed, rate, 0.0);
        assert_eq!(dsp.voices[slot].weights, expected.weights);
        assert_eq!(dsp.voices.iter().filter(|voice| voice.active()).count(), 1);
    }

    #[test]
    fn a_partial_fades_before_crossing_the_band_limit() {
        let rate = 44_100.0;
        let mut voice = Voice::new(96, 0.8, Articulation::Bowed, rate, 0.0);
        voice.frequency = 0.4599 * rate / 4.0;
        voice.update_harmonics(rate);
        assert_eq!(voice.partials, 4);
        assert!(voice.last_partial_gain < 0.0001);

        voice.frequency = 0.4601 * rate / 4.0;
        voice.update_harmonics(rate);
        assert_eq!(voice.partials, 3);
        assert_eq!(voice.last_partial_gain, 1.0);
    }

    #[test]
    fn legato_requires_overlap_and_pizzicato_keeps_independent_voices() {
        let mut dsp = StringsDSP::new(48_000.0);
        dsp.set_legato(true);
        dsp.sustain(1.0);
        dsp.note_on(60, 0.7, false);
        dsp.note_off(60);
        dsp.note_on(64, 0.7, false);
        assert_eq!(dsp.voices.iter().filter(|v| v.active()).count(), 2);
        dsp.note_on(67, 0.7, true);
        dsp.note_on(69, 0.7, true);
        assert_eq!(dsp.voices.iter().filter(|v| v.active()).count(), 4);
        dsp.all_off();
        assert!(dsp.legato_voice.is_none());
        assert_eq!(dsp.legato_count, 0);
    }

    #[test]
    fn spiccato_velocity_changes_attack_and_duration_while_the_key_is_held() {
        for rate in [44_100, 48_000, 96_000] {
            let measure = |velocity| {
                let mut dsp = StringsDSP::new(f64::from(rate));
                dsp.set_legato(true);
                dsp.set_spiccato(true);
                dsp.reverb = 0.0;
                dsp.reverb_target = 0.0;
                dsp.note_on(62, velocity, false);
                assert!(dsp.legato_voice.is_none());
                let peaks: [f32; 60] = std::array::from_fn(|_| {
                    (0..rate / 200)
                        .map(|_| dsp.render_frame()[0].abs())
                        .fold(0.0, f32::max)
                });
                assert!(dsp.voices.iter().all(|voice| !voice.active()));
                let attack = peaks[..6].iter().copied().fold(0.0, f32::max);
                let duration = peaks
                    .iter()
                    .rposition(|peak| *peak > attack * 0.05)
                    .unwrap();
                (attack, duration)
            };
            let (soft_attack, soft_duration) = measure(0.25);
            let (strong_attack, strong_duration) = measure(0.9);
            assert!(soft_attack > 0.01 && strong_attack > 1.8 * soft_attack);
            assert!(strong_duration > soft_duration + 4);
        }
    }

    #[test]
    fn releasing_a_spiccato_note_without_sustain_cuts_it_short() {
        let mut dsp = StringsDSP::new(48_000.0);
        dsp.set_spiccato(true);
        dsp.note_on(62, 0.95, false);
        for _ in 0..480 {
            dsp.render_frame();
        }
        dsp.note_off(62);
        assert!(dsp.voices[0].gate == Gate::Released);
        for _ in 0..4800 {
            dsp.render_frame();
        }
        assert!(!dsp.voices[0].active());
    }

    #[test]
    fn waveguide_responds_to_pressure_speed_and_contact() {
        let render = |pressure, speed, contact| {
            let mut dsp = StringsDSP::new(48_000.0);
            dsp.waveguide_enabled = true;
            dsp.performance[4] = pressure;
            dsp.performance_targets[4] = pressure;
            dsp.performance[10] = speed;
            dsp.performance_targets[10] = speed;
            dsp.bow_position = contact;
            dsp.bow_target = contact;
            dsp.note_on(62, 0.8, false);
            (0..12_000)
                .map(|_| dsp.render_frame()[0])
                .collect::<Vec<_>>()
        };
        let reference = render(0.5, 0.5, 0.75);
        assert!(reference.iter().any(|x| x.abs() > 0.04));
        for (pressure, speed, contact) in [(0.25, 0.5, 0.75), (0.5, 0.8, 0.75), (0.5, 0.5, 0.2)] {
            let comparison = render(pressure, speed, contact);
            let difference = reference
                .iter()
                .zip(comparison)
                .map(|(a, b)| (a - b).abs())
                .sum::<f32>();
            assert!(difference > 1.0);
        }
        for silent in [render(0.0, 0.5, 0.75), render(0.5, 0.0, 0.75)] {
            assert!(silent.into_iter().all(|sample| sample == 0.0));
        }
    }

    #[test]
    fn waveguide_switch_preserves_other_articulations() {
        for (pizzicato, spiccato, legato) in [
            (true, false, false),
            (false, true, false),
            (false, false, true),
        ] {
            let make = |enabled| {
                let mut dsp = StringsDSP::new(48_000.0);
                dsp.waveguide_enabled = enabled;
                dsp.set_spiccato(spiccato);
                dsp.set_legato(legato);
                dsp.note_on(60, 0.8, pizzicato);
                dsp
            };
            let mut legacy = make(false);
            let mut experimental = make(true);
            for _ in 0..4800 {
                assert_eq!(experimental.render_frame(), legacy.render_frame());
            }
        }
    }

    #[test]
    fn waveguide_handles_polyphony_and_clears_after_stop() {
        for rate in [44_100.0, 48_000.0, 96_000.0] {
            let mut dsp = StringsDSP::new(rate);
            dsp.waveguide_enabled = true;
            for note in (0..16).chain(112..128) {
                dsp.note_on(note, 0.8, false);
            }
            assert_eq!(
                dsp.waveguides.iter().filter(|guide| guide.active).count(),
                VOICES
            );
            for _ in 0..4096 {
                assert!(dsp.render_frame().into_iter().all(f32::is_finite));
            }
            dsp.all_off();
            assert_eq!(dsp.render_frame(), [0.0, 0.0]);
            dsp.note_on(62, 0.5, false);
            assert_eq!(
                dsp.waveguides[0].sample(160.0, 0.1, 0.0, 0.0, 0.5, (rate as f32).recip()),
                0.0
            );
        }
    }

    #[test]
    fn performance_controls_change_the_rendered_signal() {
        for (index, default) in PERFORMANCE_DEFAULTS[..10].iter().enumerate() {
            let render = |value| {
                let mut dsp = StringsDSP::new(48_000.0);
                dsp.set_legato(true);
                unsafe { strings_dsp_set_performance(&mut dsp, index as u32, value) };
                dsp.note_on(62, 0.8, false);
                (0..24_000)
                    .map(|frame| {
                        if frame == 9_600 {
                            dsp.note_on(65, 0.8, false);
                        }
                        dsp.render_frame()
                    })
                    .collect::<Vec<_>>()
            };
            let baseline = render(*default);
            let adjusted = render(0.0);
            let difference: f32 = baseline
                .iter()
                .zip(adjusted)
                .map(|(a, b)| (a[0] - b[0]).abs() + (a[1] - b[1]).abs())
                .sum();
            assert!(
                difference > 0.1,
                "control index {index} did not change the output"
            );
        }
    }

    #[test]
    fn moving_toward_the_bridge_emphasizes_upper_partials() {
        let fingerboard = bow_response(0.0);
        let bridge = bow_response(1.0);
        let relative_upper_energy = |response: [f32; PARTIALS]| {
            response[3..].iter().map(|gain| gain * gain).sum::<f32>() / response[0].powi(2)
        };
        assert!(relative_upper_energy(bridge) > 2.0 * relative_upper_energy(fingerboard));
    }
}
