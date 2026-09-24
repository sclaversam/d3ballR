# Per-game play-by-play CSV: data dictionary

Each file `analysis/pbp/{game_id}.csv` is one game's play-by-play, built by
`build_pbp()` in `R/build_pbp.R` (all games at once by `build_all_pbp()`). It
has **one row per event CMU logs** for that game, in game order. The source is
the d3football.com boxscore plays page
(`https://www.d3football.com/seasons/{year}/boxscores/{game_id}.xml?view=plays`),
a rendered HTML table of StatCrew output. There is no structured feed. The
classifier (`R/classify.R`) labels every row of that table. Only five row types
are **kept**: `play` (a scrimmage snap), `kickoff`, `extra_point`, `two_point`,
and `penalty_no_play`. Everything else (quarter markers, drive headers/footers,
timeouts, score lines, coin toss, spot corrections, navigation) is dropped. Some
of those dropped rows are read first to derive `period`, `pos_team`,
`drive_id`, and the clock columns. The 36 columns follow cfbfastR / nflfastR
names and are team-agnostic (`pos_team` / `def_pos_team`, no "opponent"
column). The raw `situation` and `play_text` are kept on every row, so any
derived value can be traced back to its source.

2025 CMU coverage: 11 games, 1,861 rows (`play` 1,616, `kickoff` 111,
`extra_point` 66, `penalty_no_play` 59, `two_point` 9). Per-game row counts
and opponents are in `analysis/pbp_row_counts.csv`.

## Reading the CSV

- Written with `write.csv(..., na = "")`: **NA is an empty field**. Read with
  `read.csv(f, na.strings = "")`. `situation` is the exception: it's a real
  empty string on kickoffs/PATs, but reads back as NA the same way.
- Logical columns are `TRUE`/`FALSE`. Clock columns are `"MM:SS"` strings.

## Key conventions

**`yards_gained` is play yards only.** It is the play's own "for N yards"
(rush, catch, sack, kneel), read only from the text *before* the `PENALTY`
clause. Penalty enforcement yardage ("N yards from X to Y", "N yards to the X")
never lands here. It's in `penalty_yards_signed`. A counting play with a
penalty keeps its own yards: a 10-yard catch plus an 11-yard face mask is
`yards_gained = 10`, `penalty_yards_signed = +11`, never 21.

**`penalty_yards_signed` sign is from the offense's (`pos_team`) point of
view.** Positive = the defense (`def_pos_team`) was flagged, so the offense
gains. Negative = the offense was flagged. Offensive delay of game, 5 yards ->
`-5`; defensive face mask, 11 yards -> `+11`. Only *accepted* infractions count.
Two accepted infractions are summed. Offsetting penalties are `0`.

**No-play gating.** `penalty_no_play` is TRUE when the text says "NO PLAY", or
when the row is a dead-ball penalty with no snap at all (text begins
"PENALTY ...", e.g. a false start in the StatCrew format that doesn't print
"NO PLAY"). It does not trust the upstream `row_type` label (see Known issues).
On every `penalty_no_play` row, `yards_gained` is NA and all ten outcome flags
are FALSE, regardless of the text. The page prints the wiped-out attempt in
full ("... for 54 yards ... TOUCHDOWN nullified by penalty ... NO PLAY"), and
none of it is credited.

**Clock bracket, not a clock.** The clock is stated only on some rows, mostly
ones that get dropped: quarter starts, drive headers/starts, timeouts, plus
scores and field goals. So each row carries the nearest stated clock at/before
it (`clock_prev_known`) and at/after it (`clock_next_known`), within the same
quarter. The play happened inside that window. The clock is **never
interpolated**, because it doesn't tick uniformly.

**`Goal_To_Go` has a numeric rule.** d3 writes goal-to-go two ways: literally
("1st and Goal at CMU06"), and as a plain number that equals the distance to
the goal line ("1st and 4 at UC 4"). Johns Hopkins and Dickinson games only use
the second form. `Goal_To_Go` is TRUE if the text says "Goal" **or**
`distance == yards_to_goal`.

**Team names.** `pos_team`, `def_pos_team`, and `penalized_team` use the
spelling on d3's drive rows (e.g. `"UChicago"`, `"Wis.-La Crosse"`,
`"Franklin & Marshall"`). That can differ from the line-score name in
`pbp_row_counts.csv` ("Chicago", "UW-La Crosse", "Franklin and Marshall").

## Columns

| # | column | type | definition | NA behavior | notes |
|---|---|---|---|---|---|
| 1 | `game_id` | character | d3football boxscore id, e.g. `"20250906_e064"`. Constant per file. | Never NA. | The part of the boxscore URL before `.xml`. |
| 2 | `play_index` | integer | Row order within the game, 1..N over kept rows. | Never NA. | Counts every kept row (kickoffs, PATs, no-play penalties included), like CMU's `play_idx`. |
| 3 | `drive_play_number` | integer | Position of the row within its `drive_id`, starting at 1. | NA only where `drive_id` is NA (each game's opening kickoff). | Counts every kept row in the drive, including the PAT and the post-score kickoff that trail it. |
| 4 | `period` | integer | Quarter, 1-4. | Never NA. | Forward-filled from quarter-marker rows before they're dropped. Overtime has not occurred in the data and isn't handled. |
| 5 | `half` | integer | 1 for periods 1-2, 2 for periods 3-4. | Never NA in 2025 (NA for any period outside 1-4). | |
| 6 | `clock_known` | character | The game clock this row itself states, `"MM:SS"`. | NA on rows that don't state one: 1,758 of 1,861. Non-NA on 101 plays (scores, field goals) and 2 kickoffs. | Parsed from "clock M:SS". Zero-padded. A reading that contradicts the readings on either side of it is discarded (only game 1 play 135, a nullified TD printed "clock 00:00" mid-4th). |
| 7 | `clock_prev_known` | character | Latest stated clock at or before this row, same quarter. | NA only when no clock is stated earlier in the quarter: 1 row (Misericordia's opening kickoff, listed before "Start of 1st quarter"). | Taken from ALL rows, dropped ones included, before the kept-row filter. More time on the clock than (or equal to) `clock_next_known`. |
| 8 | `clock_next_known` | character | Next stated clock at or after this row, same quarter. | NA when nothing after the row states a clock before the quarter ends: 111 rows, all among the last plays of a quarter ("End of Nth quarter" rows carry no clock). | Same derivation as `clock_prev_known`. Not filled with an implied 00:00. |
| 9 | `pos_team` | character | Team with the ball (the offense). | NA only on each game's opening kickoff (11 rows), which comes before any drive row. | Forward-filled from drive header/start rows. Kickoffs and PATs have no drive row of their own, so they inherit the previous drive's team. That is normally the scoring / kicking team, but not always (see Known issues). |
| 10 | `def_pos_team` | character | The other team (the defense). | NA where `pos_team` is NA. | Each game has exactly two `pos_team` values; this is whichever one `pos_team` isn't. |
| 11 | `down` | integer | Down, 1-4. | NA on `kickoff`, `extra_point`, `two_point` (186 rows). Never NA on `play` or `penalty_no_play`. | Parsed from `situation`. |
| 12 | `distance` | integer | Yards to go for a first down. | NA wherever `down` is NA. | On a literal "and Goal" situation it's set to `yards_to_goal`. 2025 range 1-37. Two PAT-penalty rows carry a placeholder "1st and 10" (see Source quirks). |
| 13 | `yards_to_goal` | integer | Yards from the ball to the opponent's end zone: own 25 -> 75, opponent 25 -> 25, "at 50" -> 50. | NA wherever `down` is NA. | Computed from the yardline in `situation` plus which yardline code is `pos_team`'s own side (see "How `yards_to_goal` knows which side is whose"). Replaces raw yard side / yard number. 2025 range 1-98. |
| 14 | `Goal_To_Go` | logical | TRUE when the line to gain is the goal line. | NA wherever `down` is NA. | TRUE if `situation` says "Goal" OR `distance == yards_to_goal` (see Key conventions). 105 TRUE in 2025. |
| 15 | `play_type` | character | What happened on the row. For `row_type == "play"`: `rush`, `pass_complete`, `pass_incomplete`, `pass_intercepted`, `sack`, `kneel`, `punt_no_return`, `punt_with_return`, `punt_blocked`, `field_goal_good`, `field_goal_missed`, `field_goal_blocked`. For other rows: the `row_type` itself (`kickoff`, `extra_point`, `two_point`, `penalty_no_play`). | Never NA. | From `R/parse_play_type.R`. A snap wiped out by a penalty keeps its play call here (e.g. `pass_complete`); check `penalty_no_play` to know if it counted. |
| 16 | `yards_gained` | integer | Yards gained on the play itself, penalty yardage excluded. | NA on every `penalty_no_play` row. Also NA on `pass_intercepted`, punts, field goals, `kickoff`, `extra_point`, `two_point` (not yet defined for those). | Filled for `rush`, `pass_complete`, `sack`, `kneel` (from "for N yards" / "loss of N" / "no gain"). `pass_incomplete` = 0. See Key conventions. 2025 range -21 to 75. |
| 17 | `rush` | logical | Designed run: `play_type` is `rush` or `kneel`. | Never NA. | A sack is NOT a rush here (NCAA stats count sacks as rushes; this table keeps them separate in `sack`). Two-point runs are FALSE. |
| 18 | `pass` | logical | Pass attempt: `pass_complete`, `pass_incomplete`, or `pass_intercepted`. | Never NA. | Sacks are not pass attempts (NCAA). Two-point passes are FALSE. |
| 19 | `completion` | logical | Completed pass (`pass_complete`). | Never NA. | |
| 20 | `sack` | logical | QB sacked (`sack`). | Never NA. | |
| 21 | `int` | logical | Pass intercepted (`pass_intercepted`). | Never NA. | Always also `turnover`. |
| 22 | `fumble_vec` | logical | A fumble happened on the play, whoever recovered. | Never NA. | Text contains "fumble"/"fumbled". Can be TRUE on kickoffs (3 in 2025). |
| 23 | `turnover` | logical | Possession lost by interception, lost fumble, or turnover on downs. | Never NA. | A fumble is lost when the last "recovered by TEAM" after it isn't the fumbling team. The fumbling team is the offense on rush/pass/sack/kneel, and the returning side on kickoffs, punts, blocked kicks, and interception returns. Exception: a blocked kick where the kicking team recovers the returner's fumble is not a turnover (possession ends where it started; McDaniel play 147). Punts and field goals are not turnovers. |
| 24 | `downs_turnover` | logical | Turnover on downs. | Never NA. | TRUE if the text says "TURNOVER ON DOWNS", or if a 4th-down rush/pass/sack/kneel fell short of the line to gain, with no TD, interception, lost fumble, or penalty, and the next snap belongs to the other team. Some StatCrew formats never print the phrase. Always also `turnover`. |
| 25 | `touchdown` | logical | A touchdown that counts was scored on the play. | Never NA. | Upper-case "TOUCHDOWN" in the text, not "TOUCHDOWN nullified". Includes defensive return TDs (interception and fumble returns). |
| 26 | `safety` | logical | A safety was scored. | Never NA. | Text says "safety". None occurred in 2025, so this rule is unvalidated. |
| 27 | `penalty_flag` | logical | The row mentions a penalty. | Never NA. | Case-insensitive "penalty". 164 TRUE in 2025. Covers accepted, declined, offsetting, and no-play penalties. |
| 28 | `penalty_yards_signed` | integer | Net accepted penalty yardage, signed from the offense's view (+ defense flagged, - offense flagged). | NA when `penalty_flag` is FALSE, when every infraction was declined (8 rows), and on the 2 "Penalty after touchdown before PAT" marker rows. | Parsed from "N yards from X to Y" / "N yards to the X", never "for N yards". Offsetting = 0. On kickoffs the sign is relative to `pos_team`, which on kickoffs is usually the kicking team. 2025 range -15 to +15. |
| 29 | `penalized_team` | character | Team that committed the penalty. | NA when `penalty_flag` is FALSE, and on the 2 marker rows. | The accepted infraction's team. If every infraction was declined, the declined team. Offsetting, or accepted penalties on both teams: both names joined with `"; "` (3 rows, e.g. `"Carnegie Mellon; McDaniel"`). |
| 30 | `penalty_no_play` | logical | A penalty nullified the snap (or there was no snap). | Never NA. FALSE on rows with no penalty. | See Key conventions ("No-play gating"). 116 TRUE in 2025: 61 wiped-out snaps (`row_type == "play"`) + 55 dead-ball penalties. |
| 31 | `penalty_declined` | logical | Every infraction on the row was declined. | NA when `penalty_flag` is FALSE. Otherwise TRUE/FALSE. | A row with one declined and one accepted infraction is FALSE (game 1 play 105); the accepted one supplies the yards. |
| 32 | `penalty_text` | character | The raw penalty clause, from the first upper-case "PENALTY" to the end of the text. | NA when `penalty_flag` is FALSE, and on the 2 marker rows (they say "Penalty", not "PENALTY"). | Starting at upper-case "PENALTY" skips the "TOUCHDOWN nullified by penalty" wording. |
| 33 | `situation` | character | Raw down-and-distance text, verbatim, e.g. `"1st and 10 at UC 25"`. | Empty (reads as NA) on `kickoff`, `extra_point`, `two_point`. | Audit column. Whitespace squished. Yardlines appear both as `"CMU35"` and `"UC 25"`. |
| 34 | `play_text` | character | Raw play description, verbatim. | Never NA. | Audit column. Team codes here can differ from `situation`'s ("UCHI" vs "UC", "DSON" vs "DIC"). |
| 35 | `row_type` | character | Classifier label: `play`, `kickoff`, `extra_point`, `two_point`, `penalty_no_play`. | Never NA. | Audit column. Use `penalty_no_play` (col 30), not this label, to decide if a snap counted. |
| 36 | `drive_id` | integer | Drive number within the game, 1..N. | NA only on each game's opening kickoff (11 rows), which comes before any drive. | See "How `drive_id` is assigned". 2025 range 1-33 per game. |

## How `drive_id` is assigned

d3's drive markers are noisy. A drive normally opens with a header row
("TEAM at MM:SS") and a start row ("TEAM drive start at MM:SS."), but the pair
isn't always complete, and the start row is sometimes repeated mid-drive after
a spot correction or penalty. The reliable boundary is the footer row ("N
plays, N yards, MM:SS elapsed") that closes each drive. So a new drive begins
at the first drive marker after a footer, and later markers before the next
footer restate the same drive.

Rows between a footer and the next drive's marker (the kickoff after a score)
keep the previous drive's `drive_id`, the same way they keep its `pos_team`.
This follows the source layout. cfbfastR/CFBD instead put a kickoff on the
receiving team's drive. StatCrew also opens a new "drive" for a re-kick after a
penalty on a punt (a 0-play footer, e.g. the Berry game) and for some
penalty-on-field-goal sequences. Those count as separate drives here.

## How `yards_to_goal` knows which side is whose

`situation` writes yardlines with a short code ("UC 25", "CMU35"), but d3 never
states which code belongs to which team. `infer_own_side()` works it out per
game. On consecutive snaps by the same offense on the same side of the field,
the yard number rises when that side is the offense's own and falls when it's
the opponent's. Gains far outnumber losses, so a whole-game vote is decisive.
It stops with an error if a game doesn't have exactly two teams and two codes,
or if the vote is close. The play text uses its own codes ("UCHI", "DSON");
`infer_text_team()` maps them to teams (one always matches a `situation` code,
the other by elimination). Those mappings are used for fumble recoveries and
`penalized_team`.

## Known issues (to fix later)

- **Kickoff `pos_team` is sometimes the receiving team.** Kickoffs inherit
  `pos_team` from the previous drive. That's right after a normal score, but
  wrong for the **second-half opening kickoff** (it inherits the first half's
  last drive). In 2025 six second-half openers have the receiving team as
  `pos_team`: Chicago 93, Berry 77, Johns Hopkins 87, Muhlenberg 88, Dickinson
  101, F&M 86. It's also wrong after the **Ursinus pick-six** (Ursinus play 49):
  the extra point (50) and kickoff (51) carry Ursinus instead of CMU, because
  d3 prints no drive row for the scoring team there. The other five defensive
  TDs are correct. On affected rows `def_pos_team` and the sign of any
  `penalty_yards_signed` are flipped too.
- **Classifier labels two return-penalty kickoffs `penalty_no_play`.** Dickinson
  (`20251101_dlys`) play 191 and Ursinus (`20251115_h3wh`) play 73 are
  kickoffs with holding on the return. They should be `row_type` / `play_type`
  `kickoff`. Worked around: `penalty_no_play` is FALSE on both because it's
  based on the text, not the label. The classifier (`R/classify.R`) is not
  fixed yet.
- **"Penalty after touchdown before PAT" marker rows are kept.** UW-La Crosse
  plays 106 and 161 are admin markers. The real penalty is the row before. They
  have `penalty_flag` TRUE, `penalty_no_play` FALSE, and the other penalty fields
  NA. They should probably be dropped.

## Source quirks

- **Placeholder situation on PAT penalties.** A penalty before an extra point
  shows as a `penalty_no_play` row with a made-up situation like "1st and 10 at
  JHU3", so `distance` (10) exceeds `yards_to_goal` (3). Two rows in 2025
  (Johns Hopkins play 12, Dickinson play 176). `Goal_To_Go` is FALSE there.
- **Bad clock readings.** A nullified TD in game 1 (play 135) prints "clock
  00:00" mid-4th. It's discarded. The Berry game prints a "clock 15:00" spot
  correction just before "End of half, clock 00:00". It affects no kept row.
- **End-of-half row wording.** The first half sometimes ends with "End of game,
  clock 00:00" (game 1). The period is still read correctly from the markers.
