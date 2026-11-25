# d3ballR

Play-by-play data for **NCAA Division III football**, read from ncaa.com
into tidy, cfbfastR-style tables.

The college football data ecosystem stops at Division I: `cfbfastR` and the
CollegeFootballData API cover only FBS and FCS. Division II and III are absent
from every published dataset
([coverage audit](docs/cfbfastr_d2_d3_coverage_audit.Rmd)). d3ballR fills that
gap for Division III.

## Status: the 2025 season

- **Coverage:** every game on ncaa.com's 2025 Division III scoreboards:
  1,263 games, regular season through the Stagg Bowl.
- **Shape:** one row per event, 67 columns ([schema](docs/schema.md)). Names
  follow cfbfastR where an equivalent exists.
- **Checks:** 1,262 of 1,263 games' play-by-play points reconcile with the
  final score (the other is missing its 4th quarter at the source), and every
  validation report is clean or explains its exceptions.
- **Generic:** nothing assumes a team or season.

## Quick start

```r
# install.packages("devtools")
devtools::load_all()

# one game (ncaa.com contest id; the game list is data-raw/ncaa/2025_games.csv)
games <- ncaa_season_games(2025)
g <- build_pbp(fetch_ncaa_game("6461445", ncaa_contest_table(games), games), index = games)

# a season, or the games involving some teams
conf <- read.csv("data-raw/ncaa/2025_conferences.csv")
build_season(2025, teams = conf$team[conf$conference_code %in% "CC"])   # writes pbp/2025/ and checks/2025/
```

Or read the built CSVs directly: `read.csv("pbp/2025/6461445.csv",
na.strings = "")`.

## What's in each row

| Group | Columns |
|---|---|
| Game | `game_id`, `season`, `game_date`, `week`, `season_type`, `home`, `away`, conferences, `conference_game` |
| Drive and clock | `drive_number`, `period`, exact snap and end clocks, the snap-clock range, seconds remaining |
| Situation | possession, score before the play, `down`, `distance`, `yards_to_goal`, `Goal_To_Go`, and the next snap's situation |
| Play | `play_type`, `yards_gained`, outcome flags (rush, pass, sack, turnover, touchdown, ...), scoring, `drive_result` |
| Series | `new_series` |
| Penalties | signed yards, penalized team, no-play, declined, raw text |
| Audit | raw `situation`, raw `play_text` |

Every column is defined in **[docs/schema.md](docs/schema.md)**.

## Repository layout

```
R/                 package code (pipeline stages; see docs/pipeline.md)
tests/testthat/    unit tests + data tests over every built game
scripts/           build_season.R
pbp/{season}/      built play-by-play, one CSV per game
checks/{season}/   validation reports for that season
data-raw/          ncaa.com game lists and conference tables, known source gaps, saved stats.ncaa.org pages (response cache: gitignored)
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

CMU 2025 → Centennial Conference 2025 → all of D3 2025 (done) → a data
loader and a package release → other seasons.
