import React from 'react';
import {AbsoluteFill, Img, staticFile, useCurrentFrame} from 'remotion';
import {Browser, type PageShot} from './app/Browser';
import landing from '../public/pages/landing.json';
import timeline from './timeline-demo.json';
import {C, ease, F, rise} from './theme';
import {DEMO_SCENES} from './scenes';
import {Outro} from './Pitch';
import {makeVideo, type Segment, type Timeline} from './Video';

const tl = timeline as Timeline;

/** The landing page first: the hero, then a slow pan down to the three-phase control sequence. */
const Intro: React.FC = () => {
	const f = useCurrentFrame();
	const out = 1 - ease(f, tl.introEnd - 14, tl.introEnd);
	return (
		<AbsoluteFill style={{opacity: out}}>
			<div style={{position: 'absolute', left: 120, top: 34, display: 'flex', alignItems: 'center', gap: 20, ...rise(f, 4)}}>
				<Img src={staticFile('brand/stockreef-coral.svg')} style={{width: 76}} />
				<div>
					<div style={{fontFamily: F.head, fontWeight: 800, fontSize: 54, letterSpacing: -2, lineHeight: 1}}>StockReef</div>
					<div style={{fontFamily: F.head, fontSize: 30, color: C.muted, marginTop: 6}}>
						the <span style={{color: C.accent}}>demo</span>, in sixteen questions
					</div>
				</div>
			</div>
			<div style={{position: 'absolute', right: 120, top: 58, display: 'flex', gap: 14, ...rise(f, 20)}}>
				<span style={{padding: '8px 20px', borderRadius: 999, border: `2px solid ${C.brand}`, color: C.accent, fontSize: 24, fontFamily: F.head}}>Live contracts · Robinhood Chain testnet 46630</span>
				<span style={{padding: '8px 20px', borderRadius: 999, border: `2px solid ${C.line}`, color: C.muted, fontSize: 24, fontFamily: F.head}}>Scripted price and clock</span>
			</div>
			<div style={{...rise(f, 0, 30, 20)}}>
				<Browser
					page={landing as PageShot}
					t={f}
					x={120}
					y={150}
					width={1680}
					height={880}
					stops={[{at: 0, zoom: 1}, {at: 40, box: 'hero', zoom: 1.25}, {at: 140, box: 'controls', y: 1500, zoom: 1}]}
				/>
			</div>
		</AbsoluteFill>
	);
};

// The seven core features and the answers that show each one.
const FEATURES = [
	'Debt reduced before the close',
	'Falling threshold',
	'Funded repayment buffer',
	'Partial liquidation',
	'Closed-session protection',
	'Controlled reopening',
	'Lender loss accounting',
];
const SHOWS: Record<string, number[]> = {d4: [0, 1], d6: [0], d7: [2], d8: [2], d9: [3], d10: [4], d11: [5], d12: [6]};

/** A strip under the progress dots that ticks off each core feature as the demo shows it. */
const FeatureTracker: React.FC<{segment: Segment | null}> = ({segment}) => {
	const f = useCurrentFrame();
	const now = segment ? SHOWS[segment.id] : undefined;
	if (!segment || !now) return null;
	const seen = new Set<number>();
	for (const s of tl.segments) {
		if (s.answerStart > f) break;
		for (const i of SHOWS[s.id] ?? []) seen.add(i);
	}
	const show = ease(f, segment.answerStart, segment.answerStart + 12) * (1 - ease(f, segment.end - 10, segment.end));
	return (
		<div style={{position: 'absolute', right: 72, top: 112, display: 'flex', alignItems: 'center', gap: 14, opacity: show, fontFamily: F.head}}>
			<span style={{fontSize: 24, color: C.text, fontWeight: 600}}>{now.map((i) => FEATURES[i]).join(' · ')}</span>
			<div style={{display: 'flex', gap: 6}}>
				{FEATURES.map((name, i) => {
					const on = now.includes(i);
					const done = seen.has(i);
					return (
						<span
							key={name}
							style={{
								width: 30,
								height: 30,
								borderRadius: 8,
								display: 'flex',
								alignItems: 'center',
								justifyContent: 'center',
								fontFamily: F.mono,
								fontSize: 17,
								fontWeight: 700,
								background: on ? C.brand : done ? `${C.brand}2e` : C.surface,
								color: on ? '#fff' : done ? C.accent : C.faint,
								border: `1.5px solid ${on || done ? C.brand : C.line}`,
							}}
						>
							{i + 1}
						</span>
					);
				})}
			</div>
			<span style={{fontSize: 20, color: C.muted, fontFamily: F.mono}}>{seen.size}/7</span>
		</div>
	);
};

export const Demo = makeVideo({name: 'demo', timeline: tl, scenes: DEMO_SCENES, Intro, Outro, Overlay: FeatureTracker});
