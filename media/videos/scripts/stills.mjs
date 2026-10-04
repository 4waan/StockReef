// Renders review stills: for each segment, the question card and three moments of the answer.
import {bundle} from '@remotion/bundler';
import {renderStill, selectComposition} from '@remotion/renderer';
import {readFileSync, mkdirSync} from 'node:fs';
import path from 'node:path';

const browserExecutable = process.env.REMOTION_BROWSER;
const comp = process.argv[2] ?? 'Pitch';
const only = process.argv[3];
const timeline = JSON.parse(readFileSync(`src/timeline-${comp.startsWith('Demo') ? 'demo' : 'pitch'}.json`, 'utf8'));
const serveUrl = await bundle({entryPoint: path.resolve('src/index.ts')});
const composition = await selectComposition({serveUrl, id: comp, browserExecutable});
mkdirSync('out/stills', {recursive: true});
const frames = [['intro', 60]];
for (const s of timeline.segments) {
	if (only && s.id !== only) continue;
	const len = s.end - s.answerStart;
	frames.push([`${s.id}-a-question`, s.questionStart + 30]);
	frames.push([`${s.id}-b-early`, s.answerStart + Math.round(len * 0.3)]);
	frames.push([`${s.id}-c-mid`, s.answerStart + Math.round(len * 0.62)]);
	frames.push([`${s.id}-d-late`, s.end - 12]);
}
frames.push(['outro', timeline.outroStart + 90]);
for (const [name, frame] of frames) {
	await renderStill({composition, serveUrl, frame, output: `out/stills/${comp}-${name}.jpg`, imageFormat: 'jpeg', jpegQuality: 70, browserExecutable});
	console.log(name, frame);
}
