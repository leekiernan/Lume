# UK essentials / sports source trial

First paired capture: **2026-10-09 12:50 UTC**. This is an offline trial, not a
shipping UK mapping change. No server, app build or provider-side changes.

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

The sample includes seven essentials/news channels, Sky Sports Football/NFL,
TNT Sports 1–4, and Sky Sports F1 (unmapped). Generic BBC One and ITV1 entries
are negative controls: their regional identity is unspecified. BBC One London
and Scotland use explicitly named regional provider channels instead. XMLTV
identity does not verify the provider's actual streamed video.

All 14 aggregate sample channels have current provider listings and complete
48-hour coverage. Both external feeds map 13, missing Sky Sports F1 in these
inventories. Neither fixes a current coverage gap in this sample.

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
times. Later captures are still outstanding. If essentials remain aligned,
trial a separate small UK feed using the existing conservative metadata lane,
eligible categories and independent source cadence. Keep sports rejected until
event identity is demonstrated. Verify image/feed usage rights before rollout.
Full season calendars remain a separate future concern.
