import React from 'react';
import {AbsoluteFill, Audio, Easing, Img, interpolate, OffthreadVideo, Sequence, staticFile, useCurrentFrame} from 'remotion';
import timeline from './timeline-demo.json';
import {Backdrop} from './Video';
import {Outro} from './Pitch';
import {C, ease, F, rise, useFonts} from './theme';
import landing from '../public/rec/landing.json';
import problem from '../public/rec/problem.json';
import book from '../public/rec/book.json';
import countdown from '../public/rec/countdown.json';
import paydown from '../public/rec/paydown.json';
import trim from '../public/rec/trim.json';
import weekend from '../public/rec/weekend.json';
import monday from '../public/rec/monday.json';
import mondayAdmit from '../public/rec/monday-admit.json';
import recovery from '../public/rec/recovery.json';
import lenders from '../public/rec/lenders.json';
import failure from '../public/rec/failure.json';
import {DataScene, NextScene, TestsScene} from './scenes/live';

// The demo: continuous screen recordings of the deployed app on the public chain 46630 testnet (capture/record.mjs),
// cut and timed by scripts/demo-timeline.mjs. Every transaction shown was signed and confirmed on that testnet.

type Point = {t: number; x: number; y: number; click?: boolean};
type ClipEvent = {t: number; kind: string; label?: string; role?: string; hash?: string};
type Clip = {name: string; duration: number; cursor: Point[]; events: ClipEvent[]};
type Piece = {clip: string; from: number; to: number; speed: number; start: number; end: number};
type Phrase = {text: string; start: number; end: number};
type Chapter = {id: string; question: string; speaker: string; questionStart: number; end: number; graphic: boolean; clips: Piece[]; urls: {frame: number; url: string}[]; phrases: Phrase[]};
type Timeline = {fps: number; outroStart: number; total: number; segments: Chapter[]};

const tl = timeline as unknown as Timeline;
const FPS = tl.fps;
const CLIPS: Record<string, Clip> = Object.fromEntries(
	[landing, problem, book, countdown, paydown, trim, weekend, monday, mondayAdmit, recovery, lenders, failure].map((c) => [c.name, c as Clip]),
);

// The recordings are 1600 × 900 CSS pixels at 1.2× (1920 × 1080 video pixels).
const CSS = 1.2;
const WIN = {x: 150, y: 104, w: 1620, bar: 42};
const VIEW_H = (WIN.w * 9) / 16;
const SCALE = WIN.w / 1920;

/** Camera moves per chapter: [from s, to s, zoom, focus x, focus y] in the recording's CSS pixels. */
const ZOOMS: Record<string, [number, number, number, number, number][]> = {
	intro: [[1.2, 6.8, 1.18, 640, 260]],
	problem: [[2, 13.5, 1.38, 560, 330]],
	book: [[2.2, 9.6, 1.3, 760, 330], [11.2, 19.6, 1.35, 700, 560], [21.4, 29, 1.35, 820, 340]],
	countdown: [[3, 8.6, 1.32, 700, 340], [9, 20, 1.75, 560, 90]],
	paydown: [[1.4, 9.8, 1.65, 1010, 170], [10.6, 16.5, 1.85, 1430, 600], [16.8, 21.8, 1.35, 720, 380], [23, 31, 1.22, 820, 420]],
	trim: [[1.2, 13.2, 1.45, 980, 380], [14.2, 20.2, 1.75, 1430, 600], [21.4, 26.4, 1.2, 820, 420]],
	weekend: [[0.6, 4.2, 1.8, 420, 200], [4.6, 22, 1.65, 1420, 360], [23, 29.8, 1.8, 600, 200], [31, 35.4, 1.8, 600, 200], [35.6, 39, 1.4, 760, 600], [39.6, 54, 1.45, 980, 420]],
	lenders: [[3.2, 16.4, 1.5, 720, 280]],
	failure: [[5.4, 17.3, 1.85, 1420, 560]],
};

/** The camera at `s` seconds into a chapter: zoom and the recording point at the centre of the window. */
function camera(id: string, s: number) {
	let z = 1;
	let fx = 800;
	let fy = 450;
	for (const [a, b, zoom, x, y] of ZOOMS[id] ?? []) {
		const k = interpolate(s, [a - 0.7, a, b, b + 0.7], [0, 1, 1, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: Easing.bezier(0.45, 0, 0.2, 1)});
		if (k > 0) {
			z = 1 + (zoom - 1) * k;
			fx = 800 + (x - 800) * k;
			fy = 450 + (y - 450) * k;
		}
	}
	return {z, fx, fy};
}

/** Which clip, and where in it, plays at chapter frame `f`. */
function clipAt(ch: Chapter, frame: number) {
	const p = ch.clips.find((c) => frame >= c.start && frame < c.end) ?? (frame < ch.clips[0].start ? ch.clips[0] : ch.clips[ch.clips.length - 1]);
	const s = p.from + (Math.min(Math.max(frame, p.start), p.end) - p.start) / FPS * p.speed;
	return {piece: p, s};
}

/** Where a clip moment lands on the video, in frames (the nearest kept moment if it was cut). */
function frameOf(ch: Chapter, clip: string, s: number): number | undefined {
	const pieces = ch.clips.filter((c) => c.clip === clip);
	for (const p of pieces) if (s >= p.from && s <= p.to) return p.start + Math.round(((s - p.from) / p.speed) * FPS);
	return undefined;
}

function cursorAt(clip: Clip, s: number) {
	const pts = clip.cursor;
	if (s <= pts[0].t) return pts[0];
	for (let i = 1; i < pts.length; i++) {
		if (pts[i].t >= s) {
			const a = pts[i - 1];
			const b = pts[i];
			const k = b.t === a.t ? 1 : (s - a.t) / (b.t - a.t);
			return {t: s, x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k};
		}
	}
	return pts[pts.length - 1];
}

const Pointer: React.FC<{x: number; y: number; ripple: number}> = ({x, y, ripple}) => (
	<div style={{position: 'absolute', left: x, top: y, width: 0, height: 0}}>
		{ripple > 0 ? (
			<div
				style={{
					position: 'absolute',
					left: -40 * ripple,
					top: -40 * ripple,
					width: 80 * ripple,
					height: 80 * ripple,
					borderRadius: 999,
					border: `3px solid ${C.brand}`,
					opacity: 1 - ripple,
				}}
			/>
		) : null}
		<svg width="30" height="36" viewBox="0 0 30 36" style={{position: 'absolute', left: -3, top: -2, filter: 'drop-shadow(0 2px 3px rgba(0,0,0,0.35))'}}>
			<path d="M3 2 L3 29 L10 22.5 L14.5 33 L19 31 L14.6 20.8 L24 20.8 Z" fill="#17191C" stroke="#fff" strokeWidth="2.2" strokeLinejoin="round" />
		</svg>
	</div>
);

/** A browser window playing the chapter's recording, with the camera, the cursor and the real address bar. */
const AppWindow: React.FC<{ch: Chapter}> = ({ch}) => {
	const f = useCurrentFrame();
	const abs = ch.questionStart + f;
	const s = f / FPS;
	const cam = camera(ch.id, s);
	const {piece, s: clipS} = clipAt(ch, abs);
	const clip = CLIPS[piece.clip];
	const onExplorer = (ch.urls.filter((u) => u.frame <= abs).pop()?.url ?? '').startsWith('explorer');
	const p = cursorAt(clip, clipS);
	const lastClick = [...clip.cursor].reverse().find((c) => c.click && c.t <= clipS);
	const since = lastClick ? (clipS - lastClick.t) / piece.speed : 9;
	const ripple = since < 0.5 ? since / 0.5 : 0;
	const url = ch.urls.filter((u) => u.frame <= abs).pop()?.url ?? 'stock-reef.vercel.app';
	// Content transform: scale by z around the focus, clamped to the recording's edges.
	const viewW = 1600;
	const viewH = 900;
	const visW = viewW / cam.z;
	const visH = viewH / cam.z;
	const left = Math.max(0, Math.min(viewW - visW, cam.fx - visW / 2));
	const top = Math.max(0, Math.min(viewH - visH, cam.fy - visH / 2));
	const k = (WIN.w / viewW) * cam.z;
	return (
		<div style={{position: 'absolute', left: WIN.x, top: WIN.y, width: WIN.w, height: VIEW_H + WIN.bar, borderRadius: 16, overflow: 'hidden', background: C.surface, border: `2px solid ${C.line}`, boxShadow: `0 24px 60px ${C.shadow}`}}>
			<div style={{height: WIN.bar, display: 'flex', alignItems: 'center', gap: 10, padding: '0 16px', background: C.surface2, borderBottom: `1px solid ${C.line}`}}>
				{['#FF5F57', '#FEBC2E', '#28C840'].map((c) => (
					<span key={c} style={{width: 12, height: 12, borderRadius: 99, background: c}} />
				))}
				<div style={{marginLeft: 14, flex: 1, height: 28, borderRadius: 8, background: C.surface, display: 'flex', alignItems: 'center', padding: '0 14px', fontFamily: F.mono, fontSize: 17, color: C.muted, overflow: 'hidden', whiteSpace: 'nowrap'}}>
					<span style={{color: C.up, marginRight: 8}}>🔒</span>
					<span style={{color: onExplorer ? C.text : C.muted}}>{url}</span>
				</div>
				<span style={{fontFamily: F.head, fontSize: 16, color: C.muted, marginLeft: 12}}>Robinhood Chain testnet · 46630</span>
			</div>
			<div style={{position: 'relative', width: WIN.w, height: VIEW_H, overflow: 'hidden'}}>
				<div style={{position: 'absolute', left: 0, top: 0, width: viewW, height: viewH, transformOrigin: '0 0', transform: `scale(${k}) translate(${-left}px, ${-top}px)`}}>
					{ch.clips.map((c, i) => (
						<Sequence key={i} from={c.start - ch.questionStart} durationInFrames={Math.max(1, c.end - c.start)} layout="none">
							<OffthreadVideo src={staticFile(`rec/${c.clip}.mp4`)} startFrom={Math.round(c.from * FPS)} playbackRate={c.speed} muted style={{position: 'absolute', left: 0, top: 0, width: viewW, height: viewH}} />
						</Sequence>
					))}
					{abs >= ch.clips[ch.clips.length - 1].end ? (
						// A hold after the last piece keeps its final frame.
						<Img src={staticFile(`rec/${piece.clip}-last.jpg`)} style={{position: 'absolute', left: 0, top: 0, width: viewW, height: viewH}} />
					) : null}
					<Pointer x={p.x} y={p.y} ripple={ripple} />
				</div>
			</div>
		</div>
	);
};

/** Notes on what the testnet clock and price are doing, by chapter: [seconds, text, tone]. */
const NOTES: Record<string, [number, string, 'amber' | 'red' | 'up' | 'accent'][]> = {
	countdown: [[2.2, 'Fri 15:15 · safe limit 71.66% and falling', 'accent']],
	weekend: [
		[0.3, 'Fri 16:00 · market closed · no new borrowing', 'amber'],
		[22.6, 'Mon 09:31 · new price $376 · waiting 5 minutes', 'amber'],
		[30.8, 'Mon 09:35 · price accepted · every loan checked', 'up'],
	],
	failure: [
		[0.4, 'Price feed stopped 2 minutes ago', 'amber'],
		[9.6, '✗ The contract said no · nothing was signed', 'red'],
	],
};

/** Transaction toasts: the real hash as it is signed, then the confirmation on chain. */
const TxToasts: React.FC<{ch: Chapter}> = ({ch}) => {
	const f = useCurrentFrame();
	const abs = ch.questionStart + f;
	const items: {frame: number; text: React.ReactNode; tone: string}[] = [];
	for (const piece of ch.clips) {
		const clip = CLIPS[piece.clip];
		for (const e of clip.events) {
			const at = frameOf(ch, piece.clip, e.t);
			if (at === undefined || items.some((i) => i.frame === at)) continue;
			if (e.kind === 'tx' && e.hash) {
				items.push({frame: at, tone: C.accent, text: <>Signed by the {e.role?.toLowerCase()} · <span style={{fontFamily: F.mono}}>{e.hash.slice(0, 8)}…{e.hash.slice(-4)}</span></>});
			} else if (e.kind === 'mark' && e.label === 'confirmed') {
				items.push({frame: at, tone: C.up, text: <>✓ Confirmed on Robinhood Chain testnet</>});
			}
		}
	}
	const tones = {amber: C.amber, red: C.red, up: C.up, accent: C.accent};
	for (const [sec, text, tone] of NOTES[ch.id] ?? []) items.push({frame: ch.questionStart + Math.round(sec * FPS), tone: tones[tone], text: <>{text}</>});
	items.sort((a, b) => a.frame - b.frame);
	const live = items.filter((i) => abs >= i.frame && abs < i.frame + 5 * FPS).slice(-3);
	return (
		<div style={{position: 'absolute', right: WIN.x + 24, top: WIN.y + WIN.bar + 20, display: 'flex', flexDirection: 'column', gap: 10, alignItems: 'flex-end'}}>
			{live.map((i) => {
				const k = ease(abs, i.frame, i.frame + 10) * (1 - ease(abs, i.frame + 5 * FPS - 12, i.frame + 5 * FPS));
				return (
					<div key={i.frame} style={{padding: '12px 20px', borderRadius: 12, background: C.surface, border: `2px solid ${i.tone}`, boxShadow: `0 10px 30px ${C.shadow}`, fontFamily: F.head, fontSize: 24, color: C.text, opacity: k, transform: `translateY(${(1 - k) * -12}px)`}}>
						{i.text}
					</div>
				);
			})}
		</div>
	);
};

const FEATURES = ['Debt reduced before the close', 'Falling threshold', 'Funded repayment buffer', 'Partial liquidation', 'Closed-session protection', 'Controlled reopening', 'Lender loss accounting'];
const SHOWS: Record<string, number[]> = {countdown: [1, 0], paydown: [2, 0], trim: [3], weekend: [4, 5], lenders: [6]};

/** The chapter title, top left, and the seven core features ticking off, top right. */
const Header: React.FC<{ch: Chapter; index: number}> = ({ch, index}) => {
	const f = useCurrentFrame();
	const abs = ch.questionStart + f;
	const now = SHOWS[ch.id] ?? [];
	const seen = new Set<number>();
	for (const s of tl.segments) {
		if (s.questionStart > abs) break;
		for (const i of SHOWS[s.id] ?? []) seen.add(i);
	}
	const exit = 1 - ease(f, ch.end - ch.questionStart - 8, ch.end - ch.questionStart);
	return (
		<>
			<div style={{position: 'absolute', left: WIN.x, top: 34, display: 'flex', alignItems: 'center', gap: 16, opacity: exit, ...rise(f, 0, -12, 12)}}>
				<span style={{fontFamily: F.mono, fontSize: 22, fontWeight: 700, color: '#fff', background: C.brand, borderRadius: 8, padding: '4px 10px'}}>{String(index + 1).padStart(2, '0')}</span>
				<span style={{fontFamily: F.head, fontWeight: 600, fontSize: 36, letterSpacing: -0.5}}>{ch.question}</span>
			</div>
			{seen.size ? (
				<div style={{position: 'absolute', right: WIN.x, top: 38, display: 'flex', alignItems: 'center', gap: 12, opacity: exit}}>
					{now.length ? <span style={{fontFamily: F.head, fontSize: 22, fontWeight: 600, color: C.accent}}>{now.map((i) => FEATURES[i]).join(' · ')}</span> : null}
					<div style={{display: 'flex', gap: 5}}>
						{FEATURES.map((name, i) => (
							<span
								key={name}
								style={{
									width: 28,
									height: 28,
									borderRadius: 7,
									display: 'flex',
									alignItems: 'center',
									justifyContent: 'center',
									fontFamily: F.mono,
									fontSize: 15,
									fontWeight: 700,
									background: now.includes(i) ? C.brand : seen.has(i) ? `${C.brand}2e` : C.surface,
									color: now.includes(i) ? '#fff' : seen.has(i) ? C.accent : C.faint,
									border: `1.5px solid ${now.includes(i) || seen.has(i) ? C.brand : C.line}`,
								}}
							>
								{i + 1}
							</span>
						))}
					</div>
					<span style={{fontFamily: F.mono, fontSize: 18, color: C.muted}}>{seen.size}/7</span>
				</div>
			) : null}
		</>
	);
};

const Caption: React.FC<{ch: Chapter}> = ({ch}) => {
	const f = useCurrentFrame();
	const abs = ch.questionStart + f;
	const p = ch.phrases.find((x) => abs >= x.start && abs < x.end + 10);
	if (!p) return null;
	const k = ease(abs, p.start, p.start + 6) * (1 - ease(abs, p.end + 4, p.end + 10));
	return (
		<div style={{position: 'absolute', left: 0, right: 0, bottom: 34, display: 'flex', justifyContent: 'center', opacity: k}}>
			<div style={{maxWidth: 1500, padding: '14px 30px', borderRadius: 16, background: `${C.surface}f2`, border: `2px solid ${C.line}`, boxShadow: `0 12px 34px ${C.shadow}`, display: 'flex', alignItems: 'baseline', gap: 16}}>
				<span style={{fontFamily: F.head, fontWeight: 600, fontSize: 24, color: C.accent}}>{ch.speaker}</span>
				<span style={{fontFamily: F.head, fontSize: 36, lineHeight: 1.25}}>{p.text}</span>
			</div>
		</div>
	);
};

/** Guide render: the line to read now, the next one, and the timecode, for recording the voice-over. */
const Prompter: React.FC<{ch: Chapter}> = ({ch}) => {
	const f = useCurrentFrame();
	const abs = ch.questionStart + f;
	const i = ch.phrases.findIndex((x) => abs < x.end);
	const cur = ch.phrases[i];
	const next = ch.phrases[i + 1];
	const tc = `${Math.floor(abs / FPS / 60)}:${String(Math.floor((abs / FPS) % 60)).padStart(2, '0')}`;
	return (
		<div style={{position: 'absolute', left: 60, right: 60, bottom: 24, padding: '20px 30px', borderRadius: 18, background: `${C.surface}f5`, border: `3px solid ${cur && abs >= cur.start ? C.red : C.amber}`}}>
			<div style={{display: 'flex', gap: 20, fontFamily: F.mono, fontSize: 24, color: C.muted}}>
				<span style={{color: C.text, fontWeight: 700}}>{tc}</span>
				<span>{ch.speaker}</span>
				<span>{ch.id}</span>
				<span>{cur && abs < cur.start ? `starts in ${((cur.start - abs) / FPS).toFixed(1)} s` : 'speak'}</span>
			</div>
			<div style={{fontFamily: F.head, fontSize: 40, marginTop: 8, color: C.text}}>{cur?.text ?? ''}</div>
			<div style={{fontFamily: F.head, fontSize: 28, marginTop: 6, color: C.faint}}>{next?.text ?? ''}</div>
		</div>
	);
};

const GRAPHICS: Partial<Record<string, React.FC<{ch: Chapter}>>> = {data: DataScene, tests: TestsScene, next: NextScene};

export type DemoProps = {guide: boolean; voices: Record<string, string>};

export const Demo: React.FC<DemoProps> = ({guide, voices}) => {
	useFonts();
	return (
		<AbsoluteFill style={{background: C.bg, fontFamily: F.body, color: C.text}}>
			<Backdrop />
			{tl.segments.map((ch, index) => {
				const G = GRAPHICS[ch.id];
				return (
					<Sequence key={ch.id} from={ch.questionStart} durationInFrames={ch.end - ch.questionStart} name={ch.question}>
						{G ? <G ch={ch} /> : <AppWindow ch={ch} />}
						{G ? null : <TxToasts ch={ch} />}
						<Header ch={ch} index={index} />
						{guide ? <Prompter ch={ch} /> : <Caption ch={ch} />}
					</Sequence>
				);
			})}
			<Sequence from={tl.outroStart} name="Outro">
				<Outro />
			</Sequence>
			<Audio src={staticFile('music-demo.wav')} volume={Object.keys(voices).length ? 0.5 : 1} />
			{tl.segments.map((ch) =>
				voices[ch.id] ? (
					<Sequence key={`voice-${ch.id}`} from={ch.phrases[0]?.start ?? ch.questionStart} name={`voice ${ch.id}`}>
						<Audio src={staticFile(`voice/demo/${voices[ch.id]}`)} />
					</Sequence>
				) : null,
			)}
		</AbsoluteFill>
	);
};

export const DEMO_FRAMES = tl.total;
export type {Chapter};
