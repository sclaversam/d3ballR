# `build_pbp()` output schema

Data dictionary for the per-game tables in `analysis/pbp/{game_id}.csv`,
produced by `R/build_pbp.R`. One row per event CMU logs (see `row_type`
below); this is d3ballR's own schema, not CMU's exact column names/values --
that mapping comes later (see `analysis/rowtype_to_cmu_category.csv` for the
row_type/play_type -> CMU play_category design notes).

Types below are the in-memory R type built by `build_pbp()`. A couple round-
trip through `write.csv()`/`read.csv()` slightly differently than their
in-memory type -- noted where that applies.

| column | type | definition | NA / convention notes |
|---|---|---|---|
| `game_id` | character | Boxscore id (e.g. `"20250906_e064"`), constant per game. | Never NA. |
| `opponent` | character | CMU's opponent for the game, read from the boxscore's line-score table header, constant per game. | Never NA. |
| `play_index` | integer | Sequential 1..N over the kept rows (the CMU-logged events) for this game. | Never NA. |
| `quarter` | character | Quarter number, forward-filled from the quarter-marker rows before they're dropped. | Never NA. Stored as character (not integer) so a future `"OT"` game can be represented without a type change; every 2025 game is regulation-only (values `"1"`-`"4"`), so it currently round-trips through the CSV as integer on read-back. |
| `possession` | character | The team with the ball on this row, forward-filled from `drive_header`/`drive_start` rows before they're dropped. | Exactly one NA per game: the opening kickoff, which occurs before any drive has established possession -- there's nothing earlier to forward-fill from. Value is whichever team-name spelling the source drive row used (e.g. `"UChicago"` from a `drive_start` row vs. `"Chicago"` from a `drive_header` row) -- not yet normalized against `opponent`. |
| `row_type` | character | The classifier label from `R/classify.R`, carried through so the table can be sliced/reconciled by event type later. | Kept rows are exactly the five CMU logs: `play`, `kickoff`, `extra_point`, `two_point`, `penalty_no_play`. |
| `down` | integer | Down (1-4), parsed from `situation`. | NA for `kickoff`/`extra_point`/`two_point` (no down applies to those events, matching how CMU logs them). Non-NA for `play` and `penalty_no_play`, which always carry a real down-and-distance. |
| `distance` | integer | Yards to go, parsed from `situation`. | NA wherever `down` is NA. On a literal "and Goal" situation, `distance` is the yards to the goal line. |
| `Goal_To_Go` | logical | TRUE when the line to gain is the goal line. d3 writes this two ways: literally ("1st and Goal at CMU06") and as a number equal to the distance to the goal ("1st and 4 at UC 4"). Both are TRUE: the text says "Goal", OR `distance` equals the yards to the goal line (computed from the yardline token and which side is the offense's own; see `infer_own_side()`). | NA wherever `down` is NA (no situation to read). |
| `yard_side` | character | The team token on the yardline (e.g. `"CMU"`, `"UC"`), parsed from `situation`. | NA at midfield (`"at 50"`, no team letters) and wherever `down` is NA. Not yet seen at midfield in the 2025 data, but the parser handles it. |
| `yard_num` | integer | The yard number off the yardline, parsed from `situation`. Handles both `"CMU35"` (no space) and `"UC 25"` (space) spacings. | NA wherever `down` is NA. |
| `play_type` | character | For `row_type == "play"`: the parsed play category from `R/parse_play_type.R` (`rush`, `pass_complete`, `pass_incomplete`, `pass_intercepted`, `sack`, `punt_no_return`, `punt_with_return`, `punt_blocked`, `field_goal_good`, `field_goal_missed`, `field_goal_blocked`, `kneel`). For the other four kept row types, `play_type` is just `row_type` itself (`kickoff`, `extra_point`, `two_point`, `penalty_no_play`). | Never NA within the kept row set. |
| `yards_gained` | integer | Play yards only, penalty enforcement yardage excluded. | Currently populated only for `play_type` in `rush`/`pass_complete`/`sack`/`kneel` (loose gain/loss regex on the description) and `pass_incomplete` (always 0). NA for `kickoff`/`extra_point`/`two_point`/`penalty_no_play` (no snap, or not a rush/pass yardage stat) and for `pass_intercepted`/punts/field goals within `play`, where what "yards_gained" should mean isn't settled yet -- deliberately loose pending real yardage validation. |
| `situation` | character | Raw down-and-distance text, verbatim (e.g. `"1st and 10 at CMU35"`). | Empty string `""` for `kickoff`/`extra_point`/`two_point`, which have no situation line. |
| `play` | character | Raw play description text, verbatim. | Never NA/empty within the kept row set. |

## Not built yet

Per CLAUDE.md's ordering, these are intentionally out of scope for this
table as it stands:

- Signed `field_pos` (negative on the offense's own side, positive on the
  opponent's side) -- `yard_side`/`yard_num` give the raw yardline, but
  computing the signed version requires reconciling `yard_side` against
  `possession`, not yet done.
- Penalty detail columns (`has_penalty`, `penalty_yards`, `penalty_text`) --
  needed to explain the row-count and yardage gap CMU's data has, since CMU
  drops penalty rows entirely.
- CMU's exact column names/values (`side_of_ball`, `play_category`,
  `play_result`, etc.) -- see `analysis/rowtype_to_cmu_category.csv` for the
  mapping design notes; not applied to this table yet.
