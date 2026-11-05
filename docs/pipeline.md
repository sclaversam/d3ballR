# Pipeline

How a season of play-by-play from ncaa.com becomes the CSVs in
`pbp/{season}/`, how it is checked, and what comes next. (Until 2026-11-04
the source was d3football.com; those builds are kept in
`pbp/d3football/{season}/`.) Column definitions are in
[`schema.md`](schema.md).

## Status (2026-11-04: Centennial 2025 rebuilt from ncaa.com)

- **Built from ncaa.com:** 58 of the 62 games in 2025 involving a Centennial
  Conference team, 9,447 rows and 1,300 drives, in `pbp/2025/`. Not built:
  - `20250905_8wt2`: pending (ncaa.com answered 502, no play-by-play yet).
  - `20251122_6buh`, `20251122_a800`: not on ncaa.com (non-NCAA bowl games).
  - `20251220_vlfc` (national semifinal, Johns Hopkins at UW-River Falls):
    ncaa.com's file tags every line with one team and has no drive-start
    lines or running score, so possession can't be read. All its plays are
    there.
- **Reconciled:** all 58 match ncaa.com's final scores.
- **Against d3football:** on the 7,136 rows whose play text matches the
  d3football build, `pos_team`, `score_pts`, `yards_gained`, the penalty
  columns and `td_team` agree 100%; down, distance, yards to goal, drive
  number and `clock_start` agree 99.5-99.7%.
- **d3football (old source):** the 133 cached 2025 games still rebuild,
  byte-identical, into `pbp/d3football/2025/`.
- **Tests:** the test suite passes.
- **Generic:** nothing in `R/` assumes a team or season. Centennial 2025 is
  just `build_season(2025, teams = <the 8 members>)`.

## Running it

The ncaa-api server must be running (Docker container `ncaa-api` on
`127.0.0.1:3000`; set `options(d3ballR.ncaa_api = ...)` for another
address). Cached runs (`OFFLINE=1`) don't need it.

```r
devtools::load_all()
members <- conference_members(2025, "CC")$team
build_season(2025, teams = members)          # one conference's games
build_season(2025)                           # every 2025 game
build_season(2025, max_requests = 100)       # cap new requests this run
build_season(2025, source = "d3football")    # old source, cached pages only
```

From the command line:

```sh
Rscript scripts/build_season.R 2025 --conference CC
Rscript scripts/build_season.R 2025 --max-requests 100
OFFLINE=1 Rscript scripts/build_season.R 2025 --conference CC   # cache only
OFFLINE=1 Rscript scripts/build_season.R 2025 --source d3football
Rscript scripts/season_index_report.R              # season index check (no requests)
```

In the cloud, prefix R commands with `LC_ALL=C.UTF-8` so accented names are
written as UTF-8.

**Resumable runs:** every run also rebuilds every game already in the
output folder, so it and the reports always cover everything built so far.
Games not fetched in a run (request cap reached, or no play-by-play on
ncaa.com yet) are listed as pending, and the next run continues from there.

## Stages

| Stage | What it does | Code | Output |
|---|---|---|---|
| Season dates | Regular-season end date per season (2019-2025 seeded and verified). A missing season is read from its Wikipedia infobox and logged for checking. | `R/season_index.R` (`ensure_season_dates`, `check_season_dates`) | `data-raw/season_dates.csv` |
| Season index | Every game of a season from d3's weekly scoreboard pages: date, week, regular/postseason, teams, boxscore URL. | `R/season_index.R` (`build_season_index`) | `data-raw/index/{season}.csv` |
| Conferences | Each team's conference that season, from ncaa.com's scoreboard tags (already read for the contest map, so no new requests); conference game = same conference, regular season. (d3football source: the team pages and their "*" marker.) | `R/ncaa.R` (`ncaa_conference_table`); `R/conferences.R` (`build_conference_table`) | `data-raw/ncaa/{season}_conferences.csv`; `data-raw/conferences/{season}*.csv` |
| ncaa contests | Each index game's ncaa.com contest id, from ncaa.com's weekly scoreboards (team names through a crosswalk, dates at most a day apart). | `R/ncaa.R` (`map_ncaa_contests`) | `data-raw/ncaa/{season}_contests.csv`, `data-raw/ncaa/team_names.csv` |
| Fetch | Each game's play-by-play JSON from ncaa.com (or, for `source = "d3football"`, its cached boxscore page). Cached and throttled. | `R/ncaa.R` (`fetch_ncaa_json`), `R/scrape_plays.R` (`fetch_html`) | `data-raw/cache/ncaa/`, `data-raw/cache/` (gitignored) |
| Rebuild table | ncaa.com's lines become d3football's (situation, play) table: situations from `driveText` with the yardline side recovered, quarter markers, drive headers, score lines, and labelled extra points ncaa.com left out. | `R/ncaa.R` (`fetch_ncaa_game`, `ncaa_play_table`) | |
| Classify | Label every row of the page: snap, kickoff, try, dead-ball penalty, or one of the non-play types (drive header / footer, quarter marker, timeout, ...). | `R/classify.R`, `R/parse_play_type.R` | |
| Derive | Period, possession, team names, kickoff teams, drives, down / distance / yards to goal, penalties, outcome flags, score, first downs and series, clock. | `R/build_pbp.R` and the files it calls: `teams.R`, `kickoffs.R`, `drives.R`, `scores.R`, `parse_penalties.R`, `parse_outcomes.R`, `game_state.R`, `parse_clock.R` | |
| Assemble | One 71-column table per game. | `R/build_pbp.R` (`build_pbp`, `build_all_pbp`) | `pbp/{season}/{game_id}.csv` |
| Validate | Reports for the season. | `R/validation.R`, `R/build_season.R` | `checks/{season}/` |

**One pipeline for everything.** `build_season()` runs all the stages. The
roadmap stages differ only in its arguments: a `teams` filter, or the `season`.

## Fetching

**ncaa.com** (the source) is read through the local ncaa-api server. The
rules:
- **Cache:** every response is cached in `data-raw/cache/ncaa/` and never
  requested twice. Copy that folder between machines to rebuild offline.
- **Throttle and cap:** requests are spaced `delay` seconds apart (6 by
  default) and capped by `max_requests`, as before.
- **Pending:** an HTTP 502 means ncaa.com has no play-by-play for the game
  (yet); the game is listed as pending and retried on a later run.
- **Terms:** NCAA's terms of use forbid scraping without permission, so
  keep requests few and get a go-ahead before large runs.

**d3football** (the old source) now serves scripts a JavaScript bot
challenge. Its pages are read from the cache only; do not try to get past
the challenge (no browser automation, no reused browser cookies).

## Validation

Run on every build; reports in `checks/{season}/` (ncaa.com) and
`checks/d3football/{season}/` (old source). The 2025 results below are for
the ncaa.com Centennial build:

| Report | Checks | 2025 result |
|---|---|---|
| `build_report.md`, `score_reconciliation.csv` | Every game's points by team, summed from `score_pts`, equal the final (ncaa.com scoreboard, or the d3football line score). Also lists pending, not-on-ncaa.com and failed games, and unclassified rows. | 58 of 58 |
| `conference_check.csv` | ncaa.com builds: our conference-game rule vs d3football's cached "*" marker. (d3football builds: the marker vs shared membership.) | 58 of 58 agree. |
| `first_downs.md` | Series formed from the situation alone (`segment_series()`). Each must have exactly one `new_series` row, on its first snap row. Also: cfbfastR comparison and edge cases. | 3,267 of 3,288. 5 of the 21 exceptions are the same as in the d3football build (labelled); the other 16 are new and not yet explained. The one traced (`20251018_uxv5`) follows a kickoff ncaa.com dropped. Most of the rest are in games where ncaa.com's file differs from d3football's. |
| `kickoff_possession.csv` | Each kickoff's kicking and receiving team, the rule that decided it, and any disagreement. | No disagreements. |
| `clock_bounds.csv` | No missing or inverted clock range in regulation, and `clock_start` inside its range. | Empty. |
| `drive_footer_clock.csv` | Each d3 drive's start clock plus "MM:SS elapsed" vs the drive's end. | Not applicable: ncaa.com has no drive footers. |
| `end_state.csv` | Every change of possession with the next snap's own down / distance / yards to goal, labeled by team. | |
| `season_index.md` | How d3 numbers weeks; the season's game count; scoreboard week vs date-based week. | 1,260 games; no week disagreements. |

`tests/testthat/` holds unit tests for every parsing rule and data tests that
run over every built game: score reconciliation, the clock invariants, and
first-down exclusivity and placement.

## Known issues

- **ncaa.com series flags:** 16 of the 21 `first_downs.md` exceptions in the
  ncaa.com Centennial build are new and unexplained (see Validation).
- **Added extra points:** 100 extra points in the 58 games have no line on
  ncaa.com and are added, labelled in `play_text`: 91 proved by the running
  score, 9 (CMU home games, no running score) by ncaa.com's scoring summary.
  The final-score fallback is not needed in Centennial 2025.
- **Games ncaa.com can't give:** non-NCAA bowl games, and the 2025 national
  semifinal `20251220_vlfc` (every play tagged with one team). Both are
  listed in the build report.
- **The 2025 Stagg Bowl isn't in the game list:** the season index and the
  cached ncaa.com scoreboards stop at 2025-12-20.
- **`yards_gained` on a lateral** reads only the first yardage segment. So a
  first down earned after a lateral is missed (1 series in 2025).
- **`yards_gained` is not defined** for interceptions, punts, field goals,
  kickoffs or tries. It is NA until a convention is chosen (return yards, kick
  distance, net).
- **"Penalty after touchdown before PAT" marker rows** (UW-La Crosse at CMU,
  plays 106 and 161) are kept as dead-ball penalty rows. They should probably
  be dropped.
- **Rule-derived first downs:** first downs in games whose StatCrew format
  never prints "1ST DOWN" come from a yardage rule. That rule matches the
  printed flag exactly where the flag exists.
- **Conference disagreement, Gallaudet:** ncaa.com tags Gallaudet "scac";
  d3football marked its game with Randolph-Macon (ODAC) a conference game.
  ncaa.com's tag is used and the disagreement is left as is (not a
  Centennial game).
- **20 teams have no ncaa.com conference tag** (non-D3 opponents such as
  Anna Maria, Madonna, Point); their conference columns are NA.
- **Older seasons:** only 2025 has been indexed. Other seasons' scoreboard
  pages may differ (2020 was a spring season; folded conferences need extra
  codes).
- **`R CMD check` fails 2 tests (to fix later).** `test-season-index.R`
  (lines 51 and 62) reads `data-raw/season_dates.csv`, but `.Rbuildignore`
  leaves `data-raw/` out of the built package, so the file is missing there.
  `devtools::test()` runs from the source tree and passes. Fix: move the CSV
  to `inst/extdata/` and read it with `system.file()`.

## Source quirks the pipeline handles

ncaa.com's own quirks are listed in `CLAUDE.md` (Source facts) and handled in
`ncaa_play_table()`. Its play text is the same StatCrew text as
d3football's, so these still apply:

- **Two StatCrew formats per site.** Team codes in the play text often differ
  from the down-and-distance codes ("DCFB" vs "DCC", "McD28", nicknames like
  "Wolves05"). The two are paired by a yardline vote.
- **Spellings vary game to game** ("URSINUS COLLEGE"). Team names are mapped to
  the season index's spelling.
- **Missing or doubled score lines, bad clock readings, 0-play drive footers.**
  Each is handled and logged in the reports.
- **A stale situation on some rows.** Kickoffs with a return penalty show a
  leftover down-and-distance, and PAT penalties show a placeholder "1st and
  10".
- **d3 keeps the old down after some turnovers** (e.g. "3rd and 1" for the new
  offense), and prints "1st and 10" after some dead-ball offensive penalties.
  Both are flagged in `first_downs.md`.

## Lessons from each batch

Every batch of new games turns up StatCrew / ncaa.com quirks. Each one gets
a **generic** rule in the code (never a per-team or per-game rule), a
CHANGELOG entry, and a line here, so later batches don't repeat the miss.
Source gaps that no rule can fix go in `data-raw/ncaa/known_exceptions.csv`
instead (listed apart in the build report; the score test skips them and
fails if one starts reconciling, so the list can't go stale). Update this
section after every batch.

### Batch 1 (2025 weeks 1-2, 144 new games, 2026-11-05)

| Quirk | Generic rule now | First seen |
|---|---|---|
| Many sacks / losses outvote gains in the yardline-side vote | `infer_own_side()`: settle from touchbacks and false starts first; the vote leaves out sacks, losses, kneel-downs and penalty plays | `20250906_nidd` |
| "drive start" lines on only a few drives, or none for the first | `ncaa_play_table()`: a different team snapping opens a drive after a kickoff, on the game's first snap, after a touchdown, and on each overtime period's first snap | `20250906_pzhf`, `20250913_2k0r`, `20250913_c7zf`, `20250913_5ivd` |
| Kickoff return "TOUCHDOWN nullified by penalty" hid a dropped extra point | `live_td` in `ncaa_play_table()` ignores nullified touchdowns | `20250906_8o5p` |
| ncaa.com repeats a line verbatim (a safety counted twice) | `ncaa_lines()` drops a line identical to the one before | `20250904_zik0` (12 games) |
| No running score and the scoring summary not fetched | `prefetch_ncaa_games()` fetches the summary right after any such game's play-by-play, within the budget | `20250913_5ivd`, `20250913_8l2c` |
| HTTP 500 / 502 retried by the build, eating the budget | `fetch_ncaa_json()` remembers HTTP errors for the run and doesn't retry | 6 week-1 games |
| "(00:00)" printed on nearly every play | `stated_clock_anchors()`: when most printed clocks are 00:00, every 00:00 reading in that game is dropped | `20250906_pzhf` |
| Punt "Touchback" with a penalty in the same line | touchback clues skip lines that have a penalty | `20250906_8o5p` |
| Source gap: play-by-play ends after Q3 | listed in `known_exceptions.csv` | `20250906_hbla` (`20250906_wk1h` was listed too; batch 2's defensive-PAT rule fixed it) |

### Batch 2 (2025 weeks 2-3, 180 new games, 2026-11-05)

| Quirk | Generic rule now | First seen |
|---|---|---|
| Blocked try "returned by NAME for defensive PAT" (no "Successful") | `score_points()` counts it as the defense's 2 points | `20250920_2fq2`, `20250906_wk1h` (wrongly listed as a source gap in batch 1) |
| Kickoff after a touchdown recovered by the kicking team and scored hid a dropped extra point | `ncaa_play_table()`: a kickoff touchdown is taken off whichever team's score rose by 6 | `20250920_3awh` |
| Coin toss names the receiver with a code no other row uses ("WEC will receive") | `parse_coin_deferrer()`: the toss winner who defers kicks | `20250920_ev5d` |
| Team codes in lowercase ("cen49") or with a hyphen ("Rose-H46") | token patterns accept a lowercase first letter and "-" | `20250920_t60m`, `20250920_upco` |
| A printed per-play clock 1-2 s past the official "drive start at" reading | clock test allows 2 s | `20250913_npl1`, `20250913_vg5b`, `20250920_a8p2` |
| Index `week` restarts at 1 in the postseason | filter on `season_type == "regular"` when fetching by week | batch 2 fetched 28 playoff games by mistake |

## Roadmap

1. **CMU 2025** (validation set): done.
2. **Centennial 2025**: done; rebuilt from ncaa.com on 2026-11-04.
3. **All of D3 2025 from ncaa.com** (next): `build_season(2025)`. About
   1,180 more games, fetched in capped runs with Sam's go-ahead.
   Conferences come from ncaa.com's scoreboards for every team. Expect new
   StatCrew formats to surface. The score-reconciliation test and the
   `first_downs.md` series check are the main guards.
4. **Other seasons:** index each season, check its week structure and
   conferences, then `build_season(season)`.

Not planned: EPA / win probability models and player names. Drive-level
summaries beyond `drive_number` and `drive_result` aren't planned either.
