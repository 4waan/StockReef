// Builds src/timeline-demo.json from demo.json and the recorded clips (public/rec/<clip>.json): each chapter's
// frames, which slice of which clip plays when and at what speed, the address bar, each caption phrase and the
// music cues. The composition and scripts/music.mjs both read it, so picture, words and music share one clock.
//
//   node scripts/demo-timeline.mjs
//
// A phrase is "text" (it follows the previous one) or [seconds into the chapter, "text"] (anchored to what the
// recording shows at that moment). Phrases are timed at wordsPerSecond; an overrun is reported.
import {readFileSync, writeFileSync} from 'node:fs';

const root = new URL('../', import.meta.url);
const script = JSON.parse(readFileSync(new URL('demo.json', root), 'utf8'));
const {fps, wordsPerSecond} = script;
const f = (s) => Math.round(s * fps);
const words = (t) => t.split(/\s+/).filter(Boolean).length;
const clipInfo = (name) => JSON.parse(readFileSync(new URL(`public/rec/${name}.json`, root), 'utf8'));

let cursor = 0;
const segments = script.chapters.map((ch) => {
	const start = cursor;
	let t = 0;
	const clips = (ch.segments ?? []).map(([clip, from, to, speed]) => {
		const info = clipInfo(clip);
		const end = Math.min(to, info.duration);
		const len = (end - from) / speed;
		const piece = {clip, from, to: end, speed, start: start + f(t), end: start + f(t + len)};
		t += len;
		return piece;
	});
	t += ch.hold ?? 0;
	if (ch.graphic) t = ch.graphic;
	const length = f(t);
	let at = 0;
	const phrases = ch.phrases.map((p) => {
		const [anchor, text] = Array.isArray(p) ? p : [undefined, p];
		const s = anchor ?? at;
		const e = s + words(text) / wordsPerSecond;
		at = e + 0.15;
		if (e > t + 0.01) console.warn(`  ${ch.id}: "${text.slice(0, 40)}…" ends at ${e.toFixed(1)} s, after the chapter (${t.toFixed(1)} s)`);
		return {text, start: start + f(s), end: start + f(e)};
	});
	cursor = start + length;
	return {
		id: ch.id,
		question: ch.title,
		speaker: ch.speaker,
		questionStart: start,
		answerStart: start,
		end: start + length,
		graphic: !!ch.graphic,
		clips,
		urls: (ch.urls ?? []).map(([s, url]) => ({frame: start + f(s), url})),
		phrases,
	};
});

const outroStart = cursor;
const total = outroStart + f(script.outroSeconds);
const byId = Object.fromEntries(segments.map((s) => [s.id, s]));
const cues = script.cues.map(([id, s, kind]) => ({frame: byId[id].questionStart + f(s), kind}));
const timeline = {fps, introEnd: f(3), outroStart, total, segments, cues};
writeFileSync(new URL('src/timeline-demo.json', root), JSON.stringify(timeline, null, '\t') + '\n');

const mmss = (fr) => `${Math.floor(fr / fps / 60)}:${(fr / fps % 60).toFixed(1).padStart(4, '0')}`;
for (const s of segments) {
	const w = s.phrases.reduce((n, p) => n + words(p.text), 0);
	console.log(`${s.id.padEnd(10)} ${mmss(s.questionStart)}–${mmss(s.end)}  ${s.speaker.padEnd(5)}  ${String(w).padStart(2)} words  ${s.question}`);
}
console.log(`outro      ${mmss(outroStart)}–${mmss(total)}  total ${mmss(total)}`);
