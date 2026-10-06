# Per-game play-by-play CSV: data dictionary (63 columns)

Each file `analysis/pbp/{season}/{game_id}.csv` is one game's play-by-play,
built by `build_pbp()` in `R/build_pbp.R`. A season's games are built by
`build_season()` (`R/build_season.R`), which also writes the validation
reports in `analysis/checks/{season}/`. It has **one row per
event CMU logs** for that game, in game order. The source is the d3football.com
boxscore plays page
(`https://www.d3football.com/seasons/{year}/boxscores/{game_id}.xml?view=plays`),
a rendered HTML table of StatCrew output. There is no structured feed. The
classifier (`R/classify.R`) labels every row of that table, and five kinds of
row are **kept**: scrimmage snaps (including snaps wiped out by a penalty),
kickoffs, extra points, two-point tries, and dead-ball penalties with no snap.
Everything else (quarter markers, drive headers/footers, timeouts, score lines,
coin toss, spot corrections, navigation) is dropped. Some of those dropped rows
are read first to derive period, possession, kickoff teams, score, and clock.
Column names follow cfbfastR / nflfastR and are team-agnostic. The raw
`situation` and `play_text` are kept on every row, so any derived value can be
traced back to its source.

Built so far: every 2025 game involving a Centennial Conference team, 62
games (including 10 postseason games and 1 overtime game), 10,149 rows,
1,400 drives. This includes CMU's 11 games, the original validation set. All
62 reconcile with their boxscore final scores
(`analysis/checks/2025/build_report.md`). Per-game counts are in
`analysis/checks/2025/pbp_row_counts.csv`. What changed from v2 is in
`analysis/CHANGELOG_v3.md`. Nothing in the build assumes a team or a season: any
d3football boxscore URL can be built.

## Conferences and score reconciliation

- **Conference membership** is season-specific. Carnegie Mellon played in the
  PAC through 2024 and the Centennial from 2025. `build_conference_table(season,
  teams)` (`R/conferences.R`) reads each listed team's d3football page once:
  - the year-by-year table links that season's conference standings
    (`/conf/CC/2025/standings`), which gives the team's conference;
  - the schedule rows carry d3's "*" conference marker per game.
  Conference names come from each conference's standings page title. Results
  are cached to `data-raw/conferences/{season}.csv` (`season, team,
  conference, conference_code`) and
  `data-raw/conferences/{season}_schedule_markers.csv`. Only the teams asked
  for are fetched; for 2025 that's the Centennial teams plus every opponent
  they played.
- **`conference_game`** comes from the "*" marker, not from shared membership,
  so playoff and bowl games between conference members aren't counted.
  `analysis/checks/{season}/conference_check.csv` cross-checks the marker against
  shared membership.
- **Score reconciliation:** `build_all_pbp()` records each game's boxscore
  line-score final next to the points parsed per team from `score_pts`
  (positive to `pos_team`, negative to `def_pos_team`; `team_points()`), in
  `analysis/checks/{season}/pbp_row_counts.csv` and `score_reconciliation.csv`.
  `tests/testthat/test-score-reconciliation.R` fails if any built game doesn't
  match. A game that fails to build is listed in
  `analysis/checks/{season}/build_failures.csv` instead of stopping the batch.

## Reading the CSV

- Written with `write.csv(..., na = "")`: **NA is an empty field**. Read with
  `read.csv(f, na.strings = "")`. `situation` is genuinely empty on most
  kickoffs and tries and reads back as NA the same way.
- Logical columns are `TRUE`/`FALSE` and are never NA unless noted. Clock
  columns are zero-padded `"MM:SS"` strings (time remaining in the quarter).

## Key conventions

**Possession (`pos_team`).** The offense on a snap. On a **kickoff** it is the
**receiving** team and `def_pos_team` is the kicking team (cfbfastR). Punts and
field goals keep the kicking team as `pos_team`. Each kickoff's teams come from
the next drive row ("TEAM at MM:SS"). If the text shows the kicking team
recovered (onside kick, or a return fumble), the receiving team is the other
team and the play is a turnover. If no drive row follows (e.g. a kickoff-return
TD), pre-kick context decides: the scorer kicks, the coin toss names the
first-half receiver, the first-half receiver kicks in the second half, and a
re-kick uses the same kicker. Every decision is in
`analysis/checks/{season}/kickoff_possession.csv`. A **try** (PAT, two-point) and any
penalty row between a score and the next kickoff belong to the **scoring team**.

**Drives.** A drive is one team's continuous possession. A kickoff is
`drive_play_number` 1 of the receiving team's drive. Tries stay on the drive of
the scoring play, even after a defensive TD. d3's own footer boundaries are not
used, because StatCrew sometimes splits one possession in two (a re-kick after
a punt penalty, a penalty on a field goal). There are 250 drives here vs 259 d3
footers.

**`yards_gained` is play yards only.** It is the play's own "for N yards", read
only from the text before the `PENALTY` clause. Enforcement yardage never lands
here. A 10-yard catch plus an 11-yard face mask is `yards_gained = 10`,
`penalty_yards_signed = +11`, never 21.

**Penalty sign.** `penalty_yards_signed` is from `pos_team`'s view. Positive =
the defense was flagged (the offense gains); negative = the offense was
flagged. On a kickoff that means positive = the **kicking** team was flagged.
Only accepted infractions count. Two accepted ones are summed. Offsetting = 0.

**No-play gating.** `penalty_no_play` is decided from the text alone: the text
says "NO PLAY", or the row is a dead-ball penalty with no snap (text starts
"PENALTY ..."). On every such row, `yards_gained` is NA. These are all FALSE:
`rush`, `pass`, `completion`, `sack`, `int`, `fumble_vec`, `turnover`,
`downs_turnover`, `touchdown`, `safety`, `field_goal_attempt`,
`field_goal_made`, `punt`, `scoring_play`, `firstD_by_yards`. `score_pts` is 0.
d3 prints the wiped-out attempt in full ("... 54 yards ... TOUCHDOWN nullified
by penalty ... NO PLAY"), and none of it is credited.

**New series (first-down flags).** `firstD_by_kickoff`, `firstD_by_poss`,
`firstD_by_yards`, `firstD_by_penalty` sit on the **first snap row of each new
series**, never on the play that caused it. The first snap row is the first row
with a down for the new series, and it can be a penalty_no_play row: a
dead-ball penalty like a false start, or a snap nullified by a penalty. A snap
that replays the same down after a no-play penalty is never a series start.

At most one flag is TRUE, chosen by the cause of the new series:
- `firstD_by_kickoff`: after a kickoff.
- `firstD_by_poss`: after a change of possession, or the first snap row of an
  overtime possession.
- `firstD_by_yards`: the previous play reached the line to gain.
- `firstD_by_penalty`: an accepted penalty awarded it.

Precedence kickoff > poss > yards > penalty decides if two causes point at one
row. `new_series` is TRUE when one of them is. Every other row is FALSE in all
five.

Validation (`analysis/checks/{season}/first_downs.md`) forms series from the
situation alone. A series is the consecutive snap rows of one offense,
starting at the first snap row of a half or OT period, after a kickoff, at a
change of offense, or at a fresh 1st down. Each series must have exactly one
`new_series` row, on its first snap row. For how this differs from cfbfastR,
see `analysis/CHANGELOG.md`.

**Overtime.** College overtime is untimed, so in periods 5+ all four clock
columns are NA. Each overtime period starts a new drive (each team's OT
possession is its own drive). No kickoff follows an OT score; a try phase
ends at the next live snap.

**Clock: exact where known, bounds always.** `clock_start` / `clock_end` are
exact readings or NA. `clock_upper` / `clock_lower` always bracket the snap:
the play started with at most `clock_upper` and at least `clock_lower` left.
When `clock_start` is known, all three are equal. Bounds come from every known
reading in the quarter (drive starts, timeouts, quarter starts, score clocks,
derived starts and ends), with 15:00 / 00:00 at the quarter's start and end. A
play's own `clock_end` can be its lower bound (the snap came no later), never
its upper. A scoring play's bracket therefore runs from the last reading before
it down to its score clock. Nothing is interpolated.

**End state (`*_end`).** The situation of the next scrimmage snap in the same
half, from **that** snap's offense view. After a change of possession, it is
the new offense's down, distance and yards to goal (cfbfastR). NA on scoring
plays, tries, and the last plays of a half.

**Score before the play.** `pos_team_score` / `def_pos_team_score` are the
score *before* the play. They are the last printed score line plus any points
scored on kept rows since. d3 prints the score line after the try, so this
makes a PAT's "before" score include its touchdown. All 92 score lines in 2025
match the parsed points exactly.

**`Goal_To_Go` numeric rule.** d3 writes goal-to-go two ways: literally ("1st
and Goal at CMU06") and as a number equal to the distance to the goal line
("1st and 4 at UC 4"). `Goal_To_Go` is TRUE if the text says "Goal" **or**
`distance == yards_to_goal`.

**Play-text team codes.** The play text names field sides with its own codes
("to the UCHI45", "DCFB32", "McD28", even nicknames like "Wolves05"), which
often differ from the down-and-distance codes ("UC 25", "DCC32", "ALV05").
`infer_text_team()` pairs them by vote: when a play ends "to the WU34" and the
next row reads "at WAY34", the same yard number links WU to WAY. These codes
are used for fumble recoveries and `penalized_team`.

**Team names.** `home`, `away`, `pos_team`, `def_pos_team`, and
`penalized_team` all use one canonical spelling per team: d3's drive-start
spelling (e.g. `"UChicago"`, `"Wis.-La Crosse"`, `"Franklin & Marshall"`).
`pbp_row_counts.csv` uses the same spelling. The season index keeps the
scoreboard spelling ("Chicago", "UW-La Crosse").

## Season index and calendar columns

`season`, `game_date`, `week` and `season_type` are joined from the **season
index**. `build_season_index(season)` (`R/season_index.R`) builds it from
d3football's weekly composite scoreboard pages
(`/scoreboard/{season}/composite?view=N`), one row per game. It is cached to
`data-raw/index/{season}.csv` and reused unless `refresh = TRUE`.

- **How d3 numbers weeks:** `view=1` is the week of the first Saturday in
  September, and views count up one per week through the Stagg Bowl.
  Postseason weeks continue the same numbering. d3 has no round or bowl
  labels: NCAA playoff and bowl games share one table.
- **`season`:** taken from the boxscore URL path `/seasons/{year}/`, **never
  from the date**. So a January game (the 2024 Stagg Bowl was played Jan 5,
  2025), or a "2020" game played in spring 2021, gets the right season.
- **`season_type`:** `"postseason"` if `game_date > regular_season_end` (from
  `data-raw/season_dates.csv`), else `"regular"`.
  - **Where the dates come from:** the table has `season`,
    `regular_season_end`, `source`. 2019-2025 are seeded from each season's
    Wikipedia infobox ("{season} NCAA Division III football season"),
    verified against the NCAA championship selection announcements
    (`source = "wikipedia (verified vs NCAA)"`).
  - **Missing seasons:** a season not in the table is fetched from its
    Wikipedia infobox by `ensure_season_dates()`, appended with
    `source = "wikipedia"`, and logged for a human check.
  - **Sanity check:** `check_season_dates()` compares every date with "two
    Saturdays before Thanksgiving" and warns on any disagreement. The only one
    is 2023: the infobox lists Sunday Nov 12, the last game day was Saturday
    Nov 11, and it's harmless. 2020 has no end date, so
  every 2020 game is regular (spring 2021 season, no playoffs). Bowls and
  NCAA playoff games are both "postseason"; d3 gives nothing to tell them
  apart.
- **`week`:** the scoreboard view number for regular-season games.
  Postseason weeks **restart at 1** (cfbfastR): `view - first postseason view
  + 1`.
- **Fallback:** if a game isn't in the index, `build_pbp()` uses a date-based
  Sunday-to-Saturday week and logs a message. Regular week 1 is the week of
  the first Saturday in September; postseason week 1 is the week of the first
  Saturday after `regular_season_end`. `pbp_row_counts.csv` records
  `week_source` (`index` / `date fallback`). In 2025 the date-based week
  agrees with the scoreboard week for all 1,260 games
  (`analysis/checks/2025/season_index.md`).

## Columns

| # | column | type | definition | NA behavior | notes |
|---|---|---|---|---|---|
| 1 | `game_id` | character | d3football boxscore id, e.g. `"20250906_e064"`. | Never NA. | Constant per file. Joins to the season index. |
| 2 | `season` | integer | Season year. | Never NA. | From the boxscore URL path `/seasons/{year}/`, never from the date. |
| 3 | `game_date` | character | Game date, ISO `YYYY-MM-DD`. | Never NA. | From the season index (the boxscore id's date). |
| 4 | `week` | integer | Week of the season. | Never NA. | Scoreboard week for regular-season games; postseason restarts at 1. Date-based fallback if the game isn't in the index. |
| 5 | `season_type` | character | `"regular"` or `"postseason"`. | Never NA. | `postseason` if `game_date > regular_season_end` (`data-raw/season_dates.csv`); all 2020 games regular. Bowls count as postseason. |
| 6 | `home` | character | Home team. | Never NA. | From the header "Away at Home"; `pos_team` spelling. |
| 7 | `away` | character | Away team. | Never NA. | As `home`. |
| 8 | `home_team_conference` | character | Home team's conference that season (d3football's name, e.g. `"Centennial Conference"`). | NA for a team with no conference that season (independent or non-D3) or not in the season's conference table. | From `data-raw/conferences/{season}.csv` (season-specific). cfbfastR name. |
| 9 | `away_team_conference` | character | Away team's conference that season. | As `home_team_conference`. | cfbfastR name. |
| 10 | `conference_game` | logical | d3football marks the game as a conference game ("*" on the team schedule). | NA if neither team's schedule page has been read. | From d3's marker, **not** shared membership, so playoff / bowl games between two members are FALSE. cfbfastR name. |
| 11 | `play_index` | integer | Row order within the game, 1..N. | Never NA. | Counts every kept row (like CMU's `play_idx`). |
| 12 | `drive_number` | integer | Drive number within the game, 1..N. | Never NA. | See Key conventions. The opening kickoff is drive 1. 2025 max 30. |
| 13 | `drive_play_number` | integer | Position of the row within its drive, from 1. | Never NA. | A kickoff is always 1. Tries and their penalty rows count. |
| 14 | `period` | integer | Quarter 1-4; overtime periods are 5, 6, ... | Never NA. | Forward-filled from quarter markers, including d3's "OT" / "Start of OT quarter" rows. 2025 example: Johns Hopkins at F&M (20251115_2lnx) went to overtime. |
| 15 | `half` | integer | 1 for periods 1-2, 2 for periods 3+ (overtime counts as the second half). | Never NA. | |
| 16 | `clock_start` | character | Exact game clock at the snap. | NA when not known exactly: 1,320 rows (known on 541). | Known when the clock was stopped at a stated reading and restarts on this snap: first snap of a drive (drive start time), snap after a timeout (timeout clock), first play of a quarter (15:00, so the opening and second-half kickoffs), and tries / kickoff after a score (the score's clock). Untimed rows before that snap (dead-ball penalties, tries) get the same reading. Set on all 113 kickoffs, 66 PATs, 9 two-point tries. |
| 17 | `clock_end` | character | Exact game clock when the play ended. | NA when not known: 1,513 rows (known on 348). | The play's own "clock M:SS" (scores, field goals, some kickoffs), else for a hand-over play (punt, turnover, downs, missed/blocked FG, kickoff) the next drive's start time. NA on nullified kicks (no hand-over). |
| 18 | `clock_upper` | character | Most time that could have been on the clock at the snap. | Never NA in regulation; NA in overtime (untimed). | Latest known reading at or before the snap in the quarter (15:00 if none). |
| 19 | `clock_lower` | character | Least time that could have been on the clock at the snap. | Never NA in regulation; NA in overtime (untimed). | Earliest known reading at or after the snap in the quarter, including the play's own `clock_end` (00:00 if none). Always <= `clock_upper` (`checks/clock_bounds.csv` is empty). |
| 20 | `pos_team` | character | Team in possession: the offense; on a kickoff the receiving team; on a try the scoring team. | Never NA. | See Key conventions. |
| 21 | `def_pos_team` | character | The other team. | Never NA. | On a kickoff, the kicking team. |
| 22 | `pos_team_score` | integer | `pos_team`'s score before the play. | Never NA. | See Key conventions. |
| 23 | `def_pos_team_score` | integer | `def_pos_team`'s score before the play. | Never NA. | |
| 24 | `score_diff` | integer | `pos_team_score - def_pos_team_score`. | Never NA. | Before the play. |
| 25 | `down` | integer | Down, 1-4. | NA on kickoffs, extra points, two-point tries (188 rows). | Parsed from `situation`. Never NA on snaps or dead-ball penalties. |
| 26 | `distance` | integer | Yards to go. | NA wherever `down` is NA. | On literal "and Goal" it is `yards_to_goal`. Two PAT-penalty rows carry a placeholder "1st and 10" (see Source quirks). |
| 27 | `yards_to_goal` | integer | Yards from the ball to the opponent's end zone (own 25 -> 75). | NA wherever `down` is NA. | From the yardline code in `situation` plus which code is `pos_team`'s own side (`infer_own_side()`, a per-game vote on yardline movement). |
| 28 | `Goal_To_Go` | logical | Line to gain is the goal line. | NA wherever `down` is NA. | Numeric rule, see Key conventions. 105 TRUE. |
| 29 | `down_end` | integer | Down of the next scrimmage snap in the half. | NA on scoring plays, tries and try-phase penalty rows, and when no snap follows in the half (196 rows). | That snap's offense view (see Key conventions). On a kickoff: the receiving team's first snap. |
| 30 | `distance_end` | integer | Distance of that next snap. | As `down_end`. | |
| 31 | `yards_to_goal_end` | integer | Yards to goal of that next snap. | As `down_end`. | After a punt, `yards_to_goal + yards_to_goal_end - 100` is the net punt. |
| 32 | `play_type` | character | What happened. Snaps: `rush`, `pass_complete`, `pass_incomplete`, `pass_intercepted`, `sack`, `kneel`, `punt_no_return`, `punt_with_return`, `punt_blocked`, `field_goal_good`, `field_goal_missed`, `field_goal_blocked`. Others: `kickoff`, `extra_point`, `two_point`, `penalty_no_play` (a dead-ball penalty with no snap). | Never NA. | A snap wiped out by a penalty keeps its call here (e.g. `pass_complete`); check `penalty_no_play`. Replaces v2's `row_type`. |
| 33 | `scrimmage_play` | logical | Down-and-distance row: has a `down`. | Never NA. | TRUE for every snap and every `penalty_no_play` row (1,673); FALSE for kickoffs, extra points, two-point tries. |
| 34 | `yards_gained` | integer | Yards gained on the play itself, penalty yardage excluded. | NA on every no-play row, and on interceptions, punts, field goals, kickoffs, tries (not defined for those yet). | Filled for `rush`, `pass_complete`, `sack`, `kneel`; `pass_incomplete` = 0. Range -21 to 75. |
| 35 | `rush` | logical | Designed run: `rush` or `kneel`. | Never NA. | A sack is not a rush here (NCAA counts it as one; this table keeps `sack` separate). Two-point runs FALSE. |
| 36 | `pass` | logical | Pass attempt: complete, incomplete, or intercepted. | Never NA. | Sacks and two-point passes FALSE. |
| 37 | `completion` | logical | Completed pass. | Never NA. | |
| 38 | `sack` | logical | QB sacked. | Never NA. | |
| 39 | `int` | logical | Interception. | Never NA. | Always also `turnover`. |
| 40 | `fumble_vec` | logical | A fumble or muff happened, whoever recovered. | Never NA. | |
| 41 | `turnover` | logical | Possession lost by interception, lost fumble, turnover on downs, or a kickoff the kicking team recovers. | Never NA. | A fumble is lost when the last "recovered by TEAM" after it isn't the fumbling team (the offense on snaps, the receiving team on kickoffs, the returner on punts / blocked kicks / interceptions). A blocked kick the kicking team gets back is not a turnover (McDaniel play 147). Punts and field goals are not turnovers. |
| 42 | `downs_turnover` | logical | Turnover on downs. | Never NA. | "TURNOVER ON DOWNS" in the text, or a 4th-down run/pass/sack/kneel short of the line, with no TD/int/lost fumble/penalty, and the next snap by the other team. |
| 43 | `touchdown` | logical | A touchdown that counts. | Never NA. | Upper-case "TOUCHDOWN", not "nullified". Includes defensive return TDs. |
| 44 | `safety` | logical | A safety. | Never NA. | None in 2025 (unvalidated). |
| 45 | `field_goal_attempt` | logical | Field goal attempted (good, missed, or blocked). | Never NA. | 24 TRUE. |
| 46 | `field_goal_made` | logical | Field goal good. | Never NA. | 17 TRUE. |
| 47 | `punt` | logical | Any punt. | Never NA. | 90 TRUE. |
| 48 | `scoring_play` | logical | Points were scored on the row (TD, FG, safety, good PAT or two-point). | Never NA. | `score_pts != 0`. A failed PAT is FALSE. 159 TRUE. |
| 49 | `score_pts` | integer | Points scored on the row, from `pos_team`'s view. | Never NA. | TD +6, FG +3, PAT +1, two-point +2; defensive TD -6; safety conceded -2; else 0. |
| 50 | `firstD_by_kickoff` | logical | First snap row after a kickoff. | Never NA. | On the first snap row of the receiving team's series (kickoff rows are always FALSE). Includes after an onside kick, whichever team recovered. cfbfastR name. |
| 51 | `firstD_by_poss` | logical | First snap after a change of possession, or the first snap of an overtime possession. | Never NA. | After a punt, interception, lost fumble, turnover on downs, or missed / blocked FG, and after a punt / FG the kicking team regained after a muff or return fumble. Also every overtime possession's first snap. cfbfastR name. |
| 52 | `firstD_by_yards` | logical | First snap of a new series earned by the previous play's yardage (same offense). | Never NA. | The previous play reached the line to gain: d3's "1ST DOWN" text, or a run / completion / sack / kneel with `yards_gained >= distance` outside goal-to-go. Not if an accepted offensive penalty on that play took it away. cfbfastR name. |
| 53 | `firstD_by_penalty` | logical | First snap of a new series awarded by a penalty (same offense). | Never NA. | The previous play didn't reach the line, and an accepted penalty awarded the first down (the penalty can be on a no-play). A declined penalty never counts. cfbfastR name. |
| 54 | `new_series` | logical | The row is the first snap row of a new series: any of the four flags. | Never NA. | Exactly one of the four is TRUE when this is. The first snap row can be a penalty_no_play row (a dead-ball penalty or a nullified snap). FALSE on kickoffs, tries, mid-series snaps, and a snap that replays the same down after a no-play penalty. |
| 55 | `penalty_flag` | logical | The row mentions a penalty. | Never NA. | 164 TRUE. |
| 56 | `penalty_yards_signed` | integer | Net accepted penalty yards, from `pos_team`'s view. | NA with no penalty, when all infractions were declined, and on 2 marker rows. | See Key conventions. Range -15 to +15. |
| 57 | `penalized_team` | character | Team that committed the penalty. | NA with no penalty, and on 2 marker rows. | Offsetting or accepted on both teams: both names joined with `"; "` (3 rows). All declined: the declined team. |
| 58 | `penalty_no_play` | logical | A penalty nullified the snap, or there was no snap. | Never NA. | Text-only rule (Key conventions). 116 TRUE: 61 wiped-out snaps + 55 dead-ball penalties. The 2 other `play_type == "penalty_no_play"` rows are the UW-La Crosse marker rows (Known issues), which are FALSE. |
| 59 | `penalty_declined` | logical | Every infraction on the row was declined. | NA when `penalty_flag` is FALSE. | One declined + one accepted is FALSE. |
| 60 | `penalty_text` | character | Raw penalty clause, from the first upper-case "PENALTY" on. | NA with no penalty clause. | |
| 61 | `drive_result` | character | How the row's drive ended, on every row of the drive. | Never NA. | `TD`, `FG`, `MISSED FG`, `BLOCKED FG`, `PUNT`, `BLOCKED PUNT`, `INT`, `FUMBLE`, `DOWNS`, `SAFETY`, `END OF HALF`, `END OF GAME`, plus `ONSIDE` (a one-play drive ended by an onside kick the kicking team recovered). A defensive TD is labelled by how the offense lost the ball (`INT`, `FUMBLE`, ...). 2025 drives: PUNT 88, TD 69, INT 19, DOWNS 19, FG 17, FUMBLE 11, END OF GAME 10, END OF HALF 8, BLOCKED FG 3, MISSED FG 3, BLOCKED PUNT 2, ONSIDE 1. |
| 62 | `situation` | character | Raw down-and-distance text, verbatim. | Empty (NA on read) on 111 kickoffs and all tries. | Audit column. Two kickoffs with a return penalty carry a stale down-and-distance here (Dickinson 191, Ursinus 73); their `down` is still NA. |
| 63 | `play_text` | character | Raw play description, verbatim. | Never NA. | Audit column. |

## Validation reports (`analysis/checks/{season}/`)

Rewritten on every `build_season()` run:
- **`kickoff_possession.csv`:** every kickoff's kicking and receiving team, the
  rule that decided it, and any disagreement between header, recovery text and
  pre-kick context.
- **`drive_footer_clock.csv`:** each d3 drive's start clock plus its footer's
  "MM:SS elapsed", compared with the drive's end (score clock, next drive
  start, or end of half).
- **`clock_bounds.csv`:** rows whose bounds are missing or inverted. It should
  be empty.
- **`end_state.csv`:** every change-of-possession row with `yards_to_goal`, the
  end state, and the next snap.

Current results are summarized in `analysis/CHANGELOG_v3.md`.

## Known issues

- **"Penalty after touchdown before PAT" marker rows are kept.** UW-La Crosse
  (`20250913_6i95`) plays 106 and 161 are admin markers. The real penalty is
  the row before. They have `penalty_flag` TRUE, the other penalty fields NA,
  and `penalty_no_play` FALSE. They should probably be dropped.
- **`yards_gained` is not defined for interceptions, punts, field goals,
  kickoffs or tries.** It stays NA there until a convention is chosen
  (return yards, kick distance, net).
- **First downs in 7 games are rule-derived.** Those formats never print "1ST
  DOWN". The rule matches the printed flag exactly where it exists, but it is
  unverified where it doesn't.

## Source quirks

- **Placeholder situation on PAT penalties.** A penalty before an extra point
  shows a made-up situation like "1st and 10 at JHU3", so `distance` (10)
  exceeds `yards_to_goal` (3). This happens on Johns Hopkins play 12 and
  Dickinson play 176. These rows are try-phase (`pos_team` = scoring team, end
  state NA).
- **Bad clock readings (discarded).** Game 1 play 135, a nullified TD, prints
  "clock 00:00" mid-4th. The Berry game prints "BERRY ball on BERRY35, clock
  15:00" and "clock 15:00" just before "End of half, clock 00:00". All three
  are dropped.
- **0-play drive footers.** d3 sometimes prints "0 plays, 0 yards, 00:00
  elapsed" for a drive that did take 5-24 seconds. These are the 3 flagged rows
  in `drive_footer_clock.csv`.
- **End-of-half wording.** The first half sometimes ends with "End of game,
  clock 00:00" (game 1). The period is still read correctly.
- **Two StatCrew formats.** Most outcomes are read from either, but only the
  "Last,First" format (Chicago, Johns Hopkins, Dickinson, Ursinus games) prints
  "1ST DOWN" and "TURNOVER ON DOWNS".
