# Offline XMLTV source comparison

Run without Xcode, an app, a simulator, a server or third-party Python packages:

```sh
python3 Scripts/test-epg-source-trial.py
python3 Scripts/epg-source-trial.py \
  ExampleData/EPGTrial/2026-10-09/manifest.json \
  --output ExampleData/EPGTrial/2026-10-09/report
```

The dated manifest and downloaded feeds are local, ignored trial artifacts.
The comparison reads plain XML or gzip directly, retains only explicitly
selected channels and writes a Markdown report plus detailed JSON. It never
changes the catalog or fetches a URL. Download feeds separately and preserve
their response headers and timestamps.

## Manifest

Paths are relative to the manifest, not the working directory. `now` fixes the
evaluation instant so rerunning a snapshot is reproducible. To evaluate a
later snapshot, create a new dated manifest and use its actual evaluation time.

```json
{
  "now": "2026-10-09T01:15:00Z",
  "streams": "../../LiveStreams.json",
  "sources": [
    {"name": "provider", "path": "../../epg.xml"},
    {"name": "external", "path": "external.xml.gz"}
  ],
  "channels": [
    {
      "stream_id": 123,
      "status": "explicit affiliate alias",
      "sports": true,
      "aliases": {"external": "exact-station-id"}
    }
  ]
}
```

`provider` is the required baseline source. Stream IDs select actual entries
from `LiveStreams.json`; their names and provider EPG IDs are read from that
file. External mappings are explicit XMLTV IDs, separately for each source.
Use `status: "explicit affiliate alias"` only for reviewed station/subchannel
identities; other status strings keep a channel in the detail report but
exclude it from aggregate metadata/strategy totals. A guide identity does
not verify which bytes the provider actually streams.

Set `sports: true` on reviewed sports selections to include the offline event
evidence report. It pairs only unique, exactly aligned intervals, then shows
title/subtitle/description excerpts, fixture-subtitle corroboration and possible
live/replay, round/leg or year conflicts. These are **manual review cues, not an
event matcher**. Absence of a conflict cue is not proof of event identity.
Unmapped and unreviewed station selections never enter that queue. No broader
event match is counted as accepted enrichment or published into the app.

Public source URLs can be included as optional provenance. **Omit account
URLs, usernames and passwords.** Do not commit guides, manifests, reports or
image samples; keep those under ignored `ExampleData`.

## What the report measures

- Current coverage and union of occupied time over the next 48 hours, gaps,
  overlapping/duplicate rows, and seven-day coverage. Future rows alone are
  not proof of a current programme.
- Metadata presence on selected near-term programmes: description, subtitle,
  categories, image URL, date/year, episode ID, credits and ratings.
- Normalized title **and exact start/end** agreement. Only case, punctuation
  and the exact trailing provider superscript New badge are normalized.
- Diagnostic integer-hour offsets (-12 to +12). These are clues only; no
  schedule is corrected or silently shifted.
- Source-first channel ownership and conservative gap fallback. Fallback
  accepts only whole non-overlapping programmes; it never clips a programme
  or merges contradictory listings.
- Potential missing-field enrichment only when title and both boundaries
  agree. No enriched XML or app state is published.
- SHA-256, on-disk bytes, decompressed bytes, total rows, validity counters
  and desktop streaming scan time. This is **not** a shipping Swift parser,
  SwiftData import or Apple TV performance benchmark.

A single snapshot cannot establish source reliability, actual stream
correctness, licensing suitability or a useful polling cadence. Repeat over
several days, retaining source-specific timestamps and hashes, before choosing
a source or an independent refresh schedule.

The [UK essentials/sports capture](epg-uk-sports-trial.md) records the first
fresh provider/UK comparison and the repeat protocol; later independent
snapshots are still pending.

## Production Swift enrichment trial

The opt-in app experiment is under **Settings → TV Guide → EPGShare metadata
(experimental)**. It supports the reviewed US PBS mappings and 13 UK
broadcasters in `EPGEnrichmentStations`: explicitly regional BBC One, BBC Two,
Channel 4/5, BBC/Sky News, Sky Sports Football/NFL and TNT Sports 1–4. Each
provider ID must have only explicitly reviewed channel-name variants. Generic
BBC One/ITV regions, unmapped F1 and provider-created team/match/PPV channels
remain provider-only. Enabling it does not add a competing timetable source.

The metadata pass reuses the production downloader, parser and store-write
coordinator. It preserves provider row IDs, titles, start/end times and any
existing metadata. Matching channel, normalized title and both exact boundaries
can fill missing description, subtitle, categories, artwork and release year.
Episode identifiers/credits are not stored by this experiment. Conflicting
duplicates and ambiguous channel-ID references are rejected.

Provider metadata baselines are saved with the additions in one transaction.
Disabling enrichment restores those fields, as do lost mappings, changed
programmes, removed external fields or an expired cache. A provider refresh
replaces the baseline; a provider 304 can still receive updated metadata.
Effective changes increment the existing guide publication generation so all
hub/guide/player readers share the normal invalidation path. No per-card
queries or image-fetching lane was introduced.

### Where the metadata appears

Guide cells retain programme artwork/subtitles in their value snapshots. The
existing programme popup displays those fields and the provider-first synopsis
on both tvOS and iOS; there is no intermediate detail screen. Hub popups resolve
only their selected listing off the main thread, including now/next hero
fallbacks, rather than fetching descriptions in the broad discovery scan.
The same landscape artwork component serves all hub channel/programme rails
and the popup, reusing the shared episode-image/cache pipeline. Channel names
remain visible, and missing/failed images fall back to fitted channel logos.
The guide grid itself remains text-only and does not request images per cell.

Stored-Series title matching is not added here: an exact series name alone
cannot identify an episode or distinguish a remake. Discovery's existing
TMDB match remains a fallback when the selected EPG listing has no synopsis.

### Scope and temporary storage

Only non-hidden channels outside hidden Live TV categories contribute eligible
station IDs, checked again at publication. Identity verification still examines
**all** channel references before applying that visibility filter: hiding a
conflicting station cannot make its shared ID safe. Removed eligibility restores
provider fields on the next metadata publication. Existing status counts now
refer to this eligible verified subset. An unsupported/empty subset downloads
nothing. Eligibility is reapplied on refresh, not by per-card observers.

One country feed is downloaded, decompressed, parsed and cleaned up at a time;
only its bounded selected-programme cache survives before the next starts.
UK runs first, then US PBS. Both indexes publish together in one transaction:
refreshing one feed cannot restore another's enriched fields. Each cache keeps
at most 10,000 selected programmes from two hours ago through four days ahead;
country XML files are never retained until combined publication. Optional
enrichment checks ordinary free space before downloading,
requiring its 768 MiB XML allowance plus a 128 MiB reserve, and refuses an
inflated/plain document above that allowance. This is a conservative admission
check, not a reservation against other processes. Failure/cancellation removes
partial inflated files; write errors propagate instead of silently succeeding.
Provider downloads keep their existing size policy. Low-storage optional
failure retains the provider schedule/recent metadata and reports the existing
warning/retry status, with a specific storage reason in logs.

### Refresh status and interruption

The settings screen exposes each feed's last in-process enrichment result, verified
station/exact-match/change counts, the cache's successful check time (when
available), and a retry time after a failure. Logs additionally report the
cached programme count. Results distinguish downloaded, HTTP-unchanged,
cached, unsupported, unavailable and retry-deferred data. Zero metadata changes
alone is not evidence that an external feed was checked successfully.

UK checks every 12 hours; US PBS every 24 hours, each with its own validators,
cache, successful-publication checkpoint and one-hour failure backoff. These
are conservative trial defaults, not measured feed publication SLAs. Unsupported
feeds download nothing and are checkpointed to avoid a permanently due loop.
A failed country does not prevent another country from refreshing; a usable
recent failed-country cache is retained, otherwise its provider fields are
restored. Per-feed retry/check times make partial success visible. Disabling
the experimental flag restores both countries' provider metadata together.

An unavailable or backed-off supplement produces **Sync complete with warnings**
when the provider guide is healthy; provider success still advances its own
schedule. Provider/publication failures remain failures. Deliberate cancellation
remains silent as a toast, shows an interrupted status in settings, and the
existing content-sync gate requeues the work after the playlist finishes.

Only actual metadata download/parse/cache failures impose the one-hour retry
backoff. Cancelling a download or parse does not. The old all-attempt timestamp
is intentionally ignored so upgrading also removes that accidental suppression.
Regression tests cancel an in-flight HTTP metadata request, retain the provider
guide, then immediately retry successfully after a provider HTTP 304.

Cache download and catalog publication are separate checkpoints. Only a
successful publication advances the scheduling check; unpublished metadata
remains due across relaunches and reuses the fresh cache. The earlier pre-save
check preference is ignored on upgrade, so an already downloaded but rejected
snapshot gets another publication attempt without another country-guide fetch.
Unchanged cloud area imports no longer invalidate work. Real profile/area
changes still reject the old write; the service makes at most one immediate
retry under a new fence, subject to the normal playback/content-sync gates.

Automatic checks run while Lume is active, with limited system time to finish
when backgrounded; this is not a guaranteed closed-app daily background job.

The public US-local feed is checked on its own daily cadence, not on every
provider refresh. Successful checks use HTTP validators when possible;
failures back off for an hour and can use a cache checked within the last 48
hours. Unsupported catalogs make no request. Country-guide parsing remains a
large download/decompression: the existing downloader inflates to a temporary
disk file, then SAX filters selected stations. Only a bounded four-day slice
(at most 10,000 programmes) survives in a local evictable cache. Provider
credentials/channel names are never sent to EPGShare. No server/dependencies.

The Swift trial uses the actual shipping matcher and parser, outside the app:

```sh
swiftc -O -swift-version 5 -default-isolation MainActor \
  Lume/Services/Network/XMLTVDate.swift \
  Lume/Services/Network/XMLTVParser.swift Lume/Utils/GzipFile.swift \
  Lume/Models/EPGListing.swift \
  Lume/Services/Sync/EPGProgrammeEnrichment.swift \
  Lume/Services/Sync/EPGEnrichmentStations.swift \
  Lume/Services/Sync/EPGEnrichmentCache.swift \
  Lume/Services/Sync/EPGEnrichmentFeed.swift \
  Scripts/epg-enrichment-trial.swift -o .build/epg-enrichment-trial
.build/epg-enrichment-trial \
  ExampleData/LiveStreams.json ExampleData/epg.xml \
  ExampleData/EPGTrial/2026-10-09/epgshare-us-locals.xml.gz \
  2026-10-09T01:15:00Z \
  ExampleData/EPGTrial/2026-10-09/swift-enrichment-report.json
```

The fixed snapshot run accepted **19 stations / 1,346 near-term provider rows**:
1,340 gained artwork, 950 subtitles, 1,338 categories and 1,325 release years.
Every addition was then reversed and checked against its original provider
fields. Programme identities/times were unchanged.

Why 19 rather than the earlier selected 20? Looking at *all* stream references,
KPBS's provider ID is shared by `US PBS (KPBS) San Diego` and
`US PBS 15 (KPBS) San Diego`. The stricter app policy excludes that ID until
both identities are verified, rather than assuming the second stream is
equivalent. This is conservative rejection, not a missing guide match.

The optional final argument selects a reviewed feed (`uk` or `us-locals`,
defaulting to PBS). To exercise the **shipping** UK registry and matcher against
the saved UK capture, using the same compiled executable:

```sh
.build/epg-enrichment-trial \
  ExampleData/EPGTrial/2026-10-09T125017Z-uk/streams.json \
  ExampleData/EPGTrial/2026-10-09T125017Z-uk/provider.xml \
  ExampleData/EPGTrial/2026-10-09T125017Z-uk/epgshare-uk.xml.gz \
  2026-10-09T12:50:17Z \
  ExampleData/EPGTrial/2026-10-09T125017Z-uk/swift-enrichment-report.json uk
```

Still needed before broader rollout: repeat with newer snapshots, verify other
regional/sports aliases against actual streams, check image/feed usage rights,
and measure large-feed refresh cost on devices. This is an enrichment trial,
not an EPG coverage replacement or a sports-calendar implementation.
