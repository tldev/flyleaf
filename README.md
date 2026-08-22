# Flyleaf

A native macOS companion that follows your Kindle reading position and quietly shows who, where, and what you're reading about. Personal v0.1 build of `flyleaf-product-spec.md`, ready for its first test with a real Kindle.

## What's here

- **Main window** with a Dashboard tab: the current chapter's context cards (people, places, organizations, products, terms) in a grid, plus book header with cover, progress, sync status, and a chapter override. Alongside it: Cast, Atlas, Timeline, Objects, and Stats tabs that accumulate spoiler-free as you read.
- **Menu bar item**: current book and percent, sync now, pause, chapter picker, Ask, Previously On, settings.
- **Floating glance panel** (optional, off by default, toggle in the menu bar): the always-on-top, non-activating card rotation from the spec, with ambient mode after a few quiet minutes.
- **Amazon connect**: embedded Amazon sign-in (2FA and passkeys work; the password never touches Flyleaf), then read-only Whispersync position polling through the same endpoints the Kindle web reader uses.
- **Content pipeline**: two-pass pack builder on the Anthropic API (research pass with web search, then schema-constrained JSON), Wikipedia enrichment for images and coordinates, spoiler windowing per chapter, SQLite pack cache keyed by (ASIN, chapter, pack version).
- **Local EPUB import (real text)**: import an EPUB you own and Flyleaf parses its real chapters on-device and extracts entities from the actual chapter text with a cheap model on OpenRouter (default `google/gemini-3.7-flash`), enriched with Wikipedia photos and coordinates. Higher accuracy than web research, works for any book, and stays spoiler-safe (only the current chapter's text is sent). Two auth pools by design: your Claude subscription for the web-research path, OpenRouter for bulk text extraction.
- **Emailed & sideloaded books**: books you Send-to-Kindle don't appear in the normal reading API, so Flyleaf (opt-in, Settings → Account) registers this Mac as a Kindle device and follows their Whispersync-for-Documents position automatically, no manual mode. Position is exact; the percentage self-calibrates (one tap on the chapter control makes it precise). See `docs/kindle-endpoints.md`.
- **Manual Mode**: pick any book by title, or from your Kindle library; identical downstream.
- Chapter briefings and opt-in notifications, Previously On recaps, Ask (Option-Command-K), Say It pronunciation, Then and Now conversions, First Mention chips, report-a-card, reading stats with projected finish, spoiler-free HTML export of the Cast and Atlas.

## Build and run

```bash
Scripts/build-app.sh release     # builds and signs dist/Flyleaf.app
open dist/Flyleaf.app            # normal run (onboarding on first launch)
open dist/Flyleaf.app --args --demo   # canned Apple in China demo, no accounts needed
swift test                       # unit tests
```

Optionally copy `dist/Flyleaf.app` to `/Applications` (needed for reliable launch-at-login).

## Configuration

- **Amazon**: connected during onboarding through Amazon's own sign-in page. Session cookies live in WebKit's store; re-auth is one click from the menu bar when the session expires. Region is selectable in Settings, Account.
- **Claude account or API key** (this developer build only): pack research prefers your Claude account via the Anthropic CLI. Install and sign in once (`brew install anthropics/tap/ant`, then `ant auth login`); Flyleaf mints short-lived OAuth tokens from that profile with nothing to paste or rotate. Alternatively paste an Anthropic API key in Settings, Pack Builder (stored in the Keychain under `com.thomasjohnell.flyleaf`); the account takes priority when both exist. Without either, position tracking and Manual Mode still work. The shipping product would bundle inference server-side per the spec.
- Everything else lives in Settings (polling cadence, panel, notifications, prefetch, model).

## First Kindle test

Follow `docs/first-kindle-test.md`. Logs stream to `~/Library/Application Support/Flyleaf/logs/flyleaf.log` (also via the Advanced settings tab); if anything misbehaves during the test, that file is the story.

## URL scheme

`flyleaf://demo`, `flyleaf://sync`, `flyleaf://panel/toggle`, `flyleaf://dashboard`, `flyleaf://shelf`, `flyleaf://atlas`, `flyleaf://stats`, `flyleaf://ask`, `flyleaf://recap`, `flyleaf://settings`, `flyleaf://chapter?set=4`, `flyleaf://session/start` (for Shortcuts and Focus automations).

## Architecture

```
Sources/Flyleaf/
  App/        FlyleafApp (menu bar entry), AppState (orchestration), MainWindowView, WindowManager
  Auth/       AmazonLoginView (embedded sign-in webview)
  Kindle/     KindleClient (private web-reader endpoints), AmazonCookies, WebViewBridge
              (browser-fingerprint fallback transport), PollPolicy + PositionPoller
  Packs/      PackBuilder (two-pass Claude pipeline), AnthropicClient (raw Messages API),
              WikipediaResolver, PackStore (SQLite), DemoPack
  Panel/      Floating panel: cards, rotation, ambient, footer, NSPanel controller
  Shelf/      Cast, Atlas, Timeline, Objects, Stats tabs
  Features/   ReadingStats, Ask/Recap windows, notifications, hotkey, speech, HTML export
  Onboarding/ Welcome, sign-in, magic moment, prefs; ManualBookView
  Settings/   Settings tabs
  Support/    SQLite wrapper, Keychain, Prefs, logging
```

Kindle endpoint details and sources: `docs/kindle-endpoints.md`.

## Deviations from the spec, and why

- **Cards live in the app window** (Dashboard tab); the floating panel is opt-in. Owner feedback during the first build review.
- **Pack builder runs locally on your API key** instead of a hosted service with a shared cache. The cache keying (ASIN, chapter, pack version) matches the spec so a server can slot in behind `PackStore` later.
- **Shortcuts integration** is via the URL scheme rather than App Intents (SwiftPM builds don't run the App Intents metadata extractor).
- **Auto-dim in dark rooms** is approximated by ambient mode; macOS has no public ambient light sensor API.
- **Monetization, iCloud sync, telemetry**: omitted from this personal build.

## Risks to keep in mind

Amazon's reader endpoints are private and can change or object; Flyleaf stays read-only, low-volume, and user-credentialed, and Manual Mode keeps the app functional if sync breaks. If Amazon's bot wall ever rejects plain requests, the client automatically falls back to a WebKit-fingerprint transport.
