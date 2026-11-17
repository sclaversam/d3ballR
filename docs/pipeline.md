# Pipeline

How a season of play-by-play from ncaa.com becomes the CSVs in
`pbp/{season}/`, how it is checked, and what comes next. Column
definitions are in [`schema.md`](schema.md).

## Status (2026-11-17: all of 2025)

- **Built:** all 1,263 games in the 2025 game list, in `pbp/2025/`: 1,254
  from ncaa.com, 9 from saved stats.ncaa.org pages.
- **Reconciled:** 1,262 of 1,263 match the final score. The other,
  `6496410` (Case Western Reserve at Rowan), is missing its 4th quarter on
  both sites.
- **Tests:** the test suite passes.
- **Generic:** nothing in `R/` assumes a team or season. A conference's
  games are `build_season(2025, teams = <its members>)`.

## Running it

Nothing else needs to be running: d3ballR asks ncaa.com's data server
directly. To go through an ncaa-api server instead (the Docker container
used until 2026-11-08), set `options(d3ballR.ncaa_api =
"http://127.0.0.1:3000")`. Cached runs (`OFFLINE=1`) make no requests.

```r
devtools::load_all()
conf <- read.csv("data-raw/ncaa/2025_conferences.csv")
build_season(2025, teams = conf$team[conf$conference_code %in% "CC"])  # one conference's games
build_season(2025)                           # every 2025 game
build_season(2025, max_requests = 100)       # cap new requests this run
```

From the command line:

```sh
Rscript scripts/build_season.R 2025 --conference CC
Rscript scripts/build_season.R 2025 --max-requests 100
OFFLINE=1 Rscript scripts/build_season.R 2025                   # cache only
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
| Season dates | Regular-season end date per season (2019-2025 seeded and verified). A missing season is read from its Wikipedia infobox and logged for checking. | `R/season_dates.R` (`ensure_season_dates`, `check_season_dates`) | `inst/extdata/season_dates.csv` (ships with the package; seasons added on an installed copy go to a user copy) |
| Game list | Every game of a season from ncaa.com's weekly D3 scoreboards (cached): `game_id` = contest id, date, ncaa.com's week, regular/postseason, teams (ncaa.com's short names), final score. Placeholder and duplicate contests are dropped (logged). | `R/ncaa.R` (`ncaa_season_games`) | `data-raw/ncaa/{season}_games.csv` |
| Conferences | Each team's conference that season, from ncaa.com's scoreboard tags (already read for the game list, so no new requests); conference game = same conference, regular season. | `R/ncaa.R` (`ncaa_conference_table`, `game_conferences`) | `data-raw/ncaa/{season}_conferences.csv` |
| stats.ncaa.org fallback | For the games ncaa.com can't give (no play-by-play, or a file that can't be built: `pull_from_stats_ncaa` TRUE in `{season}_stats_ncaa_candidates.csv`), a stats.ncaa.org "Play By Play" page Sam saved from his browser is read into ncaa.com's line table and built the same way. Pages are matched to games by date and teams, whatever their file name. The build report lists them under "Built from stats.ncaa.org". | `R/stats_ncaa.R` (`stats_ncaa_games`, `stats_ncaa_files`, `stats_ncaa_lines`, `fetch_stats_ncaa_game`) | `data-raw/stats_ncaa/*.html` (committed) |
| Fetch | Each game's play-by-play JSON from ncaa.com (and, for games without a running score, its scoring summary). Cached, throttled and capped; the request counter and throttle are shared (`R/fetch.R`). | `R/ncaa.R` (`fetch_ncaa_json`, `ncaa_direct_request`), `R/fetch.R` (`reset_fetch_state`, `throttle`) | `data-raw/cache/ncaa/` (gitignored) |
| Rebuild table | ncaa.com's lines become the (situation, play) table the parser reads (the layout of a StatCrew play-by-play page): situations from `driveText` with the yardline side recovered, quarter markers, drive headers, score lines, and labelled extra points ncaa.com left out. | `R/ncaa.R` (`fetch_ncaa_game`, `ncaa_play_table`) | |
| Classify | Label every row of the page: snap, kickoff, try, dead-ball penalty, or one of the non-play types (drive header / footer, quarter marker, timeout, ...). | `R/classify.R`, `R/parse_play_type.R` | |
| Derive | Period, possession, team names, kickoff teams, drives, down / distance / yards to goal, penalties, outcome flags, score, first downs and series, clock. | `R/build_pbp.R` and the files it calls: `teams.R`, `kickoffs.R`, `drives.R`, `scores.R`, `parse_penalties.R`, `parse_outcomes.R`, `game_state.R`, `parse_clock.R` | |
| Assemble | One 71-column table per game. | `R/build_pbp.R` (`build_pbp`, `build_all_pbp`) | `pbp/{season}/{game_id}.csv` |
| Validate | Reports for the season. | `R/validation.R`, `R/build_season.R` | `checks/{season}/` |

**One pipeline for everything.** `build_season()` runs all the stages. The
roadmap stages differ only in its arguments: a `teams` filter, or the `season`.

## Fetching

**ncaa.com** (the source) is read straight from its data server,
`sdataprod.ncaa.com`, with the same requests ncaa.com's own game pages
make (`ncaa_direct_request()` in `R/ncaa.R`): a GET with a "persisted
query" id and the game's contest id, no cookies, no browser headers. The
answer is reshaped exactly as ncaa-api reshapes it, so old and new cache
files are interchangeable. The query ids are in `ncaa_query_hashes`; if
ncaa.com redeploys and changes one, every request of that kind fails with
"PersistedQueryNotFound" in the error, and the fix is to copy the new id
from ncaa.com's page source (or henrygd/ncaa-api's `src/codes.ts`). The
rules:
- **Cache:** every response is cached in `data-raw/cache/ncaa/` and never
  requested twice. Copy that folder between machines to rebuild offline.
- **Throttle and cap:** requests are spaced `delay` seconds apart (6 by
  default) and capped by `max_requests`, as before.
- **Pending:** an HTTP 502 means ncaa.com has no play-by-play for the game
  (yet); the game is listed as pending and retried on a later run.
- **Terms:** NCAA's terms of use forbid scraping without permission. Sam's
  professor and the NCAA told him (2026-11-17) that accessing the
  play-by-play the way other public R packages do is fine. Requests stay
  few, cached and throttled, with a go-ahead before large runs.

**Bot challenges:** never try to get past one (stats.ncaa.org's Akamai
block, or any JavaScript challenge): no browser automation, no reused
browser cookies.

## Validation

Run on every build; reports in `checks/{season}/`. 2025 results:

| Report | Checks | 2025 result |
|---|---|---|
| `build_report.md`, `score_reconciliation.csv` | Every game's points by team, summed from `score_pts`, equal the final (ncaa.com scoreboard). Also lists the games built from stats.ncaa.org, pending and failed games, and unclassified rows. | 1,262 of 1,263 (the other is a known source gap) |
| `conference_check.csv` | Each game's conference columns and `conference_game` (same conference, regular season). | |
| `first_downs.md` | Series formed from the situation alone (`segment_series()`). Each must have exactly one `new_series` row, on its first snap row. Also: cfbfastR comparison and edge cases. | 477 exceptions in about 71,000 series, most in a few host files whose downs are unreliable (see Known issues). |
| `kickoff_possession.csv` | Each kickoff's kicking and receiving team, the rule that decided it, and any disagreement. | |
| `clock_bounds.csv` | No missing or inverted clock range in regulation, and `clock_start` inside its range. | Empty. |
| `end_state.csv` | Every change of possession with the next snap's own down / distance / yards to goal, labeled by team. | |

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
- **stats.ncaa.org pages' own quirks** (handled in `stats_ncaa_lines()`):
  it is a different StatCrew file from ncaa.com's (names "Blaha,Kaleb" for
  "K.Blaha"; drive-start lines everywhere). Drive headers can sit a group
  of plays off and some read 0 - 0 throughout (`6461614`: 8 drives
  relabelled from their drive-start lines). In `6529905` its 4th quarter
  starts a few lines late: 2 snaps and a try of the 4th (the 14:23
  touchdown) are filed under the 3rd; ncaa.com has them in the 4th. Left as
  stats.ncaa.org has it.
- **Non-NCAA bowl games** aren't on ncaa.com's scoreboards, so since the
  switch to ncaa.com's game list they aren't in it at all.
- **Games to patch from stats.ncaa.org:** `data-raw/ncaa/{season}_stats_ncaa_candidates.csv`
  lists the 2025 games whose ncaa.com file is unusable or badly
  incomplete, by Sam's rule (2026-11-17): (a) no play-by-play at all, (b)
  can't be built, (c) a big portion missing, (d) a severe smaller issue
  (doesn't reconcile and no rule can fix it, a missing touchdown, quarters
  mislabelled, downs unreliable). Each row has the ncaa.com link and what
  to check on stats.ncaa.org. Sam's decision (2026-11-17): stats.ncaa.org
  is used for (a) and (b), and for a game whose stats.ncaa.org version
  reconciles when ncaa.com's doesn't (`6461552`, `6529896`): the 9 rows
  with `pull_from_stats_ncaa` TRUE. The rest stay as ncaa.com has them,
  documented.
  stats.ncaa.org blocks scripts (Akamai 403
  on the first request), so a patch would come from a page Sam saves in
  his browser. (c) came from a scan of every file for a regulation quarter
  with no or few lines; thin 4th quarters in blowouts (running clock) and
  `6462325`, called for thunderstorms in the 4th quarter, are not
  problems. Checked by Sam on stats.ncaa.org (2026-11-17), recorded in the file's
  `stats_ncaa_result` column: both "big portion missing" games are the same
  there (`6496410` has no 4th quarter, `6461643` only the first half), so
  they stay as they are.
- **Elmhurst at Washington U. (`6461643`) covers only the first half:**
  ncaa.com's file (and stats.ncaa.org, checked by Sam 2026-11-17) ends
  after the 2nd quarter with "End of game". It reconciles (all 17 points
  came before halftime), so it is kept and isn't in `known_exceptions.csv`
  (that list is for games that don't reconcile), but its second half is
  missing.
- **Dead-ball penalties before a kickoff in tournament files** ("PENALTY
  CROWN Personal Foul 15 yards from WHEIL35 to WHEIL50. NO PLAY", driveText
  "- and -") have no situation, so they are unclassified and dropped
  (`6529861`, `6529867`, `6529886`; 6 rows). The kickoff
  text still shows the new spot.
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
- **20 teams have no ncaa.com conference tag** (non-D3 opponents such as
  Anna Maria, Madonna, Point); their conference columns are NA.
- **Older seasons:** only 2025 has been built. Other seasons' ncaa.com
  scoreboards may differ or not exist (2020 was a spring season; folded
  conferences need extra codes in `inst/extdata/conference_names.csv`); nobody has
  checked how far back ncaa.com's D3 play-by-play goes.

## Source quirks the pipeline handles

ncaa.com's own quirks are listed in `CLAUDE.md` (Source facts) and handled in
`ncaa_play_table()`. Its play text is StatCrew text, whose own quirks
also apply:

- **Two StatCrew formats per site.** Team codes in the play text often differ
  from the down-and-distance codes ("DCFB" vs "DCC", "McD28", nicknames like
  "Wolves05"). The two are paired by a yardline vote.
- **Spellings vary game to game** ("URSINUS COLLEGE"). Team names are mapped to
  the game list's spelling.
- **Missing or doubled score lines, bad clock readings, 0-play drive footers.**
  Each is handled and logged in the reports.
- **A stale situation on some rows.** Kickoffs with a return penalty show a
  leftover down-and-distance, and PAT penalties show a placeholder "1st and
  10".
- **StatCrew keeps the old down after some turnovers** (e.g. "3rd and 1" for the new
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
| Many sacks / losses outvote gains in the yardline-side vote | `infer_own_side()`: settle from touchbacks and false starts first; the vote leaves out sacks, losses, kneel-downs and penalty plays | `6461516` |
| "drive start" lines on only a few drives, or none for the first | `ncaa_play_table()`: a different team snapping opens a drive after a kickoff, on the game's first snap, after a touchdown, and on each overtime period's first snap | `6461790`, `6462236`, `6461949`, `6461689` |
| Kickoff return "TOUCHDOWN nullified by penalty" hid a dropped extra point | `live_td` in `ncaa_play_table()` ignores nullified touchdowns | `6462343` |
| ncaa.com repeats a line verbatim (a safety counted twice) | `ncaa_lines()` drops a line identical to the one before | `6461247` (12 games) |
| No running score and the scoring summary not fetched | `prefetch_ncaa_games()` fetches the summary right after any such game's play-by-play, within the budget | `6461689`, `6462216` |
| HTTP 500 / 502 retried by the build, eating the budget | `fetch_ncaa_json()` remembers HTTP errors for the run and doesn't retry | 6 week-1 games |
| "(00:00)" printed on nearly every play | `stated_clock_anchors()`: when most printed clocks are 00:00, every 00:00 reading in that game is dropped | `6461790` |
| Punt "Touchback" with a penalty in the same line | touchback clues skip lines that have a penalty | `6462343` |
| Source gap: play-by-play ends after Q3 | listed in `known_exceptions.csv` | `6496410` (`6462325` was listed too; batch 2's defensive-PAT rule fixed it) |

### Batch 2 (2025 weeks 2-3, 180 new games, 2026-11-05)

| Quirk | Generic rule now | First seen |
|---|---|---|
| Blocked try "returned by NAME for defensive PAT" (no "Successful") | `score_points()` counts it as the defense's 2 points | `6462115`, `6462325` (wrongly listed as a source gap in batch 1) |
| Kickoff after a touchdown recovered by the kicking team and scored hid a dropped extra point | `ncaa_play_table()`: a kickoff touchdown is taken off whichever team's score rose by 6 | `6462066` |
| Coin toss names the receiver with a code no other row uses ("WEC will receive") | `parse_coin_deferrer()`: the toss winner who defers kicks | `6462273` |
| Team codes in lowercase ("cen49") or with a hyphen ("Rose-H46") | token patterns accept a lowercase first letter and "-" | `6461781`, `6461466` |
| A printed per-play clock 1-2 s past the official "drive start at" reading | clock test allows 2 s | `6462344`, `6461618`, `6462135` |
| A defensive two-point return written as the offense's try ("Johnson,Jaylen rush attempt Successful", Johnson being a defender) | `ncaa_play_table()`: a try line where ncaa.com's running score rises by 2 for the defense and 0 for the scoring team gets a "[d3ballR: ...]" label, read as a defensive conversion | `6462421` |
| A safety on a foul in the end zone written "SAFETY ... PENALTY ... NO PLAY" (illegal forward pass from the end zone) | `ncaa_play_table()` labels it and the parser scores it although it's a no-play: the running score decides (2 for the defense on that line); without one, a safety in the scoring summary at the same quarter and clock; last resort, the safety kick from the 20 | `6461773` |
| Scoring summary periods are numbered by position, so a quarter with no scoring shifts the rest | `ncaa_scoring_entries()` adds `quarter` from the title; the safety rule and the extra-point matching use it | `6462421` |
| A scoring summary that leaves out a team's tries and field goals | a try missing from the summary only counts as evidence for a team the summary is complete for (as many good tries and field goals as the play text); otherwise the final-score rule decides | `6461828` |
| The game list's `week` restarted at 1 in the postseason | filter on `season_type == "regular"` when fetching by week | batch 2 fetched 28 playoff games by mistake |

### Batch 3 (2025 weeks 4-6, 287 new games, 2026-11-05)

| Quirk | Generic rule now | First seen |
|---|---|---|
| Every line tagged with the other team's teamId | `ncaa_unswap_team_ids()`: when the drive-start names match ncaa.com's team names the other way round on most lines, the ids are swapped back | `6461392` |
| A "drive start" line names the other team (overtime) | when its name disagrees with its own id and the next snap's, a drive start for the team that snaps is added after the raw line, labelled | `6461812` |
| Safety for the team that started the play (blocked field goal recovered by the defense, then a foul in its end zone) | when the running score gives the 2 to the line's own team (not on kickoffs, where `pos_team` is already the receiver), the row is labelled and scored +2 for `pos_team` | `6462142` (`6461603` kickoff case kept as is) |
| A safety on a try ("[Hampden-Sydney PAT safety]") | 1 point for the trying team | `6461660` |
| Dropped extra point with the kickoff line dropped too | compare the running score on the last line before the other team's first snap | `6461664` |
| Extra point after a defensive touchdown by a kicker who only kicks tries | `try_phase_team()` remembers each try's kicker within the game | `6461717` |
| Team codes with an apostrophe or two words ("King's42", "Cal Lu10", "NEB W.30") | token patterns accept both; keywords are word-anchored and can't be a code ("Deion at UMHB31") | `6461277`, `6462190`; fixed `yards_to_goal` on 41 rows of `6462405` |
| One settling play against a decisive yardline vote | a single touchback / false start doesn't overrule a decisive vote | `6462266` |
| Source gap: try lines missing and an incomplete scoring summary | `known_exceptions.csv` | `6461552` |
| A field goal with no line (the running score rises by 3 on the next, non-scoring, line) | Sam's decision: a labelled "field goal attempt GOOD" row is added before that line, for the team in possession, with down and distance rebuilt from the previous snap and the kicker from the scoring summary when cached; skipped when a field-goal line since the last score change already accounts for it (ncaa.com's score can lag a line). Without a running score, a summary field goal with no matching line is added only when the final is short by exactly 3 per such field goal | `6461313` |
| The game list's `week` and season type | fetch by `season_type == "regular"` (batch 2's lesson) held: no playoff games fetched | |

### Batch 4 (2025 weeks 7-8, 220 new games, 2026-11-08)

Week 7 was already cached; week 8 was the first batch fetched straight
from ncaa.com in R (no ncaa-api server): 124 requests (112 play-by-play,
12 scoring summaries), no failures.

| Quirk | Generic rule now | First seen |
|---|---|---|
| A replay-review note after the play ("MSU is challenging the ruling on the field - \"Fumble\". PLAY STANDS.") hid the "recovered by" before it, so a lost fumble wasn't a turnover | `strip_review_note()`: the fumble and recovery search ignores the note (and any "(Original Play: ...)"); the play before it is the final ruling | `6461675` (fumble-return TD credited to the fumbling team); also fixed `6461373`, `6461748`, `6461737` |
| Pass direction before the result ("pass short right complete to ...") | pass verbs accept up to two direction words between "pass" and complete / incomplete / intercepted | `6461766` (39 passes had been dropped as unclassified) |
| A return touchdown whose try has no kicker named, no kickoff line after it and no running score went to the scoring play's offense (the punting team) | `scoring_team()`: a first pass of the outcome flags and points says who scored; `try_phase_team()`'s last rule uses it | `6462377` (blocked punt returned for a touchdown) |
| ncaa.com prints a touchdown after its own try and kickoff (an interception return), so the try landed on the other team's drive | Sam's decision (2026-11-09): `ncaa_move_late_touchdowns()` in `ncaa_lines()` moves a touchdown that comes within 3 lines after a try with no touchdown before it (only kickoffs between) in front of the try, labelled; the running score must agree (try +1/+2 then +6 for the same team) and is put back in play order. Fires once in all cached games | `6529878` |

### Batch 5 (2025 weeks 9-10, 222 new games, 2026-11-09)

Fetched straight from ncaa.com in R: 242 requests (222 play-by-play, 20
scoring summaries), no failures. All 222 games reconcile after these
fixes.

| Quirk | Generic rule now | First seen |
|---|---|---|
| An onside kick printed with no recovery ("Gallant,Carson onside kickoff 11 yards to the SUFB46."); the drive header made the kicking team the receiver, and its kicker's tries then went to the other team | `assign_kickoffs()`: an onside kick with no "recovered by" that lands on the kicking team's own side, when the kicking team has the next drive, is a kicker recovery | `6461407`; also `6461475` (Knox's opening onside kick, reconciled before; now a turnover with `drive_result` "ONSIDE") |
| A try dropped with the running score rising by 2 (a two-point conversion) | the running-score rule adds "two-point attempt good" (`ncaa_added_two_point_text_score`) when the touchdown has no try line and the score rose by 2 | `6461897` |
| "pass attempt to Julian Toscano good" read as "no good" | "no good" / "failed" / "blocked" / "missed" / "NO PLAY" are matched as words | `6462271` |
| A try and the kickoff after it both dropped, the other team scoring on its next snap: the other team's try was taken for this touchdown's | a touchdown's try window ends at the next touchdown | `6462271` (Albion's punt-return touchdown) |

### Batch 6 (2025 week 11 and the playoffs, 117 new games, 2026-11-16)

Fetched straight from ncaa.com in R: 135 requests (115 play-by-play, 14
scoring summaries, 6 week-1 retries that came back empty), plus 1 for the
Stagg Bowl. Week 11: 108 of 108 built and reconciled. Playoffs: 45 of the
51 games then listed built (5 non-NCAA bowls aren't on ncaa.com; `6529905` can't be
read), 44 reconcile (`6529896` was a source gap, fixed later from stats.ncaa.org).

| Quirk | Generic rule now | First seen |
|---|---|---|
| A touchdown overturned on review still scored: the "(Original Play: ... TOUCHDOWN)" after "PLAY OVERTURNED" was read as the play | `has_touchdown()` drops the review note before looking for "TOUCHDOWN", everywhere (batch 4's `strip_review_note()` covered only fumbles) | `6461573` |
| Tournament files spell the sides differently in driveText and play text ("CHA36" / "CHAP36", "WRF" / "UWRF", "CRO" / "CROWN"; codes padded "  U35"), so the side recovery mixed four codes | `ncaa_spot_token_map()`: a yardline vote renames driveText's codes to the play text's; driveText codes are trimmed | `6529861`, `6529887` (failed since batch 1, never listed); 6 playoff games tidied |
| A garbled kickoff-return touchdown named the kicking team's kicker ("Adrogue onside kickoff ... TOUCHDOWN", then Adrogue's try), so the points went to the receiver | `refine_kickoffs_by_kicker()`: on a kickoff touchdown, a try by the kicking team's kicker right after it means the kicking team recovered | `6461646` |
| "rush for 22 yards to the DEAN00, TOUCHDOWN, fumble by ... recovered by DEAN" read as a defensive touchdown | a fumble printed after "TOUCHDOWN" on a scrimmage play is never lost | `6461729` |
| A try printed away from its touchdown (ncaa.com put the touchdown at the end of the game) went to the offense on the field | a try outside any try phase goes to its kicker's team when known | `6529898` |
| An empty game (`periods: []`) raised "subscript out of bounds" | `ncaa_direct_request()` returns 502 (pending) | the 6 week-1 retries |
| Source gap: a DePauw touchdown has no line (running score +6 on a drive-start line) | listed in `known_exceptions.csv` | `6529896` |
| Source quirk: in some host files the down counter rises on every snap and resets only on a printed "1ST DOWN" (a 15-yard gain shows "2 and ...") | labelled, not fixed: these games carry most of the batch's 83 new `first_downs.md` series exceptions | `6529896`, `6529897`, `6529892`, `6529893` |

## Roadmap

1. **CMU 2025** (validation set): done.
2. **Centennial 2025**: done.
3. **All of D3 2025** (done 2026-11-17): `build_season(2025)`. The game
   list is ncaa.com's (1,263 games); all 1,263 built, 1,262 reconcile (the other,
   `6496410`, is missing its 4th quarter on both sites). 9 come from saved
   stats.ncaa.org pages: the 6 week-1 games ncaa.com has no play-by-play
   for, the national semifinal `6529905`, and two games whose ncaa.com
   file doesn't reconcile (`6461552`, `6529896`).
   Conferences come from ncaa.com's scoreboards for every team. Expect new
   StatCrew formats to surface. The score-reconciliation test and the
   `first_downs.md` series check are the main guards.
4. **Other seasons:** check that ncaa.com has the season's scoreboards and
   play-by-play, then `build_season(season)`.

Not planned: EPA / win probability models and player names. Drive-level
summaries beyond `drive_number` and `drive_result` aren't planned either.
