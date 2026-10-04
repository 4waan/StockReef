// Signal-processing building blocks for the music bed: filters, control-rate
// envelopes, a feedback-delay-network reverb, a ping-pong delay, loudness
// measurement (ITU-R BS.1770), a peak limiter and a 16-bit WAV writer.
// Plain Float32Arrays and no dependencies.
import {writeFileSync} from 'node:fs';

export const RATE = 48000;
export const TAU = Math.PI * 2;

export const hz = (midi) => 440 * 2 ** ((midi - 69) / 12);
export const dbToGain = (db) => 10 ** (db / 20);

// Seeded noise (mulberry32), so the same timeline always renders the same file.
export function random(seed) {
	let a = seed >>> 0;
	return () => {
		a = (a + 0x6d2b79f5) >>> 0;
		let t = a;
		t = Math.imul(t ^ (t >>> 15), t | 1);
		t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
		return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
	};
}

// Equal-power pan: -1 is hard left, 1 hard right. Returns [left, right] gains.
export function pan(position) {
	const a = ((position + 1) * Math.PI) / 4;
	return [Math.cos(a), Math.sin(a)];
}

// A stereo buffer. A bus with sendL/sendR also feeds the shared reverb.
export function stereo(length) {
	return {L: new Float32Array(length), R: new Float32Array(length), length};
}

// RBJ cookbook biquad, one sample at a time.
export class Biquad {
	constructor(type, freq, q = Math.SQRT1_2, gainDb = 0) {
		this.x1 = this.x2 = this.y1 = this.y2 = 0;
		if (type) this.set(type, freq, q, gainDb);
	}

	// A filter from normalized coefficients (a0 = 1).
	static of(b0, b1, b2, a1, a2) {
		return Object.assign(new Biquad(), {b0, b1, b2, a1, a2});
	}

	set(type, freq, q = Math.SQRT1_2, gainDb = 0) {
		const w = (TAU * Math.min(freq, RATE * 0.45)) / RATE;
		const cos = Math.cos(w);
		const alpha = Math.sin(w) / (2 * q);
		const A = 10 ** (gainDb / 40);
		let b0, b1, b2, a0, a1, a2;
		if (type === 'lowpass') [b0, b1, b2, a0, a1, a2] = [(1 - cos) / 2, 1 - cos, (1 - cos) / 2, 1 + alpha, -2 * cos, 1 - alpha];
		else if (type === 'highpass') [b0, b1, b2, a0, a1, a2] = [(1 + cos) / 2, -(1 + cos), (1 + cos) / 2, 1 + alpha, -2 * cos, 1 - alpha];
		else if (type === 'bandpass') [b0, b1, b2, a0, a1, a2] = [alpha, 0, -alpha, 1 + alpha, -2 * cos, 1 - alpha];
		else if (type === 'peaking') [b0, b1, b2, a0, a1, a2] = [1 + alpha * A, -2 * cos, 1 - alpha * A, 1 + alpha / A, -2 * cos, 1 - alpha / A];
		else throw new Error(`unknown filter ${type}`);
		this.b0 = b0 / a0;
		this.b1 = b1 / a0;
		this.b2 = b2 / a0;
		this.a1 = a1 / a0;
		this.a2 = a2 / a0;
		return this;
	}

	process(x) {
		const y = this.b0 * x + this.b1 * this.x1 + this.b2 * this.x2 - this.a1 * this.y1 - this.a2 * this.y2;
		this.x2 = this.x1;
		this.x1 = x;
		this.y2 = this.y1;
		this.y1 = y;
		return y;
	}
}

// Topology-preserving state-variable filter (Zavalishin): cheap to retune
// every few samples, so it carries the filter sweeps. process() returns the
// lowpass; the bandpass (unity peak) is left in this.band.
export class SVF {
	constructor(freq = 1000, q = Math.SQRT1_2) {
		this.ic1 = this.ic2 = 0;
		this.band = 0;
		this.tune(freq, q);
	}

	tune(freq, q = Math.SQRT1_2) {
		const g = Math.tan((Math.PI * Math.min(freq, RATE * 0.45)) / RATE);
		this.k = 1 / q;
		this.a1 = 1 / (1 + g * (g + this.k));
		this.a2 = g * this.a1;
		this.a3 = g * this.a2;
	}

	process(x) {
		const v3 = x - this.ic2;
		const v1 = this.a1 * this.ic1 + this.a2 * v3;
		const v2 = this.ic2 + this.a2 * this.ic1 + this.a3 * v3;
		this.ic1 = 2 * v1 - this.ic1;
		this.ic2 = 2 * v2 - this.ic2;
		this.band = this.k * v1;
		return v2;
	}
}

// A control-rate signal: one value per CONTROL samples, for envelopes that
// move slowly (ducking, filter brightness, tick level, sidechain pump).
const SHIFT = 4;
export const CONTROL = 1 << SHIFT;
export class Control {
	constructor(length, value = 0) {
		this.v = new Float32Array(Math.ceil(length / CONTROL) + 2).fill(value);
	}

	// Value at a sample index.
	at(i) {
		return this.v[i >> SHIFT];
	}

	index(seconds) {
		return Math.max(0, Math.min(this.v.length - 1, Math.round((seconds * RATE) / CONTROL)));
	}

	// Piecewise-linear through sorted [seconds, value] keys, flat outside them.
	static keys(length, keys) {
		const c = new Control(length, keys.length ? keys[0][1] : 0);
		for (let k = 0; k < keys.length; k++) {
			const [t0, v0] = keys[k];
			const [t1, v1] = keys[k + 1] ?? [Infinity, v0];
			const i0 = c.index(t0);
			const i1 = t1 === Infinity ? c.v.length : c.index(t1);
			for (let i = i0; i < i1; i++) c.v[i] = t1 === Infinity || i1 === i0 ? v0 : v0 + ((v1 - v0) * (i - i0)) / (i1 - i0);
		}
		return c;
	}

	// One-pole smoothing with separate rise and fall times, in seconds.
	smooth(rise, fall) {
		const up = Math.exp(-CONTROL / (rise * RATE));
		const down = Math.exp(-CONTROL / (fall * RATE));
		let y = this.v[0];
		for (let i = 0; i < this.v.length; i++) {
			const x = this.v[i];
			y = x + (y - x) * (x > y ? up : down);
			this.v[i] = y;
		}
		return this;
	}
}

// Stereo feedback-delay-network reverb: eight damped delay lines mixed by a
// Hadamard matrix. Reads a send bus, adds the wet signal into out.
export function reverb(send, out, {seconds = 2.6, damping = 0.45, predelay = 0.022, gain = 1} = {}) {
	const lengths = [1433, 1601, 1867, 2053, 2251, 2399, 2617, 2797];
	const lines = lengths.map((n) => new Float32Array(n));
	const pos = new Int32Array(8);
	const feedback = lengths.map((n) => 10 ** ((-3 * n) / (seconds * RATE)));
	const y = new Float64Array(8);
	const lp = new Float64Array(8);
	const pre = Math.round(predelay * RATE);
	const hpL = new Biquad('highpass', 220, 0.6);
	const hpR = new Biquad('highpass', 220, 0.6);
	const norm = 1 / Math.sqrt(8);
	const wet = gain * 0.5;
	for (let i = 0; i < send.length; i++) {
		const xL = i >= pre ? hpL.process(send.L[i - pre]) : 0;
		const xR = i >= pre ? hpR.process(send.R[i - pre]) : 0;
		for (let k = 0; k < 8; k++) {
			const v = lines[k][pos[k]];
			lp[k] = v + damping * (lp[k] - v);
			y[k] = lp[k];
		}
		out.L[i] += (y[0] - y[2] + y[4] - y[6]) * wet;
		out.R[i] += (y[1] - y[3] + y[5] - y[7]) * wet;
		// Fast Walsh-Hadamard transform: an orthogonal mix, so the loop stays stable.
		for (let s = 1; s < 8; s <<= 1) {
			for (let j = 0; j < 8; j += s << 1) {
				for (let m = j; m < j + s; m++) {
					const a = y[m];
					const b = y[m + s];
					y[m] = a + b;
					y[m + s] = a - b;
				}
			}
		}
		for (let k = 0; k < 8; k++) {
			lines[k][pos[k]] = y[k] * norm * feedback[k] + (k & 1 ? xR : xL);
			pos[k] = pos[k] + 1 === lengths[k] ? 0 : pos[k] + 1;
		}
	}
}

// Ping-pong delay in place: echoes alternate left, right, left, each one
// darker and thinner than the last.
export function pingPong(buffer, {time, feedback = 0.38, mix = 0.3, tone = 2800, lowCut = 250} = {}) {
	const n = Math.round(time * RATE);
	const lineL = new Float32Array(n);
	const lineR = new Float32Array(n);
	const lpc = Math.exp((-TAU * tone) / RATE);
	const hpc = Math.exp((-TAU * lowCut) / RATE);
	let p = 0;
	let lpL = 0;
	let lpR = 0;
	let hpIn = 0;
	let hpOut = 0;
	for (let i = 0; i < buffer.length; i++) {
		const dl = lineL[p];
		const dr = lineR[p];
		lpL = dl + lpc * (lpL - dl);
		lpR = dr + lpc * (lpR - dr);
		const x = (buffer.L[i] + buffer.R[i]) * 0.5;
		hpOut = hpc * (hpOut + x - hpIn);
		hpIn = x;
		lineL[p] = hpOut + lpR * feedback;
		lineR[p] = lpL * feedback;
		buffer.L[i] += dl * mix;
		buffer.R[i] += dr * mix;
		p = p + 1 === n ? 0 : p + 1;
	}
}

// Integrated loudness in LUFS (ITU-R BS.1770-4): K-weighting, 400 ms blocks
// with 75% overlap, absolute gate at -70 LUFS and relative gate at -10 LU.
export function loudness(L, R) {
	const step = RATE / 10;
	const sums = new Float64Array(Math.floor(L.length / step));
	for (const channel of [L, R]) {
		// K-weighting at 48 kHz: a high shelf (the head) and a high-pass (RLB).
		const shelf = Biquad.of(1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585);
		const rlb = Biquad.of(1, -2, 1, -1.99004745483398, 0.99007225036621);
		for (let i = 0; i < sums.length * step; i++) {
			const y = rlb.process(shelf.process(channel[i]));
			sums[(i / step) | 0] += y * y;
		}
	}
	const blocks = [];
	for (let j = 0; j + 4 <= sums.length; j++) blocks.push((sums[j] + sums[j + 1] + sums[j + 2] + sums[j + 3]) / (4 * step));
	const lufs = (power) => -0.691 + 10 * Math.log10(power);
	const mean = (list) => list.reduce((a, b) => a + b, 0) / list.length;
	const audible = blocks.filter((p) => lufs(p) > -70);
	if (!audible.length) return -Infinity;
	const gate = lufs(mean(audible)) - 10;
	return lufs(mean(audible.filter((p) => lufs(p) > gate)));
}

// Look-ahead peak limiter in place. Gain is worked out per 64-sample block,
// looks two blocks ahead (so it is already down when a peak arrives) and
// recovers over about 150 ms.
export function limit(L, R, ceiling) {
	const size = 64;
	const count = Math.ceil(L.length / size);
	const need = new Float32Array(count + 3).fill(1);
	for (let b = 0; b < count; b++) {
		let peak = 0;
		for (let i = b * size; i < Math.min(L.length, (b + 1) * size); i++) peak = Math.max(peak, Math.abs(L[i]), Math.abs(R[i]));
		need[b] = peak > ceiling ? ceiling / peak : 1;
	}
	const gain = new Float32Array(count + 1);
	const recover = 1 - Math.exp(-size / (0.15 * RATE));
	let g = 1;
	for (let b = 0; b <= count; b++) {
		const target = Math.min(need[Math.max(0, b - 1)], need[b], need[b + 1], need[b + 2]);
		g = target < g ? target : g + (target - g) * recover;
		gain[b] = g;
	}
	for (let i = 0; i < L.length; i++) {
		const b = (i / size) | 0;
		const f = (i - b * size) / size;
		const k = gain[b] + (gain[b + 1] - gain[b]) * f;
		L[i] *= k;
		R[i] *= k;
	}
}

export function peak(L, R) {
	let p = 0;
	for (let i = 0; i < L.length; i++) p = Math.max(p, Math.abs(L[i]), Math.abs(R[i]));
	return p;
}

// 16-bit PCM stereo WAV, with a little triangular dither so fades stay clean.
export function writeWav(file, L, R) {
	const noise = random(7);
	const toInt = (x) => (x === 0 ? 0 : Math.max(-32768, Math.min(32767, Math.round(x * 32767 + noise() - noise()))));
	const data = Buffer.alloc(L.length * 4);
	for (let i = 0; i < L.length; i++) {
		data.writeInt16LE(toInt(L[i]), i * 4);
		data.writeInt16LE(toInt(R[i]), i * 4 + 2);
	}
	const header = Buffer.alloc(44);
	header.write('RIFF', 0);
	header.writeUInt32LE(36 + data.length, 4);
	header.write('WAVEfmt ', 8);
	header.writeUInt32LE(16, 16);
	header.writeUInt16LE(1, 20);
	header.writeUInt16LE(2, 22);
	header.writeUInt32LE(RATE, 24);
	header.writeUInt32LE(RATE * 4, 28);
	header.writeUInt16LE(4, 32);
	header.writeUInt16LE(16, 34);
	header.write('data', 36);
	header.writeUInt32LE(data.length, 40);
	writeFileSync(file, Buffer.concat([header, data]));
}
