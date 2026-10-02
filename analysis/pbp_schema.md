# Per-game play-by-play CSV: data dictionary (57 columns)

Each file `analysis/pbp/{game_id}.csv` is one game's play-by-play, built by
`build_pbp()` in `R/build_pbp.R` (all games at once by `build_all_pbp()`, which
also writes the validation reports in `analysis/checks/`). It has **one row per
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

2025 CMU coverage: 11 games, 1,861 rows, 250 drives. By `play_type`: rush 690,
pass_complete 451, pass_incomplete 294, kickoff 113, punt_no_return 68,
extra_point 66, penalty_no_play 57, sack 42, punt_with_return 23,
pass_intercepted 19, field_goal_good 17, two_point 9, field_goal_blocked 5,
field_goal_missed 3, kneel 2, punt_blocked 2. Per-game counts are in
`analysis/pbp_row_counts.csv`. What changed from v2 is in
`analysis/CHANGELOG_v3.md`. Nothing in the build assumes a team or a season: any
d3football boxscore URL can be built.

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
`analysis/checks/kickoff_possession.csv`. A **try** (PAT, two-point) and any
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
  from the date**. So a January game, or a "2020" game played in spring 2021,
  gets the right season.
- **`season_type`:** `"postseason"` if `game_date > regular_season_end` (from
  `data-raw/season_dates.csv`), else `"regular"`. 2020 has no end date, so
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
  (`analysis/checks/season_index_2025.md`).

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
| 8 | `play_index` | integer | Row order within the game, 1..N. | Never NA. | Counts every kept row (like CMU's `play_idx`). |
| 9 | `drive_number` | integer | Drive number within the game, 1..N. | Never NA. | See Key conventions. The opening kickoff is drive 1. 2025 max 30. |
| 10 | `drive_play_number` | integer | Position of the row within its drive, from 1. | Never NA. | A kickoff is always 1. Tries and their penalty rows count. |
| 11 | `period` | integer | Quarter, 1-4. | Never NA. | Forward-filled from quarter markers. Overtime has not occurred and isn't handled. |
| 12 | `half` | integer | 1 for periods 1-2, 2 for periods 3-4. | Never NA in 2025. | |
| 13 | `clock_start` | character | Exact game clock at the snap. | NA when not known exactly: 1,320 rows (known on 541). | Known when the clock was stopped at a stated reading and restarts on this snap: first snap of a drive (drive start time), snap after a timeout (timeout clock), first play of a quarter (15:00, so the opening and second-half kickoffs), and tries / kickoff after a score (the score's clock). Untimed rows before that snap (dead-ball penalties, tries) get the same reading. Set on all 113 kickoffs, 66 PATs, 9 two-point tries. |
| 14 | `clock_end` | character | Exact game clock when the play ended. | NA when not known: 1,513 rows (known on 348). | The play's own "clock M:SS" (scores, field goals, some kickoffs), else for a hand-over play (punt, turnover, downs, missed/blocked FG, kickoff) the next drive's start time. NA on nullified kicks (no hand-over). |
| 15 | `clock_upper` | character | Most time that could have been on the clock at the snap. | Never NA. | Latest known reading at or before the snap in the quarter (15:00 if none). |
| 16 | `clock_lower` | character | Least time that could have been on the clock at the snap. | Never NA. | Earliest known reading at or after the snap in the quarter, including the play's own `clock_end` (00:00 if none). Always <= `clock_upper` (`checks/clock_bounds.csv` is empty). |
| 17 | `pos_team` | character | Team in possession: the offense; on a kickoff the receiving team; on a try the scoring team. | Never NA. | See Key conventions. |
| 18 | `def_pos_team` | character | The other team. | Never NA. | On a kickoff, the kicking team. |
| 19 | `pos_team_score` | integer | `pos_team`'s score before the play. | Never NA. | See Key conventions. |
| 20 | `def_pos_team_score` | integer | `def_pos_team`'s score before the play. | Never NA. | |
| 21 | `score_diff` | integer | `pos_team_score - def_pos_team_score`. | Never NA. | Before the play. |
| 22 | `down` | integer | Down, 1-4. | NA on kickoffs, extra points, two-point tries (188 rows). | Parsed from `situation`. Never NA on snaps or dead-ball penalties. |
| 23 | `distance` | integer | Yards to go. | NA wherever `down` is NA. | On literal "and Goal" it is `yards_to_goal`. Two PAT-penalty rows carry a placeholder "1st and 10" (see Source quirks). |
| 24 | `yards_to_goal` | integer | Yards from the ball to the opponent's end zone (own 25 -> 75). | NA wherever `down` is NA. | From the yardline code in `situation` plus which code is `pos_team`'s own side (`infer_own_side()`, a per-game vote on yardline movement). |
| 25 | `Goal_To_Go` | logical | Line to gain is the goal line. | NA wherever `down` is NA. | Numeric rule, see Key conventions. 105 TRUE. |
| 26 | `down_end` | integer | Down of the next scrimmage snap in the half. | NA on scoring plays, tries and try-phase penalty rows, and when no snap follows in the half (196 rows). | That snap's offense view (see Key conventions). On a kickoff: the receiving team's first snap. |
| 27 | `distance_end` | integer | Distance of that next snap. | As `down_end`. | |
| 28 | `yards_to_goal_end` | integer | Yards to goal of that next snap. | As `down_end`. | After a punt, `yards_to_goal + yards_to_goal_end - 100` is the net punt. |
| 29 | `play_type` | character | What happened. Snaps: `rush`, `pass_complete`, `pass_incomplete`, `pass_intercepted`, `sack`, `kneel`, `punt_no_return`, `punt_with_return`, `punt_blocked`, `field_goal_good`, `field_goal_missed`, `field_goal_blocked`. Others: `kickoff`, `extra_point`, `two_point`, `penalty_no_play` (a dead-ball penalty with no snap). | Never NA. | A snap wiped out by a penalty keeps its call here (e.g. `pass_complete`); check `penalty_no_play`. Replaces v2's `row_type`. |
| 30 | `scrimmage_play` | logical | Down-and-distance row: has a `down`. | Never NA. | TRUE for every snap and every `penalty_no_play` row (1,673); FALSE for kickoffs, extra points, two-point tries. |
| 31 | `yards_gained` | integer | Yards gained on the play itself, penalty yardage excluded. | NA on every no-play row, and on interceptions, punts, field goals, kickoffs, tries (not defined for those yet). | Filled for `rush`, `pass_complete`, `sack`, `kneel`; `pass_incomplete` = 0. Range -21 to 75. |
| 32 | `rush` | logical | Designed run: `rush` or `kneel`. | Never NA. | A sack is not a rush here (NCAA counts it as one; this table keeps `sack` separate). Two-point runs FALSE. |
| 33 | `pass` | logical | Pass attempt: complete, incomplete, or intercepted. | Never NA. | Sacks and two-point passes FALSE. |
| 34 | `completion` | logical | Completed pass. | Never NA. | |
| 35 | `sack` | logical | QB sacked. | Never NA. | |
| 36 | `int` | logical | Interception. | Never NA. | Always also `turnover`. |
| 37 | `fumble_vec` | logical | A fumble or muff happened, whoever recovered. | Never NA. | |
| 38 | `turnover` | logical | Possession lost by interception, lost fumble, turnover on downs, or a kickoff the kicking team recovers. | Never NA. | A fumble is lost when the last "recovered by TEAM" after it isn't the fumbling team (the offense on snaps, the receiving team on kickoffs, the returner on punts / blocked kicks / interceptions). A blocked kick the kicking team gets back is not a turnover (McDaniel play 147). Punts and field goals are not turnovers. |
| 39 | `downs_turnover` | logical | Turnover on downs. | Never NA. | "TURNOVER ON DOWNS" in the text, or a 4th-down run/pass/sack/kneel short of the line, with no TD/int/lost fumble/penalty, and the next snap by the other team. |
| 40 | `touchdown` | logical | A touchdown that counts. | Never NA. | Upper-case "TOUCHDOWN", not "nullified". Includes defensive return TDs. |
| 41 | `safety` | logical | A safety. | Never NA. | None in 2025 (unvalidated). |
| 42 | `field_goal_attempt` | logical | Field goal attempted (good, missed, or blocked). | Never NA. | 24 TRUE. |
| 43 | `field_goal_made` | logical | Field goal good. | Never NA. | 17 TRUE. |
| 44 | `punt` | logical | Any punt. | Never NA. | 90 TRUE. |
| 45 | `scoring_play` | logical | Points were scored on the row (TD, FG, safety, good PAT or two-point). | Never NA. | `score_pts != 0`. A failed PAT is FALSE. 159 TRUE. |
| 46 | `score_pts` | integer | Points scored on the row, from `pos_team`'s view. | Never NA. | TD +6, FG +3, PAT +1, two-point +2; defensive TD -6; safety conceded -2; else 0. |
| 47 | `firstD_by_yards` | logical | The play gained a first down. | Never NA. | "1ST DOWN" in the play clause, or a run/completion/sack/kneel with `yards_gained >= distance` outside goal-to-go. Only 4 of 11 games print "1ST DOWN"; the rule matches it on every snap in those 4. A goal-to-go TD is not a first down (StatCrew). FALSE on turnovers and no-plays. 373 TRUE. |
| 48 | `firstD_by_penalty` | logical | A penalty awarded a first down. | Never NA. | "1ST DOWN" in the penalty clause with an accepted penalty, or an accepted defensive penalty after which the same offense starts a new series (not just the same 1st down moved). Can be TRUE on a no-play. 39 TRUE. |
| 49 | `penalty_flag` | logical | The row mentions a penalty. | Never NA. | 164 TRUE. |
| 50 | `penalty_yards_signed` | integer | Net accepted penalty yards, from `pos_team`'s view. | NA with no penalty, when all infractions were declined, and on 2 marker rows. | See Key conventions. Range -15 to +15. |
| 51 | `penalized_team` | character | Team that committed the penalty. | NA with no penalty, and on 2 marker rows. | Offsetting or accepted on both teams: both names joined with `"; "` (3 rows). All declined: the declined team. |
| 52 | `penalty_no_play` | logical | A penalty nullified the snap, or there was no snap. | Never NA. | Text-only rule (Key conventions). 116 TRUE: 61 wiped-out snaps + 55 dead-ball penalties. The 2 other `play_type == "penalty_no_play"` rows are the UW-La Crosse marker rows (Known issues), which are FALSE. |
| 53 | `penalty_declined` | logical | Every infraction on the row was declined. | NA when `penalty_flag` is FALSE. | One declined + one accepted is FALSE. |
| 54 | `penalty_text` | character | Raw penalty clause, from the first upper-case "PENALTY" on. | NA with no penalty clause. | |
| 55 | `drive_result` | character | How the row's drive ended, on every row of the drive. | Never NA. | `TD`, `FG`, `MISSED FG`, `BLOCKED FG`, `PUNT`, `BLOCKED PUNT`, `INT`, `FUMBLE`, `DOWNS`, `SAFETY`, `END OF HALF`, `END OF GAME`, plus `ONSIDE` (a one-play drive ended by an onside kick the kicking team recovered). A defensive TD is labelled by how the offense lost the ball (`INT`, `FUMBLE`, ...). 2025 drives: PUNT 88, TD 69, INT 19, DOWNS 19, FG 17, FUMBLE 11, END OF GAME 10, END OF HALF 8, BLOCKED FG 3, MISSED FG 3, BLOCKED PUNT 2, ONSIDE 1. |
| 56 | `situation` | character | Raw down-and-distance text, verbatim. | Empty (NA on read) on 111 kickoffs and all tries. | Audit column. Two kickoffs with a return penalty carry a stale down-and-distance here (Dickinson 191, Ursinus 73); their `down` is still NA. |
| 57 | `play_text` | character | Raw play description, verbatim. | Never NA. | Audit column. |

## Validation reports (`analysis/checks/`)

Rewritten on every `build_all_pbp()` run:
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
