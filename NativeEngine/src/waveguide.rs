//! Experimental two-segment bowed string with a nonlinear bow junction.

#[derive(Default)]
struct Reflection {
    previous: f32,
}

impl Reflection {
    fn apply(&mut self, incoming: f32, loss: f32) -> f32 {
        let filtered = incoming + (self.previous - incoming) * loss;
        self.previous = incoming;
        -0.996 * filtered
    }
}

pub(super) struct Waveguide {
    to_bridge: Box<[f32]>,
    to_finger: Box<[f32]>,
    mask: usize,
    cursor: usize,
    history: usize,
    bridge: Reflection,
    finger: Reflection,
    bridge_dc: f32,
    radiation: f32,
    stuck: bool,
    pub(super) active: bool,
}

impl Waveguide {
    pub(super) fn new(length: usize) -> Self {
        debug_assert!(length.is_power_of_two());
        Self {
            to_bridge: vec![0.0; length].into_boxed_slice(),
            to_finger: vec![0.0; length].into_boxed_slice(),
            mask: length - 1,
            cursor: 0,
            history: 0,
            bridge: Reflection::default(),
            finger: Reflection::default(),
            bridge_dc: 0.0,
            radiation: 0.0,
            stuck: false,
            active: false,
        }
    }

    pub(super) fn start(&mut self, active: bool) {
        // History bounds prevent stale samples on retrigger without clearing the buffers.
        self.history = 0;
        self.bridge = Reflection::default();
        self.finger = Reflection::default();
        self.bridge_dc = 0.0;
        self.radiation = 0.0;
        self.stuck = false;
        self.active = active;
    }

    fn read(&self, line: &[f32], delay: f32) -> f32 {
        let whole = delay as usize;
        let fraction = delay - whole as f32;
        let index = self.cursor.wrapping_sub(whole);
        let recent = if whole <= self.history {
            line[index & self.mask]
        } else {
            0.0
        };
        let older = if whole < self.history {
            line[index.wrapping_sub(1) & self.mask]
        } else {
            0.0
        };
        recent + fraction * (older - recent)
    }

    pub(super) fn sample(
        &mut self,
        period: f32,
        contact: f32,
        bow_velocity: f32,
        pressure: f32,
        brightness: f32,
        inverse_rate: f32,
    ) -> f32 {
        // The two round-trip delays add up to one period. Compensate the
        // low-frequency delay of the two reflection filters.
        let loss = 0.39 - 0.27 * brightness;
        let length = period - 2.0 * loss;
        let minimum = (length * 0.35).clamp(1.0, 2.0);
        let bridge_delay = (length * contact).clamp(minimum, length - minimum);
        let finger_delay = length - bridge_delay;
        let from_bridge = self
            .bridge
            .apply(self.read(&self.to_bridge, bridge_delay), loss);
        let from_finger = self
            .finger
            .apply(self.read(&self.to_finger, finger_delay), loss);
        let mismatch = bow_velocity - (from_bridge + from_finger);

        // In the sticking region the bow cancels the mismatch. Sliding uses a
        // lower velocity-dependent transfer and a smaller recapture threshold.
        let breakaway = (0.55 * pressure) * (0.5 + 3.5 * contact);
        let threshold = if self.stuck {
            breakaway
        } else {
            0.72 * breakaway
        };
        self.stuck = mismatch.abs() <= threshold;
        let transfer = if self.stuck {
            mismatch
        } else {
            mismatch.signum() * (0.72 * breakaway) / (1.0 + 2.2 * mismatch.abs())
        };

        let toward_bridge = from_finger + transfer;
        self.to_finger[self.cursor] = from_bridge + transfer;
        self.to_bridge[self.cursor] = toward_bridge;
        let at_bridge = if bridge_delay < 2.0 {
            toward_bridge
        } else {
            self.read(&self.to_bridge, bridge_delay * 0.5)
        };
        self.cursor = (self.cursor + 1) & self.mask;
        self.history = (self.history + 1).min(self.mask);

        self.bridge_dc += (at_bridge - self.bridge_dc) * (170.0 * inverse_rate);
        self.radiation += (at_bridge - self.bridge_dc - self.radiation)
            * ((16_000.0 + 14_000.0 * brightness) * inverse_rate);
        self.radiation
    }
}
