// Turns each recorded clip (public/rec/<clip>/: screencast frames with timestamps, cursor path, events) into a
// constant 30 fps video and a timing file the composition reads:
//
//   node capture/build-clips.mjs [clip …]   →   public/rec/<clip>.mp4 and public/rec/<clip>.json
//
// A screencast frame arrives only when the page repaints, so each frame is held until the next one; the cursor is
// drawn by the composition from the logged path, on the same clock (seconds from the clip's start).
import {execFileSync} from 'node:child_process';
import {existsSync, readdirSync, readFileSync, writeFileSync} from 'node:fs';

const REC = new URL('../public/rec/', import.meta.url).pathname;
const only = process.argv.slice(2);

for (const name of readdirSync(REC)) {
	if (!existsSync(`${REC}${name}/clip.json`) || (only.length && !only.includes(name))) continue;
	const c = JSON.parse(readFileSync(`${REC}${name}/clip.json`, 'utf8'));
	const frames = c.frames.filter((f) => f.t >= c.start - 0.5 && f.t <= c.end + 0.5);
	if (!frames.length) {
		console.log(`${name}: no frames`);
		continue;
	}
	// The first frame stands for the clip's start, the last is held to its end.
	const lines = [];
	frames.forEach((f, i) => {
		const t0 = i === 0 ? c.start : f.t;
		const t1 = i + 1 < frames.length ? frames[i + 1].t : c.end;
		lines.push(`file '${REC}${name}/${f.file}'`, `duration ${Math.max(0.001, t1 - t0).toFixed(4)}`);
	});
	lines.push(`file '${REC}${name}/${frames.at(-1).file}'`);
	writeFileSync(`${REC}${name}/frames.txt`, lines.join('\n') + '\n');
	execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'concat', '-safe', '0', '-i', `${REC}${name}/frames.txt`, '-vf', 'scale=1920:1080:flags=lanczos,fps=30,format=yuv420p', '-c:v', 'libx264', '-crf', '16', '-preset', 'medium', '-movflags', '+faststart', `${REC}${name}.mp4`]);
	execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-sseof', '-0.2', '-i', `${REC}${name}.mp4`, '-frames:v', '1', '-q:v', '2', `${REC}${name}-last.jpg`]);
	const rel = (t) => Math.round((t - c.start) * 1000) / 1000;
	const timing = {
		name,
		duration: rel(c.end),
		cursor: c.cursor.map((p) => ({t: rel(p.t), x: Math.round(p.x * 10) / 10, y: Math.round(p.y * 10) / 10, ...(p.click ? {click: true} : {})})),
		events: c.events.map((e) => ({...e, t: rel(e.t)})),
	};
	writeFileSync(`${REC}${name}.json`, JSON.stringify(timing) + '\n');
	console.log(`${name}: ${timing.duration.toFixed(1)} s, ${frames.length} frames, ${timing.events.length} events`);
}
