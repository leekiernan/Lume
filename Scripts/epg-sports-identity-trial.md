# Offline sports programme identity trial

## Scope

Replays the **existing** paired 2026-10-09 12:50:17 UTC capture, not a new
independent snapshot. No network calls, provider changes, new dependencies,
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
