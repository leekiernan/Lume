# Offline sports programme identity trial

## Scope

The initial pass replayed the paired 2026-10-09 12:50:17 UTC capture.
The validation below adds a fresh pair captured at 20:20 UTC that day.
Replay itself makes no network calls. No provider changes, new dependencies,
AI lookups or app publication. The shipping title matcher remains unchanged.

This is programme-to-programme identity, not fixture-to-channel suggestions.
The latter can offer plausible choices; attaching metadata must be stricter.
The trial reuses production XMLTV parsing, whole-catalog station verification,
SportsMatcher normalization and SportsTeamAliases. Scripts-only rules can be
moved into the shared production lane after validation, not copied into a
second app matcher.

## Candidate rules

- Verified station identity, identical positive start/end interval, one row
  from each source. Duplicate intervals are rejected, even identical duplicates.
- Recognised studio titles allow only a trailing `Episode N` or `Matchday N`,
  with episode/season conflicts vetoed. Removing the display live badge retains
  its live evidence; other suffixes/unknown shows do not get fuzzy matching.
- Fixture candidates require both full team names or curated aliases in each
  title/subtitle, one shared explicit competition and either corroborated
  year/season or explicit live on both sources. Opponent order can differ.
  Description-only team mentions and generic `United`/`City` aliases are not
  identity. Conflicting headline pairs/multiple fixtures abstain.
- Detected year/season, episode, numbered round/leg, competition or live/replay
  conflicts veto matching, including equal titles. Missing evidence remains
  unknown, not positive evidence. Motorsport and unsupported sports abstain
  unless the existing strict title rule applies.

Review caught a generic `Championship` competition shortcut wrongly labelling
URC rugby as EFL. Removed it: explicit EFL/English Football League and
United Rugby Championship/URC are separate. Regression negatives preserve this.
This is one reason candidate counts are not proof of correctness.

## Reproduce

```sh
bash Scripts/build-epg-trial.sh --tests
bash Scripts/build-epg-trial.sh
.build/epg-enrichment-trial \
  ExampleData/EPGTrial/2026-10-09T125017Z-uk/streams.json \
  ExampleData/EPGTrial/2026-10-09T125017Z-uk/provider.xml \
  ExampleData/EPGTrial/2026-10-09T125017Z-uk/epgshare-uk.xml.gz \
  2026-10-09T12:50:17Z \
  ExampleData/EPGTrial/2026-10-09T125017Z-uk/sports-identity-candidates.json \
  uk 116,117,118,120,125,141,187,188,191,196 \
  Lume/Resources/SportsTeamAliases.json
```

Category IDs come from the saved catalog's Sky/TNT/Premier Sports streams;
they are not portable defaults for other providers. The sports report further
selects reviewed provider IDs referenced by those broadcaster names. Guides
are SAX-filtered; only the existing external feed is decompressed, then its
temporary file is removed. No additional country downloads or retained XML.

## Results

Across 1,252 selected sports provider-ID intervals in the next 48 hours:

| Decision | Rows |
| --- | ---: |
| Exact title/interval with no detected conflict | 60 |
| Additional studio candidates | 28 |
| Additional explicit fixture candidates | 46 |
| Rejected conflicting/unrecognised identity | 142 |
| Unresolved/missing evidence | 976 |

The **74 additional candidates** span 16 provider IDs. All have an external
artwork URL where the provider has none; reachability and image correctness
are **not** verified by this count. Collapsing identical title/time pairs
across variants/simulcasts leaves 50 pairs, not 50 unique physical channels.
Full candidate titles, subtitles, bounded descriptions and reasons are in
the ignored JSON report's `sports.entries`; `publicationEnabled` is false.
Validation adds `externalChannelID` and `externalArtworkURL` for provenance.
All 50 collapsed candidate pairs were inspected; that is a text review,
not independent verification of the broadcast or episode artwork.

Examples at the captured instant: Sky NFL's *Good Morning Football*, Sky
News/Premier League's *Total Football*, Sky Football's *Nottingham Forest v
Blackpool* replay (2010 versus 2009/10). Later candidates include India v
West Indies second T20, explicit URC fixtures and named Champions League
classics. Same-time MotoGP versus powerboat racing remains unresolved.

Conservative losses are expected. A plain `Championship Retro` external title
without explicit EFL evidence is not accepted. Generic NFL highlights without
a shared year or explicit live evidence remain unknown. Same-team games within
a season, missing round/episode labels, internally inconsistent provider text
and generic programme/competition artwork still need review. Do not interpret
142 rejections as 142 independently proven wrong programmes.

Verification: 41 standalone optimized Swift checks, 149 existing focused macOS
EPG tests, 13 Python comparison tests, strict SwiftLint/SwiftFormat and shell
syntax checks. Existing provider-field restoration/schedule checks still pass
in the replay. No simulators or new app build required for Scripts-only changes.

## Fresh validation: 2026-10-09 20:20 UTC

**Verdict: useful candidate discovery, not safe for automatic publication.**
No identity rules were changed during validation and app matching is untouched.

Fresh artifacts are ignored under
`ExampleData/EPGTrial/2026-10-09T201959Z-uk/`:
`capture.json` records completion time, sizes and SHA-256; headers record the
external feed's 16:39:20 UTC last-modified time. Both guide hashes differ from
the earlier capture, so this is an independent refresh, roughly 7.5 hours later,
not another replay. It is still only two same-day snapshots, not a reliability
study across days. No account URLs/credentials were written into reports.

The fresh channel catalog has 10,056 streams; category IDs are unchanged.
Downloads were sequential: 3.84 MB catalog, 147.52 MB provider XML, 2.96 MB UK
gzip. No other countries fetched. The artwork sample adds 9.99 MB retained;
temporary UK decompression is removed by the existing CLI.

At the fresh evaluation instant, the next 48 hours contain 1,185 selected
sports provider-ID intervals: **48 strict, 11 studio candidates, 44 fixture
candidates, 185 conflicting/unrecognised identities, 897 unresolved**.
The 55 additional candidates span 14 provider IDs and collapse to 38 distinct
title/time pairs after variants/simulcasts. All 38 were text-reviewed; no clear
new cross-source fixture contradiction was observed among those candidates.
That does not verify the actual broadcast, exact historical edition or artwork.

For a fixed-window comparison, the fresh pair was also evaluated at the old
12:50:17 UTC anchor (`sports-identity-fixed-window.json`). All **991 common
provider-ID/title/interval rows retained their decision**, including 47 candidate
rows. There were no new candidate intervals in that fixed-window report.
Counts differ as old listings disappear and a moving 48-hour window admits
later fixtures; the drop from 74 to 55 is not evidence of a matching regression.

Artwork results (`artwork-validation/report.json`): all **28 unique URLs**
returned HTTP 200 JPEGs with readable 16:9 dimensions, 1024×576 or 1920×1080.
There are only 25 distinct image byte hashes: three different Live NFL URLs
return the same trophy photograph, and two PL Retro URLs return identical bytes.
Visually inspected eight samples: Hull/Everton promotion and Cardiff/Wolves
action are fixture-relevant; URC, Premier League Preview and TNT Reload are
competition/show graphics; the NFL sample is a generic trophy. Chelsea/UCL
artwork is plausible but does not independently prove the 2012 leg. This is a
useful presentation improvement, not 55 new event-specific posters. Existing
fixture/team artwork should remain primary; don't let generic EPG artwork
overwrite it. HTTP success does not establish usage rights.

The extra adversarial gate found **six unsafe acceptances**:

1. `2014/15` versus `2015/16` seasons share the year 2015 and wrongly match.
2. A source saying both second and third T20 matches a third-T20 source.
3. Title Episode 40 plus description E41 matches external E41.
4. Women's versus men's descriptions with otherwise equal fixture text match.
5. Under-21 versus under-18 descriptions with equal fixture text match.
6. Numeric team qualifiers are stripped: `England 21 v France 21` matches
   `England 18 v France 18`.

These are synthetic counterexamples, not six claimed errors in the downloaded
55 candidates. They disprove readiness to publish automatically. Run:

```sh
bash Scripts/build-epg-trial.sh --validate
```

This separate promotion gate deliberately exits **1** until unsafe acceptances
are fixed. The 41 baseline regressions remain green; they were insufficient to
establish safety. Fresh real rejected cases also reveal contextual false
negatives: NRL text references a previous 2001 final, and a player's career
dates differ from a specific past trophy year. Treating every synopsis year or
competition as the current event is unreliable in both directions.

Next repair: separate explicit headline event identity from synopsis background
references; compare season ranges as identities, not intersecting year sets;
preserve age/gender/numeric name qualifiers; abstain on contradictory event
evidence. Don't simply reject all multi-year/round descriptions: a correct
second-leg synopsis can mention the first leg. Rerun these gates and both
captures before promoting any rule. Then obtain a later-day capture.

Verification: fresh and fixed-window CLI replays preserved schedule and
restored all strict metadata additions (fresh selected-category report: 140
changed/restored rows). Baseline 41 Swift checks, 149 focused EPG tests and
13 Python comparison tests passed; formatting/lint/shell syntax clean. The
promotion gate fails as described; no app build or simulator needed.

## Promotion and architecture

Before enabling: capture later independent provider/external snapshots, review
candidate/conflict cases per rule, verify a useful artwork sample, and expand
negative tests for year/round/leg/gender/age/duplicate ambiguity. Then wire
validated rules into the existing reversible background enrichment lane; retain
provider title/timing and safe abstention. Existing Sports hub resolution should
carry a matched listing snapshot into its current detail UI, not add a screen.

A self-hosted, contract-compatible Xtream/XMLTV proxy is a worthwhile later
option: prepare/cache schedules once and return smaller hydrated feeds without
forking app behaviour. Keep provider/account data isolated; being on-premises
reduces exposure but does not remove credential, access-control, cache-isolation
or availability concerns. Keep deterministic value-type matching portable so
the same verified rules could run there. No backend deployment now; no runtime
AI dependence. AI may help propose offline aliases, never silently approve them.
