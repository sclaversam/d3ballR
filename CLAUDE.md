# CLAUDE.md

Briefing for Claude Code working in this repo. Read this first.

## What this project is

`d3ballR` scrapes and parses **NCAA Division III** college football
play-by-play from d3football.com into tidy, per-play tables. It fills a real
gap: `cfbfastR` and the CollegeFootballData API cover only Division I (FBS/FCS,
division codes 11 and 12); D2 and D3 are absent from every published dataset.
That gap is documented and verified in
`analysis/cfbfastr_d2_d3_coverage_audit.Rmd`.

**Roadmap (in order):** CMU 2025 (done, the validation set) -> Centennial
Conference 2025 (done: 62 games, all reconcile) -> all of D3 2025 -> other
seasons. Everything in `R/` must
stay generic: no code may assume a team (CMU) or a season (2025). CMU 2025 is
only the data the rules are validated on. CMU's internal coaching data was the
original validation target (see "CMU schema" below); it turned out to be
hand-charted with errors, so d3's StatCrew feed is now the reference.

The author (Sam) is a CMU statistics and machine learning student. Long-term he
may extend this into projections work, but the current scope is strictly the
scraper: get accurate, tidy play-by-play out of d3football.

## Source facts (confirmed, do not re-litigate)

- **d3football.com is the source.** The play data is baked into the rendered
  HTML table. There is NO separate structured XML or JSON feed. This was checked
  directly in the browser Network tab: only a `scheduleRelatedLinks.json` helper
  loads, no play feed. The `.xml?view=plays` URL returns rendered HTML, not raw
  XML. So parsing the HTML table is the correct and only path. Do not spend time
  hunting for an API.
- **ncaa.com is not usable.** Its page is JavaScript-rendered, and the old
  `data.ncaa.com/casablanca/game/{id}/pbp.json` endpoint is dead (returns
  NoSuchKey). Don't build on it or on third-party wrappers.
- Boxscore URL pattern:
  `https://www.d3football.com/seasons/{year}/boxscores/{id}.xml`
  with `?view=plays` (play-by-play) and `?view=drives` (drive summary,
  carries QTR and drive-start clock).
- d3football blocks default user agents, so requests must send a browser
  User-Agent (already handled in `fetch_html`).
- The plays page has three tables: a header block, a line score (6 cols), and
  the play-by-play (2 cols: `situation`, `play`).
- **2025 markup quirk:** the situation text contains a newline, e.g.
  `"1st\n and 10 at CMU35"`. All parsing must `str_squish` first. Yardlines are
  written inconsistently: `"CMU35"` (no space) and `"UC 25"` (with a space), so
  any yardline pattern needs an optional space.

## Where things are

- `R/season_index.R` — `build_season_index(season)`: one row per game in a
  season (game_id, season, game_date, week, season_type, home, away,
  boxscore_url, plus provenance), scraped from the weekly composite
  scoreboard (`/scoreboard/{season}/composite?view=N`, throttled 3 s) and
  cached to `data-raw/index/{season}.csv` (reused unless `refresh = TRUE`).
  `index_team_games(index, team)` filters it to one team: this is how to list
  any team's games (e.g. the Centennial teams next). `season_type` uses
  `data-raw/season_dates.csv` (`season, regular_season_end, source`; 2020 =
  NA, all regular; 2019-2025 from Wikipedia infoboxes verified vs NCAA).
  `ensure_season_dates()` adds a missing season from its Wikipedia infobox
  (`source = "wikipedia"`, logged: verify it), and `check_season_dates()`
  warns when a date isn't two Saturdays before Thanksgiving (2023's Sunday
  Nov 12 is the known, harmless exception). Season always comes from the `/seasons/{year}/` URL path,
  never the date; postseason weeks restart at 1. d3 has no round or bowl
  labels.
- `R/conferences.R` — season-specific conference data for a given set of
  teams: `build_conference_table(season, teams)` reads each team's page once
  for its conference that season and d3's "*" conference-game markers;
  cached to `data-raw/conferences/{season}.csv` and
  `{season}_schedule_markers.csv`. `conference_members(season, code)`,
  `index_games_for_teams(index, teams)`. Only fetch the teams in scope (for
  2025: Centennial teams + their opponents), never every conference.
- `R/build_season.R` — **the one pipeline**: `build_season(season, teams =
  NULL, max_requests = Inf)`. It takes the season index, filtered to games
  involving `teams` (e.g. a conference's members) or every game when NULL,
  builds the conference table and every game into `analysis/pbp/{season}/`,
  and writes `analysis/checks/{season}/build_report.md`. Each call also
  rebuilds every game already in the season folder, so the folder and
  reports always cover all games built so far. Resumable: cached pages are
  reused; pages not fetched (budget, rate limit) are listed as pending.
  CLI: `Rscript analysis/build_season.R 2025 [--conference CC]
  [--max-requests N]`, with `OFFLINE=1` for cache only. The roadmap stages
  (Centennial, all D3, other seasons) are just different `teams` /
  `season` arguments, not separate pipelines.
- **Fetching:** `fetch_html()` caches every page in `data-raw/cache/`
  (gitignored) and throttles requests package-wide (`build_season()` uses
  6 s); a page is never requested twice. `options(d3ballR.max_requests = N)`
  caps requests per run, and after the first refusal (HTTP 459 / empty page)
  the rest of the run uses the cache only. d3football starts returning empty pages after a
  burst of requests, so keep runs small and resumable. When it does, stop and
  retry later rather than hammering it (`options(d3ballR.offline = TRUE)`
  makes any uncached request fail instead).
- `R/scrape_plays.R` — Step 1: `fetch_html`, `tables_on`, `find_plays`, and
  the exported `scrape_plays(game_url)` (clean 2-column `situation`/`play`
  tibble).
- `R/classify.R` — Step 2 row classifier (`classify_plays`).
- `R/parse_play_type.R` — play_type within snaps.
- `R/build_pbp.R` — per-game assembly: `build_pbp()` (one game) and
  `build_all_pbp()` (called by `build_season()`; writes the per-game CSVs,
  `pbp_row_counts.csv` and the validation reports). Also situation parsing, `yards_to_goal`,
  `Goal_To_Go`, `yards_gained`, and the output column order (`pbp_columns`).
- `R/teams.R` (header / team-name mapping), `R/kickoffs.R` (kickoff
  possession), `R/drives.R` (drives, try phase), `R/scores.R` (score lines),
  `R/parse_penalties.R`, `R/parse_outcomes.R` (outcome flags),
  `R/game_state.R` (score, first downs, end state, drive_result),
  `R/parse_clock.R` (clock), `R/validation.R` (`write_pbp_checks()`).
- `data-raw/cmu_2025_games.R` — the 11 CMU 2025 boxscore URLs (the
  validation set; the same list is `index_team_games(build_season_index(2025),
  "Carnegie Mellon")`).
- `data-raw/index/{season}.csv` — cached season indexes (2025 built).
- `data-raw/season_dates.csv` — regular-season end date per season.
- `analysis/pbp/{season}/` — the built per-game CSVs (67 columns), one
  folder per season. `analysis/pbp/2025/` will hold every 2025 game; it
  currently has the 62 Centennial games. Data dictionary:
  `analysis/pbp_schema.md`. Latest change log: `analysis/CHANGELOG_v3.md`.
  Current build plan: `analysis/pbp_build_plan_v3.md`.
- `analysis/checks/{season}/` — that season's reports, regenerated on every build
  (`build_report.md`, `pbp_row_counts.csv`, `score_reconciliation.csv`,
  `conference_check.csv`, `build_failures.csv`, and those below)
  (kickoff possession, drive-footer clock, clock bounds, end state), plus
  `season_index.md` from `analysis/season_index_report.R`.
- `tests/testthat/` — unit tests.

## What is built vs. next

Built (validated on all 11 CMU 2025 games, but generic): season index ->
scrape -> classify -> play type -> a 57-column, cfbfastR-aligned per-play
table. It starts with `season`, `game_date`, `week`, `season_type` from the
season index, then `home`, `away`, `home_team_conference`,
`away_team_conference`, `conference_game` (d3's "*" marker). Each game's
points by team must match the boxscore final
(`tests/testthat/test-score-reconciliation.R`). New-series flags
(`firstD_by_kickoff`, `firstD_by_poss`, `firstD_by_yards`,
`firstD_by_penalty`, `new_series`) sit on the first snap row of each new
series, which can be a penalty_no_play row (never the causing play, a kickoff
row, or a replay of the same down after a no-play penalty) and are mutually exclusive by cause
(kickoff > poss > yards > penalty); how and why that differs from
cfbfastR is in `analysis/CHANGELOG.md`, and `analysis/checks/{season}/first_downs.md`
checks them against the next snap's situation. Clock columns: `clock_start` / `clock_end` exact or NA;
`clock_start_max` / `clock_start_min` always bound the snap clock (they use
every reading, including the "(MM:SS)" clock some stat crews print on each
play, which is a bound, not the snap time); `secs_remaining_*` mirror them as
seconds left in the game. Known open item: `yards_gained`
on plays with a lateral reads only the first yardage segment. It has possession (kickoffs =
receiving team), drives and drive results, score before each play, down /
distance / yards to goal and the end state after the play, outcome flags,
first downs, penalties (signed, no-play gated), and the clock as exact
start/end where known plus always-filled upper/lower bounds. See
`analysis/pbp_schema.md` for every column and `analysis/CHANGELOG_v3.md` for
the judgment calls.

Known open items: `yards_gained` is undefined for interceptions, punts, field
goals and kickoffs; UW-La Crosse "Penalty after touchdown before PAT" marker
rows (plays 106, 161) are still kept; first downs in the 7 games that never
print "1ST DOWN" are rule-derived; only the 2025 season index is built
(other seasons' week pages may differ; check them when indexing). Next on the
roadmap: all of D3 2025. Building more games keeps surfacing new StatCrew
formats (different team codes, overtime); the score-reconciliation test is
the main guard. Fetch in small batches (about 10 pages, 6 s apart):
d3football rate-limits (HTTP 459 / empty pages) after a few dozen
requests. Not built (by design): EPA / win
probability, player names, drive-level rollups.

## Classifier design (Step 2, built)

**Approach: positive identification.** A row is a `play` only if its situation
is a real down-and-distance AND its description contains a snap verb (rush,
pass, sacked, punt, field goal, kneel). Do NOT try to blocklist every kind of
non-play — that is what previously let the coin-toss and quarter-start rows leak
in. Those rows carry a valid down-and-distance in column 1 but no play verb in
the description, so a situation-only rule miscounts them.

Non-plays that carry a real down-and-distance (must NOT be counted as plays):
quarter start ("Start of 1st quarter, clock 15:00" — repeats the current
down-and-distance), coin toss, drive start ("... drive start at 15:00"),
timeout, spot corrections ("CMU ball on UC 19").

Every non-play still gets a labeled type (drive_start, drive_header,
drive_footer, quarter, kickoff, extra_point, score, timeout, admin, nav,
penalty_no_play). Nothing should land silently in `other` — `other` is the
unknown bucket and must come back empty.

Ordering matters in the `case_when`: the play rule first; `penalty_no_play`
after it (so nullified snaps, which have a verb, stay `play`, and only
dead-down penalties with no snap become `penalty_no_play`); `drive_start`
before `drive_header` (so "TEAM drive start at MM:SS" doesn't match the header
pattern).

Known refinement already identified: do NOT lump two-point conversions in with
extra points — a two-point try is a scrimmage snap, not a kick. Give it its own
`two_point` label. Game 1 has no two-point tries, so that rule is unvalidated
until we hit a game with one.

## How to build the classifier: surface, don't guess

The right way to harden the classifier is to run it over ALL eleven CMU 2025
games and collect what it can't classify, not to guess rules from one game.

- Fill in the 11 game URLs, run `scrape_plays()` on each, apply the classifier,
  and **show every row that lands in `other`, plus the row-type counts per
  game.** That output is what we design rules against.
- Do NOT finalize classification rules unsupervised. Surface the unclassified
  and ambiguous rows and propose rules; Sam confirms each against football
  reality and the CMU schema. Judgment calls (like the two-point/extra-point
  case) must be checked, not papered over.
- Sanity checks per game: `other` empty; play count in the rough range of a
  full game's combined scrimmage snaps for both teams (~130–160 incl. punts and
  field goals); first several `play` rows are actual snaps.

## CMU schema (the validation target)

CMU's internal data logs one row per play with these columns:
`side_of_ball, quarter, play_idx, down, ytg, field_pos, yards_gained,
play_category, play_result, opponent`.

Decoded from game 1:
- `side_of_ball` — from CMU's perspective: `K` (kicking unit), `O` (CMU
  offense), `D` (CMU defense). Derive by comparing the possessing team to CMU.
- `play_idx` — a continuous, whole-game counter over ALL rows (kickoffs,
  penalties, PATs included), does not reset.
- `field_pos` — signed yardline: negative on the offense's own side, positive on
  the opponent's side, from the ball-carrying offense's perspective (own 25 =
  -25, opponent 48 = +48). NOT distance-to-goal. Our yardline parse must
  reproduce this sign convention.
- `play_category` values seen: KO, Pass, Run, Penalty, Punt Rec, Extra Pt.
  Map our labels onto these (KO=kickoff, Run=rush, Extra Pt.=extra_point,
  Penalty=penalty_no_play, etc.).
- `play_result` — sub-detail (Fair Catch, Complete, Incomplete, Rush, Return,
  Good, "Complete, TD").

**CMU includes kickoffs as rows** (with NA down/ytg/field_pos), so keep kickoffs
as their own labeled type and include them in the comparison.

### Penalty convention (decided)

Match CMU's `yards_gained` convention: **play yards only, penalty enforcement
yards excluded.** (Example: a 10-yard catch plus an 11-yard face mask logs
`yards_gained = 10`.) But CMU's data DROPS the penalty entirely — no row, no
yardage — which is a gap in their data, not ours. So preserve penalty context in
our own columns that CMU lacks: `has_penalty` (logical), `penalty_yards`
(numeric, NA if none), `penalty_text` (raw penalty clause). This lets a
mismatch be attributed to a CMU recording gap rather than a parser error. These
fields are extracted in the play-description parse (step 4), not the classifier.

Open item, not yet built: whether to also record a penalty's effect on
down/distance for the next row. Flag when it causes a mismatch; don't build
speculatively.

## Conventions

- Package name is `d3ballR` (valid R name). The repo/folder may differ; keep the
  `Package:` line valid (no underscores/hyphens).
- Package code in `R/` uses explicit `pkg::fn()` calls and roxygen `#'` headers.
  As the package grows, put the classifier in its own file (e.g.
  `R/classify.R`) rather than overloading `scrape_plays.R`.
- Keep raw `situation`/`play` text in parsed output so any derived field can be
  traced back to its source, which is essential for the CMU comparison.
- Prefer vectorized transforms (one `mutate` per stage, forward-fill for state)
  over row-by-row loops — easier to read and debug.
- Commit at natural stopping points with clear messages.
- Sam maintains a separate companion doc explaining each function step by step;
  when you add a function, note what it does, its inputs/outputs, and any
  gotchas so that doc can be updated.

## Working style with Sam

- Sam is learning the tooling as he goes; explain what code does when it's new,
  don't just produce it.
- Run code and show the ACTUAL printed output (especially the `other` rows and
  counts), don't just summarize what it would do.
- Be honest when the parser vs. CMU disagree — it is sometimes CMU's data that
  is wrong or lossy, not the parser.
