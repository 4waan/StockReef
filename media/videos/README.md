# StockReef submission videos

The pitch (3:51, twelve questions) and the demo (4:42, twelve chapters) as one Remotion project. Both are in the app's light theme on a burnt orange grid, with original synthesized music (`scripts/music.mjs`). The narration lives in `docs/DEMO_VIDEO_SCRIPT.md`; the voice-over is recorded separately and laid on top.

| | Pitch | Demo |
|---|---|---|
| Script | `pitch.json` → `scripts/timeline.mjs` | `demo.json` → `scripts/demo-timeline.mjs` |
| Picture | generated scenes, `src/scenes/pitch.tsx` | screen recordings of the deployed app on the public testnet, `src/Demo.tsx`; data, tests and next in `src/scenes/live.tsx` |
| Overlay | none | chapter title, the seven core features ticking off, transaction toasts with the real hashes |

## Voices

| Voice | Pitch | Demo |
|---|---|---|
| Aryan Singh Rathore | q1 q2 q3 q7 q8 q11 q12 | intro problem data weekend lenders next |
| Awaan Mustafa Siddiqui | q4 q5 q6 q9 q10 | book countdown paydown trim failure tests |

## The seven core features in the demo

| Feature | Chapter |
|---|---|
| 1. Debt reduced before the close | 05 countdown, 06 paydown |
| 2. Falling threshold | 05 countdown |
| 3. Funded repayment buffer | 06 paydown (real `executeBuffer` on testnet) |
| 4. Partial liquidation | 07 trim (real trim on testnet) |
| 5. Closed-session protection | 08 weekend (credit locked, a real repayment while closed) |
| 6. Controlled reopening | 08 weekend (price admission, a real recovery trim) |
| 7. Lender loss accounting | 09 lenders |

## Build

```bash
npm install
export REMOTION_BROWSER=/path/to/chromium   # only where Remotion cannot download its own
npm run render:pitch          # out/stockreef-pitch-music-only.mp4
npm run render:pitch-guide    # out/stockreef-pitch-guide.mp4: teleprompter and timecode, for recording
npm run render:demo           # out/stockreef-demo-music-only.mp4
npm run render:demo-guide     # out/stockreef-demo-guide.mp4
npm run stills -- Pitch q2    # review pitch frames in out/stills
npm run studio                # scrub in the browser
```

`prepare:<video>` rebuilds `src/timeline-<video>.json` (when each card, answer and caption starts, at 2.45 words a second) and synthesizes the music bed. Edit a script's phrases, re-run it, and picture and music stay on one clock.

## Recording the voice-over

1. Play the guide render. The teleprompter shows the current sentence and the timecode.
2. Record one file per segment, for example `public/voice/demo/d7.m4a`. Each file starts on the answer, not on the question card.
3. Run `node scripts/mix-voices.mjs demo public/voice/demo`. It places each take at its answer's start, cleans and levels the voice, lowers the music under it, and flags any take that overruns its slot.

## The live recording (demo)

The demo is a real run on the public Robinhood Chain testnet (chain 46630), recorded against stock-reef.vercel.app. Every transaction hash is listed with its explorer link in `evidence/demo-live-46630.json`.

```bash
# keys: OPERATOR_KEY, BORROWER_KEY, LIQUIDATOR_KEY in the ignored .env.roles at the repository root
cd app && npx tsx scripts/demo.ts prepare            # Friday 13:00 at 400.00, borrower at 72 USDG with a 7 USDG buffer
bash ../media/videos/capture/book-live.sh            # Treasury lends 140 USDG; Ava, Ben and Cleo borrow
cd ../media/videos
NODE_USE_ENV_PROXY=1 node capture/record.mjs         # every chapter in order, stepping the testnet between them
node capture/build-clips.mjs                         # public/rec/<clip>.mp4 + .json (cursor path, events)
npm run render:demo
```

`capture/record.mjs` drives Chromium with a logged cursor path and captures every painted frame (CDP screencast). The page's wallet is an injected EIP-1193 provider that signs with the role keys in Node through `cast`, so it shows no wallet window of its own. `demo.json` cuts each clip, and only waits for blocks and page loads are sped up or removed. The composition draws the cursor from the logged path.

`capture/pages.mjs` and `public/pages/` hold the stills the pitch uses (Q4 and Q8).

## Sources

- `public/pitch/tsla-aug-2024.json`: TSLA daily sessions from Yahoo Finance, 22 Jul to 9 Aug 2024.
- Fonts: Geist and Geist Mono, under the SIL Open Font License (`public/fonts/LICENSE-geist.txt`).
- The engine (`src/Video.tsx`, `src/app/Browser.tsx`, `scripts/`) is adapted from the team's Lemma submission videos.
