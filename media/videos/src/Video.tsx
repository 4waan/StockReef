import React from 'react';
import {AbsoluteFill, Audio, Img, Sequence, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {C, ease, F, lin, rise, useFonts, type SceneProps} from './theme';

export type Phrase = {text: string; start: number; end: number};
export type Segment = {
	id: string;
	index: number;
	question: string;
	speaker: string;
	questionStart: number;
	answerStart: number;
	end: number;
	words: number;
	phrases: Phrase[];
};
export type Timeline = {fps: number; total: number; introEnd: number; outroStart: number; segments: Segment[]};

export type VideoProps = {
	/** Show the teleprompter and timecode instead of captions, for recording the voice-over. */
	guide: boolean;
	/** Voice files in public/voice/<video>, by segment id (for example { "q1": "q1.m4a" }). */
	voices: Record<string, string>;
};

type VideoConfig = {
	name: 'pitch' | 'demo';
	timeline: Timeline;
	scenes: Record<string, React.FC<SceneProps>>;
	Intro: React.FC;
	Outro: React.FC;
	/** Drawn above the scenes and below the captions, across the whole video. */
	Overlay?: React.FC<{segment: Segment | null}>;
};

const QUESTION_EXIT = 10;

export const makeVideo = (config: VideoConfig): React.FC<VideoProps> => {
	const View: React.FC<VideoProps> = (props) => <VideoView {...props} config={config} />;
	return View;
};

const VideoView: React.FC<VideoProps & {config: VideoConfig}> = ({guide, voices, config}) => {
	useFonts();
	const frame = useCurrentFrame();
	const {timeline, scenes, Intro, Outro, Overlay} = config;
	const hasVoices = Object.keys(voices).length > 0;
	const current = timeline.segments.find((s) => frame >= s.questionStart && frame < s.end) ?? null;

	return (
		<AbsoluteFill style={{background: C.bg, fontFamily: F.body, color: C.text}}>
			<Backdrop />
			<Sequence durationInFrames={timeline.introEnd} name="Intro">
				<Intro />
			</Sequence>
			{timeline.segments.map((s) => (
				<Sequence key={s.id} from={s.questionStart} durationInFrames={s.end - s.questionStart} name={`${s.id}: ${s.question}`}>
					<SegmentView segment={s} total={timeline.segments.length} Scene={scenes[s.id]} />
				</Sequence>
			))}
			<Sequence from={timeline.outroStart} name="Outro">
				<Outro />
			</Sequence>
			{Overlay ? <Overlay segment={current} /> : null}
			<Progress timeline={timeline} segment={current} />
			{guide ? <Teleprompter timeline={timeline} segment={current} /> : <Captions segment={current} />}
			<Audio src={staticFile(`music-${config.name}.wav`)} volume={hasVoices ? 0.55 : 1} />
			{timeline.segments.map((s) =>
				voices[s.id] ? (
					<Sequence key={`voice-${s.id}`} from={s.answerStart} name={`voice ${s.id}`}>
						<Audio src={staticFile(`voice/${config.name}/${voices[s.id]}`)} />
					</Sequence>
				) : null,
			)}
		</AbsoluteFill>
	);
};

/** A flat light page under a burnt orange grid: 56 px cells, hairline lines, no gradients or glows. */
export const GRID = 56;
export const Backdrop: React.FC = () => (
	<AbsoluteFill>
		<svg width="1920" height="1080" style={{position: 'absolute', inset: 0}}>
			<defs>
				<pattern id="reef-grid" width={GRID} height={GRID} patternUnits="userSpaceOnUse" x={-4} y={-4}>
					<path d={`M ${GRID} 0 L 0 0 0 ${GRID}`} fill="none" stroke={C.brand} strokeOpacity={0.16} strokeWidth={1} />
				</pattern>
			</defs>
			<rect width="1920" height="1080" fill="url(#reef-grid)" />
		</svg>
	</AbsoluteFill>
);

const SegmentView: React.FC<{segment: Segment; total: number; Scene: React.FC<SceneProps>}> = ({segment, total, Scene}) => {
	const f = useCurrentFrame();
	const qLen = segment.answerStart - segment.questionStart;
	const dur = segment.end - segment.answerStart;
	const t = f - qLen;
	const ph = segment.phrases.map((p) => p.start - segment.answerStart);
	const out = 1 - lin(f, segment.end - segment.questionStart - 8, segment.end - segment.questionStart);

	// The question card: in over 10 frames, holds, then shrinks away as the chip slides in.
	const cardIn = ease(f, 0, 10);
	const cardOut = ease(f, qLen - QUESTION_EXIT, qLen + 2);
	const chipIn = ease(f, qLen - 4, qLen + 10);

	return (
		<AbsoluteFill style={{opacity: out}}>
			{t >= -4 ? (
				<AbsoluteFill style={{opacity: ease(t, -4, 10)}}>
					<Scene t={Math.max(0, t)} dur={dur} ph={ph} />
				</AbsoluteFill>
			) : null}
			{cardOut < 1 ? (
				<AbsoluteFill
					style={{
						justifyContent: 'center',
						alignItems: 'center',
						opacity: cardIn * (1 - cardOut),
						transform: `scale(${0.94 + 0.06 * cardIn - 0.25 * cardOut}) translateY(${-140 * cardOut}px)`,
					}}
				>
					<div style={{fontFamily: F.head, fontSize: 34, letterSpacing: 6, color: C.accent, textTransform: 'uppercase', marginBottom: 28}}>
						Question {segment.index + 1} of {total}
					</div>
					<div style={{fontFamily: F.head, fontWeight: 500, fontSize: 104, lineHeight: 1.1, textAlign: 'center', maxWidth: 1500}}>
						{segment.question}
					</div>
				</AbsoluteFill>
			) : null}
			<div
				style={{
					position: 'absolute',
					left: 72,
					top: 56,
					display: 'flex',
					alignItems: 'center',
					gap: 16,
					padding: '12px 26px 12px 14px',
					borderRadius: 999,
					border: `2px solid ${C.accent}`,
					background: `${C.surface}e6`,
					opacity: chipIn,
					transform: `translateX(${(1 - chipIn) * -40}px)`,
				}}
			>
				<span
					style={{
						fontFamily: F.head,
						fontWeight: 600,
						fontSize: 24,
						color: '#fff',
						background: C.brand,
						borderRadius: 999,
						padding: '4px 14px',
					}}
				>
					Q{segment.index + 1}
				</span>
				<span style={{fontFamily: F.head, fontWeight: 500, fontSize: 30}}>{segment.question}</span>
			</div>
		</AbsoluteFill>
	);
};

const Progress: React.FC<{timeline: Timeline; segment: Segment | null}> = ({timeline, segment}) => {
	const frame = useCurrentFrame();
	const show = ease(frame, timeline.introEnd - 10, timeline.introEnd + 10) * (1 - ease(frame, timeline.outroStart, timeline.outroStart + 15));
	return (
		<div style={{position: 'absolute', right: 72, top: 74, display: 'flex', gap: 12, opacity: show}}>
			{timeline.segments.map((s) => {
				const done = frame >= s.end;
				const active = segment?.id === s.id;
				return (
					<div
						key={s.id}
						style={{
							width: active ? (timeline.segments.length > 12 ? 30 : 40) : timeline.segments.length > 12 ? 10 : 14,
							height: timeline.segments.length > 12 ? 10 : 14,
							borderRadius: 999,
							background: active || done ? C.accent : C.line,
							opacity: done && !active ? 0.55 : 1,
						}}
					/>
				);
			})}
		</div>
	);
};

const Captions: React.FC<{segment: Segment | null}> = ({segment}) => {
	const frame = useCurrentFrame();
	if (!segment) return null;
	const phrase = segment.phrases.find((p) => frame >= p.start && frame < p.end + 18 && frame < segment.end - 4);
	if (!phrase) return null;
	const p = ease(frame, phrase.start, phrase.start + 8);
	return (
		<div style={{position: 'absolute', left: 0, right: 0, bottom: 64, display: 'flex', justifyContent: 'center'}}>
			<div
				style={{
					maxWidth: 1500,
					padding: '16px 34px',
					borderRadius: 18,
					background: `${C.bg}d9`,
					border: `1px solid ${C.line}`,
					textAlign: 'center',
					opacity: p,
					transform: `translateY(${(1 - p) * 10}px)`,
				}}
			>
				<span style={{fontFamily: F.head, fontWeight: 600, fontSize: 26, color: C.accent, marginRight: 16}}>{segment.speaker}</span>
				<span style={{fontSize: 40, lineHeight: 1.3}}>{phrase.text}</span>
			</div>
		</div>
	);
};

export const Teleprompter: React.FC<{timeline: Timeline; segment: Segment | null; clock?: React.CSSProperties}> = ({timeline, segment, clock: clockStyle}) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const clock = `${Math.floor(frame / fps / 60)}:${String(Math.floor((frame / fps) % 60)).padStart(2, '0')}.${Math.floor(((frame % fps) / fps) * 10)}`;
	const next = timeline.segments.find((s) => s.questionStart > frame);
	const waiting = !segment || frame < segment.answerStart;
	const target = segment ?? next ?? null;
	const countdown = target ? Math.max(0, (target.answerStart - frame) / fps) : 0;

	return (
		<>
			<div style={{position: 'absolute', right: 72, top: 112, fontFamily: F.mono, fontSize: 30, color: C.amber, ...clockStyle}}>{clock}</div>
			<div
				style={{
					position: 'absolute',
					left: 60,
					right: 60,
					bottom: 30,
					padding: '22px 34px',
					borderRadius: 20,
					background: `${C.surface}f2`,
					border: `2px solid ${waiting ? C.amber : C.red}`,
				}}
			>
				{target ? (
					<>
						<div style={{display: 'flex', alignItems: 'center', gap: 16, fontFamily: F.head, fontSize: 30, marginBottom: 10}}>
							<span style={{width: 18, height: 18, borderRadius: 999, background: waiting ? C.amber : C.red}} />
							{waiting ? (
								<span style={{color: C.amber}}>
									{target.speaker}: get ready, speak in {countdown.toFixed(1)} s
								</span>
							) : (
								<span style={{color: C.red}}>{target.speaker}: speak now</span>
							)}
						</div>
						<div style={{fontSize: 34, lineHeight: 1.35}}>
							{target.phrases.map((p, i) => {
								const now = frame >= p.start && frame < p.end;
								const said = frame >= p.end;
								return (
									<span key={i} style={{color: now ? C.text : said ? C.faint : C.muted, background: now ? `${C.brandDeep}55` : 'transparent', borderRadius: 6}}>
										{p.text}{' '}
									</span>
								);
							})}
						</div>
					</>
				) : (
					<div style={{fontFamily: F.head, fontSize: 30, color: C.muted}}>Music only. Stay silent.</div>
				)}
			</div>
		</>
	);
};

