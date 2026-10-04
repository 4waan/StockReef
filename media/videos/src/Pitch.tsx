import React from 'react';
import {AbsoluteFill, Img, staticFile, useCurrentFrame} from 'remotion';
import timeline from './timeline-pitch.json';
import {C, ease, F, rise} from './theme';
import {SCENES} from './scenes';
import {makeVideo, type Timeline} from './Video';

const Intro: React.FC = () => {
	const f = useCurrentFrame();
	const mark = ease(f, 4, 28);
	const out = 1 - ease(f, timeline.introEnd - 12, timeline.introEnd);
	return (
		<AbsoluteFill style={{justifyContent: 'center', alignItems: 'center', opacity: out}}>
			<div style={{display: 'flex', alignItems: 'center', gap: 44}}>
				<Img src={staticFile('brand/stockreef-coral.svg')} style={{width: 200, opacity: mark, transform: `scale(${0.8 + 0.2 * mark}) rotate(${(1 - mark) * -8}deg)`}} />
				<div style={{fontFamily: F.head, fontWeight: 800, fontSize: 180, letterSpacing: -6, ...rise(f, 14, 30)}}>StockReef</div>
			</div>
			<div style={{fontFamily: F.head, fontSize: 52, color: C.muted, marginTop: 30, ...rise(f, 34)}}>
				in <span style={{color: C.accent}}>twelve questions</span>
			</div>
			<div style={{marginTop: 54, padding: '10px 26px', borderRadius: 999, border: `1px solid ${C.line}`, fontSize: 28, color: C.muted, ...rise(f, 52)}}>
				Built on <span style={{color: C.text}}>Robinhood Chain</span> · Paxos USDG · TSLA
			</div>
		</AbsoluteFill>
	);
};

export const Outro: React.FC = () => {
	const f = useCurrentFrame();
	return (
		<AbsoluteFill style={{justifyContent: 'center', alignItems: 'center'}}>
			<div style={{display: 'flex', alignItems: 'center', gap: 30, ...rise(f, 0, 20, 20)}}>
				<Img src={staticFile('brand/stockreef-coral.svg')} style={{width: 120}} />
				<div style={{fontFamily: F.head, fontWeight: 800, fontSize: 120, letterSpacing: -4}}>StockReef</div>
			</div>
			<div style={{fontFamily: F.head, fontSize: 46, marginTop: 40, ...rise(f, 12)}}>Borrow against your stocks, safely, even when the market is closed.</div>
			<div style={{display: 'flex', gap: 28, marginTop: 50, fontFamily: F.mono, fontSize: 30, color: C.accent, ...rise(f, 24)}}>
				<span>stock-reef.vercel.app</span>
				<span style={{color: C.faint}}>·</span>
				<span>github.com/4waan/StockReef</span>
			</div>
			<div style={{marginTop: 36, fontSize: 26, color: C.muted, ...rise(f, 34)}}>Aryan Singh Rathore · Awaan Mustafa Siddiqui</div>
		</AbsoluteFill>
	);
};

export const Pitch = makeVideo({name: 'pitch', timeline: timeline as Timeline, scenes: SCENES, Intro, Outro});
