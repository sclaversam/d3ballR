# CLAUDE.md

Briefing for Claude Code working in this repo. Read this first, then the docs
it points to.

## What this project is

`d3ballR` scrapes and parses **NCAA Division III** football play-by-play from
d3football.com into tidy, cfbfastR-style tables. `cfbfastR` and the
CollegeFootballData API cover only Division I; D2 and D3 are absent from every
published dataset (`docs/cfbfastr_d2_d3_coverage_audit.Rmd`).

The author (Sam) is a CMU statistics and machine learning student. Scope is the
scraper: accurate, tidy play-by-play. Modeling (EPA, win probability) is out of
scope for now.

**Roadmap:** CMU 2025 (done) → Centennial Conference 2025 (done; checkpoint
tag `checkpoint-centennial-2025`; rebuilt from ncaa.com 2026-11-04) → all of
D3 2025 from ncaa.com → other seasons.
Everything in `R/` must stay generic: no code may assume a team or a season.
Each roadmap stage is the same `build_season()` call with a different `teams`
filter or `season`, not a new pipeline.

## Read these

- `docs/schema.md`: every output column (71) and the conventions for reading
  them. Keep it in sync with `pbp_columns` in `R/build_pbp.R`.
- `docs/pipeline.md`: stages and code map, how to run, fetching rules,
  validation reports, known issues, roadmap.
- `docs/CHANGELOG.md`: history and decisions (including every divergence from
  cfbfastR). Add an entry for each change to the output.

## Source facts (confirmed, do not re-litigate)

- **ncaa.com is the source** (decided by Sam, 2026-11-04). Play-by-play is
  read as JSON through the open-source `henrygd/ncaa-api` wrapper, run
  locally on Sam's Mac as the Docker container `ncaa-api` on
  `127.0.0.1:3000` (`R/ncaa.R`, `fetch_ncaa_json()`). Endpoints:
  `/scoreboard/football/d3/{year}/{week}/all-conf` and
  `/game/{contest}/play-by-play`. Every response is cached in
  `data-raw/cache/ncaa/` (gitignored). An ncaa.com 502 means the game's
  play-by-play isn't available yet; it stays pending.
- **Terms of use:** NCAA's terms forbid scraping without permission. Sam was
  advised to ask his professor; keep requests few, cached and throttled.
- **The d3football season index stays the game list** (`game_id` is still
  d3football's boxscore id). `map_ncaa_contests()` pairs each index game with
  its ncaa.com contest (same teams via `data-raw/ncaa/team_names.csv`, dates
  at most a day apart) into `data-raw/ncaa/{season}_contests.csv`. 2025:
  1,237 of 1,243 matched; the rest are non-NCAA bowls and one date mismatch.
- **ncaa.com's play text is the same StatCrew text** as d3football's, so the
  parser is unchanged: `ncaa_play_table()` rebuilds d3football's
  (situation, play) table from the JSON. Its quirks, all handled there:
  - `driveText` ("2 and 9 at 28") has no yardline team; the side is recovered
    from spots in the play text. Tournament games use "2 and  at JHU13"
    (distance often blank, recomputed from the line to gain).
  - It drops many extra-point lines; one is added, labelled
    "[added by d3ballR: ...]" in `play_text`, only when the running score
    proves a point is missing.
  - Some host schools' files (CMU home games) have no running score. For
    those, `/game/{contest}/scoring-summary` (one more request per game)
    lists every good try after its touchdown ("XP", "TPC"; failed tries are
    absent), and it decides; the final score is a last resort. The box
    score's `patAttempted` is unreliable (0 with 5 made); don't use it.
  - `teamId` is unreliable on single lines (a punt can carry the receiver's
    id), so drives open at "drive start" lines.
  - Some kickoffs are dropped; no drive footers ("N plays, Y yards").
  - Some playoff games are a different StatCrew file from d3football's.
  - Stagg Bowl 2025 (contest 6529905) tags every line with one team and is
    missing lines: not buildable.
- **Conferences come from ncaa.com's scoreboards:** each team's
  `conferences[].conferenceSeo` tag, named through
  `data-raw/ncaa/conference_names.csv` (d3football's names and codes).
  ncaa.com has no conference-game marker, so a conference game is a
  regular-season game between two teams of the same conference; it matches
  d3football's "*" marker on all 58 Centennial 2025 games.
- **d3football.com is now cache-only.** Its firewall serves scripts a
  JavaScript bot challenge. Do not try to get around it: no browser
  automation, no reusing browser cookies such as `aws-waf-token`.
  `build_season(..., source = "d3football")` still rebuilds the 133 cached
  2025 games into `pbp/d3football/2025/` (kept for comparison).
- **User-Agent:** `fetch_html()` sends a browser one (d3football);
  `fetch_ncaa_json()` sends "d3ballR (CMU student research)".
- **Rate limiting:** fetch in capped batches (`max_requests`), 6 s apart.
  Prefer `OFFLINE=1` / the cache when iterating on parsing, and don't run
  large fetches without Sam's go-ahead.
- **StatCrew output varies by host school:** team codes, spellings, whether
  "1ST DOWN" is printed, per-play clocks. Expect new variants with new
  games, and handle them generically, never per team.

## Working rules

- **Validate against the data, not one game.** After any parser change,
  rebuild from the cache (`OFFLINE=1 Rscript scripts/build_season.R 2025
  --conference CC`, and `--source d3football` for the cached d3football
  games) and check `checks/2025/` and `checks/d3football/2025/` (score
  reconciliation must stay 100%; the series and clock checks must stay clean
  or explained), then run `devtools::test()`. Run R with a UTF-8 locale
  (`LC_ALL=C.UTF-8` in the cloud) or accented names are written as
  `<U+00F6>`.
- **Surface, don't guess.** When a rule is a judgment call, show the affected
  rows and ask; record decisions in `docs/CHANGELOG.md`.
- **Keep raw text.** Keep `situation` / `play_text` in the output so every
  derived value can be traced to its source.
- **Code style:** package code uses explicit `pkg::fn()` calls and roxygen
  `#'` headers. Run `devtools::document()` after changing exports. Prefer
  vectorized transforms.
- **Commits:** commit at natural stopping points with clear messages.

## Working style with Sam

- Sam is learning the tooling as he goes. Explain what new code does; don't
  just produce it.
- Run code and show the actual output (counts, exceptions), not a summary of
  what it would do.
- Be honest about disagreements and limits. When d3's data is wrong (a source
  quirk), say so and label it, rather than bending the parser.
- Sam maintains a companion doc explaining each function. When you add a
  function, note what it does, its inputs / outputs, and any gotchas.
