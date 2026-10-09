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

## Production Swift enrichment trial

The opt-in app experiment is under **Settings → TV Guide → EPGShare metadata
(experimental)**. It currently supports only the reviewed US PBS mappings in
`EPGEnrichmentStations`; UK essentials, sports and other station families are
not guessed. Enabling it does not add a competing timetable source.

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

Still needed before broader rollout: repeat with newer snapshots, verify other
regional/sports aliases against actual streams, check image/feed usage rights,
and measure large-feed refresh cost on devices. This is an enrichment trial,
not an EPG coverage replacement or a sports-calendar implementation.
