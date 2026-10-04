// The instruments. Each function renders one note or hit into a stereo bus
// ({L, R, length}); a bus that also has sendL/sendR feeds the shared reverb
// with `send` times the dry signal. Times are in seconds, pitches in MIDI.
import {Biquad, RATE, SVF, TAU, hz, pan} from './dsp.mjs';

function span(bus, start, seconds) {
	return [Math.max(0, Math.round(start * RATE)), Math.min(bus.length, Math.round((start + seconds) * RATE))];
}

function put(bus, i, l, r, send) {
	bus.L[i] += l;
	bus.R[i] += r;
	if (send) {
		bus.sendL[i] += l * send;
		bus.sendR[i] += r * send;
	}
}

// PolyBLEP correction for a band-limited sawtooth.
function blep(p, dt) {
	if (p < dt) {
		const x = p / dt;
		return x + x - x * x - 1;
	}
	if (p > 1 - dt) {
		const x = (p - 1) / dt;
		return x * x + x + x + 1;
	}
	return 0;
}

// Warm pad voice: three detuned band-limited saws spread left, centre and
// right over a sine for body. The pad bus filter decides how bright it is.
export function padVoice(bus, {start, end, midi, gain, attack, release, rand}) {
	const f = hz(midi);
	const [i0, i1] = span(bus, start, end - start + release);
	const steps = [0.9957, 1, 1.0046].map((d) => (f * d) / RATE);
	const gains = [pan(-0.65), pan(0), pan(0.65)];
	const phase = steps.map(() => rand());
	const lfo = (TAU * (0.07 + rand() * 0.08)) / RATE;
	let lfoPhase = rand() * TAU;
	const sineStep = (TAU * f) / RATE;
	let sine = 0;
	const sustain = end - start;
	for (let i = i0; i < i1; i++) {
		const t = i / RATE - start;
		let env = t < attack ? Math.sin((Math.PI / 2) * (t / attack)) ** 2 : 1;
		if (t > sustain) env *= Math.cos((Math.PI / 2) * Math.min(1, (t - sustain) / release)) ** 2;
		env *= gain * (1 + 0.08 * Math.sin(lfoPhase));
		lfoPhase += lfo;
		let l = 0;
		let r = 0;
		for (let k = 0; k < 3; k++) {
			const dt = steps[k];
			let p = phase[k] + dt;
			if (p >= 1) p -= 1;
			phase[k] = p;
			const v = 2 * p - 1 - blep(p, dt);
			l += v * gains[k][0];
			r += v * gains[k][1];
		}
		const s = Math.sin(sine) * 0.85;
		sine += sineStep;
		bus.L[i] += (0.3 * l + s) * env;
		bus.R[i] += (0.3 * r + s) * env;
	}
}

// Soft sub bass: a sine with a little second and third harmonic, gently
// saturated so small speakers still hear the line. `pump` is the sidechain
// from the kick.
export function bass(bus, {start, dur, midi, gain, pump}) {
	const release = 0.1;
	const [i0, i1] = span(bus, start, dur + release);
	const step = (TAU * hz(midi)) / RATE;
	let ph = 0;
	for (let i = i0; i < i1; i++) {
		const t = i / RATE - start;
		let env = Math.min(1, t / 0.012) * (0.72 + 0.28 * Math.exp(-t / 0.22));
		if (t > dur) env *= 0.5 + 0.5 * Math.cos(Math.PI * Math.min(1, (t - dur) / release));
		const v = Math.tanh(1.25 * (Math.sin(ph) + 0.28 * Math.sin(2 * ph) + 0.08 * Math.sin(3 * ph)));
		ph += step;
		const y = v * env * gain * pump.at(i);
		bus.L[i] += y;
		bus.R[i] += y;
	}
}

// Muted pluck: a few slightly stretched partials, the higher ones dying
// faster. After `hold` seconds the string is damped, so quick patterns stay
// tidy instead of smearing.
export function pluck(bus, {start, midi, gain, pan: position = 0, decay = 0.5, bright = 0.5, hold = Infinity}) {
	const f = hz(midi);
	const [gl, gr] = pan(position);
	const i0 = Math.max(0, Math.round(start * RATE));
	const attack = Math.round(0.0015 * RATE);
	const holdAt = hold * RATE;
	const damp = Math.exp(-1 / (0.06 * RATE));
	for (let k = 1; k <= 6; k++) {
		const fk = f * k * Math.sqrt(1 + 0.00015 * k * k);
		if (fk > RATE * 0.42) break;
		const tau = decay / (1 + 0.9 * (k - 1));
		const fall = Math.exp(-1 / (tau * RATE));
		const w = (TAU * fk) / RATE;
		const cw = Math.cos(w);
		const sw = Math.sin(w);
		const n = Math.min(bus.length - i0, Math.ceil(Math.min(tau * 7, hold + 0.45) * RATE));
		let amp = (gain * bright ** (k - 1)) / k ** 0.6;
		let c = 1;
		let s = 0;
		for (let j = 0; j < n; j++) {
			const y = s * (j < attack ? (amp * j) / attack : amp);
			bus.L[i0 + j] += y * gl;
			bus.R[i0 + j] += y * gr;
			const c2 = c * cw - s * sw;
			s = s * cw + c * sw;
			c = c2;
			amp *= j >= holdAt ? fall * damp : fall;
		}
	}
}

// Two-operator FM electric piano: a round body with a glassy tine on the
// attack that fades within a few hundred milliseconds. Carries the StockReef
// motif and some of the arpeggios.
export function keys(bus, {start, midi, gain, pan: position = 0, decay = 1.2, hold = Infinity, bright = 1}) {
	const f = hz(midi);
	const [gl, gr] = pan(position);
	const [i0, i1] = span(bus, start, Math.min(decay * 6, hold + 0.4));
	const step = (TAU * f) / RATE;
	let pc = 0;
	let pt = 0;
	for (let i = i0; i < i1; i++) {
		const t = i / RATE - start;
		const index = bright * (0.25 + 1.4 * Math.exp(-t / 0.3));
		const tine = bright * 0.8 * Math.exp(-t / 0.035);
		let env = Math.min(1, t / 0.002) * Math.exp(-t / decay);
		if (t > hold) env *= Math.exp(-(t - hold) / 0.07);
		const y = Math.sin(pc + index * Math.sin(pc) + tine * Math.sin(pt)) * env * gain;
		pc += step;
		pt += step * 14;
		bus.L[i] += y * gl;
		bus.R[i] += y * gr;
	}
}

// Sum of exponentially decaying sine modes, [ratio, level, decay seconds,
// detune Hz]. The bell, the chime and the clock tick are all built on it.
function modal(bus, {start, f, modes, gain, pan: position = 0, send = 0, attack = 0.001}) {
	const [gl, gr] = pan(position);
	const i0 = Math.max(0, Math.round(start * RATE));
	const a = Math.max(1, Math.round(attack * RATE));
	for (const [ratio, level, decay, detune = 0] of modes) {
		const w = (TAU * (f * ratio + detune)) / RATE;
		if (w >= Math.PI * 0.9) continue;
		const cw = Math.cos(w);
		const sw = Math.sin(w);
		const fall = Math.exp(-1 / (decay * RATE));
		const n = Math.min(bus.length - i0, Math.ceil(decay * 7 * RATE));
		let amp = gain * level;
		let c = 1;
		let s = 0;
		for (let j = 0; j < n; j++) {
			const y = s * (j < a ? (amp * j) / a : amp);
			put(bus, i0 + j, y * gl, y * gr, send);
			const c2 = c * cw - s * sw;
			s = s * cw + c * sw;
			c = c2;
			amp *= fall;
		}
	}
}

// The closing bell: a small tuned bell with the inharmonic partials of a
// real one (hum, prime, tierce, quint, nominal and the upper partials), each
// split into a close pair so it shimmers as it rings. Its tierce is a minor
// third, swapped for a major third once the music has resolved.
const BELL = [
	[0.5, 0.22, 2.6],
	[1, 1, 1.9],
	[1.19, 0.12, 1.3],
	[1.5, 0.08, 1.1],
	[2, 0.42, 1.25],
	[2.52, 0.16, 0.75],
	[3.01, 0.12, 0.55],
	[4.17, 0.06, 0.35],
	[5.43, 0.03, 0.22],
];
export function bell(bus, {start, midi, gain, pan: position = 0, major = false, ring = 1, send = 0}) {
	const modes = BELL.flatMap(([ratio, level, decay]) => {
		const r = ratio === 1.19 && major ? 1.26 : ratio;
		return [
			[r, level / 2, decay * ring, -0.35 * r],
			[r, level / 2, decay * ring, 0.35 * r],
		];
	});
	modal(bus, {start, f: hz(midi), modes, gain, pan: position, send, attack: 0.0012});
}

// One ping of the confirmation chime: glassy, short, a touch of sparkle.
export function chime(bus, {start, midi, gain, pan: position = 0, decay = 0.5, send = 0}) {
	const modes = [
		[1, 1, decay],
		[2, 0.22, decay * 0.4],
		[4.2, 0.07, decay * 0.12],
	];
	modal(bus, {start, f: hz(midi), modes, gain, pan: position, send, attack: 0.0015});
}

// The clock: a precise filtered click, a high "tick" and a lower "tock".
export function tick(bus, {start, gain, accent, pan: position = 0, send = 0}) {
	const modes = [
		[1, 1, 0.0035],
		[0.4, 0.45, 0.009],
		[1.7, 0.35, 0.002],
	];
	modal(bus, {start, f: accent ? 3300 : 2750, modes, gain, pan: position, send, attack: 0.0002});
}

// Filtered noise through an envelope: shaker, brushed hat and clap.
function noise(bus, {start, gain, pan: position = 0, filter, envelope, length, rand, send = 0}) {
	const [gl, gr] = pan(position);
	const [i0, i1] = span(bus, start, length);
	const f = new Biquad(...filter);
	for (let i = i0; i < i1; i++) {
		const y = f.process(rand() * 2 - 1) * envelope(i / RATE - start) * gain;
		put(bus, i, y * gl, y * gr, send);
	}
}

const swell = (attack, decay) => (t) => Math.min(1, t / attack) * Math.exp(-Math.max(0, t - attack) / decay);

export function shaker(bus, options) {
	noise(bus, {filter: ['bandpass', 8200, 1.3], envelope: swell(0.006, 0.03), length: 0.2, ...options});
}

export function brush(bus, options) {
	noise(bus, {filter: ['highpass', 5200, 0.7], envelope: swell(0.02, 0.07), length: 0.5, ...options});
}

export function clap(bus, options) {
	const envelope = (t) => {
		let e = 0.9 * Math.exp(-Math.max(0, t - 0.03) / 0.09) * (t >= 0.03 ? 1 : 0);
		for (const at of [0, 0.011, 0.022]) if (t >= at) e = Math.max(e, Math.exp(-(t - at) / 0.0045));
		return e;
	};
	noise(bus, {filter: ['bandpass', 1350, 0.9], envelope, length: 0.6, ...options});
}

// Soft kick: a sine that drops from about 125 Hz to 50 Hz.
export function kick(bus, {start, gain}) {
	const [i0, i1] = span(bus, start, 1.4);
	let ph = 0;
	for (let i = i0; i < i1; i++) {
		const t = i / RATE - start;
		ph += (TAU * (50 + 75 * Math.exp(-t / 0.03))) / RATE;
		const y = Math.tanh(1.6 * Math.sin(ph)) * Math.min(1, t / 0.002) * Math.exp(-t / 0.2) * gain;
		bus.L[i] += y;
		bus.R[i] += y;
	}
}

// Noise riser that sweeps up into `end` and stops dead on it.
export function riser(bus, {end, dur, gain, rand, send = 0}) {
	const start = end - dur;
	const [i0, i1] = span(bus, start, dur);
	const fl = new SVF(400, 2);
	const fr = new SVF(400, 2);
	for (let i = i0; i < i1; i++) {
		const x = Math.max(0, (i / RATE - start) / dur);
		if ((i & 31) === 0) {
			const fc = 350 * (6500 / 350) ** x;
			fl.tune(fc, 2.2);
			fr.tune(fc, 2.2);
		}
		fl.process(rand() * 2 - 1);
		fr.process(rand() * 2 - 1);
		const env = gain * x ** 2.4 * Math.min(1, (end - i / RATE) / 0.03);
		put(bus, i, fl.band * env, fr.band * env, send);
	}
}

// A soft low thump under a lift's downbeat.
export function impact(bus, {start, gain}) {
	const [i0, i1] = span(bus, start, 3.2);
	let ph = 0;
	for (let i = i0; i < i1; i++) {
		const t = i / RATE - start;
		ph += (TAU * (40 + 34 * Math.exp(-t / 0.08))) / RATE;
		const y = Math.sin(ph) * Math.min(1, t / 0.005) * Math.exp(-t / 0.45) * gain;
		bus.L[i] += y;
		bus.R[i] += y;
	}
}
