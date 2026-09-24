# `build_pbp()` output schema

Data dictionary for the per-game tables in `analysis/pbp/{game_id}.csv`,
produced by `R/build_pbp.R`. One row per kept event (see `row_type`). The
column set and order follow the 36-column cfbfastR-aligned target in
`analysis/pbp_schema_and_build_plan.md`; the order lives in code as
`pbp_columns`. Team-agnostic: no CMU-specific `opponent` column (the
opponent name is still reported in `analysis/pbp_row_counts.csv`).

Status: columns marked **T3** are placeholders, NA on every row, until Task 3
populates them (3a outcome flags are done). They're NA rather than FALSE so an unfilled flag can't be read
as a real "no".

| # | column | type | definition | NA / convention notes |
|---|---|---|---|---|
| 1 | `game_id` | character | Boxscore id (e.g. `"20250906_e064"`), constant per game. | Never NA. |
| 2 | `play_index` | integer | Sequential 1..N over the kept rows for this game. | Never NA. |
| 3 | `drive_play_number` | integer | Position of the row within its `drive_id` (1, 2, ...), counting every kept row, including PATs and the kickoff that follows a score. | NA where `drive_id` is NA (the opening kickoff). |
| 4 | `period` | integer | Quarter, forward-filled from the quarter-marker rows before they're dropped. | Never NA. All 2025 games are regulation (1-4); OT has not been seen, so it isn't handled yet. |
| 5 | `half` | integer | 1 for period 1-2, 2 for period 3-4. | NA for any other period (none in 2025). |
| 6-8 | `clock_known`, `clock_prev_known`, `clock_next_known` | character | **T3.** Stated game clock and the bracket around it. | All NA for now. |
| 9 | `pos_team` | character | Team with the ball, forward-filled from `drive_header`/`drive_start` rows before they're dropped. | One NA per game: the opening kickoff, which comes before any drive. Uses the drive rows' spelling (e.g. `"UChicago"`, `"Wis.-La Crosse"`), which can differ from the line-score name. On kickoffs and PATs this is the scoring/kicking team (the row sits before the next drive header). |
| 10 | `def_pos_team` | character | The other of the game's two `pos_team` values. | NA where `pos_team` is NA. |
| 11 | `down` | integer | Down (1-4), parsed from `situation`. | NA for `kickoff`/`extra_point`/`two_point`. |
| 12 | `distance` | integer | Yards to go, parsed from `situation`. | NA wherever `down` is NA. On a literal "and Goal" situation, it's `yards_to_goal`. |
| 13 | `yards_to_goal` | integer | Distance to the opponent's end zone (0-100): own 25 -> 75, opponent 25 -> 25, bare "at 50" -> 50. Computed from the yardline token plus which token is `pos_team`'s own side. | NA wherever `down` is NA. The page never says which token ("UC", "CMU") belongs to which team name, so `infer_own_side()` infers it per game from how the yard number moves on consecutive snaps (see below). |
| 14 | `Goal_To_Go` | logical | TRUE when the line to gain is the goal line. d3 writes this two ways: literally ("1st and Goal at CMU06") and as a number equal to the distance to the goal ("1st and 4 at UC 4"). TRUE if the text says "Goal" OR `distance == yards_to_goal`. | NA wherever `down` is NA. |
| 15 | `play_type` | character | For `row_type == "play"`, the parsed category from `R/parse_play_type.R` (`rush`, `pass_complete`, `pass_incomplete`, `pass_intercepted`, `sack`, `punt_no_return`, `punt_with_return`, `punt_blocked`, `field_goal_good`, `field_goal_missed`, `field_goal_blocked`, `kneel`). For other kept rows, `row_type` itself. | Never NA. |
| 16 | `yards_gained` | integer | Play yards only, penalty enforcement excluded. | Still the loose pre-Task-3 parse: set only for `rush`/`pass_complete`/`sack`/`kneel` (regex on the description) and `pass_incomplete` (0). Task 3b extends it and applies the no-play rule. |
| 17-26 | `rush`, `pass`, `completion`, `sack`, `int`, `fumble_vec`, `turnover`, `downs_turnover`, `touchdown`, `safety` | logical | Outcome flags, set by `parse_outcome_flags()` in `R/parse_outcomes.R`. `rush` = play_type `rush`/`kneel` (a sack is NOT a rush; it has its own flag). `pass` = complete/incomplete/intercepted. `fumble_vec` = text mentions a fumble, on any row type. `turnover` = interception, lost fumble, or turnover on downs. A fumble is lost when the last "recovered by TEAM" after it isn't the fumbling team (offense on rush/pass/sack/kneel, the returning side on kickoffs, punts, blocked kicks, interception returns). `downs_turnover` = "TURNOVER ON DOWNS" in text, OR a 4th-down rush/pass/sack/kneel short of the line to gain, no TD/int/lost fumble/penalty, next snap by the other team (some StatCrew formats never print the phrase). `touchdown` = "TOUCHDOWN" not "nullified"; includes defensive return TDs. | Never NA. All FALSE on no-play rows (`row_type == "penalty_no_play"` or text says "NO PLAY"), per convention 3. `two_point` rows get no rush/pass flag. `safety` is FALSE everywhere in 2025 (none occurred). Play-text team tokens ("UCHI", "DSON") are mapped to teams by `infer_text_team()`. |
| 27-32 | `penalty_flag`, `penalty_yards_signed` (integer), `penalized_team` (character), `penalty_no_play`, `penalty_declined`, `penalty_text` (character) | mixed | **T3b.** Penalty columns. | All NA for now. |
| 33 | `situation` | character | Raw down-and-distance text, verbatim (audit). | Empty for `kickoff`/`extra_point`/`two_point`. |
| 34 | `play_text` | character | Raw play description, verbatim (audit). | Never empty. |
| 35 | `row_type` | character | Classifier label from `R/classify.R` (audit): `play`, `kickoff`, `extra_point`, `two_point`, `penalty_no_play`. | Never NA. |
| 36 | `drive_id` | integer | Sequential drive number within the game. | NA only on the opening kickoff. See below. |

## How `drive_id` is assigned

d3's drive markers are noisy: a drive normally opens with a `drive_header`
("TEAM at MM:SS") plus a `drive_start` ("TEAM drive start at MM:SS."), but the
pair isn't always complete, and `drive_start` is sometimes repeated mid-drive
(after a spot correction or penalty). The reliable boundary is the
`drive_footer` ("N plays, N yards, MM:SS elapsed") that closes each drive. A
new drive begins at the first drive marker after a footer. Later markers before
the next footer restate the same drive.

Rows between a footer and the next marker, usually the kickoff after a score,
keep the previous drive's id, the same way they keep its `pos_team`. This
follows the source layout. cfbfastR/CFBD attach a kickoff to the receiving
team's drive instead, so revisit this if that matters downstream.

StatCrew also opens a new "drive" for a re-kick after a penalty on a punt (a
0-play footer, e.g. Berry game) and after some penalty-on-FG sequences. We
follow the source, so those count as separate drives.

## How `yards_to_goal` knows which side is whose

`infer_own_side()` looks at consecutive kept rows where the same `pos_team` is
on the same yardline token. On its own side the yard number rises as the offense
gains ground; on the opponent's side it falls. Gains far outnumber losses, so a
vote over the whole game is decisive. The function stops with an error if a game
doesn't have exactly two teams and two tokens, or if the vote is close. For the
2025 CMU games it maps CMU -> `CMU` in all 11, and each opponent to its own
token (UChicago -> `UC`, Ursinus -> `UCB`, F&M -> `F&M`, ...).

## Known source quirk

A penalty before an extra point (e.g. CMU delay of game on a PAT) shows as a
`penalty_no_play` row with a placeholder situation like "1st and 10 at JHU3".
So `distance` (10) exceeds `yards_to_goal` (3). Two such rows in 2025 (JHU
play 12, Dickinson play 176). `Goal_To_Go` is FALSE there. They're really PAT
penalties, not scrimmage downs.
