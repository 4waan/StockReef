import React from 'react';
import {C, ease, F} from '../theme';

/** The area between the question chip and the captions. */
export const Stage: React.FC<{children: React.ReactNode; style?: React.CSSProperties}> = ({children, style}) => (
	<div style={{position: 'absolute', left: 120, right: 120, top: 160, bottom: 200, ...style}}>{children}</div>
);

export const Card: React.FC<{children: React.ReactNode; style?: React.CSSProperties; glow?: number}> = ({children, style, glow = 0}) => (
	<div
		style={{
			background: C.surface,
			border: `2px solid ${glow > 0 ? C.accent : C.line}`,
			borderRadius: 24,
			padding: 32,
			boxShadow: glow > 0 ? `0 0 ${60 * glow}px ${C.accent}55` : `0 18px 50px ${C.shadow}`,
			...style,
		}}
	>
		{children}
	</div>
);

export const Pill: React.FC<{children: React.ReactNode; color?: string; style?: React.CSSProperties}> = ({children, color = C.accent, style}) => (
	<span
		style={{
			display: 'inline-flex',
			alignItems: 'center',
			gap: 10,
			padding: '8px 20px',
			borderRadius: 999,
			border: `2px solid ${color}`,
			color,
			fontFamily: F.head,
			fontSize: 26,
			fontWeight: 500,
			whiteSpace: 'nowrap',
			...style,
		}}
	>
		{children}
	</span>
);

/** A terminal window; lines appear one by one as progress goes 0 → 1. */
export const Terminal: React.FC<{
	title: string;
	lines: string[];
	progress: number;
	tokens?: number;
	failed?: boolean;
	scale?: number;
	style?: React.CSSProperties;
}> = ({title, lines, progress, tokens, failed = false, scale = 1, style}) => {
	const shown = Math.floor(progress * (lines.length + 0.999));
	return (
		<div
			style={{
				background: C.surface2,
				border: `${2 * scale}px solid ${failed ? C.red : C.line}`,
				borderRadius: 14 * scale,
				overflow: 'hidden',
				boxShadow: failed ? `0 0 ${30 * scale}px ${C.red}66` : 'none',
				...style,
			}}
		>
			<div
				style={{
					display: 'flex',
					alignItems: 'center',
					gap: 8 * scale,
					padding: `${8 * scale}px ${14 * scale}px`,
					background: C.surface2,
					fontFamily: F.mono,
					fontSize: 18 * scale,
					color: C.muted,
				}}
			>
				{['#FF5F57', '#FEBC2E', '#28C840'].map((c) => (
					<span key={c} style={{width: 11 * scale, height: 11 * scale, borderRadius: 99, background: c, opacity: 0.8}} />
				))}
				<span style={{marginLeft: 8 * scale}}>{title}</span>
				{tokens !== undefined ? (
					<span style={{marginLeft: 'auto', color: failed ? C.red : C.amber}}>{Math.round(tokens).toLocaleString('en-US')} tokens</span>
				) : null}
			</div>
			<div style={{padding: `${10 * scale}px ${16 * scale}px`, fontFamily: F.mono, fontSize: 20 * scale, lineHeight: 1.5}}>
				{lines.slice(0, shown).map((line, i) => (
					<div key={i} style={{color: line.startsWith('✗') ? C.red : line.startsWith('›') ? C.text : C.muted, whiteSpace: 'nowrap'}}>
						{line}
					</div>
				))}
				{failed ? <div style={{color: C.red, fontWeight: 700}}>✗ tests failed</div> : null}
			</div>
		</div>
	);
};

/** An SVG arrow from (x1,y1) to (x2,y2) that draws itself, with dots travelling along it. */
export const Arrow: React.FC<{
	x1: number;
	y1: number;
	x2: number;
	y2: number;
	progress: number;
	t: number;
	color?: string;
	dots?: boolean;
	width?: number;
}> = ({x1, y1, x2, y2, progress, t, color = C.accent, dots = true, width = 4}) => {
	const ang = Math.atan2(y2 - y1, x2 - x1);
	const hx = x1 + (x2 - x1) * progress;
	const hy = y1 + (y2 - y1) * progress;
	const head = 18;
	return (
		<g opacity={progress > 0 ? 1 : 0}>
			<line x1={x1} y1={y1} x2={hx} y2={hy} stroke={color} strokeWidth={width} strokeLinecap="round" />
			{progress > 0.98 ? (
				<polygon
					points={`${x2},${y2} ${x2 - head * Math.cos(ang - 0.45)},${y2 - head * Math.sin(ang - 0.45)} ${x2 - head * Math.cos(ang + 0.45)},${y2 - head * Math.sin(ang + 0.45)}`}
					fill={color}
				/>
			) : null}
			{dots && progress >= 1
				? [0, 1, 2].map((k) => {
						const p = ((t / 45 + k / 3) % 1 + 1) % 1;
						return <circle key={k} cx={x1 + (x2 - x1) * p} cy={y1 + (y2 - y1) * p} r={7} fill={color} opacity={Math.sin(p * Math.PI)} />;
					})
				: null}
		</g>
	);
};

/** A numbered phrase helper: progress of the reveal that starts with phrase i. */
export const at = (t: number, ph: number[], i: number, offset = 0, length = 14) => ease(t, (ph[i] ?? 0) + offset, (ph[i] ?? 0) + offset + length);
