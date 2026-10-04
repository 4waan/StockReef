import React from 'react';
import {Img, staticFile, useCurrentFrame} from 'remotion';
import forge from '../forge-lines.json';
import {C, ease, F, lin, rise} from '../theme';
import type {Chapter} from '../Demo';

// The demo's three chapters that are not screen recordings: the market today, the real test run, what comes next.

const big = (size = 64): React.CSSProperties => ({fontFamily: F.head, fontWeight: 600, fontSize: size, letterSpacing: -1.2, lineHeight: 1.1});
const label: React.CSSProperties = {fontFamily: F.mono, fontSize: 20, letterSpacing: 3, color: C.accent, textTransform: 'uppercase'};
const panel: React.CSSProperties = {background: C.surface, border: `2px solid ${C.line}`, borderRadius: 20, padding: 30, boxShadow: `0 18px 50px ${C.shadow}`};
const at = (ch: Chapter, i: number) => (ch.phrases[i]?.start ?? ch.questionStart) - ch.questionStart;
const Stage: React.FC<{children: React.ReactNode}> = ({children}) => <div style={{position: 'absolute', left: 150, right: 150, top: 120, bottom: 150}}>{children}</div>;

// Lending today: the size of the market, one fixed limit all week, and what that costs lenders in a deep gap.
const LOSSES: [string, number, string][] = [
	['Fixed-limit market', 1014.91, C.red],
	['With a borrowing lock', 1014.91, C.red],
	['StockReef, funded buffer', 314.38, C.brand],
	['StockReef, partial trim', 247.78, C.up],
];

export const DataScene: React.FC<{ch: Chapter}> = ({ch}) => {
	const t = useCurrentFrame();
	const bars = ease(t, at(ch, 0) + 6, at(ch, 0) + 40);
	const limit = ease(t, at(ch, 1), at(ch, 1) + 40);
	const loss = ease(t, at(ch, 2), at(ch, 2) + 36);
	const W = 640;
	const H = 230;
	const x = (h: number) => (h / 168) * W;
	const y = (v: number) => H - ((v - 60) / 25) * H;
	// Hours from Monday 00:00: StockReef's threshold falls from Friday 14:00 to 15:30 and returns after Monday's reopening.
	const reef = [[0, 80], [4 * 24 + 14, 80], [4 * 24 + 15.5, 70], [7 * 24, 70]];
	return (
		<Stage>
			<div style={{display: 'flex', gap: 30, height: '100%'}}>
				<div style={{...panel, flex: 1, ...rise(t, at(ch, 0))}}>
					<div style={label}>The market today</div>
					<div style={{marginTop: 30}}>
						<div style={{display: 'flex', justifyContent: 'space-between', fontSize: 28}}>
							<span>Stock RWAs on chain</span>
							<b style={{fontFamily: F.head, color: C.accent}}>$3.21B</b>
						</div>
						<div style={{height: 46, marginTop: 10, borderRadius: 10, background: C.surface2}}>
							<div style={{height: '100%', width: `${bars * 100}%`, background: C.brand, borderRadius: 10}} />
						</div>
						<div style={{display: 'flex', justifyContent: 'space-between', fontSize: 28, marginTop: 36}}>
							<span>Lent against them, busiest market</span>
							<b style={{fontFamily: F.head, color: C.red}}>≈ $53M</b>
						</div>
						<div style={{height: 46, marginTop: 10, borderRadius: 10, background: C.surface2}}>
							<div style={{height: '100%', width: `max(10px, ${bars * (53 / 3210) * 100}%)`, background: C.red, borderRadius: 10, opacity: bars}} />
						</div>
						<div style={{marginTop: 40, ...big(44)}}>
							Loans equal under <span style={{color: C.red}}>2%</span> of the market
						</div>
						<div style={{marginTop: 18, fontSize: 20, color: C.faint}}>Sources: rwa.xyz · Solana Compass</div>
					</div>
				</div>
				<div style={{flex: 1.15, display: 'flex', flexDirection: 'column', gap: 30}}>
					<div style={{...panel, opacity: limit, transform: `translateY(${(1 - limit) * 20}px)`}}>
						<div style={label}>One limit, all week</div>
						<svg width={W} height={H + 40} style={{marginTop: 16, overflow: 'visible'}}>
							{['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'].map((d, i) => (
								<text key={d} x={x(i * 24 + 12)} y={H + 32} textAnchor="middle" fontSize={20} fontFamily="Geist Mono" fill={i > 4 ? C.faint : C.muted}>
									{d}
								</text>
							))}
							<rect x={x(4 * 24 + 16)} y={0} width={x(7 * 24) - x(4 * 24 + 16)} height={H} fill={C.surface2} />
							<line x1={0} x2={W * limit} y1={y(80)} y2={y(80)} stroke={C.red} strokeWidth={4} strokeDasharray="10 8" />
							<polyline points={reef.map(([h, v]) => `${x(h)},${y(v)}`).join(' ')} fill="none" stroke={C.brand} strokeWidth={5} opacity={limit} />
							<text x={8} y={y(80) - 14} fontSize={22} fontFamily="Geist" fill={C.red}>Today: the same limit at 3:59 pm Friday</text>
							<text x={x(4 * 24 + 17)} y={y(70) + 32} fontSize={22} fontFamily="Geist" fill={C.accent}>StockReef: lower before the bell</text>
						</svg>
					</div>
					<div style={{...panel, flex: 1, opacity: loss, transform: `translateY(${(1 - loss) * 20}px)`}}>
						<div style={label}>Lender loss in a modeled 35% weekend gap</div>
						<div style={{display: 'flex', flexDirection: 'column', gap: 12, marginTop: 18}}>
							{LOSSES.map(([name, v, color], i) => {
								const k = ease(t, at(ch, 2) + 8 + i * 6, at(ch, 2) + 30 + i * 6);
								return (
									<div key={name} style={{display: 'flex', alignItems: 'center', gap: 16}}>
										<span style={{width: 300, fontSize: 24}}>{name}</span>
										<div style={{flex: 1, height: 30, borderRadius: 8, background: C.surface2}}>
											<div style={{height: '100%', width: `${(v / 1014.91) * 100 * k}%`, background: color, borderRadius: 8}} />
										</div>
										<span style={{width: 110, textAlign: 'right', fontFamily: F.mono, fontSize: 24}}>{v.toFixed(2)}</span>
									</div>
								);
							})}
						</div>
						<div style={{marginTop: 14, fontSize: 20, color: C.faint}}>USDG per 7,200 lent · StockReef scenario harness, evidence/scenarios.json</div>
					</div>
				</div>
			</div>
		</Stage>
	);
};

// Built to hold up: the real `forge test` run from this repository, streamed in a terminal.
const lineColor = (l: string) => (l.startsWith('[PASS]') ? C.text : l.startsWith('Suite result') ? C.up : l.startsWith('Ran 33') ? C.up : l.startsWith('$') ? C.accent : C.muted);

export const TestsScene: React.FC<{ch: Chapter}> = ({ch}) => {
	const t = useCurrentFrame();
	const lines = forge as string[];
	const shown = Math.floor(lin(t, 6, 6 + 9 * 30) * lines.length);
	const done = shown >= lines.length;
	const visible = lines.slice(Math.max(0, shown - 17), shown);
	const sum = ease(t, 6 + 9 * 30, 6 + 9 * 30 + 16);
	return (
		<Stage>
			<div style={{display: 'flex', gap: 30, height: '100%'}}>
				<div style={{flex: 1.8, borderRadius: 18, overflow: 'hidden', border: `2px solid ${C.line}`, background: '#16181B', boxShadow: `0 18px 50px ${C.shadow}`, ...rise(t, 0)}}>
					<div style={{display: 'flex', alignItems: 'center', gap: 9, padding: '12px 18px', background: '#202327', fontFamily: F.mono, fontSize: 18, color: '#9097A0'}}>
						{['#FF5F57', '#FEBC2E', '#28C840'].map((c) => (
							<span key={c} style={{width: 12, height: 12, borderRadius: 99, background: c}} />
						))}
						<span style={{marginLeft: 10}}>StockReef/contracts · forge test</span>
						<span style={{marginLeft: 'auto', color: done ? '#3ECF8E' : '#F2B84B'}}>{done ? 'passed' : 'running…'}</span>
					</div>
					<div style={{padding: '14px 20px', fontFamily: F.mono, fontSize: 19, lineHeight: 1.55}}>
						{visible.map((l, i) => (
							<div key={`${shown}-${i}`} style={{whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', color: lineColor(l) === C.text ? '#E8EAED' : lineColor(l) === C.up ? '#3ECF8E' : lineColor(l) === C.accent ? '#E88A5A' : '#9097A0', fontWeight: l.startsWith('Ran 33') ? 700 : 400}}>
								{l.startsWith('[PASS]') ? (
									<>
										<span style={{color: '#3ECF8E'}}>[PASS]</span>
										{l.slice(6)}
									</>
								) : (
									l
								)}
							</div>
						))}
					</div>
				</div>
				<div style={{flex: 1, display: 'flex', flexDirection: 'column', gap: 24}}>
					{[
						['Tests passed', '531', C.up],
						['Failed', '0', C.text],
						['Suites', '33', C.text],
						['Wall time', '68.5 s', C.text],
					].map(([k, v, color], i) => (
						<div key={k} style={{...panel, padding: 24, opacity: sum, transform: `translateX(${(1 - sum) * 30}px)`, transitionDelay: `${i}`}}>
							<div style={label}>{k}</div>
							<div style={{...big(56), color, marginTop: 6}}>{v}</div>
						</div>
					))}
					<div style={{...panel, padding: 22, ...rise(t, at(ch, 2))}}>
						<div style={{fontSize: 26}}>
							<b style={{color: C.accent}}>+ 4</b> fork tests against Robinhood Chain mainnet
						</div>
					</div>
				</div>
			</div>
		</Stage>
	);
};

// Next for StockReef: four steps to mainnet, then the closing line.
const STEPS: [string, string, string][] = [
	['Calibrate', 'Limits tuned on years of real closure gaps', 'every weekend, holiday and early close'],
	['More stock RWAs', 'One market at a time', 'the exchange calendar is already on chain'],
	['Audit', 'Independent review of every risk rule', 'before real deposits'],
	['Mainnet', 'Robinhood Chain, with our first lenders', 'a capped TSLA market to start'],
];

export const NextScene: React.FC<{ch: Chapter}> = ({ch}) => {
	const t = useCurrentFrame();
	const close = ease(t, at(ch, 3), at(ch, 3) + 16);
	const reveal = [at(ch, 0), at(ch, 1), at(ch, 2), at(ch, 2) + 30];
	return (
		<Stage>
			<div style={{opacity: 1 - close}}>
				<div style={{display: 'flex', gap: 24, marginTop: 40}}>
					{STEPS.map(([k, v, d], i) => {
						const on = ease(t, reveal[i], reveal[i] + 16);
						return (
							<div key={k} style={{...panel, flex: 1, minHeight: 360, border: `2px solid ${i === 3 ? C.brand : C.line}`, opacity: 0.25 + 0.75 * on, transform: `translateY(${(1 - on) * 24}px)`}}>
								<div style={{fontFamily: F.mono, fontSize: 26, color: C.accent}}>0{i + 1}</div>
								<div style={{...big(48), marginTop: 16}}>{k}</div>
								<div style={{fontSize: 30, marginTop: 16, lineHeight: 1.3}}>{v}</div>
								<div style={{fontSize: 24, marginTop: 14, color: C.muted, lineHeight: 1.3}}>{d}</div>
							</div>
						);
					})}
				</div>
				<div style={{height: 10, marginTop: 40, borderRadius: 99, background: C.surface2, overflow: 'hidden'}}>
					<div style={{height: '100%', width: `${lin(t, reveal[0], reveal[3] + 20) * 100}%`, background: C.brand}} />
				</div>
			</div>
			{close > 0 ? (
				<div style={{position: 'absolute', inset: 0, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', opacity: close}}>
					<Img src={staticFile('brand/stockreef-coral.svg')} style={{width: 110}} />
					<div style={{...big(76), textAlign: 'center', marginTop: 30}}>
						StockReef reduces stock-backed debt
						<br />
						<span style={{color: C.accent}}>before the market closes.</span>
					</div>
				</div>
			) : null}
		</Stage>
	);
};
