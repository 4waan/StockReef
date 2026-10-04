// Builds src/timeline-<video>.json from <video>.json (pitch or demo): when each
// question card, answer and caption phrase starts, in frames. The Remotion
// composition and the music synth both read it, so picture and sound share
// one clock.
//
//   node scripts/timeline.mjs pitch|demo
import {readFileSync, writeFileSync} from 'node:fs';

const video = process.argv[2];
if (!['pitch', 'demo'].includes(video)) throw new Error('usage: node scripts/timeline.mjs pitch|demo');
const script = JSON.parse(readFileSync(new URL(`../${video}.json`, import.meta.url), 'utf8'));
const {fps} = script;
const sec = (s) => Math.round(s * fps);
const words = (text) => text.split(/\s+/).filter(Boolean).length;

let cursor = sec(script.introSeconds);
const segments = script.segments.map((segment, index) => {
	const questionStart = cursor;
	const answerStart = questionStart + sec(script.questionSeconds);
	const answerWords = segment.phrases.reduce((n, p) => n + words(p), 0);
	const speech = sec(answerWords / script.wordsPerSecond);
	let phraseCursor = answerStart + sec(0.3);
	const phrases = segment.phrases.map((text) => {
		const start = phraseCursor;
		const length = Math.round((words(text) / answerWords) * speech);
		phraseCursor += length;
		return {text, start, end: phraseCursor};
	});
	const end = phraseCursor + sec(script.answerPadSeconds);
	cursor = end;
	return {
		id: segment.id,
		index,
		question: segment.question,
		speaker: segment.speaker,
		questionStart,
		answerStart,
		end,
		words: answerWords,
		phrases,
	};
});

const outroStart = cursor;
const total = outroStart + sec(script.outroSeconds);
const timeline = {fps, total, introEnd: sec(script.introSeconds), outroStart, segments};
writeFileSync(new URL(`../src/timeline-${video}.json`, import.meta.url), JSON.stringify(timeline, null, '\t') + '\n');

const clock = (f) => {
	const s = f / fps;
	return `${Math.floor(s / 60)}:${(s % 60).toFixed(1).padStart(4, '0')}`;
};
for (const s of segments) {
	console.log(`${s.id.padEnd(4)} ${clock(s.questionStart)}–${clock(s.end)}  ${s.speaker.padEnd(6)} ${s.words} words  ${s.question}`);
}
console.log(`outro ${clock(outroStart)}–${clock(total)}  total ${clock(total)}`);
