# Lume — AI Agent Guide

Lume is a native, multi-platform IPTV player (iOS 18+, macOS 15+, tvOS 18+, visionOS 2+) built with SwiftUI + SwiftData. Single Swift codebase with four interchangeable playback engines: KSPlayer (default) → VLCKit → AVPlayer, plus the opt-in beta LumeEngine (sibling repo `../LumeEngine`). It is built with the iOS 26 SDK and uses Liquid Glass / iOS 26 navigation APIs where available, falling back to system materials on older OS versions.

---

## Build & run

```bash
# Open in Xcode
open Lume.xcodeproj   # pick scheme "Lume", any destination

# CLI build (iOS Simulator)
xcodebuild build \
  -project Lume.xcodeproj -scheme Lume \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -clonedSourcePackagesDirPath ~/Library/Developer/Lume-SharedSPM
```

The project injects API secrets from a repo-root `.env` file via `Scripts/inject-env.sh`. The file is gitignored; features degrade gracefully when it's absent.

### Private DerivedData needs a shared package clone

Parallel builds (per platform, per worker, per worktree) each need their own
`-derivedDataPath /tmp/lume-dd-<label>` — the project has several DerivedData
dirs and a bare `xcodebuild` can install a stale app. **Always pair that with
`-clonedSourcePackagesDirPath ~/Library/Developer/Lume-SharedSPM`.** Without it
each private DerivedData re-clones the whole package graph — KSPlayer's FFmpeg
xcframeworks plus VLCKit's 865 MB xcframework, **6.4 GB per build dir**; eight
of them once filled `/tmp` with 65 GB. Sharing one clone dir also builds faster
and dodges the botched-checkout race that breaks multi-platform archiving.

Delete your `-derivedDataPath` dir when the task is done, or run
`Scripts/clean-build-cache.sh` (report only; `--apply` to reclaim, `--deep` to
also drop DeviceSupport, the SwiftPM download cache and idle simulators). It
deliberately keeps the two live package checkouts and each checkout's
`.build/tools`, which is what the pre-commit hook runs SwiftFormat/SwiftLint
from.

---

## Testing

Tests deploy to **iOS 26.4+ Simulator only** — never tvOS. Use an iPhone 17 Pro or newer sim; iOS 26.2 sims fail with a deployment-target mismatch (exit 65).

```bash
# Every invocation below takes the shared package clone — see "Private
# DerivedData needs a shared package clone" above.
SPM=(-clonedSourcePackagesDirPath ~/Library/Developer/Lume-SharedSPM)

# Full suite
xcodebuild test -project Lume.xcodeproj -scheme Lume "${SPM[@]}" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# Unit tests only
xcodebuild test -project Lume.xcodeproj -scheme Lume "${SPM[@]}" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:LumeTests

# UI tests only
xcodebuild test -project Lume.xcodeproj -scheme Lume "${SPM[@]}" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:LumeUITests
```

Every test `ModelConfiguration` must set `cloudKitDatabase: .none` — `@Attribute(.unique)` models + the default `.automatic` crashes on entitled simulator hosts.

---

## Performance testing

Benchmarks live in their own target (`LumePerformanceTests`), scheme
(`LumePerformance`), test plan (`Performance.xctestplan`) and build configuration
(**Benchmark** = Release + `ENABLE_TESTABILITY`). They are *not* in the `Lume`
scheme, so a normal `xcodebuild test` never runs them.

```bash
Scripts/run-performance-tests.sh                    # whole suite + measurements
Scripts/run-performance-tests.sh ParsingBenchmarks  # one suite
```

- Never benchmark in Debug — `-Onone` makes parser/import numbers fiction. That's
  what the Benchmark configuration exists for.
- Store benchmarks use **on-disk** containers (`PerfStore`); in-memory skips
  SQLite, the very cost being measured.
- **`context.save()` is ~90% of the *Xtream* import.** That figure is from a
  282,288-row Xtream catalog of series shells; it does not describe the m3u cold
  path, where 86% of the entries are episodes. There the biggest single item was
  wiring `Episode.series` through the initializer instead of assigning it after
  `context.insert` — 64% of the whole import.
- **Four knobs were measured at under 6%** — `batchSize` (500/2k/10k/50k all
  within noise), the 11 `#Index` groups on `Movie`, `@Attribute(.unique)`, and
  the per-batch existing-row lookup. On a 178k-row harness that no longer
  exists; only the existing-row lookup has been re-verified at 1.5M rows. Don't
  re-derive them; `LumePerformanceTests/README.md` carries the numbers.
- **`M3UColdImportBenchmarks` is the end-to-end one** — it drives the real
  `ContentSyncManager.syncPlaylist` over a provider-shaped `file://` playlist,
  with clock, peak RSS and every m3u signpost in one pass.
- Fixtures are generated per run from a fixed seed (`PerfFixtures`), never
  committed.
- App-defined phases are named once in `Services/Diagnostics/PerformanceSignposts.swift`
  (`Perf.begin`/`Perf.end`). Those names are a contract with `SignpostBenchmarks`
  and feed Instruments' Points of Interest lane — rename one and update both.
- Field layer, in the shipping app: `AppPerformanceMetrics` (MetricKit; compiled
  out on tvOS) and `PlaybackQoE` (join time, rebuffer ratio, exits before video
  start, engine fallbacks). Both surface in the exported diagnostic report.
- `PlaybackQoE` flushes to `UserDefaults` at session boundaries only — never
  periodically, which is what used to hitch KSPlayer.

See `LumePerformanceTests/README.md` for baselines and why there is no CI gate.

---

## Architecture

```
Lume/
├── LumeApp.swift            App entry + SwiftData containers
├── Models/                  SwiftData @Model types (Playlist, LiveStream, Movie, Series, …)
├── Services/
│   ├── Network/             XtreamClient, M3UClient, TMDBClient, MDBListClient, TraktService
│   ├── Sync/                ContentSyncManager (background catalog indexing + enrichment)
│   ├── Player/              PlayerSettings, PlayerHistory, NextUp resolver
│   ├── Diagnostics/         Perf signposts, PlaybackQoE, MetricKit subscriber
│   └── Images/              CachedAsyncImage, ImagePipeline
└── Views/                   SwiftUI, platform-adaptive
    ├── Home/                Hero carousel, rails, tvOS fold
    ├── Player/              Engine wrappers + unified overlay
    └── …
```

Two separate `ModelContainer`s:
- **Catalog** (`default.store`) — local-only, what all `@Query` bindings target
- **CloudKit mirror** (`CloudUserData.store`) — user state (profiles, watch progress, favorites); never bind `@Query` against this container

---

## Key patterns & gotchas

### Swift concurrency
`SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor` is set project-wide. Value types and DTOs used by `nonisolated` callers must be explicitly marked `nonisolated` (type + every extension).

### SwiftData
- Enrichment saves run on a **background** `ModelContext` (`ContentSyncManager.enrich*`) — not the view context.
- Main-thread saves during playback stall KSPlayer every ~5 s. Buffer to `UserDefaults`; flush at playback boundaries.
- `PlaylistDeletion` helper must be used for any playlist removal (UI **and** iCloud reconcile) — `Movie`/`Series`/`LiveStream` have no cascade relationship to `Playlist`.
- The reconciler after `switchProfile` rebuilds the dropped content shadow — don't remove that pass; optimize the fetch predicate instead.

### iCloud sync
- Guard reconcile against `LocalCatalogReadiness`; an empty `default.store` would push mass deletions to CloudKit.
- `UserProfile` must be deduped on every reconcile (not just launch) — fixed-id default profiles multiply per device in CloudKit.

### tvOS-specific
- `Color.accentColor` resolves to white on tvOS — never use it for fills/tints.
- `.onMoveCommand` runs inside the focus engine's animated context; defer layout mutations with `Task { }`.
- Full-width focus targets needed for vertical navigation — a narrow target won't catch "down" from a full-width section.
- `@FocusState` must not drive layout sizing in the hero fold — use `TVHomeScreen`'s `ScrollTargetBehavior`.

### KSPlayer
- Hardware decode requires **both** `asynchronousDecompression = true` **and** `hardwareDecode = true`; `async` defaults to `false` → silent software decode → frame drops on tvOS.
- Never call `layer.prepareToPlay()` on a running session — use `player.replace()` (`rebuildStream(on:)`) to avoid a UAF crash.
- Frozen image + healthy audio on live TV = MPEG-TS 2³³ clock wrap; fixed by the `noteClockDrift()` watchdog.

### LumeEngine (beta, 4th engine)
- Our own FFmpeg 9 engine, developed in the sibling repo [`bilipp/LumeEngine`](https://github.com/bilipp/LumeEngine) and referenced as a **local** SPM package at `../LumeEngine` — a clone without that sibling (and its FFmpeg xcframework built once) will not resolve. It has its own `AGENTS.md` and a `PLAN.md` that is authoritative for engine design.
- App-side wiring only lives here (`Lume/Views/Player/LumeEngine*.swift`); demux/decode/render/sync bugs are engine-side. Decide which side a bug belongs to *before* editing.
- Declared last in `PlayerEngineKind` so it appends to the end of existing priority lists — opt-in, never silently promoted while KSPlayer is the default.
- The engine never retries on its own schedule: reconnect/backoff, engine fallback, and overlays stay Lume's job. If a fix would add retry policy to the engine, it belongs here instead.

### Localization
String Catalogs (9 languages: en, de, es, fr, it, ja, ko, pt, zh-Hans; the App Store listing mirrors them — see `ship-release`'s `references/store-metadata.json`). Run `xcstringstool sync` and include the tvOS stringsdata. Normalize `.xcstrings` with `Scripts/normalize-xcstrings.swift` (pre-commit hook) to avoid format churn.

### Pre-commit hooks (lefthook)
SwiftFormat + SwiftLint run as errors. Notable: `String(decoding:)` is banned; `redundantStaticSelf` crashes on `for x in (try? …) ?? []` — avoid that pattern.

---

## External integrations

| Service | Auth | Notes |
|---------|------|-------|
| TMDB | Bearer token (`.env`) | Metadata, artwork, trailers |
| MDBList | API key (`.env`) | IMDb / RT / Metacritic / Trakt / Letterboxd ratings |
| Trakt | Device OAuth (Keychain) | Scrobbling; no web view — works on tvOS |

---

## Working environment, testing & handoff (agents)

This section is authoritative. It exists because "the workspace is empty" and
"the package flags are broken" have both been filed as blockers when the real
cause was working in the wrong directory. Read it before declaring a blocker.

### The one checkout

There is exactly one Lume checkout, and it is the repo you are reading now:

```
/Users/lee/Sites/lume-app/Lume
```

- It is a full Git working tree (`git rev-parse --is-inside-work-tree` → `true`),
  with all Swift sources, `Lume.xcodeproj`, `LumeTests`, and both remotes wired.
- The Paperclip **project mount** (`…/projects/…/_default`) is intentionally
  empty. It is *not* the code and never will be. If your shell lands there,
  `cd /Users/lee/Sites/lume-app/Lume` before doing anything else.
- Before writing "blocked: no repository / empty workspace", run
  `git -C /Users/lee/Sites/lume-app/Lume status`. If it succeeds, you are not
  blocked — you were in the wrong directory. Fix the directory, don't file a
  blocker.

### Remotes (they mean different things)

| Remote | URL | Role |
|--------|-----|------|
| `origin` | `leekiernan/Lume` | Our fork — where team branches land |
| `upstream` | `bilipp/Lume` | Community upstream — public contributions |

### Who verifies what

Verification is split so nobody blocks on hardware they don't have:

| Check | Owner | Notes |
|-------|-------|-------|
| Local unit tests (`LumeTests`) | Engineer **or** QA before handoff | iPhone 17 Pro sim, iOS 26.4+; see **Testing** above |
| Build verification | Engineer **or** QA before handoff | `xcodebuild build` with the shared SPM clone |
| Linting / formatting | Engineer **or** QA before handoff | SwiftFormat + SwiftLint (pre-commit hook enforces) |
| **Device testing** | **Board** | Physical-device runs are the board's job — **never block a handoff on device testing** |

A simulator that won't launch, DerivedData bloat, or a package-resolution flag
is a **developer-environment problem, not a task blocker**. Fix it (see
**Build & run**), or hand off with unit tests + build + lint green and note the
local-env snag — do not stop the task for it.

### Definition of Done

A task is **complete only when its branch is merged.** `in_review`, `blocked`,
and "implemented but unmerged" are all *not done*. The sequence is:

1. Engineer implements on a branch; runs unit tests + build + lint (or QA does).
2. Branch handed to Staff Engineer for review.
3. On approval, **merge the branch**, then mark the task complete — not before.

### Branch lifecycle after merge

- Branch cut from `origin/main` (our fork): **delete it once merged.** It has
  served its purpose; keeping it clutters the fork.
- Branch cut from `upstream/main` (community upstream): **keep it after merge**
  — it backs the public PR and community history.

If you're unsure which a branch came from, check its upstream tracking
(`git branch -vv`): branches showing `[upstream/main: …]` are community branches
and are kept; branches tracking (or based on) `origin/main` are deleted on merge.

---

## GitHub
Issues & roadmap: <https://github.com/bilipp/Lume/issues>
