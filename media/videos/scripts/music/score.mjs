// What the music plays and when.
//
// Harmony: F# minor, voice-led by hand, resolving to its relative major, A,
// on the outro: the weekend gap held open, then released at the reopening.
// The StockReef motif is root, fifth, ninth, third (F# C# G# A in the minor,
// A E B C# in the major), so the tune that opens on F# minor already ends on
// the note the piece finally comes home to.
//
// Time: about 96 BPM, but the grid is stretched a beat at a time (within
// about 2%) so every section starts exactly on a question card or a cue.
//
// Cues (timeline.cues, optional): [{frame, kind}] with kind one of
//   bell      the closing bell, three descending strokes
//   chime     the confirmation ping, two rising notes
//   tick-on   fade the ticking clock in (it stops by itself at the outro)
//   tick-off  fade it out
//   lift      a riser and a brighter, fuller section from this frame
//   breath    everything but the pad stops for about two seconds
// Without a cues array the clock ticks under the intro and again through the
// last answer, the countdown to the close. Either way every question card
// gets a barely-there lift (a cued lift on a card makes it a full one), and
// the outro stops the clock and rings the bell.
import {random} from './dsp.mjs';

const BPM = 96;
const KINDS = ['bell', 'chime', 'tick-on', 'tick-off', 'lift', 'breath'];

// Each chord's bass note and, where the motif can be played over it, the
// note the motif starts on.
const CHORDS = {
	'F#m9': {bass: 'F#2', motif: 'F#4'},
	'Dmaj7#11': {bass: 'D2', motif: 'D4', major: true},
	'Dmaj9': {bass: 'D2', motif: 'D4', major: true},
	'Bm9': {bass: 'B1', motif: 'B3'},
	'Bm11': {bass: 'B1', motif: 'B3'},
	'C#7sus4': {bass: 'C#2'},
	'C#7': {bass: 'C#2'},
	'C#m11': {bass: 'C#2'},
	'Amaj9/C#': {bass: 'C#2'},
	'E6/9': {bass: 'E2'},
	'Esus4': {bass: 'E2'},
	'E': {bass: 'E2'},
	'Amaj9': {bass: 'A1', motif: 'A4', major: true},
};

// Progressions, each chord with its pad voicing. Inner voices move by step
// or hold; the top voice draws a slow line that differs per progression: A
// arches C#-E-D-C#, A2 climbs C#-D-E, B falls E-E-D-C#, B2 sits low on
// C#-C#-B-B, and the climb rises C#-E-F#-A-G# so the outro's A lands like
// the motif's last two notes. A pair splits its slot in half.
const PROGRESSIONS = {
	intro: ['F#m9: A3 E4 G#4 C#5', 'Dmaj7#11: A3 F#4 G#4 C#5', ['C#7sus4: G#3 B3 F#4 C#5', 'C#7: G#3 B3 E#4 C#5']],
	A: ['F#m9: A3 E4 G#4 C#5', 'Dmaj7#11: A3 C#4 G#4 E5', 'Bm9: A3 C#4 F#4 D5', ['C#7sus4: G#3 B3 F#4 C#5', 'C#7: G#3 B3 E#4 C#5']],
	A2: ['F#m9: A3 E4 G#4 C#5', 'Bm9: A3 C#4 F#4 D5', 'Dmaj9: A3 C#4 F#4 E5', 'C#7sus4: G#3 B3 F#4 C#5'],
	B: ['Dmaj9: A3 C#4 F#4 E5', 'Amaj9/C#: A3 B3 G#4 E5', 'Bm11: A3 C#4 E4 D5', 'E6/9: G#3 B3 F#4 C#5'],
	B2: ['Bm9: A3 D4 F#4 C#5', 'Dmaj9: A3 E4 F#4 C#5', 'Amaj9/C#: A3 E4 G#4 B4', 'C#7sus4: G#3 C#4 F#4 B4'],
	climb: ['Bm9: A3 D4 F#4 C#5', 'C#m11: G#3 B3 F#4 E5', 'Dmaj9: A3 C#4 E4 F#5', ['Esus4: A3 E4 F#4 B4 A5', 'E: G#3 E4 F#4 B4 G#5']],
	outro: ['Amaj9: A3 C#4 E4 G#4 B4 A5'],
};

const LETTERS = {C: 0, D: 2, E: 4, F: 5, G: 7, A: 9, B: 11};
const midi = (note) => {
	const [, letter, accidental = '', octave] = note.match(/^([A-G])([#b]?)(\d)$/);
	return LETTERS[letter] + {'#': 1, b: -1, '': 0}[accidental] + 12 * (Number(octave) + 1);
};

function chord(slot, t0, t1) {
	const [name, notes] = slot.split(':');
	const {bass, motif, major = false} = CHORDS[name];
	return {name, t0, t1, bass: midi(bass), voicing: notes.trim().split(/\s+/).map(midi), motif: motif && midi(motif), major};
}

// Body sections walk this cycle, so no two neighbours share a progression.
const CYCLE = ['A', 'A2', 'B', 'A', 'B2', 'A2', 'B', 'B2', 'A', 'B', 'A2', 'B2'];

// Energy over the body, 0 to 1: a gentle build, a lighter stretch a little
// past halfway, the fullest stretch before the final climb.
const ENERGY = [[0, 0.25], [0.2, 0.45], [0.4, 0.62], [0.52, 0.45], [0.62, 0.6], [0.88, 0.8], [1, 0.72]];

// Arpeggio patterns: pool indexes on a grid of `step` beats (null rests),
// with the pluck's decay and how many steps a note rings before it is damped.
const ARPS = {
	halves: {step: 2, notes: [0, 3], decay: 1.1},
	quarters: {step: 1, notes: [0, 2, 1, 3], decay: 0.8},
	eighths: {step: 0.5, notes: [0, 2, 4, 2, 3, 1, 4, 2], decay: 0.5, hold: 0.9},
	wave: {step: 0.5, notes: [0, 3, 1, 4, 2, 5, 3, 1], decay: 0.5, hold: 0.9},
	pairs: {step: 0.5, notes: [0, null, 2, 4, null, 3, 1, null], decay: 0.55, hold: 1.4},
	synco: {step: 0.25, notes: [0, null, null, 2, null, null, 4, null, 1, null, null, 3, null, null, 5, null], decay: 0.4, hold: 2.2},
	tresillo: {step: 0.25, notes: [0, null, 3, null, null, 2, null, 4, null, 1, null, null, 3, null, 5, null], decay: 0.4, hold: 1.6},
};

// Bass patterns per bar: [beat, length in beats, interval, velocity].
const BASS = {
	pulse: [[0, 1.4, 0, 1], [1.5, 0.4, 0, 0.6], [2, 1.4, 0, 0.9], [3.5, 0.35, 12, 0.55]],
	drive: [[0, 0.45, 0, 1], [0.5, 0.3, 0, 0.5], [1, 0.45, 0, 0.75], [1.5, 0.3, 0, 0.5], [2, 0.45, 0, 0.9], [2.5, 0.3, 0, 0.5], [3, 0.45, 7, 0.7], [3.5, 0.3, 12, 0.55]],
};

const lerp = (points, x) => {
	for (let k = 1; k < points.length; k++) {
		const [x0, y0] = points[k - 1];
		const [x1, y1] = points[k];
		if (x <= x1) return y0 + ((y1 - y0) * (x - x0)) / (x1 - x0);
	}
	return points.at(-1)[1];
};

export function plan(timeline) {
	const fps = timeline.fps;
	const total = timeline.total / fps;
	const segments = timeline.segments ?? [];
	const introEnd = (timeline.introEnd ?? segments[0]?.questionStart ?? 0) / fps;
	const outroStart = Math.min(total, (timeline.outroStart ?? segments.at(-1)?.end ?? timeline.total) / fps);
	const beat0 = 60 / BPM;
	const cues = readCues(timeline, {fps, total, introEnd, outroStart, segments});

	// Anchors: section starts the grid must hit exactly.
	const candidates = [
		{t: 0, priority: 3},
		{t: introEnd, priority: 2},
		...segments.map((s) => ({t: s.questionStart / fps, priority: 1})),
		...cues.filter((c) => c.kind === 'lift').map((c) => ({t: c.t, priority: 2, lift: c.subtle ? 'subtle' : 'full'})),
		{t: outroStart, priority: 3, outro: true},
	]
		.filter((a) => a.t >= 0 && a.t <= outroStart)
		.sort((a, b) => a.t - b.t || b.priority - a.priority);
	const anchors = [];
	for (const a of candidates) {
		const last = anchors.at(-1);
		if (last && a.t - last.t < 1.6) {
			// Too close to make a section of its own: fold it into its neighbour,
			// at the time of whichever matters more.
			const keep = a.priority > last.priority ? a : last;
			anchors[anchors.length - 1] = {
				t: keep.t,
				priority: keep.priority,
				outro: last.outro || a.outro,
				lift: last.lift === 'full' || a.lift === 'full' ? 'full' : (last.lift ?? a.lift),
			};
		} else anchors.push({...a});
	}

	// Beats and bars between anchors. A leftover beat stretches the last bar
	// to five; two or three leftover beats make a short last bar.
	const sections = anchors.map((a, k) => {
		const t0 = a.t;
		const last = k === anchors.length - 1;
		const t1 = last ? total : anchors[k + 1].t;
		const count = last ? Math.ceil((t1 - t0) / beat0) + 4 : Math.max(2, Math.round((t1 - t0) / beat0));
		const beat = last ? beat0 : (t1 - t0) / count;
		let full = Math.floor(count / 4);
		let rest = count % 4;
		if (rest === 1 && full > 0) [full, rest] = [full - 1, 5];
		const bars = [];
		for (let b = 0; b < full; b++) bars.push({t: t0 + b * 4 * beat, beats: 4});
		if (rest) bars.push({t: t0 + full * 4 * beat, beats: rest});
		const kind = a.outro ? 'outro' : t0 < introEnd - 0.05 ? 'intro' : 'body';
		return {t0, t1, beat, count, bars, kind, lift: a.lift ?? null};
	});
	const body = sections.filter((s) => s.kind === 'body');
	body.forEach((s, j) => {
		s.j = j;
		s.final = j === body.length - 1;
		const p = body.length > 1 ? j / (body.length - 1) : 1;
		s.energy = Math.min(0.92, lerp(ENERGY, p) + (s.lift === 'full' ? 0.12 : 0));
		let name = s.final ? 'climb' : CYCLE[j % CYCLE.length];
		// A cued lift moves to one of the brighter progressions.
		if (s.lift === 'full' && !s.final && name.startsWith('A')) name = body[j - 1]?.progression === 'B' ? 'B2' : 'B';
		s.progression = name;
		s.arp = pickArp(s);
		s.arpLow = j % 4 === 3 && s.energy >= 0.45 ? 64 : 61;
		s.arpVoice = j % 3 === 2 ? 'keys' : 'pluck';
		s.bassMode = s.energy < 0.4 ? 'hold' : s.energy < 0.7 ? 'pulse' : 'drive';
		// Every third section and the last one say the motif once, if the voice
		// leaves room for it.
		s.motif = (j > 0 && j % 3 === 0) || s.final;
	});
	for (const s of sections) {
		if (s.kind === 'intro') [s.progression, s.energy, s.arp, s.arpVoice, s.arpLow] = ['intro', 0.3, 'quarters', 'pluck', 61];
		if (s.kind === 'outro') [s.progression, s.energy, s.lift] = ['outro', 0.5, s.lift ?? 'outro'];
		s.chords = layChords(s, PROGRESSIONS[s.progression]);
	}

	const beats = sections.flatMap((s) => s.bars.flatMap((bar) => Array.from({length: bar.beats}, (_, b) => bar.t + b * s.beat))).filter((t) => t < total);
	const breaths = cues
		.filter((c) => c.kind === 'breath')
		.map((c) => [c.t, beats.find((t) => t >= c.t + 1.9) ?? c.t + 2]);
	const speech = voice(segments, fps);
	const notes = arrange(sections, {cues, beats, breaths, speech, outroStart, total});
	return {total, beat0, sections, speech, notes, cues};
}

// Where the voice is, in seconds: each caption phrase, padded a little, with
// pauses shorter than 1.5 s bridged so the bed does not pump between
// sentences. A segment without phrases counts from its answer to its end.
function voice(segments, fps) {
	const spans = segments
		.flatMap((s) => (s.phrases?.length ? s.phrases.map((p) => [p.start / fps - 0.25, p.end / fps + 0.5]) : [[s.answerStart / fps, s.end / fps - 0.25]]))
		.sort((a, b) => a[0] - b[0]);
	const merged = [];
	for (const [a, b] of spans) {
		const last = merged.at(-1);
		if (last && a - last[1] < 1.5) last[1] = Math.max(last[1], b);
		else merged.push([a, b]);
	}
	return merged;
}

// The cue list: the timeline's own or the default clock, plus the small
// lifts into the cards and the outro's bell.
function readCues(timeline, {fps, total, introEnd, outroStart, segments}) {
	let cues;
	if (Array.isArray(timeline.cues)) {
		cues = timeline.cues
			.filter((c) => {
				const ok = KINDS.includes(c?.kind) && Number.isFinite(c?.frame) && c.frame >= 0 && c.frame <= timeline.total;
				if (!ok) console.warn(`music: ignoring cue ${JSON.stringify(c)}`);
				return ok;
			})
			.map((c) => ({t: c.frame / fps, kind: c.kind}));
	} else {
		cues = [{t: 0, kind: 'tick-on'}, {t: introEnd, kind: 'tick-off'}];
		if (segments.length) cues.push({t: segments.at(-1).questionStart / fps, kind: 'tick-on'});
	}
	for (const s of segments) cues.push({t: s.questionStart / fps, kind: 'lift', subtle: true});
	if (!cues.some((c) => c.kind === 'bell' && Math.abs(c.t - outroStart) < 1.5) && outroStart < total) cues.push({t: outroStart, kind: 'bell'});
	cues.push({t: outroStart, kind: 'tick-off'});
	return cues.sort((a, b) => a.t - b.t);
}

function pickArp(s) {
	if (s.energy < 0.4) return ['halves', 'quarters'][s.j % 2];
	if (s.energy < 0.65) return ['eighths', 'pairs', 'wave'][s.j % 3];
	return ['synco', 'wave', 'tresillo'][s.j % 3];
}

// Spreads a progression over a section's bars, whole bars per chord where it
// can. A short last bar joins the last chord; a section with fewer bars than
// chords keeps the first and last chords and an even pick between.
function layChords(section, progression) {
	const whole = section.bars.filter((b) => b.beats >= 4);
	const short = section.bars.filter((b) => b.beats < 4);
	const bars = whole.length ? whole : section.bars;
	let slots = progression;
	if (bars.length < slots.length) {
		const n = bars.length;
		slots = n === 1 ? [slots[0]] : Array.from({length: n}, (_, i) => progression[Math.round((i * (progression.length - 1)) / (n - 1))]);
	}
	const chords = [];
	let b = 0;
	slots.forEach((slot, k) => {
		const size = Math.floor(bars.length / slots.length) + (k < bars.length % slots.length ? 1 : 0);
		const group = bars.slice(b, b + size);
		b += size;
		if (k === slots.length - 1 && whole.length) group.push(...short);
		const beats = group.reduce((n, bar) => n + bar.beats, 0);
		const t0 = group[0].t;
		const t1 = t0 + beats * section.beat;
		if (Array.isArray(slot)) {
			const tm = t0 + Math.max(1, Math.floor(beats / 2)) * section.beat;
			chords.push(chord(slot[0], t0, tm), chord(slot[1], tm, t1));
		} else chords.push(chord(slot, t0, t1));
	});
	return chords;
}

const chordAt = (section, t) => section.chords.findLast((c) => c.t0 <= t + 1e-6) ?? section.chords[0];

// Chord tones (any octave) from low up an octave and a fifth.
function pool(c, low) {
	const classes = new Set([c.bass, ...c.voicing].map((n) => n % 12));
	const notes = [];
	for (let n = low; n <= low + 19 && notes.length < 7; n++) if (classes.has(n % 12)) notes.push(n);
	return notes;
}

// Turns the sections and cues into note lists, one per instrument.
function arrange(sections, {cues, beats, breaths, speech, outroStart, total}) {
	const n = {pad: [], swell: [], bass: [], pluck: [], keys: [], kick: [], shaker: [], brush: [], clap: [], tick: [], bell: [], chime: [], riser: [], impact: []};
	const rand = random(1907);
	const humanize = () => (rand() - 0.5) * 0.006;
	const breathing = (t) => breaths.some(([a, b]) => t >= a - 0.01 && t < b);
	const breathCut = (t0, t1) => Math.min(t1, ...breaths.filter(([a]) => a > t0).map(([a]) => a));
	const quiet = (t0, t1) => !speech.some(([a, b]) => a < t1 && b > t0);

	// The StockReef motif: root, fifth, ninth, third, on the electric piano,
	// doubled an octave down by a soft pluck.
	const motif = (t, beat, base, major, gain) => {
		if (breathing(t)) return;
		const steps = [[0, 0, 0.85], [0.75, 7, 0.8], [1.5, 14, 0.85], [2, major ? 16 : 15, 1]];
		steps.forEach(([b, interval, v], k) => {
			const last = k === steps.length - 1;
			n.keys.push({start: t + b * beat, midi: base + interval, gain: gain * v, pan: [-0.2, 0.15, -0.1, 0.2][k], decay: last ? 2.2 : 1, bright: 0.9});
			n.pluck.push({start: t + b * beat, midi: base + interval - 12, gain: gain * v * 0.5, pan: 0, decay: last ? 1.2 : 0.6, bright: 0.4});
		});
	};

	for (const s of sections) {
		const {beat} = s;

		// Pad: common tones are held across chord changes instead of re-struck.
		const padGain = s.kind === 'outro' ? 0.05 : 0.046 * (1.15 - 0.3 * s.energy);
		let held = [];
		s.chords.forEach((c, k) => {
			const attack = k > 0 ? 0.7 : s.t0 === 0 ? 0.04 : 0.3;
			held = c.voicing.map((midi, v) => {
				if (k > 0 && held[v]?.midi === midi) {
					held[v].end = c.t1;
					return held[v];
				}
				const note = {start: c.t0, end: Math.min(c.t1, total), midi, gain: padGain, attack, release: s.kind === 'outro' ? 0.6 : 1.6};
				n.pad.push(note);
				return note;
			});
		});

		// Lift into this section: a noise riser and the incoming chord swelling
		// up into the downbeat (the default lifts are barely there).
		if (s.lift && s.t0 > 0) {
			const size = {subtle: [1.5, 0.015, 0.012], outro: [3, 0.035, 0.02], full: [4, 0.06, 0.028]}[s.lift];
			const [beatsLong, riserGain, swellGain] = size;
			const dur = beatsLong * beat;
			n.riser.push({end: s.t0, dur, gain: riserGain});
			const voices = s.lift === 'subtle' ? s.chords[0].voicing.slice(-2).map((m) => m + 12) : s.chords[0].voicing;
			for (const midi of voices) n.swell.push({start: s.t0 - dur, end: s.t0, midi, gain: swellGain, attack: dur, release: 0.05});
			if (s.lift === 'full') n.impact.push({start: s.t0, gain: 0.22});
		}

		if (s.kind === 'outro') {
			// Home: A major under the bell, the motif answering in the major.
			n.bass.push({start: s.t0, dur: total - s.t0, midi: 33, gain: 0.09}, {start: s.t0, dur: total - s.t0, midi: 45, gain: 0.11});
			n.kick.push({start: s.t0, gain: 0.2});
			motif(s.t0 + 2 * beat, beat, 69, true, 0.075);
			continue;
		}

		// Bass.
		const bassGain = {hold: 0.16, pulse: 0.16, drive: 0.14}[s.kind === 'intro' ? 'hold' : s.bassMode];
		if (s.kind === 'intro' || s.bassMode === 'hold') {
			for (const c of s.chords) {
				if (breathing(c.t0)) continue;
				n.bass.push({start: c.t0, dur: breathCut(c.t0, c.t1 - 0.04) - c.t0, midi: c.bass, gain: bassGain});
			}
		} else {
			for (const bar of s.bars) {
				for (const [b, len, interval, v] of BASS[s.bassMode]) {
					if (b >= bar.beats) continue;
					const t = bar.t + b * beat;
					if (breathing(t)) continue;
					const c = chordAt(s, t);
					const end = breathCut(t, Math.min(t + len * beat, c.t1 - 0.03));
					n.bass.push({start: t, dur: end - t, midi: c.bass + interval, gain: bassGain * v});
				}
			}
		}

		// Arpeggio, giving way to the motif: on the intro's first bars, and in a
		// chosen section on the first downbeat (a question card, or a pause in
		// the voice) with 1.6 s clear and a chord the motif fits.
		const arp = ARPS[s.arp];
		const arpGain = (s.arpVoice === 'keys' ? 0.07 : 0.095) * (0.85 + 0.3 * s.energy);
		const motifBar = s.motif ? s.bars.findIndex((bar) => quiet(bar.t, bar.t + 1.6) && chordAt(s, bar.t).motif) : -1;
		s.bars.forEach((bar, bi) => {
			const c = chordAt(s, bar.t);
			const motifHere = s.kind === 'intro' ? bi === 0 || (bi === 1 && s.bars.length > 2) : bi === motifBar;
			if (motifHere && c.motif) {
				motif(bar.t + 0.01, beat, c.motif, c.major, s.kind === 'intro' ? 0.085 : 0.07);
				return;
			}
			for (let st = 0; st * arp.step < bar.beats; st++) {
				const index = arp.notes[st % arp.notes.length];
				if (index === null) continue;
				const b = st * arp.step;
				const t = bar.t + b * beat;
				if (breathing(t)) continue;
				const notes = pool(chordAt(s, t), s.arpLow);
				const accent = b === 0 ? 1 : b % 1 === 0 ? 0.8 : 0.62;
				n[s.arpVoice].push({
					start: t + humanize(),
					midi: notes[index % notes.length],
					gain: arpGain * accent * (0.9 + 0.2 * rand()),
					pan: 0.35 * Math.sin(st * 1.7 + bi),
					decay: s.arpVoice === 'keys' ? arp.decay * 1.6 : arp.decay,
					hold: arp.hold ? arp.hold * arp.step * beat : Infinity,
					bright: s.arpVoice === 'keys' ? 0.6 : 0.5,
				});
			}
		});

		// Drums (none on the intro: the clock is its pulse).
		if (s.kind !== 'body') continue;
		s.bars.forEach((bar, bi) => {
			const lastBar = bi === s.bars.length - 1;
			const e = s.final ? s.energy + ((0.88 - s.energy) * bi) / Math.max(1, s.bars.length - 1) : s.energy;
			let kicks;
			if (s.final && lastBar && s.bars.length > 1) kicks = [[0, 1], [1, 0.6], [2, 0.75], [3, 0.85], [3.5, 0.5]];
			else if (e < 0.3) kicks = bi % 2 === 0 ? [[0, 0.8]] : [];
			else if (e < 0.55) kicks = [[0, 1], [2, 0.65]];
			else if (e < 0.75) kicks = bi % 2 ? [[0, 1], [1.5, 0.4], [2, 0.7]] : [[0, 1], [2, 0.7]];
			else kicks = bi % 2 ? [[0, 1], [1.5, 0.45], [2, 0.75], [3.5, 0.35]] : [[0, 1], [2, 0.75], [2.5, 0.35]];
			const hit = (list, b, entry) => {
				const t = bar.t + b * beat;
				if (b < bar.beats && !breathing(t)) list.push({start: t + humanize(), ...entry});
			};
			for (const [b, v] of kicks) hit(n.kick, b, {gain: 0.19 * v});
			for (let b = 0; b < bar.beats; b++) {
				if (e >= 0.35) [0.5, 0.25, 0.8, 0.3].forEach((v, k) => hit(n.shaker, b + k / 4, {gain: 0.1 * v * (0.6 + e) * (0.85 + 0.3 * rand()), pan: 0.35}));
				if (e >= 0.5) hit(n.brush, b + 0.5, {gain: 0.075 * (0.85 + 0.3 * rand()), pan: -0.3});
			}
			if (e >= 0.6 && bi % 4 === 3) hit(n.clap, 3, {gain: 0.1, pan: 0.1});
			else if (lastBar && e >= 0.4) hit(n.clap, bar.beats - 1, {gain: 0.08, pan: 0.1});
		});
	}

	// The clock: a tick on every beat while it is on.
	const level = tickLevel(cues);
	beats.forEach((t, k) => {
		const v = level(t);
		if (v > 0.02 && t < outroStart && !breathing(t)) n.tick.push({start: t, gain: 0.2 * v, accent: k % 2 === 0, pan: 0.2});
	});

	// The closing bell, three descending strokes (5, 3, 1 of the key), and the
	// confirmation chime, two rising notes.
	for (const c of cues) {
		const major = c.t >= outroStart - 0.05;
		if (c.kind === 'bell') {
			const strokes = major ? [76, 73, 69] : [73, 69, 66];
			strokes.forEach((midi, k) => n.bell.push({start: c.t + k * 0.36, midi, major, gain: 0.09 * [1, 0.8, 0.95][k], ring: k === 2 ? 1.5 : 1, pan: [-0.25, 0.25, 0][k]}));
		}
		if (c.kind === 'chime') {
			const [a, b] = major ? [88, 93] : [85, 90];
			n.chime.push({start: c.t, midi: a, gain: 0.07, decay: 0.25, pan: -0.15}, {start: c.t + 0.12, midi: b, gain: 0.075, decay: 0.7, pan: 0.15});
		}
	}
	return n;
}

// Level of the ticking clock over time: fades in over 1.4 s, out over 0.8 s.
function tickLevel(cues) {
	const keys = [[0, 0]];
	const at = (t) => {
		let v = 0;
		for (let k = 0; k < keys.length; k++) {
			const [t0, v0] = keys[k];
			const [t1, v1] = keys[k + 1] ?? [Infinity, v0];
			if (t >= t0 && t < t1) v = t1 === Infinity ? v0 : v0 + ((v1 - v0) * (t - t0)) / (t1 - t0);
		}
		return v;
	};
	for (const c of cues) {
		if (c.kind !== 'tick-on' && c.kind !== 'tick-off') continue;
		// A cue cuts short any fade still running from the one before.
		const from = at(c.t);
		const cut = keys.findIndex((k) => k[0] >= c.t);
		if (cut >= 0) keys.length = cut;
		const on = c.kind === 'tick-on';
		keys.push([c.t, from], [c.t + (on ? (c.t === 0 ? 0.3 : 1.4) : 0.8), on ? 1 : 0]);
	}
	return at;
}
