// Synthesizes a video's music bed from src/timeline-<video>.json and writes
// public/music-<video>.wav (48 kHz, 16-bit stereo). Everything is generated
// here, with no samples, so nothing needs a license.
//
//   node scripts/music.mjs pitch|demo [timeline.json] [out.wav]
//
// The optional paths are for testing: another timeline (one with a cues
// array, for example) and another output file.
//
// The music: a warm F# minor bed at about 96 BPM that resolves to A major on
// the outro, with a soft sub bass, a filtered saw pad, muted plucks and an FM
// electric piano through a ping-pong delay, and light drums (soft kick,
// shaker, brushed hats, an occasional clap). Three StockReef sounds sit on
// top: the closing bell, the ticking clock and the confirmation chime. The
// harmony, tempo grid and cue handling are in music/score.mjs.
//
// While the voice speaks (each caption phrase, short pauses bridged) the bed
// dips about 4 dB, its pad and plucks close down and a gentle cut around
// 2.5 kHz leaves the speech band to the voice; in the gaps it comes back up.
// The result is normalized to about -20 LUFS with peaks under -3 dBFS.
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {Biquad, CONTROL, Control, RATE, SVF, dbToGain, limit, loudness, peak, pingPong, random, reverb, stereo, writeWav} from './music/dsp.mjs';
import * as play from './music/instruments.mjs';
import {plan} from './music/score.mjs';

const LOUDNESS = -20;
const CEILING = dbToGain(-4);

const [video, timelineFile, outFile] = process.argv.slice(2);
if (!['pitch', 'demo'].includes(video)) throw new Error('usage: node scripts/music.mjs pitch|demo [timeline.json] [out.wav]');
const timeline = JSON.parse(readFileSync(timelineFile ?? new URL(`../src/timeline-${video}.json`, import.meta.url), 'utf8'));
const output = outFile ? path.resolve(outFile) : fileURLToPath(new URL(`../public/music-${video}.wav`, import.meta.url));

const score = plan(timeline);
const {notes, total, sections} = score;
const length = Math.ceil(total * RATE);
const rand = random(video === 'pitch' ? 11 : 23);

// Control signals. speech is 1 while the voice speaks (eased in and out);
// pump is the kick's sidechain; brightness is the pad's filter cutoff.
const speech = new Control(length, 0);
for (const [t0, t1] of score.speech) speech.v.fill(1, speech.index(t0), speech.index(t1));
speech.smooth(0.15, 0.45);

const pump = new Control(length, 1);
for (const k of notes.kick) {
	// Dips by the kick's own level (at most about 2 dB) and recovers in ~0.3 s.
	const i0 = pump.index(k.start);
	for (let j = 0; j * CONTROL < 0.5 * RATE && i0 + j < pump.v.length; j++) {
		const dt = (j * CONTROL) / RATE;
		pump.v[i0 + j] = Math.min(pump.v[i0 + j], 1 - k.gain * Math.min(1, dt / 0.004) * Math.exp(-dt / 0.12));
	}
}

const cutoff = (s) => (s.kind === 'outro' ? 2600 : s.kind === 'intro' ? 1700 : 900 + 1500 * s.energy);
const brightness = Control.keys(length, sections.flatMap((s) => [[s.t0, cutoff(s)], [s.t1, cutoff(s)]])).smooth(0.4, 0.4);

// The bed (everything but the motifs on top) and the shared reverb send.
const send = stereo(length);
const bed = {...stereo(length), sendL: send.L, sendR: send.R};
const fx = {...stereo(length), sendL: send.L, sendR: send.R};

// Pad: high-passed to leave the low end to the bass, low-passed by the
// section's energy and closed further while someone talks.
const pad = stereo(length);
for (const note of [...notes.pad, ...notes.swell]) play.padVoice(pad, {...note, rand});
{
	const hp = [new Biquad('highpass', 130, 0.6), new Biquad('highpass', 130, 0.6)];
	const lp = [new SVF(), new SVF()];
	for (let i = 0; i < length; i++) {
		if ((i & 31) === 0) for (const f of lp) f.tune(brightness.at(i) * (1 - 0.4 * speech.at(i)), 0.8);
		const g = 0.5 + 0.5 * pump.at(i);
		const l = lp[0].process(hp[0].process(pad.L[i])) * g;
		const r = lp[1].process(hp[1].process(pad.R[i])) * g;
		bed.L[i] += l;
		bed.R[i] += r;
		send.L[i] += l * 0.3;
		send.R[i] += r * 0.3;
	}
}

// Plucks and electric piano: open when nobody speaks, pulled down out of
// the speech band under the voice, then a dotted-eighth ping-pong.
const lead = stereo(length);
for (const note of notes.pluck) play.pluck(lead, note);
for (const note of notes.keys) play.keys(lead, note);
{
	const lp = [new SVF(), new SVF()];
	for (let i = 0; i < length; i++) {
		if ((i & 31) === 0) for (const f of lp) f.tune(5200 * (1 - 0.62 * speech.at(i)), 0.7);
		lead.L[i] = lp[0].process(lead.L[i]);
		lead.R[i] = lp[1].process(lead.R[i]);
	}
	pingPong(lead, {time: 0.75 * score.beat0, feedback: 0.36, mix: 0.28});
	for (let i = 0; i < length; i++) {
		bed.L[i] += lead.L[i];
		bed.R[i] += lead.R[i];
		send.L[i] += lead.L[i] * 0.32;
		send.R[i] += lead.R[i] * 0.32;
	}
}

// Bass, drums and transitions straight onto the bed.
for (const note of notes.bass) play.bass(bed, {...note, pump});
for (const hit of notes.kick) play.kick(bed, hit);
for (const hit of notes.shaker) play.shaker(bed, {...hit, rand, send: 0.12});
for (const hit of notes.brush) play.brush(bed, {...hit, rand, send: 0.15});
for (const hit of notes.clap) play.clap(bed, {...hit, rand, send: 0.45});
for (const r of notes.riser) play.riser(bed, {...r, rand, send: 0.35});
for (const hit of notes.impact) play.impact(bed, hit);

// The StockReef sounds.
for (const b of notes.bell) play.bell(fx, {...b, send: 0.55});
for (const c of notes.chime) play.chime(fx, {...c, send: 0.45});
for (const t of notes.tick) play.tick(fx, {...t, send: 0.12});

reverb(send, bed, {seconds: 2.8, damping: 0.45});

// Master: duck and carve the bed under the voice, add the motifs, trim the
// rumble, open fast, fade to silence exactly at the end.
const L = new Float32Array(length);
const R = new Float32Array(length);
{
	const eq = [new Biquad('peaking', 2500, 0.8, 0), new Biquad('peaking', 2500, 0.8, 0)];
	const hp = [new Biquad('highpass', 35), new Biquad('highpass', 35)];
	const outroStart = sections.find((s) => s.kind === 'outro')?.t0 ?? total;
	const fade = Math.max(0.5, Math.min(3, 0.55 * (total - outroStart)));
	for (let i = 0; i < length; i++) {
		const s = speech.at(i);
		if ((i & 63) === 0) for (const f of eq) f.set('peaking', 2500, 0.8, -5 * s);
		const duck = 1 - 0.38 * s;
		const fxDuck = 1 - 0.25 * s;
		const t = i / RATE;
		const edge = Math.min(1, t / 0.01, Math.max(0, total - t - 1 / RATE) / fade);
		const g = Math.sin((Math.PI / 2) * edge) ** 2;
		L[i] = hp[0].process(eq[0].process(bed.L[i]) * duck + fx.L[i] * fxDuck) * g;
		R[i] = hp[1].process(eq[1].process(bed.R[i]) * duck + fx.R[i] * fxDuck) * g;
	}
}

const gain = dbToGain(LOUDNESS - loudness(L, R));
for (let i = 0; i < length; i++) {
	L[i] *= gain;
	R[i] *= gain;
}
limit(L, R, CEILING);
writeWav(output, L, R);
const db = (x) => (20 * Math.log10(x)).toFixed(1);
console.log(`${path.basename(output)}: ${total.toFixed(1)} s, ${loudness(L, R).toFixed(1)} LUFS, peak ${db(peak(L, R))} dBFS`);
