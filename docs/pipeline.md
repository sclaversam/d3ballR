# Pipeline

How a season of d3football play-by-play becomes the CSVs in `pbp/{season}/`,
how it is checked, and what comes next. Column definitions are in
[`schema.md`](schema.md).

## Status (checkpoint: Centennial Conference 2025)

- **Built:** every 2025 game involving a Centennial Conference team. That's 62
  games (10 postseason, 1 overtime), 10,149 rows and 1,400 drives, across the
  8 Centennial teams and 28 opponents.
- **Reconciled:** all 62 games match their boxscore final scores.
- **Tests:** the test suite passes, and every report in `checks/2025/` is
  clean or explains each exception (see Validation).
- **Generic:** nothing in `R/` assumes a team or season. Centennial 2025 is
  just `build_season(2025, teams = <the 8 members>)`.

## Running it

```r
devtools::load_all()
members <- conference_members(2025, "CC")$team
build_season(2025, teams = members)          # one conference's games
build_season(2025)                           # every 2025 game
build_season(2025, max_requests = 100)       # cap new page requests this run
```

From the command line:

```sh
Rscript scripts/build_season.R 2025 --conference CC
Rscript scripts/build_season.R 2025 --max-requests 100
OFFLINE=1 Rscript scripts/build_season.R 2025      # cache only, no requests
Rscript scripts/season_index_report.R              # season index check (no requests)
```

**Resumable runs:** every run also rebuilds every game already in
`pbp/{season}/`, so the folder and `checks/{season}/` always cover everything
built so far. Pages not fetched in a run (request cap reached, or d3football
rate-limiting) are listed as pending, and the next run continues from there.

## Stages

| Stage | What it does | Code | Output |
|---|---|---|---|
| Season dates | Regular-season end date per season (2019-2025 seeded and verified). A missing season is read from its Wikipedia infobox and logged for checking. | `R/season_index.R` (`ensure_season_dates`, `check_season_dates`) | `data-raw/season_dates.csv` |
| Season index | Every game of a season from d3's weekly scoreboard pages: date, week, regular/postseason, teams, boxscore URL. | `R/season_index.R` (`build_season_index`) | `data-raw/index/{season}.csv` |
| Conferences | For the teams in scope: each team's conference that season and d3's "*" conference-game marker, from the team's page. | `R/conferences.R` (`build_conference_table`) | `data-raw/conferences/{season}*.csv` |
| Fetch | Each game's play-by-play page. Cached and throttled. | `R/scrape_plays.R` (`fetch_html`) | `data-raw/cache/` (gitignored) |
| Classify | Label every row of the page: snap, kickoff, try, dead-ball penalty, or one of the non-play types (drive header / footer, quarter marker, timeout, ...). | `R/classify.R`, `R/parse_play_type.R` | |
| Derive | Period, possession, team names, kickoff teams, drives, down / distance / yards to goal, penalties, outcome flags, score, first downs and series, clock. | `R/build_pbp.R` and the files it calls: `teams.R`, `kickoffs.R`, `drives.R`, `scores.R`, `parse_penalties.R`, `parse_outcomes.R`, `game_state.R`, `parse_clock.R` | |
| Assemble | One 67-column table per game. | `R/build_pbp.R` (`build_pbp`, `build_all_pbp`) | `pbp/{season}/{game_id}.csv` |
| Validate | Reports for the season. | `R/validation.R`, `R/build_season.R` | `checks/{season}/` |

**One pipeline for everything.** `build_season()` runs all the stages. The
roadmap stages differ only in its arguments: a `teams` filter, or the `season`.

## Fetching

d3football is the only source. The play-by-play is rendered HTML; there is no
structured feed. The rules:
- **Cache:** every page is cached in `data-raw/cache/` and never requested
  twice.
- **Throttle:** requests are spaced 6 seconds apart in `build_season()`.
- **Cap:** `max_requests` limits new requests per run.
- **Stop on refusal:** after the first refusal (HTTP 459 or an empty page,
  which is how d3football rate-limits), the rest of the run uses the cache
  only.

In practice, fetch in batches of about 10-100 pages and stop when refused.
Bursts of a few dozen requests have triggered the limit: the first all-D3
run (6 s apart) was refused after 21 pages; 50 pages 15 s apart went through
cleanly. Use `--delay 15` (or `build_season(..., delay = 15)`).

## Validation

Run on every build; reports in `checks/{season}/`:

| Report | Checks | 2025 result |
|---|---|---|
| `build_report.md`, `score_reconciliation.csv` | Every game's points by team, summed from `score_pts`, equal the boxscore final. Also lists pending and failed games. | 62 of 62 |
| `conference_check.csv` | d3's "*" conference marker vs shared membership. | Agree wherever both conferences are known (NJAC's name pending a fetch). |
| `first_downs.md` | Series formed from the situation alone (`segment_series()`). Each must have exactly one `new_series` row, on its first snap row. Also: cfbfastR comparison and edge cases. | 3,538 of 3,541; the 3 exceptions are labeled (2 d3 quirks, 1 lateral). |
| `kickoff_possession.csv` | Each kickoff's kicking and receiving team, the rule that decided it, and any disagreement. | No disagreements. |
| `clock_bounds.csv` | No missing or inverted clock range in regulation, and `clock_start` inside its range. | Empty. |
| `drive_footer_clock.csv` | Each d3 drive's start clock plus "MM:SS elapsed" vs the drive's end. | 15 of 1,325 flagged, mostly d3 "00:00 elapsed" footers. |
| `end_state.csv` | Every change of possession with the next snap's situation. | |
| `season_index.md` | How d3 numbers weeks; the season's game count; scoreboard week vs date-based week. | 1,260 games; no week disagreements. |

`tests/testthat/` holds unit tests for every parsing rule and data tests that
run over every built game: score reconciliation, the clock invariants, and
first-down exclusivity and placement.

## Known issues

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
- **NJAC's conference name** is pending one standings-page fetch. Until then,
  NJAC teams' conference columns are NA.
- **Older seasons:** only 2025 has been indexed. Other seasons' scoreboard
  pages may differ (2020 was a spring season; folded conferences need extra
  codes).

## d3 source quirks the pipeline handles

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

## Roadmap

1. **CMU 2025** (validation set): done.
2. **Centennial 2025**: done (this checkpoint).
3. **All of D3 2025** (in progress, branch `all-d3-2025`; 133 games built):
   `build_season(2025)`. About 1,180 more games plus about
   230 team pages, fetched in capped runs. Expect new StatCrew formats to
   surface. The score-reconciliation test and the `first_downs.md` series
   check are the main guards.
4. **Other seasons:** index each season, check its week structure and
   conferences, then `build_season(season)`.

Not planned: EPA / win probability models and player names. Drive-level
summaries beyond `drive_number` and `drive_result` aren't planned either.
