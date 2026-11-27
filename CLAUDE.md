# CLAUDE.md

Briefing for Claude Code working in this repo. Read this first, then the docs
it points to.

## What this project is

`d3ballR` scrapes and parses **NCAA Division III** football play-by-play from
ncaa.com into tidy, cfbfastR-style tables. `cfbfastR` and the
CollegeFootballData API cover only Division I; D2 and D3 are absent from every
published dataset (`docs/cfbfastr_d2_d3_coverage_audit.Rmd`).

The author (Sam) is a CMU statistics and machine learning student. Scope is the
scraper: accurate, tidy play-by-play. Modeling (EPA, win probability) is out of
scope for now.

**Roadmap:** CMU 2025 (done) → Centennial Conference 2025 (done; checkpoint
tag `checkpoint-centennial-2025`) → all of
D3 2025 (done 2026-11-17: all 1,263 games, 9 of them from saved
stats.ncaa.org pages; 1,262 reconcile) → package release (2026-11-27:
users get `load_d3_pbp()`, `load_d3_games()`, `build_season()`; everything
else is internal) → other seasons. After any change to the output, rerun
`Rscript scripts/release_season.R 2025` and re-upload the release file
(`docs/pipeline.md`, "Releasing a season").
Everything in `R/` must stay generic: no code may assume a team or a season.
Each roadmap stage is the same `build_season()` call with a different `teams`
filter or `season`, not a new pipeline.

## Read these

- `docs/schema.md`: every output column (68) and the conventions for reading
  them. Keep it in sync with `pbp_columns` in `R/build_pbp.R`.
- `docs/pipeline.md`: stages and code map, how to run, fetching rules,
  validation reports, known issues, roadmap.
- `docs/CHANGELOG.md`: history and decisions (including every divergence from
  cfbfastR). Add an entry for each change to the output.

## Source facts (confirmed, do not re-litigate)

- **ncaa.com is the source** (decided by Sam, 2026-11-04). Play-by-play is
  read as JSON straight from ncaa.com's data server, `sdataprod.ncaa.com`
  (`R/ncaa.R`: `fetch_ncaa_json()`, `ncaa_direct_request()`), with the
  requests the `henrygd/ncaa-api` wrapper makes; until 2026-11-08 it went
  through that wrapper in Docker, still possible with
  `options(d3ballR.ncaa_api = "http://127.0.0.1:3000")`. Paths (also the
  cache file names): `/scoreboard/football/d3/{year}/{week}/all-conf`,
  `/game/{contest}/play-by-play`. Every response is cached in
  `data-raw/cache/ncaa/` (gitignored). An ncaa.com 502 means the game's
  play-by-play isn't available yet; it stays pending.
- **Terms of use:** keep requests few, cached and throttled.
- **The game list is ncaa.com's** (decided by Sam, 2026-11-16):
  `ncaa_season_games()` reads the season's cached D3 scoreboards into
  `data-raw/ncaa/{season}_games.csv`, and `game_id` is the ncaa.com contest
  id ("6461490"), the file name in `pbp/{season}/`. Placeholder contests
  dated outside the season and second listings of the same game are
  dropped. Team names are ncaa.com's short names and `week` is ncaa.com's
  scoreboard week (decided by Sam, 2026-11-17). CHANGELOG entries before
  2026-11-16 use an older id scheme ("6461445").
- **ncaa.com's play text is StatCrew text**: `ncaa_play_table()` turns the
  JSON into the (situation, play) table the parser reads, the layout of a
  StatCrew play-by-play page. Its quirks, all handled there:
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
  - Some playoff games are a different StatCrew file from the regular one.
  - The 2025 national semifinal Johns Hopkins at UW-River Falls (contest
    6529905) tags every line with one team and has no
    drive-start lines or running score, so possession can't be read. Its
    plays are all there.
  - The 2025 Stagg Bowl (UW-River Falls 24, North Central 14, 2026-01-04)
    is contest 6534822; ncaa.com also lists a placeholder 6529906 dated
    2025-01-04, dropped from the game list.
- **stats.ncaa.org is a hand-fed fallback** (Sam, 2026-11-17), only for
  games with no ncaa.com play-by-play, that can't be built, or whose
  stats.ncaa.org version reconciles when ncaa.com's doesn't
  (`pull_from_stats_ncaa` in `data-raw/ncaa/{season}_stats_ncaa_candidates.csv`).
  Sam saves the pages from his browser into `data-raw/stats_ncaa/`, and
  `R/stats_ncaa.R` reads them.
- **Conferences come from ncaa.com's scoreboards:** each team's
  `conferences[].conferenceSeo` tag, named through
  `inst/extdata/conference_names.csv` (a name and code per tag). ncaa.com
  has no conference-game marker, so a conference game is a regular-season
  game between two teams of the same conference.
- **User-Agent:** `fetch_ncaa_json()` sends "d3ballR (CMU student
  research)". Every request goes through the shared counter and throttle in
  `R/fetch.R`.
- **Rate limiting:** fetch in capped batches (`max_requests`), 6 s apart.
  Prefer `OFFLINE=1` / the cache when iterating on parsing, and don't run
  large fetches without Sam's go-ahead.
- **StatCrew output varies by host school:** team codes, spellings, whether
  "1ST DOWN" is printed, per-play clocks. Expect new variants with new
  games, and handle them generically, never per team.

## Working rules

- **Validate against the data, not one game.** After any parser change,
  rebuild from the cache (`OFFLINE=1 Rscript scripts/build_season.R 2025`)
  and check `checks/2025/` (score reconciliation must stay at every game
  but the known source gaps; the series and clock checks must stay clean
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
- Be honest about disagreements and limits. When the source's data is wrong (a source
  quirk), say so and label it, rather than bending the parser.
- Sam maintains a companion doc explaining each function. When you add a
  function, note what it does, its inputs / outputs, and any gotchas.
