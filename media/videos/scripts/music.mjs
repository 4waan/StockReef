// Synthesizes a video's music bed from src/timeline-<video>.json: a soft pad, a
// quiet arpeggio and a sub bass on a four-chord loop, a chime on every
// question card, and the bed dipped under every answer so a voice sits on top.
// Original audio, so nothing needs a license. Writes public/music-<video>.wav.
//
//   node scripts/music.mjs pitch|demo
import {readFileSync, writeFileSync} from 'node:fs';

const video = process.argv[2];
if (!['pitch', 'demo'].includes(video)) throw new Error('usage: node scripts/music.mjs pitch|demo');
const timeline = JSON.parse(readFileSync(new URL(`../src/timeline-${video}.json`, import.meta.url), 'utf8'));
const RATE = 44100;
const seconds = timeline.total / timeline.fps;
const length = Math.ceil(seconds * RATE);
const left = new Float32Array(length);
const right = new Float32Array(length);

const midi = (n) => 440 * 2 ** ((n - 69) / 12);
const BPM = 80;
const beat = 60 / BPM;
const bar = beat * 4;
// Am9, F add9, Cmaj7/E, G6: two bars each. Only two of the four hold an E,
// so no single note drones under the whole piece.
const chords = [
	{root: 45, notes: [57, 60, 64, 67, 71]},
	{root: 41, notes: [53, 57, 60, 65, 67]},
	{root: 40, notes: [55, 60, 64, 67, 71]},
	{root: 43, notes: [55, 59, 62, 67, 69]},
];
const chordLength = bar * 2;

function addTone(start, duration, freq, gain, {attack = 0.01, release = 0.3, pan = 0, shape = 'sine', decay = 0} = {}) {
	const s0 = Math.max(0, Math.floor(start * RATE));
	const s1 = Math.min(length, Math.floor((start + duration + release) * RATE));
	const lg = gain * Math.cos(((pan + 1) * Math.PI) / 4);
	const rg = gain * Math.sin(((pan + 1) * Math.PI) / 4);
	let phase = Math.random() * Math.PI * 2;
	const step = (2 * Math.PI * freq) / RATE;
	for (let i = s0; i < s1; i++) {
		const t = i / RATE - start;
		let env = t < attack ? t / attack : 1;
		if (decay > 0) env *= Math.exp(-t / decay);
		if (t > duration) env *= Math.max(0, 1 - (t - duration) / release);
		let v = Math.sin(phase);
		if (shape === 'soft') v = 0.88 * v + 0.06 * Math.sin(phase * 2) + 0.04 * Math.sin(phase * 3);
		phase += step;
		left[i] += v * env * lg;
		right[i] += v * env * rg;
	}
}

// Pad: two slightly detuned voices per note, slow attack and release.
for (let t = 0, k = 0; t < seconds; t += chordLength, k++) {
	const chord = chords[k % chords.length];
	chord.notes.forEach((n, j) => {
		const pan = (j / (chord.notes.length - 1)) * 1.2 - 0.6;
		addTone(t, chordLength, midi(n) * 1.002, 0.028, {attack: 1.8, release: 2.2, pan, shape: 'soft'});
		addTone(t, chordLength, midi(n) * 0.998, 0.028, {attack: 2.2, release: 2.2, pan: -pan, shape: 'soft'});
	});
	addTone(t, chordLength, midi(chord.root), 0.03, {attack: 0.6, release: 1.2});
}

// Arpeggio: quarter notes an octave up, plucked, panned across.
const pattern = [0, 2, 4, 3, 1, 3, 4, 2];
for (let t = bar * 2, step = 0; t < seconds - 2; t += beat, step++) {
	const chord = chords[Math.floor(t / chordLength) % chords.length];
	const note = chord.notes[pattern[step % pattern.length]] + 12;
	const pan = Math.sin(step * 0.7) * 0.5;
	addTone(t, 0.05, midi(note), 0.03, {attack: 0.008, release: 0.08, decay: 0.6, pan});
}

// Simple stereo reverb: four feedback delays per side.
function reverb(buffer, delays, feedback, mix) {
	const dry = buffer.slice();
	for (const ms of delays) {
		const d = Math.floor((ms / 1000) * RATE);
		const line = new Float32Array(length);
		for (let i = d; i < length; i++) line[i] = dry[i - d] + line[i - d] * feedback;
		for (let i = 0; i < length; i++) buffer[i] += (line[i] * mix) / delays.length;
	}
}
reverb(left, [29.7, 37.1, 41.1, 43.7], 0.78, 0.55);
reverb(right, [31.3, 35.9, 40.3, 45.1], 0.78, 0.55);

// High-pass at 90 Hz (two biquads, 24 dB per octave): the feedback delays
// pile up low rumble that laptop speakers cannot play and that eats headroom.
function highpass(buffer, cutoff) {
	const w = (2 * Math.PI * cutoff) / RATE;
	const alpha = Math.sin(w) / Math.SQRT2;
	const cos = Math.cos(w);
	const a0 = 1 + alpha;
	const b0 = (1 + cos) / 2 / a0;
	const b1 = -(1 + cos) / a0;
	const b2 = b0;
	const a1 = (-2 * cos) / a0;
	const a2 = (1 - alpha) / a0;
	let x1 = 0, x2 = 0, y1 = 0, y2 = 0;
	for (let i = 0; i < buffer.length; i++) {
		const x = buffer[i];
		const y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
		x2 = x1;
		x1 = x;
		y2 = y1;
		y1 = y;
		buffer[i] = y;
	}
}
for (const channel of [left, right]) {
	highpass(channel, 90);
	highpass(channel, 90);
}

// Ducking: full level on the intro, question cards and outro; low under answers.
const fps = timeline.fps;
const under = 0.42;
const gainAt = new Float32Array(length).fill(1);
for (const s of timeline.segments) {
	const a = Math.floor(((s.answerStart + 3) / fps) * RATE);
	const b = Math.floor((s.end / fps) * RATE);
	for (let i = a; i < b && i < length; i++) gainAt[i] = under;
}
// Smooth the ducking curve (about 250 ms).
const smooth = Math.exp(-1 / (0.25 * RATE));
let g = 1;
for (let i = 0; i < length; i++) {
	g = gainAt[i] + (g - gainAt[i]) * smooth;
	left[i] *= g;
	right[i] *= g;
}

// Chime on each question card: a soft bell (two partials), not ducked.
for (const s of timeline.segments) {
	const t = s.questionStart / fps + 0.05;
	addTone(t, 0.02, midi(88), 0.09, {attack: 0.003, release: 0.02, decay: 0.9, pan: -0.15});
	addTone(t, 0.02, midi(95), 0.05, {attack: 0.003, release: 0.02, decay: 0.6, pan: 0.15});
	addTone(t + 0.09, 0.02, midi(91), 0.06, {attack: 0.003, release: 0.02, decay: 1.1, pan: 0.1});
}

// Fade in over 2 s, out over the last 4 s, then normalize to -3 dBFS peak.
for (let i = 0; i < length; i++) {
	const t = i / RATE;
	const f = Math.min(1, t / 2, (seconds - t) / 4);
	left[i] *= Math.max(0, f);
	right[i] *= Math.max(0, f);
}
let peak = 0;
for (let i = 0; i < length; i++) peak = Math.max(peak, Math.abs(left[i]), Math.abs(right[i]));
const norm = 0.708 / peak;

const data = Buffer.alloc(length * 4);
for (let i = 0; i < length; i++) {
	data.writeInt16LE(Math.round(Math.max(-1, Math.min(1, left[i] * norm)) * 32767), i * 4);
	data.writeInt16LE(Math.round(Math.max(-1, Math.min(1, right[i] * norm)) * 32767), i * 4 + 2);
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
writeFileSync(new URL(`../public/music-${video}.wav`, import.meta.url), Buffer.concat([header, data]));
console.log(`music-${video}.wav: ${seconds.toFixed(1)} s`);
