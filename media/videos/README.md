# StockReef submission videos

The pitch (3:28, twelve questions) and the demo (4:37, sixteen questions) as one Remotion project, in the app's light theme. The narration lives in `docs/DEMO_VIDEO_SCRIPT.md`, and this project turns it into picture and music. The voice-over is recorded separately and laid on top.

| | Pitch | Demo |
|---|---|---|
| Script | `pitch.json` | `demo.json` |
| Scenes | `src/scenes/pitch.tsx` | `src/scenes/demo.tsx` |
| Opens on | the StockReef mark | the landing page, panning from the hero to the control sequence |
| Overlay | none | a strip that ticks off the seven core features as each is shown |

## Voices

| Voice | Pitch | Demo |
|---|---|---|
| Aryan Singh Rathore | q1 q2 q3 q7 q8 q11 q12 | d1 d2 d3 d4 d10 d12 d14 d16 |
| Awaan Mustafa Siddiqui | q4 q5 q6 q9 q10 | d5 d6 d7 d8 d9 d11 d13 d15 |

## The seven core features in the demo

| Feature | Shown in |
|---|---|
| 1. Debt reduced before the close | d4, d6 |
| 2. Falling threshold | d4 |
| 3. Funded repayment buffer | d7, d8 |
| 4. Partial liquidation | d9 |
| 5. Closed-session protection | d10 |
| 6. Controlled reopening | d11 |
| 7. Lender loss accounting | d12 |

## Build

```bash
npm install
export REMOTION_BROWSER=/path/to/chromium   # only where Remotion cannot download its own
npm run render:pitch          # out/stockreef-pitch-music-only.mp4
npm run render:pitch-guide    # out/stockreef-pitch-guide.mp4: teleprompter and timecode, for recording
npm run render:demo           # out/stockreef-demo-music-only.mp4
npm run render:demo-guide     # out/stockreef-demo-guide.mp4
npm run stills -- Demo d12    # review frames in out/stills
npm run studio                # scrub in the browser
```

`prepare:<video>` rebuilds `src/timeline-<video>.json` (when each card, answer and caption starts, at 2.45 words a second) and synthesizes the music bed. Edit a script's phrases, re-run it, and picture and music stay on one clock.

## Recording the voice-over

1. Play the guide render. The teleprompter shows the current sentence and the timecode.
2. Record one file per segment, for example `public/voice/demo/d7.m4a`. Each file starts on the answer, not on the question card.
3. Run `node scripts/mix-voices.mjs demo public/voice/demo`. It places each take at its answer's start, cleans and levels the voice, lowers the music under it, and flags any take that overruns its slot.

## App captures

`public/pages/*.jpg` are 2× screenshots of the app, and each comes with a `.json` of the element boxes the camera moves to. They were taken in the light theme on a local anvil fork of the chain 46630 deployment, stepped through the scripted weekend with `app/scripts/demo.ts --fork`:

```bash
anvil --fork-url https://rpc.testnet.chain.robinhood.com --auto-impersonate   # plus anvil_setBalance for the role accounts
cd app && NEXT_PUBLIC_RPC_URL=http://127.0.0.1:8545 npx next dev -p 3100
npx tsx scripts/demo.ts prepare --fork && npx tsx scripts/demo.ts step prep --fork
cd ../media/videos
APP=http://localhost:3100 node capture/pages.mjs trade-prep                                   # pitch pages
APP=http://localhost:3100 PAGES=capture/demo-pages.json GROUP=prep node capture/pages.mjs     # demo, before the buffer
# then demo.ts run-buffer, and step closed / wait / admit with GROUP=<step>;
# for GROUP=stale, step credit and advance the fork 150 s so the price is stale
```

A page in `capture/demo-pages.json` can open popovers, fill the ticket or move the what-if slider. With `wallet` set, it connects a stub wallet that forwards to the fork, so the signing preview and the contract's preflight rejection render. Nothing is signed.

The transaction hashes in these captures come from the fork, so they are not on the public explorer. For explorer receipts, re-capture against testnet after `npm run demo -- prepare`.

## Sources

- `public/pitch/tsla-aug-2024.json`: TSLA daily sessions from Yahoo Finance, 22 Jul to 9 Aug 2024.
- Fonts: Geist and Geist Mono, under the SIL Open Font License (`public/fonts/LICENSE-geist.txt`).
- The engine (`src/Video.tsx`, `src/app/Browser.tsx`, `scripts/`) is adapted from the team's Lemma submission videos.
