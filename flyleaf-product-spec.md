# Flyleaf (working title)

Product spec, v0.1 draft. Alternate names: Gazetteer, Dogear.

## One-liner

A native macOS companion that follows your Kindle reading position and quietly shows who, where, and what you're reading about. A glance at your Mac answers the question before you reach for your phone.

## Problem

Reading nonfiction generates constant micro-questions: where is Zhengzhou, who is this executive, what did the iPod Mini look like. Today the answer is: put the book down, pick up the phone, search, get distracted, lose ten minutes. Kindle's X-Ray answers some of this but requires stopping and tapping, only covers what shipped with the book, and shows no real photos of people or places. Nothing follows your position automatically.

## Core proposition

"At a glance" is the whole product. Every decision defers to it:

- Zero interaction while reading. The panel updates itself.
- Readable at arm's length: large type, high contrast, calm transitions.
- Always current: within a chapter of where you actually are.
- Spoiler-safe: draws only on the book up to your position.

Any feature that requires touching the Mac during a reading session is secondary by definition.

## Primary user story

Reader is on the couch or at a desk with an e-ink Kindle, Mac nearby, reading *Apple in China*. The panel shows a map card pinned on Zhengzhou with a photo of the iPhone City campus, a person card for Terry Gou (photo, one-line bio, "first mentioned Ch. 3"), and a product card for the iPod Mini. When the reader crosses into the next chapter, cards fade to the new chapter's cast. They never touch anything.

## Position tracking (the hard part)

Amazon exposes no public API for reading position, so we use the same private Whispersync endpoints the official Kindle apps use (the approach proven by the open-source kindle-api project): after the user signs in, the app registers a reader device token, then polls per-book furthest-read position.

Reality of sync cadence: e-ink Kindles push position on page turns while on Wi-Fi and at book open/close. Expect chapter-level granularity with lag from seconds to a few minutes. The design treats each position advance as a "sync moment" that refreshes the panel, which is plenty for chapter-scoped context.

Polling behavior:

- Active session (position moved in the last 20 min): poll every 45-60 seconds.
- Idle: back off to 10 minutes; suspend overnight.
- Read-only, low-volume, user-credentialed. Be a polite guest.

Manual override is always one click away: a chapter scrubber in the panel footer ("I'm actually at...").

## Content pipeline

Input is book identity (ASIN, title, author) plus position (percent, mapped to chapter via the public table of contents). A server-side pack builder uses an LLM with web retrieval to produce, per chapter, a "context pack": entities (people, places, organizations, products, terms), each with a one-line description, an image, map coordinates where relevant, first-mention chapter, and one or two source links.

Key properties:

- **Spoiler windowing.** The pack for chapter N is built only from knowledge of the book through chapter N. Cards never reference later chapters.
- **Shared cache.** Packs are keyed by (ASIN, chapter, pack version) and shared across all users. The first reader of a chapter waits 10-20 seconds; everyone after gets it instantly. Cost scales with unique books, not users.
- **No DRM contact.** We never download or decrypt book content. Packs are built from metadata, public TOC and sample data, and web sources. (A future local-only EPUB import path covers non-Kindle books without crossing that line.)
- **Grounding.** Cards are retrieval-backed with visible sources, not free-form LLM recall.

## The glanceable surface

**The Panel (core).** A floating, always-on-top, non-activating window. At most three stacked cards, auto-rotating every ~20 seconds through the current chapter's top entities. Big serif type, light and dark themes, auto-dim in dark rooms, Reduce Motion respected. Optional click-through so it never steals focus. Two sizes: compact (one card) and regular.

**Menu bar item.** Current book and percent, pause toggle, chapter picker, re-auth if needed.

**The Shelf (on demand, separate window).** Where accumulated context lives:

- *Cast*: everyone met so far, grouped by affiliation.
- *Atlas*: a map of every place mentioned up to your position.
- *Timeline*: dated events encountered so far (nonfiction).
- *Objects*: gallery of products and artifacts.

**Notifications (opt-in).** A rich "chapter briefing" notification when you enter a new chapter.

## Fun and useful, strictly secondary

- **Previously On.** Open the app after three-plus days away and get a recap up to your exact position.
- **Chapter Briefing.** Three spoiler-free sentences of orientation when a chapter starts.
- **Say It.** Hover any name for pronunciation (Zhengzhou, Luxshare) via speech synthesis.
- **Then & Now.** Money and date conversions ("$300 in 2004 is about $510 today").
- **First Mention.** Click an entity to jump to where it entered the story.
- **Ambient mode.** After a couple of minutes without a sync, the panel dims into a slow slideshow of the chapter's maps and imagery. The desk starts to feel like the book.
- **Reading stats.** Session detection from sync deltas gives pace, streaks, and a projected finish date, nearly free since we're polling anyway.
- **Ask.** A global hotkey opens a one-off, spoiler-safe question box.
- **Shortcuts and Focus.** "Start reading session" action; auto-activate with a Reading Focus.
- **Share a pack.** Send a book's Atlas or Cast as a web link. This is the growth loop.

## Onboarding (target: under two minutes, one decision)

1. **Welcome.** One sentence and a single "Connect Amazon" button. Nothing else on screen.
2. **Amazon sign-in.** An embedded web view of Amazon's real login page, so 2FA, passkeys, and CAPTCHA all just work and we never see the password. On success the app silently captures session tokens and performs the reader-device registration handshake, the same one official Kindle apps perform. No cookie pasting, no developer steps, no keys.
3. **Magic moment.** "You're reading *Apple in China*, 38%." The current book is auto-selected from the most recent Whispersync activity, cover art and all. The first context pack builds behind a progress shimmer and the first cards appear before this screen is dismissed.
4. **Optional prefs (skippable).** Panel size and position, notifications, launch at login.

Fallbacks, automated wherever possible:

- No recent Kindle activity: search-as-you-type book picker, set the chapter manually, everything downstream identical.
- Session expires later: menu bar badge, one-click re-auth in the same embedded view.
- No Amazon account at all: Manual Mode is a first-class citizen. Pick any book, scrub chapters. Still valuable, and it demos the product.

Deliberately absent from onboarding: account creation (anonymous device ID, optional iCloud sync of preferences), API keys (inference is bundled into the product), and permission dialogs (core needs none).

## Monetization

Free: Manual Mode plus one connected book, current-chapter cards. Pro (roughly $5/month or $39/year): unlimited books, the Shelf, recaps, ambient mode, stats. Inference and retrieval have real marginal cost; the shared pack cache is what keeps unit economics sane.

## Platform and architecture notes

- Swift and SwiftUI. MenuBarExtra for the menu bar; a non-activating NSPanel at floating window level for the glance surface.
- Local: SQLite cache of packs and positions, Keychain for Amazon tokens.
- Server: pack builder (LLM plus search retrieval plus image sourcing with a licensing filter), pack CDN, anonymous telemetry.
- Poller as a background task, App Nap aware, conditional requests.
- macOS 14+.

## Risks and mitigations

- **Private API breaks, or Amazon objects.** Read-only, low-rate, user-credentialed access; a source-abstraction layer so Manual Mode keeps the app fully functional the day anything breaks; roadmap toward friendlier ecosystems (Kobo, KOReader) to de-risk long term.
- **Amazon ships this themselves.** They are clearly moving here (Ask This Book, the 2026 AI features), but inside the reading device, single ecosystem, tap-to-use. Our wedge is the second surface at your desk, ambient design, and an eventual cross-source library.
- **Hallucinated context.** Retrieval-grounded cards with visible sources, confidence thresholds on entity extraction, and a one-tap "report this card" affordance.
- **Image licensing.** Prefer Wikimedia and openly licensed imagery; fall back to maps and stylized placeholders. Never hotlink scraped press photos.
- **Spoiler leakage in fiction.** v1 markets to nonfiction readers, where the stakes are low. Fiction packs get stricter windowing and a red-team test suite before we promote the use case.

## MVP cut

**v0.1** (nights-and-weekends scope): Amazon connect, position polling, auto book detection, the Panel with People, Places, and Terms cards for the current chapter, Manual Mode, shared pack cache.

**v1.0**: Atlas, Cast, chapter briefings, Previously On, notifications, stats, Pro paywall.

**Later**: iPhone and iPad glance app (the book-stand companion), EPUB import, book clubs, and a live mode for people who read in the Kindle Mac app, using accessibility APIs to follow the actual page in real time.

## Success metrics

- Time to first card under two minutes from download.
- At least 60% of reading sessions require zero manual input.
- D7 retention of connected users at 40% or better.
- The qualitative one that matters: "I stopped reaching for my phone."

## Open questions

- Panel default: always-on-top window, desktop widget via WidgetKit, or both?
- Prefetch the next chapter's pack aggressively, or build on arrival?
- Real name. Flyleaf is a placeholder and may collide with existing reading apps.
