# d3ballR

Play-by-play data for **NCAA Division III football**, scraped from
d3football.com into tidy, cfbfastR-style tables.

The college football data ecosystem stops at Division I: `cfbfastR` and the
CollegeFootballData API cover only FBS and FCS. Division II and III are absent
from every published dataset
([coverage audit](docs/cfbfastr_d2_d3_coverage_audit.Rmd)). d3ballR fills that
gap for Division III.

## Status: checkpoint Centennial Conference 2025

- **Coverage:** every 2025 game involving a Centennial Conference team, 62 games
  (10 postseason, 1 overtime). That's 10,149 rows across 36 teams.
- **Shape:** one row per event, 67 columns. Names follow cfbfastR where an
  equivalent exists.
- **Checks:** every game's play-by-play points reconcile with its boxscore
  final score, and every validation report is clean or explains its exceptions.
- **Generic:** nothing assumes a team or season. Building all of D3 2025 is
  the same call without a filter.

## Quick start

```r
# install.packages("devtools")
devtools::load_all()

# one game
g <- build_pbp("https://www.d3football.com/seasons/2025/boxscores/20250906_e064.xml")

# a season, or the games involving some teams
members <- conference_members(2025, "CC")$team
build_season(2025, teams = members)   # writes pbp/2025/ and checks/2025/
```

Or read the built CSVs directly: `read.csv("pbp/2025/20250906_e064.csv",
na.strings = "")`.

## What's in each row

| Group | Columns |
|---|---|
| Game | `game_id`, `season`, `game_date`, `week`, `season_type`, `home`, `away`, conferences, `conference_game` |
| Drive and clock | `drive_number`, `period`, exact snap and end clocks, the snap-clock range, seconds remaining |
| Situation | possession, score before the play, `down`, `distance`, `yards_to_goal`, `Goal_To_Go`, and the next snap's situation |
| Play | `play_type`, `yards_gained`, outcome flags (rush, pass, sack, turnover, touchdown, ...), scoring, `drive_result` |
| Series | `firstD_by_kickoff` / `_poss` / `_yards` / `_penalty`, `new_series` |
| Penalties | signed yards, penalized team, no-play, declined, raw text |
| Audit | raw `situation`, raw `play_text` |

Every column is defined in **[docs/schema.md](docs/schema.md)**.

## Repository layout

```
R/                 package code (pipeline stages; see docs/pipeline.md)
tests/testthat/    unit tests + data tests over every built game
scripts/           build_season.R, season_index_report.R
pbp/{season}/      built play-by-play, one CSV per game
checks/{season}/   validation reports for that season
data-raw/          season dates, season index, conference tables (page cache: gitignored)
docs/              schema.md, pipeline.md, CHANGELOG.md, coverage audit
```

## Docs

- **[docs/schema.md](docs/schema.md):** every column, and the conventions for
  reading them.
- **[docs/pipeline.md](docs/pipeline.md):** how the pipeline works, how to run
  it, what's checked, known issues, and the roadmap.
- **[docs/CHANGELOG.md](docs/CHANGELOG.md):** how it got here, and the
  decisions made along the way.

## Roadmap

CMU 2025 (done) → Centennial 2025 (done, this checkpoint) → all of D3 2025 →
other seasons.
