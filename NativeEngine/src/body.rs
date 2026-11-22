//! Stereo body resonators excited by the pitch range of each sounding string.

// Center frequency in Hz, time to decay by 60 dB in seconds, and signed gain.
// These profiles are voiced by hand for the section's low, middle and high notes.
const PROFILES: [[(f32, f32, f32); 6]; 3] = [
    [
        (98.0, 0.096, 0.40),
        (164.0, 0.080, 0.47),
        (302.0, 0.056, 0.44),
        (557.0, 0.041, 0.29),
        (1210.0, 0.023, -0.13),
        (2320.0, 0.012, 0.23),
    ],
    [
        (119.0, 0.055, 0.25),
        (238.0, 0.050, 0.35),
        (460.0, 0.036, 0.47),
        (710.0, 0.024, 0.30),
        (1530.0, 0.014, -0.14),
        (2800.0, 0.008, 0.38),
    ],
    [
        (196.0, 0.034, 0.14),
        (372.0, 0.030, 0.19),
        (590.0, 0.026, 0.36),
        (1020.0, 0.020, 0.32),
        (1980.0, 0.013, -0.14),
        (3320.0, 0.010, 0.54),
    ],
];

pub(super) struct BodyResonance {
    modes: [[[Mode; 6]; 2]; 3],
}

impl BodyResonance {
    pub(super) fn new(rate: f32) -> Self {
        Self {
            modes: PROFILES.map(|profile| {
                [0.96, 1.04].map(|spread| {
                    profile.map(|(hz, decay, gain)| Mode::new(rate, hz * spread, decay, gain))
                })
            }),
        }
    }

    pub(super) fn render(&mut self, inputs: [[f32; 2]; 3]) -> [f32; 2] {
        let mut output = [0.0; 2];
        for (register, input) in self.modes.iter_mut().zip(inputs) {
            for ((channel, modes), sample) in output.iter_mut().zip(register).zip(input) {
                *channel += modes
                    .iter_mut()
                    .map(|mode| mode.sample(sample))
                    .sum::<f32>();
            }
        }
        output
    }

    pub(super) fn clear(&mut self) {
        for mode in self.modes.iter_mut().flatten().flatten() {
            mode.state = [0.0; 2];
        }
    }

    pub(super) fn weights(frequency: f32) -> [f32; 3] {
        fn smooth(low: f32, high: f32, hz: f32) -> f32 {
            let x = ((hz - low) / (high - low)).clamp(0.0, 1.0);
            x * x * (3.0 - 2.0 * x)
        }
        let low = 1.0 - smooth(165.0, 330.0, frequency);
        let high = smooth(440.0, 880.0, frequency);
        [low, 1.0 - low - high, high]
    }
}

/// Unity-peak bandpass with a pole radius set by the decay time.
struct Mode {
    gain: f32,
    b0: f32,
    a1: f32,
    a2: f32,
    state: [f32; 2],
}

impl Mode {
    fn new(rate: f32, frequency: f32, decay: f32, gain: f32) -> Self {
        let rate = f64::from(rate);
        let radius = (-1000.0_f64.ln() / (rate * f64::from(decay))).exp();
        let radius_squared = radius * radius;
        let cosine = (std::f64::consts::TAU * f64::from(frequency) / rate).cos();
        Self {
            gain,
            b0: (0.5 * (1.0 - radius_squared)) as f32,
            a1: (-(1.0 + radius_squared) * cosine) as f32,
            a2: radius_squared as f32,
            state: [0.0; 2],
        }
    }

    fn sample(&mut self, input: f32) -> f32 {
        let feed = self.b0 * input;
        let output = feed + self.state[0];
        self.state[0] = self.state[1] - self.a1 * output;
        self.state[1] = -feed - self.a2 * output;
        self.gain * output
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn register_weights_are_continuous_and_sum_to_one() {
        assert_eq!(BodyResonance::weights(110.0), [1.0, 0.0, 0.0]);
        assert_eq!(BodyResonance::weights(392.0), [0.0, 1.0, 0.0]);
        assert_eq!(BodyResonance::weights(1046.0), [0.0, 0.0, 1.0]);
        for hz in 100..1000 {
            let a = BodyResonance::weights(hz as f32);
            let b = BodyResonance::weights((hz + 1) as f32);
            assert!((a.iter().sum::<f32>() - 1.0).abs() < 1e-6);
            assert!(a
                .into_iter()
                .zip(b)
                .all(|(a, b)| a >= 0.0 && (a - b).abs() < 0.01));
        }
    }

    #[test]
    fn low_register_ring_lasts_longer_and_responds_at_lower_frequencies() {
        let measure = |register: usize, hz: f32| {
            let rate = 48_000.0_f32;
            let mut body = BodyResonance::new(rate);
            let mut response = [0.0; 4800];
            for (frame, sample) in response.iter_mut().enumerate() {
                let mut input = [[0.0; 2]; 3];
                if frame == 0 {
                    input[register][0] = 1.0;
                }
                *sample = body.render(input)[0];
            }
            let (real, imaginary) = response.iter().enumerate().fold(
                (0.0_f32, 0.0_f32),
                |(real, imaginary), (frame, y)| {
                    let phase = std::f32::consts::TAU * hz * frame as f32 / rate;
                    let (sine, cosine) = phase.sin_cos();
                    (real + y * cosine, imaginary + y * sine)
                },
            );
            let late = response[1200..].iter().map(|x| x * x).sum::<f32>();
            (real.hypot(imaginary), late)
        };
        let (low_gain, low_tail) = measure(0, 94.0);
        let (high_gain, high_tail) = measure(2, 94.0);
        assert!(low_gain > high_gain * 2.0);
        assert!(low_tail > high_tail * 2.0);
        assert!(measure(2, 3187.0).0 > measure(0, 3187.0).0 * 1.5);
    }
}
