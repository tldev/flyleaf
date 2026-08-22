# First Kindle test

Goal: prove the core loop on a real account and device. Time to first card should be under two minutes from launch.

Before you start:

- Kindle on Wi-Fi, signed into the same Amazon account you'll connect.
- Pack builder auth ready: either `ant auth login` completed in Terminal (Claude account, preferred) or an Anthropic API key to paste in Settings, Pack Builder.
- The book you test with must be a store-purchased Kindle book. Emailed (Send-to-Kindle) books never appear in the Cloud Reader API; use Manual Mode for those.
- Log file open if you want to watch: `tail -f ~/Library/Application\ Support/Flyleaf/logs/flyleaf.log`

## 1. Onboarding and connect

1. `open dist/Flyleaf.app`. The welcome window should appear.
2. Click Connect Amazon. Sign in on the embedded Amazon page (2FA or passkey as usual).
3. Expected within a few seconds of landing back on read.amazon.com: the magic moment screen shows your most recent Kindle book with cover and percent.
   - Log lines to expect: `Amazon sign-in detected`, `Registered reader device`, `Amazon session verified, N books visible`.
   - If it stalls on "Checking your Kindle library": the log will show which endpoint failed and the first bytes of Amazon's response. A `bot challenge` line means the fallback transport engaged; give it one retry.
4. Paste the Anthropic key when the field appears (first run only). The first context pack builds behind the shimmer; the TOC pass plus the chapter pass usually takes 1 to 3 minutes on the first book.
5. Continue, pick preferences, Start reading. The main window opens on the Dashboard.

## 2. The core loop

6. Dashboard shows the current chapter's cards: briefing, people with photos, places on maps, terms. Chapter and percent in the header should match your Kindle roughly (within a chapter).
7. On the Kindle: read a few pages, then sleep the device (sleep forces a sync). Within about a minute the Dashboard header percent should tick and "synced just now" should appear.
   - Expected log: `Position for <book>: NN.N%`.
8. Read across a chapter boundary (or use the chapter menu to jump): cards fade to the new chapter's cast. First visit to a chapter builds for a while; with prefetch on, the next chapter is usually instant.
9. Wrong chapter? Use the header stepper ("I'm actually at..."). A pin badge appears; Flyleaf follows the Kindle again once the position moves to a new chapter.

## 3. The rest, in any order

- Menu bar: percent label, Sync now, Pause, Ask (Option-Command-K), Previously On.
- Cast, Atlas, Timeline, Objects, Stats tabs populate as chapters accumulate.
- Optional: menu bar, Show floating panel, for the always-on-top glance surface with ambient mode after a few quiet minutes.
- Notifications: enable in Settings, then cross a chapter; a briefing notification should arrive.
- Share: Dashboard header, Share button, produces a spoiler-free HTML page in the exports folder.

## If something breaks

- Everything lands in `~/Library/Application Support/Flyleaf/logs/flyleaf.log` (Settings, Advanced, Open log file).
- Session expired: menu bar shows a re-connect badge; one click opens Amazon sign-in again.
- Pack build failed: the Dashboard shows the error inline with a retry button; the log has the API detail.
- Nuclear option: Settings, Advanced, Run onboarding again, or delete `~/Library/Application Support/Flyleaf/` to start fresh.

## What to note for v0.2

- Actual sync lag on your Kindle model (page turns vs sleep vs book close).
- Whether the metadata TOC appeared (`Using exact TOC from book metadata` in the log) or the LLM TOC was used, and how accurate the chapter mapping felt.
- Pack quality: hallucinated entities, spoiler leaks, image mismatches (use the hide button on any bad card; hidden cards are logged).
- Cost per chapter: token counts are logged per build (`Completed via ... in Nt out Nt`).
