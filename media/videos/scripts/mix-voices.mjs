// Mixes the voice-over into the rendered pitch with ffmpeg only.
//
//   node scripts/mix-voices.mjs pitch|demo <voice-dir> [video-in] [video-out]
//
// voice-dir holds one file per answer, named by segment id: q1.m4a … q10.m4a
// for the pitch, d1.m4a … d16.m4a for the demo (any extension ffmpeg reads:
// m4a, mp3, wav, aiff). Each file starts
// at its answer's start time. Leading silence is trimmed, every voice is
// cleaned up (rumble filter, light noise reduction, gentle compression) and
// levelled, the music is lowered under it, and the result is loudness
// normalized for YouTube. A take that runs past its slot is sped up by at most
// 8%; a longer one is cut at the end of its slot and reported, so it can be
// re-recorded.
import {execFileSync} from 'node:child_process';
import {existsSync, readdirSync, readFileSync} from 'node:fs';
import path from 'node:path';

const here = path.dirname(new URL(import.meta.url).pathname);
const root = path.resolve(here, '..');
const video = process.argv[2];
if (!['pitch', 'demo'].includes(video)) {
	console.error('usage: node scripts/mix-voices.mjs pitch|demo <voice-dir> [video-in] [video-out]');
	process.exit(1);
}
const voiceDir = path.resolve(process.argv[3] ?? path.join(root, 'public/voice', video));
const videoIn = path.resolve(process.argv[4] ?? path.join(root, `out/lemma-${video}-music-only.mp4`));
const videoOut = path.resolve(process.argv[5] ?? path.join(root, `out/lemma-${video}.mp4`));
const timeline = JSON.parse(readFileSync(path.join(root, `src/timeline-${video}.json`), 'utf8'));

const probe = (file) =>
	Number(execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', file]).toString().trim());

const files = existsSync(voiceDir) ? readdirSync(voiceDir) : [];
const inputs = [];
const filters = [];
const problems = [];
for (const s of timeline.segments) {
	const file = files.find((f) => path.parse(f).name.toLowerCase() === s.id);
	if (!file) {
		problems.push(`${s.id}: no voice file (${s.speaker}: "${s.question}")`);
		continue;
	}
	const full = path.join(voiceDir, file);
	const slot = (s.end - s.answerStart) / timeline.fps - 0.3;
	const length = probe(full);
	let tempo = 1;
	if (length > slot) {
		tempo = length / slot;
		if (tempo > 1.08) {
			problems.push(`${s.id}: take is ${length.toFixed(1)} s, slot is ${slot.toFixed(1)} s. Re-record it a little faster.`);
			tempo = 1.08;
		}
	}
	const index = inputs.length + 1;
	inputs.push(full);
	const delay = Math.round((s.answerStart / timeline.fps + 0.25) * 1000);
	filters.push(
		`[${index}:a]silenceremove=start_periods=1:start_threshold=-45dB,highpass=f=80,afftdn=nf=-25,` +
			`acompressor=threshold=-20dB:ratio=3:attack=5:release=120,` +
			`${tempo > 1 ? `atempo=${tempo.toFixed(3)},` : ''}atrim=0:${slot.toFixed(2)},afade=t=out:st=${(slot - 0.3).toFixed(2)}:d=0.3,` +
			`loudnorm=I=-17:TP=-2:LRA=7,` +
			`aresample=48000,adelay=${delay}|${delay}[v${index}]`,
	);
	console.log(`${s.id}  ${file}  ${length.toFixed(1)} s  slot ${slot.toFixed(1)} s${tempo > 1 ? `  sped up ${((tempo - 1) * 100).toFixed(1)}%` : ''}`);
}

if (inputs.length === 0) {
	console.error(`No voice files found in ${voiceDir}. Name them by segment id, for example ${timeline.segments[0].id}.m4a.`);
	process.exit(1);
}

const voices = inputs.map((_, i) => `[v${i + 1}]`).join('');
const graph = [
	'[0:a]aresample=48000,volume=0.6[m]',
	...filters,
	`[m]${voices}amix=inputs=${inputs.length + 1}:normalize=0:dropout_transition=0,loudnorm=I=-15:TP=-1.5:LRA=9[a]`,
].join(';');

execFileSync(
	'ffmpeg',
	['-y', '-v', 'error', '-i', videoIn, ...inputs.flatMap((f) => ['-i', f]), '-filter_complex', graph, '-map', '0:v', '-map', '[a]', '-c:v', 'copy', '-c:a', 'aac', '-b:a', '192k', '-shortest', videoOut],
	{stdio: 'inherit'},
);
console.log(`\nWrote ${videoOut}`);
if (problems.length) {
	console.log('\nCheck these:');
	for (const p of problems) console.log(`- ${p}`);
}
