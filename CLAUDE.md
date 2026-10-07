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
tag `checkpoint-centennial-2025`) → all of D3 2025 → other seasons.
Everything in `R/` must stay generic: no code may assume a team or a season.
Each roadmap stage is the same `build_season()` call with a different `teams`
filter or `season`, not a new pipeline.

## Read these

- `docs/schema.md`: every output column (67) and the conventions for reading
  them. Keep it in sync with `pbp_columns` in `R/build_pbp.R`.
- `docs/pipeline.md`: stages and code map, how to run, fetching rules,
  validation reports, known issues, roadmap.
- `docs/CHANGELOG.md`: history and decisions (including every divergence from
  cfbfastR). Add an entry for each change to the output.

## Source facts (confirmed, do not re-litigate)

- **d3football.com is the only source.** The play data is in the rendered HTML
  table of `https://www.d3football.com/seasons/{year}/boxscores/{id}.xml?view=plays`.
  There is NO structured XML/JSON feed (checked in the browser Network tab).
- **ncaa.com is not usable:** the page is JavaScript-rendered, and the
  `data.ncaa.com` JSON endpoint is dead.
- **User-Agent:** d3football blocks default user agents; `fetch_html()` sends a
  browser one.
- **Rate limiting:** d3football answers with HTTP 459 or empty pages after a
  burst of a few dozen requests. Fetch in capped batches (`max_requests`), 6 s
  apart. `fetch_html()` caches every page in `data-raw/cache/` (gitignored), so
  nothing is requested twice, and the rest of a run uses the cache after the
  first refusal. Prefer `OFFLINE=1` / the cache when iterating on parsing, and
  don't run large fetches without Sam's go-ahead.
- **StatCrew output varies by host school:** team codes, spellings, whether
  "1ST DOWN" is printed, per-play clocks. Expect new variants with new
  games, and handle them generically, never per team.

## Working rules

- **Validate against the data, not one game.** After any parser change,
  rebuild the season from the cache (`OFFLINE=1 Rscript scripts/build_season.R
  2025`) and check `checks/2025/` (score reconciliation must stay 100%; the
  series and clock checks must stay clean or explained), then run
  `devtools::test()`.
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
