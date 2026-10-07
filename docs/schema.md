# Play-by-play schema (67 columns)

Every column of the per-game play-by-play CSVs in `pbp/{season}/{game_id}.csv`,
and the conventions needed to read them. How the files are built and checked
is in [`pipeline.md`](pipeline.md); how the schema got here is in
[`CHANGELOG.md`](CHANGELOG.md).

## What a file is

One file per game, **one row per event**, in game order. A row is one of:
- **a scrimmage snap**, including a snap wiped out by a penalty;
- **a kickoff**;
- **an extra point or two-point try**;
- **a dead-ball penalty with no snap** (false start, delay of game, ...).

Everything else on d3football's play-by-play page is read but not kept: quarter
markers, drive headers and summaries, timeouts, score lines, coin toss, spot
corrections. The pipeline uses those rows to work out the period, possession,
kickoff teams, score and clock.

Column names follow cfbfastR / nflfastR wherever an equivalent exists. Nothing
is specific to a team or season. The raw `situation` and `play_text` are kept
on every row, so any value can be traced back to its source.

## Reading a file

- **NA is an empty field.** Files are written with `write.csv(..., na = "")`,
  so read them with `read.csv(f, na.strings = "")`.
- **Types:** logical columns are `TRUE` / `FALSE`. `clock_*` columns are
  zero-padded `"MM:SS"` strings of time left in the quarter. `secs_remaining_*`
  columns are integers.
- **Team names** (`home`, `away`, `pos_team`, `def_pos_team`, `penalized_team`)
  use the season index's spelling, one name per team for the whole season.
  The raw `play_text` keeps each stat crew's own spelling and codes.

## Conventions

**Possession.** `pos_team` is the offense on a snap. On a **kickoff** it is the
**receiving** team, and `def_pos_team` is the kicking team, as in cfbfastR. On
punts and field goals the kicking team stays `pos_team`. A **try** (PAT or
two-point), and any penalty row between a score and the next kickoff, belongs
to the **scoring** team. The try's kicker or passer decides it when that player's team
is known from their other plays; otherwise the team that kicks off next, then
the score line.

**Drives.** A drive is one team's continuous possession. A kickoff is play 1 of
the receiving team's drive. A try stays on the drive of its scoring play, even
after a defensive touchdown. Each overtime possession is its own drive.

**`yards_gained` is play yards only.** It is the play's own "for N yards", read
from the text before any `PENALTY` clause; enforcement yardage never counts.
A 10-yard catch plus an 11-yard face mask is `yards_gained = 10` and
`penalty_yards_signed = +11`, never 21.

**Penalty sign.** `penalty_yards_signed` is from `pos_team`'s view: positive
means the defense was flagged, negative means the offense was. Only accepted
infractions count. Two accepted ones are summed; offsetting penalties are 0.

**No-play gating.** `penalty_no_play` is TRUE when the text says "NO PLAY" or
the row is a dead-ball penalty with no snap. d3 still prints the wiped-out
attempt in full ("... 54 yards ... TOUCHDOWN nullified by penalty ... NO
PLAY"), but none of it is credited:
- `yards_gained` is NA and `score_pts` is 0;
- every outcome flag is FALSE: `rush`, `pass`, `completion`, `sack`, `int`,
  `fumble_vec`, `turnover`, `downs_turnover`, `touchdown`, `safety`,
  `field_goal_attempt`, `field_goal_made`, `punt`, `scoring_play`.

**Score.** `pos_team_score` / `def_pos_team_score` are the score *before* the
play, summed from the parsed points of every earlier row. d3's printed score
lines are used only as a check (a stat crew sometimes skips one), and the
game total is reconciled against the boxscore final. A PAT's "before" score
includes its touchdown.

**Down, distance, field position.**
- `yards_to_goal` is the distance to the opponent's end zone (own 25 → 75).
- `Goal_To_Go` is TRUE when the line to gain is the goal line. d3 writes this
  either literally ("1st and Goal at CMU06") or as a number equal to the
  distance to the goal ("1st and 4 at UC 4"); both count.
- `down_end`, `distance_end` and `yards_to_goal_end` are the situation of the
  next snap in the half, from **that** snap's offense view. After a change of
  possession, it's the new offense's situation.

**New series.** `firstD_by_kickoff`, `firstD_by_poss`, `firstD_by_yards` and
`firstD_by_penalty` sit on the **first snap row of each new series** (the
1st-and-10 or 1st-and-goal row), never on the play that caused it.
- **First snap row:** it can be a `penalty_no_play` row, such as a false start
  right after a punt.
- **Replays:** a snap that replays the same down after a no-play penalty is
  never a series start.
- **One flag per series:** chosen by the cause, with precedence kickoff >
  poss > yards > penalty. `new_series` is TRUE when one of them is.
- **Unflagged rows:** kickoffs, tries and mid-series snaps are FALSE in all
  five.

**Clock.** Two kinds of clock column:
- **Exact or NA:** `clock_start` and `clock_end` are the game clock at the
  snap and when the play ended, filled only when known exactly.
- **Always a range:** `clock_start_max` and `clock_start_min` are the most and
  least time that could have been left at the snap. When `clock_start` is
  known, all three are equal.

The range uses every known reading:
- drive starts, timeouts, quarter starts, score clocks;
- the clock some stat crews print at the start of each play ("(11:25) Shotgun
  ..."), which always falls between that play's snap and end.

Readings that contradict the others are dropped. Nothing is interpolated.

`secs_remaining_*` are the same four values as integer seconds left in the
game: `(4 − period) × 900` plus the quarter clock. Overtime is untimed, so all
clock and seconds columns are NA in periods 5+.

**Season and week.**
- `season` comes from the boxscore URL (`/seasons/{year}/`), never from the
  date. A January championship and the 2020 season (played in spring 2021)
  are labeled correctly.
- `season_type` is `"postseason"` after the season's regular-season end date.
  NCAA playoff and bowl games are both postseason.
- `week` is d3's scoreboard week. Postseason weeks restart at 1, as in
  cfbfastR.

## Columns

| # | column | type | definition | NA behavior | notes |
|---|---|---|---|---|---|
| 1 | `game_id` | character | d3football boxscore id, e.g. `"20250906_e064"`. | Never NA. | Constant per file; joins to the season index. |
| 2 | `season` | integer | Season year. | Never NA. | From the boxscore URL path, never the date. |
| 3 | `game_date` | character | Game date, `YYYY-MM-DD`. | Never NA. | |
| 4 | `week` | integer | Week of the season. | Never NA. | d3 scoreboard week; postseason restarts at 1. Date-based if the game isn't in the season index (logged). |
| 5 | `season_type` | character | `"regular"` or `"postseason"`. | Never NA. | Postseason if `game_date` is after the regular-season end date (`data-raw/season_dates.csv`). All 2020 games are regular. |
| 6 | `home` | character | Home team. | Never NA. | Season-index spelling. |
| 7 | `away` | character | Away team. | Never NA. | Season-index spelling. |
| 8 | `home_team_conference` | character | Home team's conference that season, e.g. `"Centennial Conference"`. | NA for a team with no conference that season (independent, non-D3) or not yet looked up. | Membership is per season (Carnegie Mellon: PAC through 2024, Centennial from 2025). cfbfastR name. |
| 9 | `away_team_conference` | character | Away team's conference that season. | As `home_team_conference`. | cfbfastR name. |
| 10 | `conference_game` | logical | d3football marks it a conference game ("*" on the team schedule). | NA if neither team's schedule has been read. | From d3's marker, not shared membership, so playoff and bowl games between members are FALSE. cfbfastR name. |
| 11 | `play_index` | integer | Row order within the game, 1..N. | Never NA. | |
| 12 | `drive_number` | integer | Drive within the game, 1..N. | Never NA. | The opening kickoff starts drive 1. |
| 13 | `drive_play_number` | integer | Row's position within its drive, from 1. | Never NA. | A kickoff is always 1. |
| 14 | `period` | integer | Quarter 1-4; overtime periods 5, 6, ... | Never NA. | |
| 15 | `half` | integer | 1 for periods 1-2, 2 for periods 3+. | Never NA. | Overtime counts as the second half. |
| 16 | `clock_start` | character | Exact game clock at the snap (`"MM:SS"` left in the quarter). | NA when not known exactly; NA in overtime. | Known after a stop at a known reading (quarter start, timeout, drive start, score; carried through untimed rows to the next snap), or when the snap's range closes to one value. |
| 17 | `clock_end` | character | Exact game clock when the play ended. | NA when not known; NA in overtime. | The play's own "clock M:SS" (scores, field goals, some kickoffs), else, after a hand-over (punt, turnover, downs, missed / blocked FG, kickoff), the next drive's start time in the same quarter. |
| 18 | `clock_start_max` | character | The most time that could have been left at the snap. | Never NA in regulation; NA in overtime. | Latest known reading at or before the snap (15:00 if none). |
| 19 | `clock_start_min` | character | The least time that could have been left at the snap. | Never NA in regulation; NA in overtime. | Earliest known reading at or after the snap, including the play's own printed clock and `clock_end` (00:00 if none). |
| 20 | `secs_remaining_start` | integer | `clock_start` as seconds left in the game. | As `clock_start`. | `(4 − period) × 900` + quarter clock seconds. |
| 21 | `secs_remaining_end` | integer | `clock_end` as seconds left in the game. | As `clock_end`. | |
| 22 | `secs_remaining_start_max` | integer | `clock_start_max` as seconds left in the game. | NA in overtime. | |
| 23 | `secs_remaining_start_min` | integer | `clock_start_min` as seconds left in the game. | NA in overtime. | |
| 24 | `pos_team` | character | Team with the ball: the offense; the receiving team on a kickoff; the scoring team on a try. | Never NA. | Season-index spelling. |
| 25 | `def_pos_team` | character | The other team. | Never NA. | The kicking team on a kickoff. |
| 26 | `pos_team_score` | integer | `pos_team`'s score before the play. | Never NA. | |
| 27 | `def_pos_team_score` | integer | `def_pos_team`'s score before the play. | Never NA. | |
| 28 | `score_diff` | integer | `pos_team_score − def_pos_team_score`. | Never NA. | |
| 29 | `down` | integer | Down, 1-4. | NA on kickoffs and tries. | Parsed from `situation`. |
| 30 | `distance` | integer | Yards to go. | NA wherever `down` is NA. | On "and Goal" it is `yards_to_goal`. A PAT penalty can carry a placeholder "1st and 10". |
| 31 | `yards_to_goal` | integer | Yards to the opponent's end zone (own 25 → 75). | NA wherever `down` is NA. | |
| 32 | `Goal_To_Go` | logical | The line to gain is the goal line. | NA wherever `down` is NA. | Literal "and Goal", or `distance == yards_to_goal`. |
| 33 | `down_end` | integer | Down of the next snap in the half. | NA on scoring plays, tries, and when no snap follows in the half. | That snap's offense view. On a kickoff: the receiving team's first snap. |
| 34 | `distance_end` | integer | Distance of the next snap. | As `down_end`. | |
| 35 | `yards_to_goal_end` | integer | Yards to goal of the next snap. | As `down_end`. | After a punt, `yards_to_goal + yards_to_goal_end − 100` is the net punt. |
| 36 | `play_type` | character | What happened. Snaps: `rush`, `pass_complete`, `pass_incomplete`, `pass_intercepted`, `sack`, `kneel`, `punt_no_return`, `punt_with_return`, `punt_blocked`, `field_goal_good`, `field_goal_missed`, `field_goal_blocked`, `safety` (a row reading only "TEAM SAFETY", with no play described). Other rows: `kickoff`, `extra_point`, `two_point`, `penalty_no_play` (dead-ball penalty, no snap). | Never NA. | A snap wiped out by a penalty keeps its call (e.g. `pass_complete`); check `penalty_no_play`. |
| 37 | `scrimmage_play` | logical | The row has a down: a snap or a dead-ball penalty. | Never NA. | FALSE on kickoffs and tries. |
| 38 | `yards_gained` | integer | Yards gained on the play itself, penalty yardage excluded. | NA on no-play rows, and on interceptions, punts, field goals, kickoffs, tries (not defined yet). | Filled for `rush`, `pass_complete`, `sack`, `kneel`; 0 for `pass_incomplete`. |
| 39 | `rush` | logical | Designed run: `rush` or `kneel`. | Never NA. | A sack is not a rush here (NCAA counts it as one). |
| 40 | `pass` | logical | Pass attempt: complete, incomplete, or intercepted. | Never NA. | Sacks and two-point passes are FALSE. |
| 41 | `completion` | logical | Completed pass. | Never NA. | |
| 42 | `sack` | logical | QB sacked. | Never NA. | |
| 43 | `int` | logical | Interception. | Never NA. | Always also `turnover`. |
| 44 | `fumble_vec` | logical | A fumble or muff, whoever recovered. | Never NA. | |
| 45 | `turnover` | logical | Possession lost by interception, lost fumble, turnover on downs, or a kickoff the kicking team recovered. | Never NA. | A blocked kick the kicking team gets back is not a turnover. Punts and field goals are not turnovers. |
| 46 | `downs_turnover` | logical | Turnover on downs. | Never NA. | "TURNOVER ON DOWNS" in the text, or a 4th-down play short of the line with the next snap by the other team. |
| 47 | `touchdown` | logical | A touchdown that counts. | Never NA. | Includes defensive return touchdowns. |
| 48 | `safety` | logical | A safety. | Never NA. | |
| 49 | `field_goal_attempt` | logical | Field goal attempted (good, missed, or blocked). | Never NA. | |
| 50 | `field_goal_made` | logical | Field goal good. | Never NA. | |
| 51 | `punt` | logical | Any punt. | Never NA. | |
| 52 | `scoring_play` | logical | Points scored on the row. | Never NA. | `score_pts != 0`. A failed PAT is FALSE. |
| 53 | `score_pts` | integer | Points scored on the row, from `pos_team`'s view. | Never NA. | TD +6, FG +3, PAT +1, two-point +2, defensive TD −6, safety conceded −2. |
| 54 | `drive_result` | character | How the row's drive ended, repeated on every row of the drive. | Never NA. | `TD`, `FG`, `MISSED FG`, `BLOCKED FG`, `PUNT`, `BLOCKED PUNT`, `INT`, `FUMBLE`, `DOWNS`, `SAFETY`, `END OF HALF`, `END OF GAME`, `ONSIDE`. A defensive TD is labeled by how the offense lost the ball. |
| 55 | `firstD_by_kickoff` | logical | First snap row of a series that began with a kickoff. | Never NA. | Kickoff rows themselves are FALSE. Includes after an onside kick, whoever recovered. cfbfastR name. |
| 56 | `firstD_by_poss` | logical | First snap row after a change of possession, or of an overtime possession. | Never NA. | After a punt, interception, lost fumble, downs, missed / blocked FG, or a punt / FG the kicking team regained. cfbfastR name. |
| 57 | `firstD_by_yards` | logical | First snap row of a series earned by the previous play's yardage. | Never NA. | Same offense; the previous play reached the line (d3's "1ST DOWN" text, or yards ≥ distance outside goal-to-go), unless an accepted offensive penalty took it away. cfbfastR name. |
| 58 | `firstD_by_penalty` | logical | First snap row of a series awarded by a penalty. | Never NA. | Same offense; the previous play didn't reach the line; an accepted penalty awarded it. A declined penalty never counts. cfbfastR name. |
| 59 | `new_series` | logical | The row starts a new series: one of the four flags. | Never NA. | Exactly one of the four is TRUE when this is. |
| 60 | `penalty_flag` | logical | The row mentions a penalty. | Never NA. | |
| 61 | `penalty_yards_signed` | integer | Net accepted penalty yards, from `pos_team`'s view. | NA with no penalty or when every infraction was declined. | + = defense flagged, − = offense flagged; offsetting = 0. |
| 62 | `penalized_team` | character | Team that committed the penalty. | NA with no penalty. | Both teams joined with `"; "` when offsetting or accepted on both. |
| 63 | `penalty_no_play` | logical | A penalty nullified the snap, or there was no snap. | Never NA. | See No-play gating. |
| 64 | `penalty_declined` | logical | Every infraction on the row was declined. | NA when `penalty_flag` is FALSE. | |
| 65 | `penalty_text` | character | Raw penalty clause, from the first "PENALTY" on. | NA with no penalty clause. | |
| 66 | `situation` | character | Raw down-and-distance text, verbatim. | Empty (NA on read) on kickoffs and tries. | Audit column. |
| 67 | `play_text` | character | Raw play description, verbatim. | Never NA. | Audit column. |
