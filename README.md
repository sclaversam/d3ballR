# d3ballR

Scrape and parse **NCAA Division III** college football play-by-play data from
d3football.com into tidy, per-play tables.

## Why this exists

The existing college football data ecosystem stops at Division I. `cfbfastR`
and the CollegeFootballData API cover only FBS and FCS (division codes 11 and
12); Division II and III are absent from every published dataset and package.
This package fills that gap, starting with Carnegie Mellon and the Centennial
Conference.

The coverage gap is documented in `analysis/cfbfastr_d2_d3_coverage_audit.Rmd`.

## Status

Built generically for any d3football game and season; validated on all 11
Carnegie Mellon 2025 games:

- **Scrape** (`scrape_plays()`): fetch a game's play-by-play table from
  d3football.com as a clean two-column tibble (`situation`, `play`).
- **Index** (`build_season_index()`): every game in a season (date, week,
  regular/postseason, teams, boxscore URL) from d3football's weekly
  scoreboard, cached in `data-raw/index/`.
- **Build** (`build_pbp()` / `build_all_pbp()`): classify rows, parse them,
  and assemble one 57-column, cfbfastR-aligned row per play. It covers
  possession, drives, score, down / distance / yards to goal, outcome flags,
  first downs, penalties, and clock. Output is in `analysis/pbp/`, with the
  data dictionary in `analysis/pbp_schema.md` and validation reports in
  `analysis/checks/`.

Roadmap: Centennial Conference 2025, then all of D3 2025, then other seasons.

## Source notes

- d3football serves the play-by-play in the rendered HTML table only; there is
  no separate structured XML/JSON feed (verified via the browser Network tab).
- Boxscore URL pattern:
  `https://www.d3football.com/seasons/{year}/boxscores/{id}.xml`
  with `?view=plays` and `?view=drives` for the two views.

## Layout

- `R/` package functions
- `analysis/` notebooks (coverage audit, single-game parser walkthrough)
- `data-raw/` raw inputs and scraping scripts
- `tests/` unit tests
