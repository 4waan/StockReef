import React from 'react';
import {Browser, type Mark, type PageShot, type Stop} from '../app/Browser';
import tsla from '../../public/pages/tsla.json';
import tradeOpen from '../../public/pages/trade-open.json';
import tradePrep from '../../public/pages/trade-prep.json';
import prepLiq from '../../public/pages/trade-prep-liq.json';
import prepBuffer from '../../public/pages/trade-prep-buffer.json';
import prepOracle from '../../public/pages/trade-prep-oracle.json';
import prepAfter from '../../public/pages/trade-prep-after.json';
import closed from '../../public/pages/trade-closed.json';
import wait from '../../public/pages/trade-wait.json';
import admit from '../../public/pages/trade-admit.json';
import lendAdmit from '../../public/pages/lend-admit.json';
import lendWhatIf from '../../public/pages/lend-whatif.json';
import stale from '../../public/pages/trade-stale.json';
import evidence from '../../public/pages/evidence.json';
import {C, F, rise, type SceneProps} from '../theme';
import {at, Card, Pill, Stage, Terminal} from './ui';

// Every number on these cards is read off the captures in public/pages, taken on a fork of the chain 46630
// deployment with the public borrower (capture/demo-pages.json).

const big = (size = 64): React.CSSProperties => ({fontFamily: F.head, fontWeight: 600, fontSize: size, letterSpacing: -1.5, lineHeight: 1.1});
const label: React.CSSProperties = {fontFamily: F.mono, fontSize: 20, letterSpacing: 3, color: C.accent, textTransform: 'uppercase'};
const W = 1180;
const H = 700;
const SIDE = {position: 'absolute', left: 1230, top: 0, width: 450, display: 'flex', flexDirection: 'column', gap: 20} as const;

/** The standard demo shot: one captured page on the left, eased between camera stops. */
const Shot: React.FC<{page: unknown; t: number; stops: Stop[]; marks?: Mark[]; opacity?: number}> = ({page, t, stops, marks, opacity}) => (
	<Browser page={page as PageShot} t={t} stops={stops} marks={marks} x={0} y={0} width={W} height={H} opacity={opacity} />
);

/** A labelled number card for the right column. */
const Stat: React.FC<{k: string; v: React.ReactNode; sub?: React.ReactNode; color?: string; style?: React.CSSProperties}> = ({k, v, sub, color = C.text, style}) => (
	<Card style={{padding: 24, ...style}}>
		<div style={label}>{k}</div>
		<div style={{...big(52), color, marginTop: 8}}>{v}</div>
		{sub ? <div style={{fontSize: 22, color: C.muted, marginTop: 8, lineHeight: 1.35}}>{sub}</div> : null}
	</Card>
);

/** A row that says whether something is allowed. */
const Rule: React.FC<{ok: boolean; children: React.ReactNode; style?: React.CSSProperties}> = ({ok, children, style}) => (
	<div style={{display: 'flex', alignItems: 'center', gap: 16, fontSize: 28, fontFamily: F.head, ...style}}>
		<span style={{width: 40, height: 40, borderRadius: 99, display: 'flex', alignItems: 'center', justifyContent: 'center', background: ok ? `${C.up}22` : `${C.red}1f`, color: ok ? C.up : C.red, fontWeight: 700}}>
			{ok ? '✓' : '✗'}
		</span>
		{children}
	</div>
);

const p = (ph: number[], i: number) => ph[i] ?? 0;

const SidePill: React.FC<React.ComponentProps<typeof Pill>> = ({style, ...props}) => <Pill {...props} style={{alignSelf: 'flex-start', ...style}} />;

// d1. What's the problem? The TSLA page: Friday's last price and Monday's gap on one chart.
export const D1: React.FC<SceneProps> = ({t, ph}) => (
	<Stage>
		<Shot
			page={tsla}
			t={t}
			stops={[{at: 0, zoom: 1}, {at: p(ph, 1), box: 'chart', zoom: 1.45}]}
			marks={[{box: 'chart', from: p(ph, 1) + 16, label: 'Fri 397.20 → Mon 376.00', side: 'below', color: C.red}]}
		/>
		<div style={SIDE}>
			<Stat k="No real price" v="65.5 hours" sub="Friday 16:00 to Monday 09:30 ET" style={rise(t, p(ph, 1))} />
			<Stat k="Monday gaps ≥ 5%" v="1 in 16" color={C.red} sub="TSLA, five years of daily data" style={rise(t, p(ph, 2))} />
		</div>
	</Stage>
);

// d2. Who has it? The borrower at Friday 13:00: 0.25 TSLA, 72.08 USDG, 72%.
export const D2: React.FC<SceneProps> = ({t, ph}) => (
	<Stage>
		<Shot
			page={tradeOpen}
			t={t}
			stops={[{at: 0, zoom: 1}, {at: p(ph, 0) + 30, box: 'row', zoom: 1.5}]}
			marks={[{box: 'row', from: p(ph, 0) + 50, label: '0.25 TSLA · 72.08 USDG debt · 72% LTV', side: 'above'}]}
		/>
		<div style={SIDE}>
			<Card style={{padding: 26, ...rise(t, p(ph, 0))}}>
				<div style={label}>The borrower</div>
				{[
					['Collateral', '0.25 TSLA'],
					['Debt', '72.08 USDG'],
					['LTV', '72.1%'],
					['Threshold now', '80%'],
				].map(([k, v], i) => (
					<div key={k} style={{display: 'flex', justifyContent: 'space-between', fontSize: 28, marginTop: 18, ...rise(t, p(ph, 0) + 10 + i * 8)}}>
						<span style={{color: C.muted}}>{k}</span>
						<span style={{fontFamily: F.mono}}>{v}</span>
					</div>
				))}
			</Card>
			<SidePill color={C.up} style={rise(t, p(ph, 2))}>Healthy on Friday afternoon</SidePill>
			<SidePill color={C.red} style={rise(t, p(ph, 3))}>Exposed to a weekend gap</SidePill>
		</div>
	</Stage>
);

// d3. What's missing today? Three ways to treat a stock loan into the close.
const MODELS = ['Fixed-limit market', 'Borrowing lock', 'StockReef'];
const ROWS: [string, boolean[]][] = [
	['Acts before the close', [false, true, true]],
	['Shrinks existing debt', [false, false, true]],
	['Controlled reopening', [false, false, true]],
];
export const D3: React.FC<SceneProps> = ({t, ph}) => (
	<Stage>
		<div style={{display: 'grid', gridTemplateColumns: '520px repeat(3, 1fr)', rowGap: 18, columnGap: 18, marginTop: 40}}>
			<div />
			{MODELS.map((m, i) => (
				<div
					key={m}
					style={{
						...big(36),
						textAlign: 'center',
						padding: '22px 10px',
						borderRadius: 18,
						background: i === 2 ? `${C.brand}1c` : C.surface,
						border: `2px solid ${i === 2 ? C.brand : C.line}`,
						color: i === 2 ? C.accent : C.text,
						...rise(t, i === 2 ? p(ph, 2) : p(ph, i)),
					}}
				>
					{m}
				</div>
			))}
			{ROWS.map(([row, cells], r) => (
				<React.Fragment key={row}>
					<div style={{fontSize: 34, fontFamily: F.head, display: 'flex', alignItems: 'center', ...rise(t, p(ph, 0) + 10 + r * 8)}}>{row}</div>
					{cells.map((ok, i) => (
						<div
							key={i}
							style={{
								display: 'flex',
								alignItems: 'center',
								justifyContent: 'center',
								height: 96,
								borderRadius: 18,
								background: C.surface,
								border: `2px solid ${C.line}`,
								fontSize: 48,
								fontWeight: 700,
								color: ok ? C.up : C.red,
								...rise(t, (i === 2 ? p(ph, 2) : p(ph, i)) + 12 + r * 6),
							}}
						>
							{ok ? '✓' : '✗'}
						</div>
					))}
				</React.Fragment>
			))}
		</div>
	</Stage>
);

// d4. What's our insight? The falling threshold, then the repayment it asks for.
export const D4: React.FC<SceneProps> = ({t, ph}) => (
	<Stage>
		<Shot
			page={tradePrep}
			t={t}
			stops={[{at: 0, zoom: 1}, {at: p(ph, 1), box: 'chart', zoom: 1.4}, {at: p(ph, 2), box: 'tiles', zoom: 1.45}]}
			marks={[
				{box: 'chart', from: p(ph, 1) + 20, to: p(ph, 2) - 2, label: 'threshold 80% → 70% through the afternoon', side: 'below', color: C.lt},
				{box: 'close', from: p(ph, 2) + 24, label: 'Repay 7.34 by 15:30', side: 'below'},
			]}
		/>
		<div style={SIDE}>
			<Stat k="Act while a price exists" v="Before 16:00" sub="the debt shrinks while TSLA still trades" style={rise(t, p(ph, 0))} />
			<Stat k="Threshold" v={<span>80% → <span style={{color: C.lt}}>70%</span></span>} sub="falls from 14:00 to 15:30" style={rise(t, p(ph, 1))} />
			<Stat k="The borrower sees" v="7.34 USDG" sub="an amount and a deadline" color={C.accent} style={rise(t, p(ph, 2))} />
		</div>
	</Stage>
);

// d5. Why on chain, why Robinhood Chain? The oracle gate, then the TSLA token the market uses.
export const D5: React.FC<SceneProps> = ({t, ph}) => {
	const swap = at(t, ph, 2, 0, 18);
	return (
		<Stage>
			<Shot
				page={prepOracle}
				t={t}
				opacity={1 - swap}
				stops={[{at: 0, zoom: 1}, {at: 20, box: 'pop', zoom: 1.9}]}
				marks={[{box: 'pop', from: 44, label: 'the contract checks price age · 120 s', side: 'left'}]}
			/>
			{swap > 0 ? (
				<Shot
					page={tsla}
					t={t}
					opacity={swap}
					stops={[{at: 0, box: 'token', zoom: 1.5}]}
					marks={[{box: 'token', from: p(ph, 2) + 24, label: 'TSLA Stock Token on chain 46630', side: 'left'}]}
				/>
			) : null}
			<div style={SIDE}>
				<Card style={{padding: 26, ...rise(t, p(ph, 0))}}>
					<div style={label}>Enforced by contract</div>
					<div style={{fontSize: 28, marginTop: 14, lineHeight: 1.4}}>Thresholds, limits, price age and reopening are checked on every call</div>
				</Card>
				<SidePill style={rise(t, p(ph, 2))}>Robinhood Chain</SidePill>
				<SidePill style={rise(t, p(ph, 2) + 8)}>TSLA Stock Token</SidePill>
				<SidePill style={rise(t, p(ph, 2) + 16)}>Paxos USDG</SidePill>
			</div>
		</Stage>
	);
};

// d6. What does the borrower see at 15:15? The tiles: threshold 71.66%, LTV 72.37%, repay 7.34 by 15:30.
export const D6: React.FC<SceneProps> = ({t, ph}) => (
	<Stage>
		<Shot
			page={tradePrep}
			t={t}
			stops={[{at: 0, zoom: 1}, {at: p(ph, 0), box: 'threshold', zoom: 2.3}, {at: p(ph, 2), box: 'close', zoom: 2.3}]}
			marks={[
				{box: 'threshold', from: p(ph, 0) + 24, to: p(ph, 2) - 2, label: '71.66% · your LTV 72.37%', side: 'below', color: C.red},
				{box: 'close', from: p(ph, 2) + 24, label: 'one instruction', side: 'below'},
			]}
		/>
		<div style={SIDE}>
			<Stat k="Fri 15:15 ET" v={<span style={{color: C.red}}>72.37%</span>} sub={<>LTV, above a threshold of <b style={{color: C.lt}}>71.66%</b></>} style={rise(t, p(ph, 0))} />
			<Stat k="Before the close" v="Repay 7.34" sub="by 15:30, or add 0.0284 TSLA" color={C.accent} style={rise(t, p(ph, 3))} />
		</div>
	</Stage>
);

// d7. Show the transaction. The funded buffer, run by anyone, signed.
export const D7: React.FC<SceneProps> = ({t, ph}) => {
	const signed = at(t, ph, 2, 20, 14);
	return (
		<Stage>
			<Shot
				page={prepBuffer}
				t={t}
				stops={[{at: 0, zoom: 1}, {at: p(ph, 0), box: 'pop', zoom: 1.9}]}
				marks={[
					{box: 'pop', from: p(ph, 0) + 24, to: p(ph, 2) - 2, label: 'funded 7.00 · plan 65% · runs now', side: 'below'},
					{box: 'pop', from: p(ph, 2) + 4, label: 'Run buffer · 7.00 USDG', side: 'below', color: C.up},
				]}
			/>
			<div style={SIDE}>
				<Stat k="Funded in advance" v="7.00 USDG" sub="escrowed by the borrower, toward 65%" style={rise(t, p(ph, 0))} />
				<SidePill color={C.muted} style={rise(t, p(ph, 1))}>Anyone can execute it</SidePill>
				<Card glow={signed} style={{padding: 24, opacity: signed, transform: `translateY(${(1 - signed) * 20}px)`}}>
					<div style={{...label, color: C.up}}>✓ Confirmed</div>
					<div style={{fontSize: 26, marginTop: 10}}>executeBuffer · 7.00 USDG</div>
				</Card>
				<Rule ok={false} style={rise(t, p(ph, 3))}>No stock sold</Rule>
				<Rule ok={false} style={rise(t, p(ph, 3) + 10)}>No bonus paid</Rule>
			</div>
		</Stage>
	);
};

// d8. Show the state change. Debt 72.08 → 65.08, LTV 72.4% → 65.3%, the marker on the chart.
export const D8: React.FC<SceneProps> = ({t, ph}) => (
	<Stage>
		<Shot
			page={prepAfter}
			t={t}
			stops={[{at: 0, zoom: 1}, {at: p(ph, 0), box: 'state', zoom: 2.1}, {at: p(ph, 2), box: 'chart', zoom: 1.4}]}
			marks={[
				{box: 'state', from: p(ph, 0) + 24, to: p(ph, 2) - 2, label: 'debt 72.08 → 65.08', side: 'left', color: C.up},
				{box: 'buffer', from: p(ph, 1) + 10, to: p(ph, 2) - 2, label: 'Repaid 7.00', side: 'below', color: C.up},
			]}
		/>
		<div style={SIDE}>
			<Stat k="Debt" v={<span>72.08 → <span style={{color: C.up}}>65.08</span></span>} sub="USDG" style={rise(t, p(ph, 0))} />
			<Stat k="LTV" v={<span>72.4% → <span style={{color: C.up}}>65.3%</span></span>} sub={<>under the falling threshold of <b style={{color: C.lt}}>71.66%</b></>} style={rise(t, p(ph, 1))} />
			<SidePill color={C.up} style={rise(t, p(ph, 2))}>Liquidation · not eligible</SidePill>
		</div>
	</Stage>
);

// d9. What if nothing had executed? The partial liquidation the market would allow instead.
export const D9: React.FC<SceneProps> = ({t, ph}) => (
	<Stage>
		<Shot
			page={prepLiq}
			t={t}
			stops={[{at: 0, zoom: 1}, {at: p(ph, 0), box: 'pop', zoom: 2.1}]}
			marks={[{box: 'pop', from: p(ph, 0) + 24, label: 'partial liquidation · buffer first', side: 'below', color: C.red}]}
		/>
		<div style={SIDE}>
			<Card style={{padding: 26, ...rise(t, p(ph, 0))}}>
				<div style={{...label, color: C.red}}>Without the buffer</div>
				{[
					['Debt cut', '21.79 USDG'],
					['TSLA taken', '0.0558'],
					['Bonus', '2%'],
					['LTV after', '65.0%'],
				].map(([k, v], i) => (
					<div key={k} style={{display: 'flex', justifyContent: 'space-between', fontSize: 28, marginTop: 18, ...rise(t, p(ph, 0) + 14 + i * 8)}}>
						<span style={{color: C.muted}}>{k}</span>
						<span style={{fontFamily: F.mono}}>{v}</span>
					</div>
				))}
			</Card>
			<SidePill color={C.up} style={rise(t, p(ph, 2))}>The loan stays open</SidePill>
			<SidePill color={C.red} style={rise(t, p(ph, 2) + 20)}>Waiting costs the borrower</SidePill>
		</div>
	</Stage>
);

// d10. What happens over the weekend? Protection: only actions that shrink the loan.
export const D10: React.FC<SceneProps> = ({t, ph}) => (
	<Stage>
		<Shot
			page={closed}
			t={t}
			stops={[{at: 0, zoom: 1}, {at: p(ph, 1), box: 'pop', zoom: 2.2}]}
			marks={[{box: 'pop', from: p(ph, 1) + 24, label: 'credit locked through the closure', side: 'below'}]}
		/>
		<div style={SIDE}>
			<Card style={{padding: 26, display: 'flex', flexDirection: 'column', gap: 18, ...rise(t, p(ph, 0))}}>
				<div style={label}>Fri 16:00 · closed</div>
				<Rule ok style={rise(t, p(ph, 1))}>Repay</Rule>
				<Rule ok style={rise(t, p(ph, 1) + 8)}>Add TSLA</Rule>
				<Rule ok={false} style={rise(t, p(ph, 2))}>Borrow</Rule>
				<Rule ok={false} style={rise(t, p(ph, 2) + 8)}>Withdraw TSLA</Rule>
				<Rule ok={false} style={rise(t, p(ph, 2) + 16)}>Trim · buffer · lend</Rule>
			</Card>
		</div>
	</Stage>
);

// d11. How does Monday reopen? The fresh quote waits for admission, then the loan is valued at 376.
export const D11: React.FC<SceneProps> = ({t, ph}) => {
	const swap = at(t, ph, 2, 0, 18);
	return (
		<Stage>
			<Shot
				page={wait}
				t={t}
				opacity={1 - swap}
				stops={[{at: 0, zoom: 1}, {at: p(ph, 0), box: 'pop', zoom: 2.1}]}
				marks={[{box: 'pop', from: p(ph, 1), label: 'fresh 376.00 · not admitted until 09:35', side: 'below', color: C.amber}]}
			/>
			{swap > 0 ? (
				<Shot
					page={admit}
					t={t}
					opacity={swap}
					stops={[{at: 0, box: 'chart', zoom: 1.3}, {at: p(ph, 2) + 40, box: 'row', zoom: 1.5}]}
					marks={[{box: 'row', from: p(ph, 2) + 64, label: 'LTV 69.29% · threshold 70%', side: 'above', color: C.up}]}
				/>
			) : null}
			<div style={SIDE}>
				<Stat k="Monday 09:31" v="376.00" sub="fresh, but not yet admitted" color={C.amber} style={rise(t, p(ph, 0))} />
				<Stat k="Admitted 09:35" v={<span style={{color: C.up}}>69.29%</span>} sub="LTV at 376, under the 70% limit" style={rise(t, p(ph, 2))} />
				<SidePill color={C.muted} style={rise(t, p(ph, 3))}>New credit returns at 09:45</SidePill>
			</div>
		</Stage>
	);
};

// d12. Who carries a loss? The lender book: recoverable value, the what-if at 220, the share value.
export const D12: React.FC<SceneProps> = ({t, ph}) => {
	const swap = at(t, ph, 1, 10, 18);
	return (
		<Stage>
			<Shot
				page={lendAdmit}
				t={t}
				opacity={1 - swap}
				stops={[{at: 0, zoom: 1}, {at: p(ph, 0) + 10, box: 'loss', zoom: 1.55}]}
				marks={[{box: 'loss', from: p(ph, 0) + 34, label: 'fully covered at 376', side: 'below', color: C.up}]}
			/>
			{swap > 0 ? (
				<Shot
					page={lendWhatIf}
					t={t}
					opacity={swap}
					stops={[{at: 0, box: 'loss', zoom: 1.55}]}
					marks={[
						{box: 'slider', from: p(ph, 1) + 30, to: p(ph, 2) - 2, label: 'what if TSLA were 220', side: 'below', color: C.red},
						{box: 'loss', from: p(ph, 2), label: 'shortfall 12.75 · share value 0.8515', side: 'below', color: C.red},
					]}
				/>
			) : null}
			<div style={SIDE}>
				<Stat k="Recoverable" v="85.13" sub="USDG: cash plus what each loan can repay" style={rise(t, p(ph, 0))} />
				<Stat k="TSLA at 220" v={<span style={{color: C.red}}>12.75 short</span>} sub="0.25 TSLA after the recovery bonus covers 52.38 of 65.13" style={rise(t, p(ph, 1) + 20)} />
				<Stat k="Share value" v={<span>1.0016 → <span style={{color: C.red}}>0.8515</span></span>} sub="the loss is shared before anyone exits" style={rise(t, p(ph, 2))} />
			</div>
		</Stage>
	);
};

// d13. What happens when something goes wrong? A stale price: the contract refuses, the wallet never opens.
export const D13: React.FC<SceneProps> = ({t, ph}) => (
	<Stage>
		<Shot
			page={stale}
			t={t}
			stops={[{at: 0, zoom: 1}, {at: p(ph, 1), box: 'alert', zoom: 2.4}]}
			marks={[
				{box: 'pill', from: p(ph, 0) + 30, to: p(ph, 1) - 2, label: 'price stale', side: 'above', color: C.red},
				{box: 'alert', from: p(ph, 1) + 24, label: 'rejected by the contract', side: 'left', color: C.red},
			]}
		/>
		<div style={SIDE}>
			<Stat k="Mon 09:47 · borrow 1 USDG" v={<span style={{color: C.red}}>Refused</span>} sub="NotAllowedNow · Guarded · stock price stale" style={rise(t, p(ph, 1))} />
			<Stat k="Wallet requests" v="0" sub="the call is simulated first, so nothing is signed" style={rise(t, p(ph, 2))} />
		</div>
	</Stage>
);

// d14. Is it durable? The evidence page, then the engine checked against the contract's own view.
const CHECK = [
	'› npx tsx scripts/check-scenario.ts admit',
	'step admit: script t 1791812100 chain t 1791812100',
	'same  state          5 | 5',
	'same  ltWad          0.70 | 0.70',
	'same  target         0.65 | 0.65',
	'same  admissionAt    09:35 | 09:35',
	'same  canBorrow      false | false',
	'same  value          94.00 | 94.00',
	'same  debt           65.132771 | 65.132771',
	'same  ltv            0.692901… | 0.692901…',
	'same  repayToTarget  4.032771 | 4.032771',
	'20 of 20 fields identical',
];
export const D14: React.FC<SceneProps> = ({t, ph}) => (
	<Stage>
		<Browser
			page={evidence as PageShot}
			t={t}
			x={0}
			y={0}
			width={820}
			height={H}
			stops={[{at: 0, zoom: 1}, {at: p(ph, 0), box: 'tests', zoom: 1.8}, {at: p(ph, 1), box: 'fork', zoom: 1.8}]}
			marks={[
				{box: 'tests', from: p(ph, 0) + 24, to: p(ph, 1) - 2},
				{box: 'fork', from: p(ph, 1) + 24},
			]}
		/>
		<div style={{position: 'absolute', left: 860, top: 0, width: 820, ...rise(t, p(ph, 2))}}>
			<Terminal title="app · fork of chain 46630" lines={CHECK} progress={at(t, ph, 2, 0, 90)} scale={1.15} />
		</div>
	</Stage>
);

// d15. What roadblocks did we overcome? Two stuck → fixed rows.
const ROADBLOCKS = [
	['Stale demo price, every screen read zero', 'Contracts value the scripted step', 'lib/scenario.ts'],
	['MetaMask warned on unlimited approvals', 'Exact approval, simulated before signing', 'useTx'],
];
export const D15: React.FC<SceneProps> = ({t, ph}) => (
	<Stage>
		<div style={{display: 'flex', flexDirection: 'column', gap: 50, marginTop: 50}}>
			{ROADBLOCKS.map(([stuck, fix, where], i) => (
				<div key={stuck} style={{display: 'flex', alignItems: 'center', gap: 40}}>
					<Card style={{width: 660, padding: 28, borderColor: C.red, ...rise(t, p(ph, i * 2))}}>
						<div style={{...label, color: C.red}}>✗ Stuck</div>
						<div style={{fontSize: 34, fontFamily: F.head, marginTop: 10}}>{stuck}</div>
					</Card>
					<div style={{fontSize: 60, color: C.accent, ...rise(t, p(ph, i * 2 + 1))}}>→</div>
					<Card style={{width: 760, padding: 28, borderColor: C.up, ...rise(t, p(ph, i * 2 + 1) + 6)}}>
						<div style={{...label, color: C.up}}>✓ What we did</div>
						<div style={{fontSize: 34, fontFamily: F.head, marginTop: 10}}>{fix}</div>
						<div style={{fontFamily: F.mono, fontSize: 22, color: C.muted, marginTop: 8}}>{where}</div>
					</Card>
				</div>
			))}
		</div>
	</Stage>
);

// d16. What did we trade off, and what's next? The trade-off card, the roadmap, the closing line.
const ROADMAP = ['Calibrate against real gaps', 'More stocks', 'Audit', 'Robinhood Chain mainnet'];
export const D16: React.FC<SceneProps> = ({t, ph}) => {
	const closing = at(t, ph, 4, 0, 16);
	return (
		<Stage>
			<div style={{opacity: 1 - closing}}>
				<Card style={{display: 'flex', gap: 40, padding: 32, ...rise(t, p(ph, 0))}}>
					{[
						['We chose', 'Operator-set price and clock on testnet'],
						['So that', 'a weekend can be shown on demand'],
						['Later', 'live stock feeds, already read in the fork tests'],
					].map(([k, v]) => (
						<div key={k} style={{flex: 1}}>
							<div style={label}>{k}</div>
							<div style={{fontSize: 30, fontFamily: F.head, marginTop: 10, lineHeight: 1.3}}>{v}</div>
						</div>
					))}
				</Card>
				<div style={{display: 'flex', gap: 18, marginTop: 50}}>
					{ROADMAP.map((r, i) => (
						<div
							key={r}
							style={{
								flex: 1,
								padding: '26px 24px',
								borderRadius: 18,
								background: i === 3 ? `${C.brand}1c` : C.surface,
								border: `2px solid ${i === 3 ? C.brand : C.line}`,
								...rise(t, p(ph, i < 2 ? 2 : 3) + (i % 2) * 12),
							}}
						>
							<div style={{fontFamily: F.mono, fontSize: 22, color: C.accent}}>{i + 1}</div>
							<div style={{fontSize: 32, fontFamily: F.head, fontWeight: 600, marginTop: 8}}>{r}</div>
						</div>
					))}
				</div>
				<div style={{marginTop: 26, fontSize: 24, color: C.muted, ...rise(t, p(ph, 3) + 20)}}>Fees on at mainnet: 10% of interest and 10% of liquidation bonuses</div>
			</div>
			<div style={{position: 'absolute', inset: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', textAlign: 'center', opacity: closing}}>
				<div style={big(76)}>
					StockReef reduces stock-backed debt
					<br />
					<span style={{color: C.accent}}>before the market closes.</span>
				</div>
			</div>
		</Stage>
	);
};
