# UK essentials / sports source trial

First paired capture: **2026-10-09 12:50 UTC**. The capture ran outside the app,
without server or provider-side changes. Its reviewed UK mappings now back the
opt-in metadata experiment described below.

Local artifacts (ignored):
`ExampleData/EPGTrial/2026-10-09T125017Z-uk/` contains the fresh 9,938-stream
catalog, provider guide, source-specific response headers, explicit reviewed
selection manifest, and detailed JSON/Markdown reports. No account URL appears
in the reports or this note.

Sources:

- EPGShare UK: <https://epgshare01.online/epgshare01/epg_ripper_UK1.xml.gz>
- EPG.pw GB: <https://epg.pw/xmltv/epg_GB.xml.gz>

## Findings

| Snapshot | Download | Inflated XML | All programmes |
| --- | ---: | ---: | ---: |
| Provider | 152.52 MB | 152.52 MB | 505,986 |
| EPGShare UK | 2.96 MB | 22.41 MB | 41,981 |
| EPG.pw GB | 2.58 MB | 20.30 MB | 53,425 |

The initial sample includes seven essentials/news channels, Sky Sports Football/NFL,
TNT Sports 1–4, and Sky Sports F1 (unmapped in that first inventory pass). Generic BBC One and ITV1 entries
are negative controls: their regional identity is unspecified. BBC One London
and Scotland use explicitly named regional provider channels instead. XMLTV
identity does not verify the provider's actual streamed video.

All 14 aggregate sample channels have current provider listings and complete
48-hour coverage. Both external feeds mapped 13 in the initial inventory pass.
A subsequent review found EPGShare F1 under `SkySp.F1.HD.uk`; see the expansion
below. Neither fixes a current coverage gap in the initial sample.

EPGShare has images on **99.8%** of its 825 sampled near-term rows, subtitles
on 44.6% and categories on 66.9%. Provider rows have descriptions on 99.9%,
but no images/subtitles/categories. External descriptions are shorter on
average (99 vs 139 characters), so replacing provider descriptions is not an
improvement. Exact normalized title **and both boundaries** yield 407 matches
out of 794 shared intervals, allowing 405 missing images and 42 subtitles.
These are potential additions, not independently verified episode images.

Most useful enrichment is in essentials/news. Sky Sports Football shares all
92 intervals but only one title matches: provider entries identify particular
matches, while external entries use generic programme names. TNT Sports 1
shares 30 intervals but no exact titles. Do not discard provider event names,
match on boundaries alone, or assume an image of a competition identifies the
current fixture. Sports need a separately validated event-aware identity rule.

EPG.pw offers no artwork/subtitles/categories in the selected sample. Only 19
titles/boundaries match over 190 shared intervals. Some channels show diagnostic
eight-hour offsets; these are clues, not an approved automatic correction.
It is not suitable for automatic enrichment or source replacement on this
evidence. Its declared year/date presence also needs semantic validation before
treating it as a production release year.

Provider-first seven-day mean coverage is 78.0%; EPGShare-first is 39.2% and
EPG.pw-first 38.3%. The public feeds have a shorter future horizon. Preserving
provider ownership and using supplementary metadata is preferable in this
capture; standalone external ownership would lose reminder-range listings.

## Repeat protocol / next decision

This first capture **does not establish reliability or polling cadence**.
Capture fresh provider + country feeds on subsequent days and around a sports
schedule change. Keep each capture in its own timestamped directory with
headers, hashes, the same explicit station selections, and an actual evaluation
instant. Process feeds sequentially. Do not call repeated scans of the same
files independent snapshots. Do not silently select an arbitrary duplicate
EPG.pw ID or an unspecified BBC/ITV region.

Run the existing comparison against each dated manifest:

```sh
python3 Scripts/epg-source-trial.py \
  ExampleData/EPGTrial/2026-10-09T125017Z-uk/manifest.json \
  --output ExampleData/EPGTrial/2026-10-09T125017Z-uk/report
```

Track current/48-hour gaps, exact metadata matches by channel family, changed
boundaries, duplicate/conflicting entries, validators and feed publication
times. Later captures are still outstanding. The app now trials the separate
UK feed using the existing conservative metadata lane, eligible categories
and independent source cadence. Strict title/time matches are allowed on the
reviewed national sports broadcasters, but broader event matching remains
offline until identity is demonstrated. Verify image/feed usage rights before rollout.
Full season calendars remain a separate future concern.

## Offline sports field review

The same saved capture was reprocessed with `sports: true` on the named Sky/TNT
selections; this is **not a second independent snapshot**. The ignored output
is `sports-review.json` / `sports-review.md` beside the original reports.

EPGShare's six reviewed sports channels have 312 time-aligned title mismatches
and only one strict title/time match. Of the mismatches, 20 have the external
fixture subtitle corroborated by provider text; 18 are queued for manual event
review without detected conflict cues. Eleven mismatches have possible
live/replay or round/year conflicts (including two of those 20 corroborated
subtitles). The remaining 283 are unresolved. A subtitle such as “India v West
Indies” helps explain why generic external titles differ, but does not by
itself prove which T20, replay or season is airing.

The report retains bounded title/subtitle/description examples, rejects duplicate
intervals, never corrects times, and accepts **zero** broader event matches.
Cue detection is deliberately diagnostic and incomplete; descriptions can
mention previous rounds or highlights. EPG.pw still offers no useful metadata
in this sample and is not enabled in the app.

## App trial scope

The existing experimental flag enables UK and US PBS, without new source
configuration or category switches. Only enabled-category/non-hidden reviewed
stations are selected, and that scope is checked again at publication. UK
uses a separate 12-hour cache/checkpoint; PBS retains its 24-hour cache. Downloads
are sequential and temporary country XML is removed before the next download.
All selected metadata publishes together, preserving provider ownership and
times. Settings and logs show per-feed results, counts and retry times.

Sports broadcasters are not categorically excluded: their strict title/time
matches use the same lane as essentials. Provider-created event channels and
unknown identities stay untouched. Category-level opt-in controls and event-aware
matching remain later work. Existing popup and rail artwork/subtitles consume additions
through the shared guide publication/invalidation path.

The shipping Swift parser, reviewed registry and exact matcher were also run
against the saved capture: **13 verified stations, 864 near-term provider rows,
407 exact matches**. It added artwork to 405 listings, categories to 404,
subtitles to 42 and years to six. All 405 enriched rows restored to their
original provider metadata on disable; titles, IDs and times were unchanged.
This verifies the implementation against one snapshot, not ongoing reliability.

Verification for this expansion: generic iOS/tvOS builds, 132 focused macOS EPG
tests, 13 Python comparison tests, strict SwiftLint, SwiftFormat and translation
checks passed. No simulator was installed or launched. Physical-device testing
and subsequent independent guide snapshots remain follow-up checks.

## Broader reviewed UK registry

After the initial device trial, the same saved guide/catalog was reviewed for
additional explicit identities. This is **not a later independent snapshot**.
The registry now contains **119 distinct external schedules / 131 provider IDs**:

- Regional BBC One, BBC Two NI/Wales, BBC Three/Four/Scotland/Alba/Parliament.
- ITV2–4 and Quiz; E4/Extra, More4, Film4, 4seven; 5STAR/USA/SELECT/Action.
- Sky entertainment and nine cinema channels; U, Comedy Central and Challenge.
- Discovery, National Geographic, PBS America and other factual broadcasters.
- CBBC, CBeebies, Cartoon Network/Boomerang/Cartoonito and Nickelodeon family.
- Named news stations and Sky Cricket/F1/Golf/PL/Tennis/News/Racing/+, Racing TV,
  Premier Sports 1/2, MUTV/LFCTV, plus reviewed variants of Football/NFL/TNT1.

Case-distinct provider IDs for quality variants are preserved as a set per
external schedule. Every ID is independently checked against **all** stream
references before enabled-category filtering. Hiding an unsafe reference cannot
make a shared ID eligible. Generic BBC One/ITV1, unspecified ITV regions, +1
inference and event/UHD-only channels remain excluded. Sky Main Event and Sky
Sports Mix share provider IDs with fixture/RedZone streams in this catalog;
they are deliberately excluded rather than claiming every reference is equivalent.

The production Swift parser/matcher replay over 48 hours produced:

| Measure | Result |
| --- | ---: |
| Provider rows (distinct provider IDs, not per stream quality duplicate) | 8,112 |
| Exact title/start/end matches | 5,169 |
| Changed / successfully restored rows | 5,165 / 5,165 |
| Added artwork URLs / subtitles | 5,044 / 1,935 |
| Added categories / release years | 5,038 / 216 |
| Four-day metadata cache | 9,275 programmes / 3.63 MB JSON |

The ignored report is `swift-expanded-enrichment-report.json` in the capture
directory. Regional/entertainment/factual channels account for most gains.
Examples with good exact agreement include ITV3/Quiz, Film4, 4seven and Sky Mix.
Named sports identities are allowed, but some (Cricket/Tennis/Premier2) have
zero strict matches in this snapshot. Different fixture naming is **not**
resolved by this expansion; boundary-only or fuzzy event matching remains off.
Artwork URLs can return 404, so additions do not guarantee visible images.

The metadata cap rises from 10k to 20k selected programmes per country to
accommodate variable horizons and high-frequency children's listings. Country
XML/decompression bounds and sequential cleanup are unchanged. The new UK
publication key makes the expanded selection due on upgrade; a cached subset
cannot validate a newly expanded external-ID selection with stale validators.

Expansion verification: generic iOS/tvOS builds, 140 focused macOS EPG tests
across 17 suites, 13 Python comparison tests, strict SwiftLint, SwiftFormat and
translation checks passed. New tests cover many-provider-ID enrichment,
conflicting metadata/identities, per-variant eligibility and restoration,
selection-expansion refetching, upgrade scheduling and the cache limit. No
simulator was installed or launched.
