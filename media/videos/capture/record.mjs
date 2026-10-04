// Records the demo as continuous screen captures of the deployed app on the PUBLIC chain 46630 testnet: every frame
// the browser paints, the cursor path that drove it, and every transaction it signed. One clip per chapter; the
// testnet is stepped along the scripted weekend between chapters (off camera) with app/scripts/demo.ts.
//
//   NODE_USE_ENV_PROXY=1 node capture/record.mjs [clip …]
//
// The wallet is an injected EIP-1193 provider whose signing happens here, in Node, with the role keys from the ignored
// .env.roles (cast send); it never shows a wallet UI. Output: public/rec/<clip>/ (frames, clip.json), see build-clips.mjs.
import {chromium} from 'playwright-core';
import {execFileSync} from 'node:child_process';
import {mkdirSync, readFileSync, rmSync, writeFileSync} from 'node:fs';

const APP = process.env.APP ?? 'https://stock-reef.vercel.app';
const RPC = process.env.RPC_URL ?? 'https://rpc.testnet.chain.robinhood.com';
const ROOT = new URL('../../../', import.meta.url).pathname;
const OUT = new URL('../public/rec/', import.meta.url).pathname;
const CAST = `${process.env.HOME}/.foundry/bin/cast`;
const only = process.argv.slice(2);

const keys = Object.fromEntries(
	readFileSync(`${ROOT}.env.roles`, 'utf8')
		.trim()
		.split('\n')
		.map((l) => [l.slice(0, l.indexOf('=')).replace(/_KEY$/, ''), l.slice(l.indexOf('=') + 1)]),
);
const address = (role) => execFileSync(CAST, ['wallet', 'address', '--private-key', keys[role]]).toString().trim();
const ROLE = Object.fromEntries(Object.keys(keys).map((r) => [r, address(r)]));

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const now = () => Date.now() / 1000;
const demo = (...args) => {
	const out = execFileSync('npx', ['tsx', 'scripts/demo.ts', ...args], {cwd: `${ROOT}app`, env: process.env}).toString();
	console.log(out.split('\n').filter((l) => /0x[0-9a-f]{64}|clock/.test(l)).join('\n'));
};

// ---- browser, wallet bridge and capture ------------------------------------------------------------------------
const browser = await chromium.launch({executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome', args: ['--no-sandbox']});
const context = await browser.newContext({viewport: {width: 1600, height: 900}, deviceScaleFactor: 1.2, colorScheme: 'light'});
await context.addInitScript(() => {
	try {
		localStorage.setItem('reef.theme', 'light');
	} catch {}
	const listeners = {};
	window.ethereum = {
		isMetaMask: false,
		on: (e, f) => ((listeners[e] ??= []).push(f)),
		removeListener: (e, f) => (listeners[e] = (listeners[e] ?? []).filter((g) => g !== f)),
		request: ({method, params}) => window.__wallet(method, params ?? []),
	};
	window.__emit = (e, v) => (listeners[e] ?? []).forEach((f) => f(v));
});
const wallet = {role: 'BORROWER'};
let clip = null;
await context.exposeFunction('__wallet', async (method, params) => {
	if (method === 'eth_requestAccounts' || method === 'eth_accounts') return [ROLE[wallet.role]];
	if (method === 'eth_chainId') return '0xb626';
	if (method === 'net_version') return '46630';
	if (method === 'wallet_getPermissions' || method === 'wallet_requestPermissions') return [{parentCapability: 'eth_accounts'}];
	if (method.startsWith('wallet_')) return null;
	if (method === 'eth_sendTransaction') {
		const tx = params[0];
		const args = ['send', '--async', '--private-key', keys[wallet.role], '--rpc-url', RPC, tx.to, tx.data ?? '0x'];
		if (tx.value && BigInt(tx.value) > 0n) args.push('--value', BigInt(tx.value).toString());
		if (tx.gas) args.push('--gas-limit', BigInt(tx.gas).toString());
		const hash = execFileSync(CAST, args).toString().trim();
		console.log(`  signed by ${wallet.role.toLowerCase()}: ${hash}`);
		clip?.events.push({t: now(), kind: 'tx', role: wallet.role, hash});
		return hash;
	}
	const r = await fetch(RPC, {method: 'POST', headers: {'content-type': 'application/json'}, body: JSON.stringify({jsonrpc: '2.0', id: 1, method, params})});
	const j = await r.json();
	if (j.error) throw Object.assign(new Error(j.error.message), {code: j.error.code, data: j.error.data});
	return j.result;
});

const capturing = new Map();
async function capture(page) {
	if (capturing.has(page)) return;
	const cdp = await context.newCDPSession(page);
	cdp.on('Page.screencastFrame', async (f) => {
		cdp.send('Page.screencastFrameAck', {sessionId: f.sessionId}).catch(() => {});
		if (!clip) return;
		const file = `${String(clip.frames.length).padStart(5, '0')}.jpg`;
		writeFileSync(`${clip.dir}/${file}`, Buffer.from(f.data, 'base64'));
		clip.frames.push({file, t: f.metadata.timestamp});
	});
	await cdp.send('Page.startScreencast', {format: 'jpeg', quality: 90, maxWidth: 1920, maxHeight: 1080});
	capturing.set(page, cdp);
}
context.on('page', (p) => capture(p).catch(() => {}));

const page = await context.newPage();
await capture(page);
const mouse = {x: 800, y: 450};

function begin(name) {
	const dir = `${OUT}${name}`;
	rmSync(dir, {recursive: true, force: true});
	mkdirSync(dir, {recursive: true});
	clip = {name, dir, start: now(), frames: [], cursor: [{t: now(), x: mouse.x, y: mouse.y}], events: []};
	console.log(`● ${name}`);
}
function end() {
	clip.end = now();
	const {dir, ...rest} = clip;
	writeFileSync(`${dir}/clip.json`, JSON.stringify(rest, null, 1));
	console.log(`■ ${clip.name}: ${(clip.end - clip.start).toFixed(1)} s, ${clip.frames.length} frames, ${clip.events.length} events`);
	clip = null;
}
const mark = (label) => clip?.events.push({t: now(), kind: 'mark', label});

/** Glide the cursor to (x, y) along an eased path, logging every point. */
async function glide(x, y, ms = 650, p = page) {
	const [x0, y0] = [mouse.x, mouse.y];
	const n = Math.max(8, Math.round(ms / 16));
	for (let i = 1; i <= n; i++) {
		const k = i / n;
		const e = k < 0.5 ? 4 * k * k * k : 1 - Math.pow(-2 * k + 2, 3) / 2;
		mouse.x = x0 + (x - x0) * e;
		mouse.y = y0 + (y - y0) * e;
		await p.mouse.move(mouse.x, mouse.y);
		clip?.cursor.push({t: now(), x: mouse.x, y: mouse.y});
		await sleep(ms / n);
	}
}
async function boxOf(target, p = page) {
	const loc = typeof target === 'string' ? p.getByText(target, {exact: true}).first() : target;
	await loc.waitFor({state: 'visible', timeout: 30000});
	await loc.scrollIntoViewIfNeeded();
	return loc.boundingBox();
}
async function hover(target, ms = 650, p = page) {
	const b = await boxOf(target, p);
	await glide(b.x + b.width / 2, b.y + b.height / 2, ms, p);
	return b;
}
async function click(target, p = page) {
	await hover(target, 650, p);
	await sleep(180);
	clip?.cursor.push({t: now(), x: mouse.x, y: mouse.y, click: true});
	await p.mouse.down();
	await sleep(90);
	await p.mouse.up();
}
async function scroll(dy, ms = 1800, p = page) {
	const n = Math.round(ms / 30);
	for (let i = 0; i < n; i++) {
		await p.mouse.wheel(0, dy / n);
		await sleep(30);
	}
}
const btn = (name, p = page) => p.getByRole('button', {name, exact: true}).first();
const link = (name, p = page) => p.getByRole('link', {name, exact: true}).first();
async function go(path, wait = 7000) {
	await page.goto(`${APP}${path}`, {waitUntil: 'domcontentloaded', timeout: 90000});
	await page.waitForTimeout(wait);
}
/** Waits until text appears (a confirmation, a state), up to `ms`. */
const until = (text, ms = 60000) => page.getByText(text, {exact: false}).first().waitFor({timeout: ms});

/** Opens the explorer tab that the app's receipt link targets, shows it, closes it. */
async function receipt(linkLoc, hold = 6500) {
	const opened = context.waitForEvent('page', {timeout: 20000});
	await click(linkLoc);
	const tab = await opened;
	await tab.bringToFront();
	await tab.waitForLoadState('domcontentloaded').catch(() => {});
	await tab.waitForTimeout(2500);
	mark('explorer');
	await glide(700, 520, 900, tab);
	await tab.waitForTimeout(hold);
	await tab.close();
	await page.bringToFront();
	await sleep(600);
}

// ---- chapters --------------------------------------------------------------------------------------------------
const CLIPS = {
	// The real landing page, then into the app.
	async landing() {
		await page.goto(APP, {waitUntil: 'domcontentloaded', timeout: 90000});
		await page.waitForTimeout(6000);
		begin('landing');
		await sleep(1200);
		await hover(page.locator('h1').first(), 1100);
		await sleep(1200);
		await scroll(1250, 2600);
		await sleep(2200);
		await scroll(-1250, 1600);
		await sleep(600);
		await click(link('Borrow against TSLA ↗').or(page.getByText('Borrow against TSLA', {exact: false}).first()));
		await page.waitForTimeout(6000);
		end();
	},
	// The TSLA page: the weekend with no price, and Monday's gap.
	async problem() {
		await go('/markets/tsla?step=admit', 9000);
		begin('problem');
		await sleep(800);
		await hover(page.locator('main svg[role=img]').first(), 900);
		await sleep(700);
		const chart = await boxOf(page.locator('main svg[role=img]').first());
		await glide(chart.x + chart.width * 0.66, chart.y + chart.height * 0.5, 900);
		await sleep(1800);
		await glide(chart.x + chart.width * 0.8, chart.y + chart.height * 0.7, 900);
		await sleep(2500);
		await hover(page.getByText('Session schedule', {exact: false}).first(), 900);
		await scroll(420, 1200);
		await sleep(3000);
		end();
	},
	// Connect the borrower's wallet, then the book at scale: portfolio, lenders, operations.
	async book() {
		demo('price');
		wallet.role = 'BORROWER';
		await go('/portfolio?step=open', 8000);
		begin('book');
		await sleep(600);
		await click(btn('Connect wallet'));
		await page.waitForTimeout(4500);
		await hover(page.getByText('Position health', {exact: false}).first(), 900);
		await sleep(1600);
		await hover(page.getByText('Before the close', {exact: false}).first(), 700);
		await sleep(1200);
		await hover(page.getByText('Funded buffer', {exact: false}).first(), 700);
		await sleep(1200);
		await click(link('Lend'));
		await page.waitForTimeout(6500);
		await hover(page.getByText('Loans in the book', {exact: false}).first(), 900);
		const rows = page.locator('main table tbody tr');
		for (let i = 0; i < Math.min(await rows.count(), 5); i++) {
			await hover(rows.nth(i), 380);
			await sleep(260);
		}
		await sleep(1500);
		await click(link('Operations'));
		await page.waitForTimeout(6500);
		await hover(page.locator('main table').first(), 900).catch(() => {});
		await sleep(3500);
		end();
	},
	// 15:15: the threshold has fallen; what the borrower must do, and by when.
	async countdown() {
		demo('step', 'prep');
		wallet.role = 'BORROWER';
		await go('/trade?step=open', 8000);
		await click(btn('Connect wallet')).catch(() => {});
		await page.waitForTimeout(3000);
		begin('countdown');
		await sleep(800);
		await click(page.locator("ol[aria-label='Session steps']").getByText('15:15', {exact: false}).first());
		await page.waitForTimeout(5000);
		await hover(page.locator('main svg[role=img]').first(), 900);
		await sleep(1500);
		await hover(btn('Threshold'), 800);
		await sleep(1800);
		await hover(btn('Before the close'), 800);
		await sleep(2600);
		await hover(btn('Liquidation'), 800);
		await sleep(2200);
		end();
	},
	// The borrower's funded buffer runs: the transaction, the state change, the receipt on the explorer.
	async paydown() {
		demo('price');
		wallet.role = 'BORROWER';
		await go('/trade?step=prep', 8000);
		await click(btn('Connect wallet')).catch(() => {});
		await page.waitForTimeout(4000);
		begin('paydown');
		await sleep(600);
		await click(btn('Funded buffer'));
		await page.waitForTimeout(2600);
		await click(page.getByRole('button', {name: /Run buffer/}).first());
		mark('signed');
		await until('Buffer repaid', 90000);
		mark('confirmed');
		await page.waitForTimeout(2500);
		await page.keyboard.press('Escape');
		await hover(page.locator("[aria-label='Last state change']").first(), 900);
		await sleep(3200);
		await hover(page.locator('main svg[role=img]').first(), 900);
		await sleep(2200);
		await receipt(page.locator("[aria-label='Last state change'] a").first());
		await sleep(1200);
		end();
	},
	// Ben has no buffer: the liquidator trims part of the loan, from the operations queue.
	async trim() {
		demo('price');
		wallet.role = 'LIQUIDATOR';
		await go('/operations?step=prep', 8000);
		await click(btn('Connect wallet')).catch(() => {});
		await page.waitForTimeout(5000);
		begin('trim');
		await sleep(600);
		const row = page.locator('main table tbody tr').filter({has: page.getByRole('button', {name: 'Trim', exact: true})}).first();
		await hover(row, 900);
		await sleep(2200);
		await click(row.getByRole('button', {name: 'Trim', exact: true}));
		mark('signed');
		await page.waitForTimeout(22000);
		mark('confirmed');
		await go(`/trade?step=prep&account=${ROLE.BEN}`, 7000);
		await hover(page.locator("[aria-label='Last state change']").first(), 900).catch(() => {});
		await sleep(3000);
		await receipt(page.locator("[aria-label='Last state change'] a").first());
		end();
	},
	// 16:00 closed: credit locked, but paying down still works (a real repayment).
	async weekend() {
		demo('step', 'closed');
		wallet.role = 'BORROWER';
		await go('/trade?step=closed', 8000);
		await click(btn('Connect wallet')).catch(() => {});
		await page.waitForTimeout(4000);
		begin('weekend');
		await sleep(600);
		await click(btn('Protection'));
		await sleep(3000);
		await page.keyboard.press('Escape');
		await click(page.getByRole('tab', {name: 'Borrow'}));
		await sleep(2200);
		await click(page.getByRole('tab', {name: 'Repay'}));
		await click(page.getByLabel('Amount in USDG'));
		await page.keyboard.type('1', {delay: 120});
		await sleep(2500);
		await click(page.locator('aside').getByRole('button', {name: /repay/i}).last());
		mark('signed');
		await page.waitForTimeout(20000);
		mark('confirmed');
		await sleep(1500);
		end();
	},
	// Monday: a fresh price waits for admission, the reopening, then credit returns.
	async monday() {
		demo('step', 'wait');
		wallet.role = 'BORROWER';
		await go('/trade?step=wait', 8000);
		begin('monday');
		await sleep(600);
		await click(btn('Reopening'));
		await sleep(3500);
		await page.keyboard.press('Escape');
		await hover(page.locator('main svg[role=img]').first(), 900);
		await sleep(1500);
		end();
		demo('step', 'admit');
		await go('/trade?step=admit', 8000);
		begin('monday-admit');
		await sleep(600);
		await click(btn('Reopening'));
		await sleep(3200);
		await page.keyboard.press('Escape');
		await hover(page.locator('main table tbody tr').first(), 900);
		await sleep(2500);
		end();
		// The reopening's recovery: Cleo's loan crossed 70% at the 376 price, so the liquidator trims it back.
		demo('price');
		wallet.role = 'LIQUIDATOR';
		await go('/operations?step=admit', 8000);
		await click(btn('Connect wallet')).catch(() => {});
		await page.waitForTimeout(5000);
		begin('recovery');
		await sleep(600);
		const row = page.locator('main table tbody tr').filter({has: page.getByRole('button', {name: 'Trim', exact: true})}).first();
		await hover(row, 900);
		await sleep(2200);
		await click(row.getByRole('button', {name: 'Trim', exact: true}));
		mark('signed');
		await page.waitForTimeout(22000);
		mark('confirmed');
		await hover(row, 700).catch(() => {});
		await sleep(2500);
		end();
	},
	// Lenders: the book after the weekend, and what a deeper gap would cost them.
	async lenders() {
		await go('/earn?step=admit', 9000);
		begin('lenders');
		await sleep(700);
		await hover(page.getByLabel('Lender book composition'), 900);
		await sleep(2000);
		const slider = page.getByLabel('What-if TSLA price');
		const b = await boxOf(slider);
		const at = (usd) => b.x + ((usd - 150) / (420 - 150)) * b.width;
		await glide(at(376), b.y + b.height / 2, 900);
		await sleep(400);
		clip.cursor.push({t: now(), x: mouse.x, y: mouse.y, click: true});
		await page.mouse.down();
		await glide(at(220), b.y + b.height / 2, 2600);
		await page.mouse.up();
		await sleep(3500);
		await hover(page.getByText('Loans in the book', {exact: false}).first(), 900);
		await sleep(2500);
		end();
	},
	// The deliberate failure: the price feed goes quiet, and the contract refuses a borrow before any signature.
	async failure() {
		demo('step', 'credit');
		console.log('  waiting 150 s for the price to go stale');
		await sleep(150000);
		wallet.role = 'BORROWER';
		await go('/trade?step=credit', 8000);
		await click(btn('Connect wallet')).catch(() => {});
		await page.waitForTimeout(4000);
		begin('failure');
		await sleep(600);
		await hover(btn('Testnet oracle and clock'), 900);
		await sleep(1500);
		await click(page.getByRole('tab', {name: 'Borrow'}));
		await click(page.getByLabel('Amount in USDG'));
		await page.keyboard.type('1', {delay: 120});
		await page.waitForTimeout(7000);
		await hover(page.getByRole('alert').first(), 900);
		await sleep(3500);
		end();
	},
};

for (const [name, fn] of Object.entries(CLIPS)) {
	if (only.length && !only.includes(name)) continue;
	try {
		await fn();
	} catch (e) {
		console.log(`✗ ${name}: ${String(e).split('\n')[0]}`);
		if (clip) end();
	}
}
await browser.close();
