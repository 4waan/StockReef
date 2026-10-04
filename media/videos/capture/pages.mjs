// Captures the app pages the videos show, as 2x screenshots, plus the box of every element the video points at.
// Remotion pans and zooms over them. Run against the app on a fork (or testnet) aligned to the scripted step:
//
//   APP=http://localhost:3000 [THEME=dark] [PAGES=capture/demo-pages.json] node capture/pages.mjs [name …]
//
// Light by default. A page can set "wallet" (an address: a stub wallet that forwards to the fork at RPC, so signing
// previews and preflight rejections render) and "actions" run in order before the shot: ["click", target],
// ["fill", target, text], ["range", target, value], ["wait", ms].
//
// Needs Chromium (CHROMIUM, default the Playwright build in /opt/pw-browsers).
import {chromium} from 'playwright-core';
import {mkdirSync, writeFileSync, readFileSync} from 'node:fs';

const APP = process.env.APP ?? 'http://localhost:3000';
const PAGES = JSON.parse(readFileSync(process.env.PAGES ?? new URL('./pages.json', import.meta.url), 'utf8'));
const RPC = process.env.RPC ?? 'http://127.0.0.1:8545';
const only = process.argv.slice(2);
const GROUP = process.env.GROUP;
const THEME = process.env.THEME === 'dark' ? 'dark' : 'light';
const executablePath = process.env.CHROMIUM ?? '/opt/pw-browsers/chromium-1194/chrome-linux/chrome';
const out = new URL('../public/pages/', import.meta.url);
mkdirSync(out, {recursive: true});
const browser = await chromium.launch({executablePath, args: ['--no-sandbox']});
const context = await browser.newContext({viewport: {width: 1600, height: 900}, deviceScaleFactor: 2, colorScheme: THEME});
await context.addInitScript((theme) => {
	try {
		localStorage.setItem('reef.theme', theme);
		localStorage.removeItem('reef.session.46630');
	} catch {}
}, THEME);
// "css:<selector>", "up<N>:<text>" (the text's Nth ancestor), "button:<name>", "dialog:<name>", or plain text.
const find = (p, target) => {
	const up = /^up(\d):(.*)$/.exec(target);
	if (target.startsWith('css:')) return p.locator(target.slice(4)).first();
	if (target.startsWith('button:')) return p.getByRole('button', {name: target.slice(7), exact: true}).first();
	if (target.startsWith('dialog:')) return p.getByRole('dialog', {name: target.slice(7)}).first();
	if (target.startsWith('tab:')) return p.getByRole('tab', {name: target.slice(4)}).first();
	if (target.startsWith('label:')) return p.getByLabel(target.slice(6)).first();
	if (up) return p.getByText(up[2], {exact: true}).first().locator(`xpath=${Array(Number(up[1])).fill('..').join('/')}`);
	return p.getByText(target, {exact: false}).first();
};
for (const page of PAGES) {
	if (only.length && !only.includes(page.name)) continue;
	if (GROUP && page.group !== GROUP) continue;
	const url = page.url.replace('$APP', APP);
	const p = await context.newPage();
	if (page.wallet) {
		await p.exposeFunction('__rpc', async (method, params) => {
			const r = await fetch(RPC, {method: 'POST', headers: {'content-type': 'application/json'}, body: JSON.stringify({jsonrpc: '2.0', id: 1, method, params})});
			const j = await r.json();
			if (j.error) throw new Error(j.error.message);
			return j.result;
		});
		await p.addInitScript((addr) => {
			window.ethereum = {
				isMetaMask: true,
				on: () => {},
				removeListener: () => {},
				request: async ({method, params}) => {
					if (method === 'eth_requestAccounts' || method === 'eth_accounts') return [addr];
					if (method === 'eth_chainId') return '0xb626';
					if (method.startsWith('wallet_')) return null;
					return window.__rpc(method, params ?? []);
				},
			};
		}, page.wallet);
	}
	await p.goto(url, {waitUntil: 'networkidle', timeout: 90000}).catch(() => {});
	// Contract reads and the event history settle over a few polls.
	await p.waitForTimeout(page.wait ?? 9000);
	if (page.wallet) {
		await p.getByRole('button', {name: 'Connect wallet', exact: true}).first().click().catch(() => console.log(page.name, 'no connect button'));
		await p.waitForTimeout(5000);
	}
	for (const [kind, target, value] of page.actions ?? []) {
		if (kind === 'wait') await p.waitForTimeout(target);
		else if (kind === 'click') await find(p, target).click();
		else if (kind === 'fill') await find(p, target).fill(value);
		else if (kind === 'range') await find(p, target).evaluate((el, v) => {
			Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, String(v));
			el.dispatchEvent(new Event('input', {bubbles: true}));
			el.dispatchEvent(new Event('change', {bubbles: true}));
		}, value);
		await p.waitForTimeout(kind === 'wait' ? 0 : 1200);
	}
	if (!page.keepScroll) await p.evaluate(() => window.scrollTo(0, 0));
	const height = Math.min(page.height ?? 900, await p.evaluate(() => document.documentElement.scrollHeight));
	const boxes = {};
	for (const [key, target] of Object.entries(page.targets ?? {})) {
		const loc = find(p, target);
		const box = await loc.boundingBox().catch(() => null);
		if (!box) console.log(page.name, 'missing target', key, target);
		else boxes[key] = {x: box.x, y: box.y + (await p.evaluate(() => window.scrollY)), w: box.width, h: box.height};
	}
	await p.screenshot({path: new URL(`${page.name}.jpg`, out).pathname, type: 'jpeg', quality: 90, fullPage: true, clip: {x: 0, y: 0, width: 1600, height}});
	writeFileSync(new URL(`${page.name}.json`, out), JSON.stringify({name: page.name, url: url.replace(APP, 'stock-reef.vercel.app'), width: 1600, height, scale: 2, boxes}, null, '\t') + '\n');
	console.log(page.name, height, Object.keys(boxes).join(','));
	await p.close();
}
await browser.close();
