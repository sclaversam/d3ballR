# d3pbp

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

Early development. Working so far:

- **Scrape** (`scrape_plays()`): fetch a game's play-by-play table from
  d3football.com and return it as a clean two-column tibble (`situation`,
  `play`). Selects the right table by content and fixes the whitespace quirks in
  the 2025 markup.

Next:

- **Classify** rows into plays vs. non-plays (kickoffs, drive starts, quarter
  markers, penalties, etc.), hardened across all 2025 Carnegie Mellon games.
- **Parse** the situation and play text into fields (down, distance, yardline,
  play type, yards, penalties).
- **Align** output to Carnegie Mellon's internal schema for validation.

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
