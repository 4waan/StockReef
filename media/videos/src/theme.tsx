import React, {useEffect, useState} from 'react';
import {continueRender, delayRender, Easing, interpolate, staticFile} from 'remotion';

// StockReef's light palette (app/src/app/globals.css, :root[data-theme='light']): burnt orange is the brand and accent,
// green marks what went right, amber the threshold, red what is at risk; blue and amber are the chart's LTV and threshold.
export const C = {
	bg: '#F4F3EE',
	surface: '#FFFFFF',
	surface2: '#EEECE5',
	line: '#E0DDD3',
	text: '#17191C',
	muted: '#5A616A',
	faint: '#868C95',
	accent: '#B4521F',
	brand: '#C4581F',
	brandDeep: '#8F4520',
	up: '#0F8A5F',
	red: '#C9323F',
	amber: '#A8681A',
	ltv: '#2F6FB0',
	lt: '#A8681A',
	shadow: '#2A1F1424',
};

export const F = {
	head: 'Geist, sans-serif',
	body: 'Geist, sans-serif',
	mono: '"Geist Mono", monospace',
};

/** 0 → 1 between frames a and b, eased, clamped. */
export const ease = (f: number, a: number, b: number) =>
	interpolate(f, [a, b], [0, 1], {
		extrapolateLeft: 'clamp',
		extrapolateRight: 'clamp',
		easing: Easing.bezier(0.2, 0.8, 0.2, 1),
	});

/** Linear 0 → 1 between a and b, clamped. */
export const lin = (f: number, a: number, b: number) =>
	interpolate(f, [a, b], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});

/** Fade and rise in from frame a. */
export const rise = (f: number, a: number, distance = 24, length = 14): React.CSSProperties => {
	const p = ease(f, a, a + length);
	return {opacity: p, transform: `translateY(${(1 - p) * distance}px)`};
};

const FONTS: [string, string, string][] = [
	['Geist', 'fonts/geist.woff2', '100 900'],
	['Geist Mono', 'fonts/geist-mono.woff2', '100 900'],
];

/** Loads the brand fonts before the first frame renders. */
export const useFonts = () => {
	const [handle] = useState(() => delayRender('fonts'));
	useEffect(() => {
		Promise.all(
			FONTS.map(([family, file, weight]) => {
				const face = new FontFace(family, `url(${staticFile(file)}) format('woff2')`, {weight});
				return face.load().then((loaded) => document.fonts.add(loaded));
			}),
		)
			.then(() => continueRender(handle))
			.catch((error) => {
				console.error(error);
				continueRender(handle);
			});
	}, [handle]);
};

/** Props every answer scene receives: frames since the answer began and each phrase's start. */
export type SceneProps = {t: number; dur: number; ph: number[]};
