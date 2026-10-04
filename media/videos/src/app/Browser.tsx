import React from 'react';
import {Img, interpolate, Easing, staticFile} from 'remotion';
import {C, ease, F} from '../theme';

export type Box = {x: number; y: number; w: number; h: number};
export type PageShot = {name: string; url: string; width: number; height: number; scale: number; boxes: Record<string, Box>};

/** A camera stop: from frame `at`, look at `box` (or the point `y`) at `zoom`. */
export type Stop = {at: number; box?: string; y?: number; zoom?: number};
/** An orange outline around a box from `from` to `to`, with an optional label. */
export type Mark = {box: string; from: number; to?: number; label?: string; color?: string; side?: 'right' | 'left' | 'below' | 'above'};

const BAR = 52;

/**
 * A browser window showing a captured page. The camera moves between stops
 * (eased over 24 frames), and marks outline the elements the narration names.
 */
export const Browser: React.FC<{
	page: PageShot;
	t: number;
	stops: Stop[];
	marks?: Mark[];
	x: number;
	y: number;
	width: number;
	height: number;
	opacity?: number;
}> = ({page, t, stops, marks = [], x, y, width, height, opacity = 1}) => {
	const viewW = width;
	const viewH = height - BAR;
	const base = viewW / page.width;
	const target = (s: Stop) => {
		const zoom = s.zoom ?? 1;
		const scale = base * zoom;
		const b = s.box ? page.boxes[s.box] : undefined;
		const cx = b ? b.x + b.w / 2 : page.width / 2;
		const cy = b ? b.y + b.h / 2 : (s.y ?? viewH / 2 / scale);
		const visW = viewW / scale;
		const visH = viewH / scale;
		const left = Math.max(0, Math.min(page.width - visW, cx - visW / 2));
		const top = Math.max(0, Math.min(Math.max(0, page.height - visH), cy - visH / 2));
		return {scale, left, top};
	};
	let cam = target(stops[0]);
	for (let i = 1; i < stops.length; i++) {
		const p = interpolate(t, [stops[i].at, stops[i].at + 24], [0, 1], {
			extrapolateLeft: 'clamp',
			extrapolateRight: 'clamp',
			easing: Easing.bezier(0.45, 0, 0.2, 1),
		});
		if (p <= 0) break;
		const next = target(stops[i]);
		cam = {scale: cam.scale + (next.scale - cam.scale) * p, left: cam.left + (next.left - cam.left) * p, top: cam.top + (next.top - cam.top) * p};
	}
	const isScan = page.url.includes('arbiscan');
	return (
		<div
			style={{
				position: 'absolute',
				left: x,
				top: y,
				width,
				height,
				borderRadius: 18,
				overflow: 'hidden',
				border: `2px solid ${C.line}`,
				boxShadow: `0 30px 80px ${C.shadow}`,
				background: isScan ? '#fff' : C.bg,
				opacity,
			}}
		>
			<div style={{height: BAR, display: 'flex', alignItems: 'center', gap: 10, padding: '0 18px', background: C.surface2, borderBottom: `1px solid ${C.line}`}}>
				{['#FF5F57', '#FEBC2E', '#28C840'].map((c) => (
					<span key={c} style={{width: 13, height: 13, borderRadius: 99, background: c}} />
				))}
				<div
					style={{
						marginLeft: 16,
						flex: 1,
						height: 32,
						borderRadius: 9,
						background: C.bg,
						display: 'flex',
						alignItems: 'center',
						padding: '0 14px',
						fontFamily: F.mono,
						fontSize: 18,
						color: C.muted,
						overflow: 'hidden',
						whiteSpace: 'nowrap',
					}}
				>
					<span style={{color: C.up, marginRight: 8}}>🔒</span>
					{page.url.replace('https://', '')}
				</div>
			</div>
			<div style={{position: 'relative', width: viewW, height: viewH, overflow: 'hidden'}}>
				<div
					style={{
						position: 'absolute',
						left: 0,
						top: 0,
						width: page.width,
						height: page.height,
						transformOrigin: '0 0',
						transform: `scale(${cam.scale}) translate(${-cam.left}px, ${-cam.top}px)`,
					}}
				>
					<Img src={staticFile(`pages/${page.name}.jpg`)} style={{width: page.width, height: page.height, display: 'block'}} />
					{marks.map((m, i) => {
						const b = page.boxes[m.box];
						if (!b) return null;
						const p = ease(t, m.from, m.from + 12) * (m.to === undefined ? 1 : 1 - ease(t, m.to, m.to + 10));
						if (p <= 0) return null;
						const pad = 8;
						const color = m.color ?? C.brand;
						const side = m.side ?? 'right';
						const labelStyle: React.CSSProperties =
							side === 'right'
								? {left: b.w + pad * 2 + 14, top: '50%', transform: 'translateY(-50%)'}
								: side === 'left'
									? {right: b.w + pad * 2 + 14, top: '50%', transform: 'translateY(-50%)'}
									: side === 'below'
										? {left: 0, top: b.h + pad * 2 + 10}
										: {left: 0, bottom: b.h + pad * 2 + 10};
						return (
							<div
								key={i}
								style={{
									position: 'absolute',
									left: b.x - pad,
									top: b.y - pad,
									width: b.w + pad * 2,
									height: b.h + pad * 2,
									border: `${3 / Math.max(cam.scale, 0.5)}px solid ${color}`,
									borderRadius: 10,
									boxShadow: `0 0 24px ${color}88`,
									opacity: p,
									transform: `scale(${1.06 - 0.06 * p})`,
								}}
							>
								{m.label ? (
									<div
										style={{
											position: 'absolute',
											...labelStyle,
											whiteSpace: 'nowrap',
											background: color,
											color: '#fff',
											fontFamily: F.head,
											fontWeight: 600,
											fontSize: 22 / Math.max(cam.scale, 0.5),
											padding: `${4 / Math.max(cam.scale, 0.5)}px ${12 / Math.max(cam.scale, 0.5)}px`,
											borderRadius: 8,
										}}
									>
										{m.label}
									</div>
								) : null}
							</div>
						);
					})}
				</div>
			</div>
		</div>
	);
};
