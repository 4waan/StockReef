import React from 'react';
import {Img, staticFile} from 'remotion';
import {Browser, type PageShot} from '../app/Browser';
import tradePrep from '../../public/pages/trade-prep.json';
import tradeAfter from '../../public/pages/trade-prep-after.json';
import evidence from '../../public/pages/evidence.json';
import tsla from '../../public/pitch/tsla-aug-2024.json';
import {C, ease, F, lin, rise, type SceneProps} from '../theme';
import {at, Card, Pill, Stage} from './ui';

const big = (size = 64): React.CSSProperties => ({fontFamily: F.head, fontWeight: 600, fontSize: size, letterSpacing: -1.5, lineHeight: 1.1});
const label: React.CSSProperties = {fontFamily: F.mono, fontSize: 22, letterSpacing: 4, color: C.accent, textTransform: 'uppercase'};

// Q1. What's changing? The token trades every hour of the week; the market behind it does not.
const DAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

export const Q1: React.FC<SceneProps> = ({t, ph}) => {
	const W = 1500;
	const x = (day: number, hour: number) => ((day * 24 + hour) / (7 * 24)) * W;
	const token = ease(t, 6, 50);
	const market = at(t, ph, 2, 0, 40);
	return (
		<Stage>
			<div style={{...big(64), whiteSpace: 'nowrap', ...rise(t, 0)}}>
				Stock RWAs live on chain. <span style={{color: C.accent}}>The market still closes.</span>
			</div>
			<div style={{position: 'absolute', left: 90, top: 150, width: W}}>
				<div style={{display: 'flex', marginLeft: 0}}>
					{DAYS.map((d) => (
						<div key={d} style={{width: W / 7, fontFamily: F.mono, fontSize: 24, color: d === 'Sat' || d === 'Sun' ? C.faint : C.muted}}>
							{d}
						</div>
					))}
				</div>
				<Row title="TSLA RWA token" sub="on chain, every hour" top={50}>
					<div style={{position: 'absolute', left: 0, top: 0, height: '100%', width: W * token, background: C.brand, borderRadius: 10}} />
				</Row>
				<Row title="TSLA on Nasdaq" sub="09:30 to 16:00 ET, weekdays" top={250}>
					<svg width="100%" height="100%" style={{position: 'absolute', inset: 0, opacity: market}}>
						<defs>
							<pattern id="closed-hatch" width={14} height={14} patternUnits="userSpaceOnUse" patternTransform="rotate(45)">
								<line x1={0} y1={0} x2={0} y2={14} stroke={C.line} strokeWidth={6} />
							</pattern>
						</defs>
						<rect width="100%" height="100%" fill="url(#closed-hatch)" />
					</svg>
					{[0, 1, 2, 3, 4].map((d) => (
						<div
							key={d}
							style={{
								position: 'absolute',
								left: x(d, 9.5),
								width: (x(d, 16) - x(d, 9.5)) * ease(t, (ph[2] ?? 0) + d * 5, (ph[2] ?? 0) + d * 5 + 14),
								top: 0,
								height: '100%',
								background: C.up,
								borderRadius: 6,
							}}
						/>
					))}
					<div style={{position: 'absolute', left: x(5, 0) + 40, top: 40, fontFamily: F.head, fontSize: 36, color: C.red, ...rise(t, (ph[3] ?? 0) - 6)}}>
						Closed all weekend
					</div>
				</Row>
			</div>
			<div style={{position: 'absolute', left: 90, top: 640, ...rise(t, ph[4] ?? 0)}}>
				<Pill color={C.muted}>Aryan Singh Rathore · Co-founder</Pill>
			</div>
		</Stage>
	);
};

const Row: React.FC<{title: string; sub: string; top: number; children: React.ReactNode}> = ({title, sub, top, children}) => (
	<div style={{position: 'absolute', left: 0, top, width: '100%'}}>
		<div style={{display: 'flex', alignItems: 'baseline', gap: 18, marginBottom: 12}}>
			<span style={{fontFamily: F.head, fontWeight: 600, fontSize: 32}}>{title}</span>
			<span style={{fontSize: 24, color: C.muted}}>{sub}</span>
		</div>
		<div style={{position: 'relative', height: 120, background: C.surface, border: `2px solid ${C.line}`, borderRadius: 12, overflow: 'hidden'}}>{children}</div>
	</div>
);

// Q2. What's the problem? Real TSLA sessions around one weekend gap, then the five-year statistics.
export const Q2: React.FC<SceneProps> = ({t, ph}) => {
	const s = tsla.sessions;
	const W = 1000;
	const H = 420;
	const lo = 175;
	const hi = 260;
	const y = (v: number) => H - ((v - lo) / (hi - lo)) * H;
	const step = W / s.length;
	const gapIdx = s.findIndex((d) => d.date === '2024-08-05');
	const show = (i: number) => ease(t, 4 + i * 3, 14 + i * 3);
	const mark = ease(t, 52, 66);
	const stat1 = at(t, ph, 0, 6);
	const stat2 = at(t, ph, 2);
	return (
		<Stage>
			<div style={{position: 'absolute', left: 0, top: 0, ...rise(t, 0)}}>
				<div style={label}>TSLA · daily · one real weekend gap</div>
			</div>
			<svg width={W + 80} height={H + 140} style={{position: 'absolute', left: 0, top: 50}}>
				{s.map((d, i) => {
					const weekday = new Date(`${d.date}T12:00:00Z`).getUTCDay();
					const cx = 40 + i * step + step / 2;
					const up = d.close >= d.open;
					const col = up ? C.up : C.red;
					return (
						<g key={d.date} opacity={show(i)}>
							{weekday === 1 && i > 0 ? (
								<g>
									<rect x={cx - step / 2 - 9} y={30} width={18} height={H - 30} fill={C.line} opacity={0.6} />
									<text x={cx - step / 2} y={20} textAnchor="middle" fontSize={18} fill={C.faint} fontFamily="Geist">
										weekend
									</text>
								</g>
							) : null}
							<line x1={cx} x2={cx} y1={y(d.high)} y2={y(d.low)} stroke={col} strokeWidth={3} />
							<rect x={cx - step * 0.28} y={y(Math.max(d.open, d.close))} width={step * 0.56} height={Math.max(3, Math.abs(y(d.open) - y(d.close)))} fill={col} rx={3} />
						</g>
					);
				})}
				{mark > 0 ? (
					(() => {
						const gx = 40 + gapIdx * step + step / 2;
						const fri = y(s[gapIdx - 1].close);
						const mon = y(s[gapIdx].open);
						const bx = gx - step / 2 - 2;
						return (
							<g opacity={mark}>
								<line x1={gx - step - step * 0.3} x2={gx + step * 0.3} y1={fri} y2={fri} stroke={C.text} strokeDasharray="6 6" strokeWidth={2} />
								<line x1={bx} x2={bx} y1={fri} y2={mon} stroke={C.red} strokeWidth={6} />
								<line x1={bx} x2={bx - 40} y1={mon} y2={H + 62} stroke={C.red} strokeWidth={2} />
								<text x={bx - 50} y={H + 80} textAnchor="end" fontSize={46} fontWeight={700} fill={C.red} fontFamily="Geist">
									−10.8% at Monday&apos;s open
								</text>
								<text x={bx - 50} y={H + 116} textAnchor="end" fontSize={24} fill={C.muted} fontFamily="Geist">
									Fri close 207.67 → Mon open 185.22
								</text>
							</g>
						);
					})()
				) : null}
			</svg>
			<div style={{position: 'absolute', right: 0, top: 70, width: 520, display: 'flex', flexDirection: 'column', gap: 28}}>
				<Card style={{opacity: stat1, transform: `translateY(${(1 - stat1) * 20}px)`}}>
					<div style={{...big(96), color: C.accent}}>65.5 hours</div>
					<div style={{fontSize: 30, marginTop: 10, lineHeight: 1.3}}>every weekend with no real TSLA price, while loans stay open</div>
				</Card>
				<Card style={{opacity: stat2, transform: `translateY(${(1 - stat2) * 20}px)`}}>
					<div style={{...big(96), color: C.red}}>1 in 16</div>
					<div style={{fontSize: 30, marginTop: 10, lineHeight: 1.3}}>Monday opens 5% or more away from Friday&apos;s close</div>
				</Card>
				<div style={{fontSize: 20, color: C.faint, opacity: stat1}}>Yahoo Finance daily data, last five years</div>
			</div>
		</Stage>
	);
};

// Q3. Who feels it first? Holders and lenders; today's answer is a low limit.
export const Q3: React.FC<SceneProps> = ({t, ph}) => {
	const bar = at(t, ph, 2, 0, 30);
	return (
		<Stage>
			<div style={{display: 'flex', gap: 40}}>
				{[
					{k: 'Holders', v: 'Own stock RWAs', d: 'Want dollars without selling', c: C.accent, i: 0},
					{k: 'Lenders', v: 'Supply USDG', d: 'Take the loss when a gap lands', c: C.ltv, i: 1},
				].map((p) => (
					<Card key={p.k} style={{flex: 1, ...rise(t, ph[p.i] ?? 0)}}>
						<div style={{...label, color: p.c}}>{p.k}</div>
						<div style={{...big(56), marginTop: 14}}>{p.v}</div>
						<div style={{fontSize: 32, color: C.muted, marginTop: 10}}>{p.d}</div>
					</Card>
				))}
			</div>
			<div style={{position: 'absolute', left: 0, right: 0, top: 360, opacity: bar}}>
				<div style={{fontFamily: F.head, fontSize: 36, marginBottom: 20}}>How much you can borrow against a stock RWA today</div>
				<div style={{position: 'relative', height: 90, background: C.surface, border: `2px solid ${C.line}`, borderRadius: 14, overflow: 'hidden'}}>
					<div style={{position: 'absolute', left: 0, top: 0, bottom: 0, width: `${50 * bar}%`, background: C.muted, opacity: 0.55}} />
					<div style={{position: 'absolute', left: `${35}%`, width: '15%', top: 0, bottom: 0, background: C.muted, opacity: 0.35 * bar}} />
					<div style={{position: 'absolute', left: 24, top: 22, ...big(40)}}>≈ half the collateral or less</div>
				</div>
				<div style={{display: 'flex', justifyContent: 'space-between', fontFamily: F.mono, fontSize: 22, color: C.faint, marginTop: 10}}>
					<span>0%</span>
					<span>50%</span>
					<span>100%</span>
				</div>
			</div>
		</Stage>
	);
};

// Q4. What is StockReef? The terminal at 15:15, then the funded buffer cutting the debt under the falling threshold.
const STEPS = ['Reduce debt before the close', 'Lock new credit through the closure', 'Reopen carefully'];

export const Q4: React.FC<SceneProps> = ({t, ph}) => {
	const after = at(t, ph, 2, 40, 20);
	const browser = {x: 0, y: 0, width: 1120, height: 680};
	return (
		<Stage>
			<div style={{position: 'absolute', left: 0, top: -6, ...rise(t, 0)}}>
				<Pill color={C.muted}>Awaan Mustafa Siddiqui · Co-founder</Pill>
			</div>
			<div style={{position: 'absolute', left: 0, top: 70}}>
				<Browser
					page={tradePrep as PageShot}
					t={t}
					opacity={1 - after}
					{...browser}
					stops={[{at: 0, zoom: 1}, {at: ph[1] ?? 0, box: 'tiles', zoom: 1.5}, {at: ph[2] ?? 0, box: 'chart', zoom: 1.35}]}
					marks={[
						{box: 'threshold', from: (ph[1] ?? 0) + 10, to: (ph[2] ?? 0) - 4, label: 'threshold falls to 70%', side: 'below'},
						{box: 'trim', from: (ph[1] ?? 0) + 30, to: (ph[2] ?? 0) - 4, label: 'eligible for a trim', side: 'below', color: C.red},
					]}
				/>
				{after > 0 ? (
					<Browser
						page={tradeAfter as PageShot}
						t={t}
						opacity={after}
						{...browser}
						stops={[{at: 0, box: 'chart', zoom: 1.35}]}
						marks={[{box: 'state', from: (ph[2] ?? 0) + 60, label: 'debt 72 → 65 USDG', side: 'left', color: C.up}]}
					/>
				) : null}
			</div>
			<div style={{position: 'absolute', left: 1170, top: 90, width: 510, display: 'flex', flexDirection: 'column', gap: 24}}>
				<Card style={{...rise(t, ph[1] ?? 0), padding: 26}}>
					<div style={{...label}}>Lends up to</div>
					<div style={{...big(84)}}>75%</div>
				</Card>
				{STEPS.map((s, i) => {
					const on = at(t, ph, i + 2);
					return (
						<div
							key={s}
							style={{
								display: 'flex',
								alignItems: 'center',
								gap: 18,
								padding: '18px 22px',
								borderRadius: 16,
								border: `2px solid ${on > 0.5 ? C.brand : C.line}`,
								background: on > 0.5 ? `${C.brand}22` : C.surface,
								opacity: 0.35 + 0.65 * on,
							}}
						>
							<span style={{...big(34), color: C.accent}}>{i + 1}</span>
							<span style={{fontSize: 30, fontFamily: F.head, fontWeight: 500}}>{s}</span>
						</div>
					);
				})}
			</div>
		</Stage>
	);
};

// Q5. Why now? Mainnet, the size of tokenized stocks, and how little lends against them.
export const Q5: React.FC<SceneProps> = ({t, ph}) => {
	const bars = at(t, ph, 3, 0, 30);
	return (
		<Stage>
			<div style={{display: 'flex', gap: 32}}>
				<Card style={{flex: 1, ...rise(t, ph[0] ?? 0)}}>
					<div style={label}>Robinhood Chain</div>
					<div style={{...big(64), marginTop: 12}}>Mainnet live</div>
					<div style={{fontSize: 30, color: C.muted, marginTop: 8}}>an Arbitrum chain</div>
				</Card>
				<Card style={{flex: 1, ...rise(t, ph[1] ?? 0)}}>
					<div style={label}>Side by side</div>
					<div style={{display: 'flex', gap: 16, marginTop: 20}}>
						<Pill>Stock RWAs</Pill>
						<Pill color={C.ltv}>USDG by Paxos</Pill>
					</div>
					<div style={{fontSize: 26, color: C.muted, marginTop: 18}}>lending on chain through Morpho</div>
				</Card>
			</div>
			<div style={{position: 'absolute', left: 0, right: 0, top: 300, ...rise(t, ph[2] ?? 0)}}>
				<BarRow name="Tokenized stock RWAs on chain" value="$3.21B" frac={bars} color={C.accent} />
				<div style={{height: 34}} />
				<BarRow name="Lending against stock RWAs, busiest market (Solana)" value="≈ $53M" frac={bars * (53 / 3210)} color={C.red} min={10} />
				<div style={{fontSize: 20, color: C.faint, marginTop: 22}}>Sources: rwa.xyz · Solana Compass</div>
			</div>
		</Stage>
	);
};

const BarRow: React.FC<{name: string; value: string; frac: number; color: string; min?: number}> = ({name, value, frac, color, min = 0}) => (
	<div>
		<div style={{display: 'flex', justifyContent: 'space-between', fontSize: 30, marginBottom: 12}}>
			<span>{name}</span>
			<span style={{fontFamily: F.head, fontWeight: 600, color}}>{value}</span>
		</div>
		<div style={{height: 46, background: C.surface, borderRadius: 10, border: `2px solid ${C.line}`, overflow: 'hidden'}}>
			<div style={{height: '100%', width: frac > 0 ? `max(${min}px, ${frac * 100}%)` : 0, background: color, borderRadius: 8}} />
		</div>
	</div>
);

// Q6. Why is RWA lending so small, and how do we fix it? Today's limit, the rules that replace it, the credit it frees.
const RULES = ['Falling threshold', 'Funded repayment buffer', 'Credit locked while closed', 'Reopen on a fresh price'];

export const Q6: React.FC<SceneProps> = ({t, ph}) => {
	const today = at(t, ph, 0, 0, 30);
	const reef = at(t, ph, 3, 0, 30);
	return (
		<Stage>
			<div style={{display: 'flex', gap: 36}}>
				<Card style={{flex: 1, ...rise(t, ph[0] ?? 0)}}>
					<div style={{...label, color: C.red}}>Today</div>
					<div style={{...big(46), marginTop: 12}}>No lender can price the weekend gap</div>
					<div style={{fontSize: 28, color: C.muted, marginTop: 14}}>so stock RWAs get half the credit, or none</div>
				</Card>
				<Card glow={at(t, ph, 1)} style={{flex: 1.25, ...rise(t, ph[1] ?? 0)}}>
					<div style={label}>With StockReef</div>
					<div style={{...big(46), marginTop: 12}}>Rules the contract enforces before every close</div>
					<div style={{display: 'flex', flexWrap: 'wrap', gap: 12, marginTop: 20}}>
						{RULES.map((r, i) => (
							<div key={r} style={rise(t, (ph[2] ?? 0) + i * 8)}>
								<Pill>{r}</Pill>
							</div>
						))}
					</div>
				</Card>
			</div>
			<div style={{position: 'absolute', left: 0, right: 0, top: 380}}>
				<div style={{fontFamily: F.head, fontSize: 34, marginBottom: 18, ...rise(t, ph[0] ?? 0)}}>Credit from $100 of TSLA RWA</div>
				<CreditBar name="Lenders today" value={50 * today} color={C.muted} />
				<div style={{height: 18}} />
				<CreditBar name="With StockReef" value={50 + 25 * reef} color={C.brand} on={reef} />
				<div style={{marginTop: 22, ...rise(t, ph[4] ?? 0)}}>
					<Pill color={C.up}>+50% more credit from the same RWA</Pill>
				</div>
			</div>
		</Stage>
	);
};

const CreditBar: React.FC<{name: string; value: number; color: string; on?: number}> = ({name, value, color, on = 1}) => (
	<div style={{display: 'flex', alignItems: 'center', gap: 24, opacity: 0.3 + 0.7 * on}}>
		<div style={{width: 260, fontSize: 28, color: C.muted}}>{name}</div>
		<div style={{flex: 1, height: 58, background: C.surface, border: `2px solid ${C.line}`, borderRadius: 12, overflow: 'hidden'}}>
			<div style={{height: '100%', width: `${value}%`, background: color, borderRadius: 10, display: 'flex', alignItems: 'center', justifyContent: 'flex-end', paddingRight: 18}}>
				<span style={{fontFamily: F.head, fontWeight: 700, fontSize: 30, color: '#fff'}}>${Math.round(value)}</span>
			</div>
		</div>
	</div>
);

// Q7. How does it make money? Two fee lines with their benchmarks, and USDG rewards as upside.
export const Q7: React.FC<SceneProps> = ({t, ph}) => {
	const rows = [
		{from: 'Borrower interest', note: '10% fixed APR', keep: 'StockReef keeps 10%', rest: 'Lenders earn 90%', bench: 'Aave USDC reserve factor: 10%', i: 1},
		{from: 'Liquidation bonus', note: '2% scheduling · 5% recovery', keep: 'StockReef keeps 10%', rest: 'Liquidator keeps 90%', bench: 'Aave WETH / WBTC liquidation fee: 10%', i: 2},
	];
	return (
		<Stage>
			<div style={{display: 'flex', flexDirection: 'column', gap: 40}}>
				{rows.map((r) => {
					const p = at(t, ph, r.i, 0, 26);
					return (
						<div key={r.from} style={{opacity: p}}>
							<div style={{display: 'flex', alignItems: 'baseline', gap: 18, marginBottom: 14}}>
								<span style={{...big(42)}}>{r.from}</span>
								<span style={{fontSize: 26, color: C.muted}}>{r.note}</span>
							</div>
							<div style={{display: 'flex', height: 86, borderRadius: 14, overflow: 'hidden', border: `2px solid ${C.line}`}}>
								<div style={{width: `${90 * p}%`, background: C.surface2, display: 'flex', alignItems: 'center', padding: '0 26px', fontSize: 30}}>{r.rest}</div>
								<div style={{flex: 1, background: C.brand, display: 'flex', alignItems: 'center', justifyContent: 'center', fontFamily: F.head, fontWeight: 600, fontSize: 26, color: '#fff'}}>10%</div>
							</div>
							<div style={{display: 'flex', justifyContent: 'space-between', marginTop: 10, fontSize: 24}}>
								<span style={{color: C.accent}}>{r.keep}</span>
								<span style={{color: C.faint}}>{r.bench}</span>
							</div>
						</div>
					);
				})}
				<div style={{...rise(t, ph[4] ?? 0), display: 'flex', alignItems: 'center', gap: 20}}>
					<Pill color={C.ltv}>+ USDG partner rewards</Pill>
					<span style={{fontSize: 26, color: C.muted}}>Global Dollar Network · upside, terms by agreement</span>
				</div>
			</div>
		</Stage>
	);
};

// Q8. How does it grow? One market at a time, on a calendar the contracts already hold.
export const Q8: React.FC<SceneProps> = ({t, ph}) => {
	const later = at(t, ph, 1);
	const cal = at(t, ph, 2);
	return (
		<Stage>
			<div style={{display: 'flex', gap: 22}}>
				<div style={{width: 250, height: 200, borderRadius: 22, border: `3px solid ${C.brand}`, background: `${C.brand}22`, boxShadow: `0 0 60px ${C.brand}55`, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 14, ...rise(t, 0)}}>
					<Img src={staticFile('brand/tesla-t.svg')} style={{width: 70, height: 70, background: '#fff', borderRadius: 999, padding: 12}} />
					<div style={{...big(40)}}>TSLA / USDG</div>
				</div>
				{[0, 1, 2, 3, 4].map((i) => (
					<div
						key={i}
						style={{
							width: 230,
							height: 200,
							borderRadius: 22,
							border: `3px dashed ${C.line}`,
							display: 'flex',
							alignItems: 'center',
							justifyContent: 'center',
							fontSize: 26,
							color: C.faint,
							opacity: ease(t, (ph[1] ?? 0) + i * 5, (ph[1] ?? 0) + i * 5 + 14) * later,
						}}
					>
						next stock RWA
					</div>
				))}
			</div>
			<div style={{position: 'absolute', left: 0, right: 0, top: 290, display: 'flex', gap: 28, opacity: cal}}>
				{[
					{k: 'Weekends', v: 'Friday close to Monday open'},
					{k: 'Holidays', v: 'Exchange calendar, loaded'},
					{k: 'Early closes', v: 'and daylight saving'},
				].map((c, i) => (
					<Card key={c.k} style={{flex: 1, ...rise(t, (ph[2] ?? 0) + i * 8)}}>
						<div style={{...big(44)}}>{c.k}</div>
						<div style={{fontSize: 28, color: C.muted, marginTop: 8}}>{c.v}</div>
					</Card>
				))}
			</div>
			<div style={{position: 'absolute', left: 0, top: 540, ...rise(t, ph[3] ?? 0)}}>
				<Pill>587 market sessions already loaded in the deployed SessionCalendar</Pill>
			</div>
		</Stage>
	);
};

// Q9. What's real today? The evidence page, zoomed to the tests, the fork block and the deployment.
export const Q9: React.FC<SceneProps> = ({t, ph}) => (
	<Stage>
		<Browser
			page={evidence as PageShot}
			t={t}
			x={0}
			y={0}
			width={1100}
			height={700}
			stops={[{at: 0, zoom: 1}, {at: ph[2] ?? 0, box: 'tests', zoom: 2.2}, {at: ph[3] ?? 0, box: 'fork', zoom: 2.2}]}
			marks={[
				{box: 'deploy', from: (ph[1] ?? 0) + 6, to: (ph[2] ?? 0) - 2, label: 'live on testnet 46630', side: 'below'},
				{box: 'tests', from: (ph[2] ?? 0) + 20, to: (ph[3] ?? 0) - 2},
				{box: 'fork', from: (ph[3] ?? 0) + 20, label: 'mainnet fork', side: 'below'},
			]}
		/>
		<div style={{position: 'absolute', left: 1150, top: 40, display: 'flex', flexDirection: 'column', gap: 22}}>
			{['Robinhood Chain testnet', 'Funded public market', 'Explorer receipts', '535 tests and invariants'].map((s, i) => (
				<div key={s} style={rise(t, (ph[Math.min(i, 3)] ?? 0) + 6)}>
					<Pill color={i === 3 ? C.up : C.accent}>{s}</Pill>
				</div>
			))}
		</div>
	</Stage>
);

// Q10. Who's building it? Two founders, built during the buildathon.
export const Q10: React.FC<SceneProps> = ({t, ph}) => (
	<Stage>
		<div style={{display: 'flex', gap: 40, justifyContent: 'center', marginTop: 40}}>
			{[
				['Aryan Singh Rathore', 'AR'],
				['Awaan Mustafa Siddiqui', 'AS'],
			].map(([name, initials], i) => (
				<Card key={name} style={{width: 760, display: 'flex', alignItems: 'center', gap: 32, ...rise(t, i * 10)}}>
					<div style={{width: 130, height: 130, borderRadius: 999, background: `${C.brand}33`, border: `3px solid ${C.brand}`, display: 'flex', alignItems: 'center', justifyContent: 'center', ...big(48), color: C.accent}}>
						{initials}
					</div>
					<div>
						<div style={{...big(42)}}>{name}</div>
						<div style={{fontSize: 30, color: C.muted, marginTop: 8}}>Co-founder</div>
					</div>
				</Card>
			))}
		</div>
		<div style={{display: 'flex', gap: 20, justifyContent: 'center', marginTop: 60, ...rise(t, ph[1] ?? 0)}}>
			<Pill>Contracts</Pill>
			<Pill>Keeper</Pill>
			<Pill>App</Pill>
			<Pill color={C.muted}>Built during the buildathon</Pill>
		</div>
	</Stage>
);

// Q11. What will we do at Open House Singapore? The launch plan, step by step.
const PLAN = [
	{k: 'Launch', v: 'Robinhood Chain mainnet', d: 'a capped TSLA / USDG market'},
	{k: 'Seed', v: 'Our first lenders', d: 'USDG into the vault'},
	{k: 'Show', v: 'A live Friday close', d: 'with RWA holders in the room'},
	{k: 'Tune', v: 'The thresholds', d: 'with the Robinhood Chain team'},
];

export const Q11: React.FC<SceneProps> = ({t, ph}) => (
	<Stage>
		<div style={{display: 'flex', alignItems: 'center', gap: 20, ...rise(t, 0)}}>
			<Img src={staticFile('brand/stockreef-coral.svg')} style={{width: 64}} />
			<div style={{...big(60)}}>
				Open House <span style={{color: C.accent}}>Singapore</span>
			</div>
			<div style={{marginLeft: 12}}>
				<Pill color={C.muted}>Founder House week</Pill>
			</div>
		</div>
		<div style={{display: 'flex', gap: 24, marginTop: 70}}>
			{PLAN.map((s, i) => (
				<Card key={s.k} glow={at(t, ph, i) * (1 - at(t, ph, i + 1))} style={{flex: 1, minHeight: 300, ...rise(t, (ph[i] ?? 0) + (i === 1 ? 30 : 0))}}>
					<div style={{fontFamily: F.mono, fontSize: 26, color: C.accent}}>0{i + 1}</div>
					<div style={{...label, marginTop: 14}}>{s.k}</div>
					<div style={{...big(42), marginTop: 10}}>{s.v}</div>
					<div style={{fontSize: 28, color: C.muted, marginTop: 12}}>{s.d}</div>
				</Card>
			))}
		</div>
	</Stage>
);

// Q12. What do we need? The asks tick in, then the closing line.
const ASKS = ['An audit', 'A market maker for TSLA', 'A Global Dollar partnership for the vault'];

export const Q12: React.FC<SceneProps> = ({t, ph}) => {
	const close = at(t, ph, 2, 0, 18);
	return (
		<Stage>
			<div style={{opacity: 1 - close, display: 'flex', flexDirection: 'column', gap: 24, marginTop: 20}}>
				<div style={{...label, ...rise(t, 0)}}>To launch on mainnet</div>
				{ASKS.map((a, i) => {
					const at0 = i === 0 ? 4 : i === 1 ? 50 : (ph[1] ?? 0) - (ph[0] ?? 0) + 4;
					const p = ease(t, (ph[0] ?? 0) + at0, (ph[0] ?? 0) + at0 + 14);
					return (
						<div key={a} style={{display: 'flex', alignItems: 'center', gap: 24, ...rise(t, (ph[0] ?? 0) + at0)}}>
							<span
								style={{
									width: 54,
									height: 54,
									borderRadius: 999,
									border: `3px solid ${p > 0.6 ? C.up : C.line}`,
									color: C.up,
									display: 'flex',
									alignItems: 'center',
									justifyContent: 'center',
									fontSize: 32,
									fontWeight: 700,
								}}
							>
								{p > 0.6 ? '✓' : ''}
							</span>
							<span style={{...big(54)}}>{a}</span>
						</div>
					);
				})}
			</div>
			{close > 0 ? (
				<div style={{position: 'absolute', inset: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', opacity: close}}>
					<div style={{...big(86), textAlign: 'center', maxWidth: 1500}}>
						StockReef reduces stock-backed debt <span style={{color: C.accent}}>before the market closes.</span>
					</div>
				</div>
			) : null}
		</Stage>
	);
};

export {lin};
