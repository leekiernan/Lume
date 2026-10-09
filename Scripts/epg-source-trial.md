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
