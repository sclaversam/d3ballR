# PBP Schema Target + Build Plan (v2)

Hand this to Claude Code. It defines the target schema (cfbfastR-aligned) and the
exact order to build it. Do the tasks in order; commit after each. Surface
checks and wait for confirmation where noted — do not finalize rules unsupervised.

## Context (why this is happening)

Week 1 was validated against CMU's internal data. Finding: CMU's internal PBP is
hand-charted and contains real errors (e.g. internally impossible down/distance
sequences), so it is NOT ground truth. The authoritative source is the
d3football StatCrew feed. Validation target is now: faithfully represent d3, and
adopt the cfbfastR / nflfastR schema so the output is compatible with standard
college-football analytics tooling.

The scan of week 1 surfaced issues that are almost all one gap: penalties and
play outcomes aren't captured, and play_type conflates the play call with the
result. The cfbfastR schema fixes this by separating play_type from boolean
outcome flags and adding explicit penalty columns.

Keep the schema team-agnostic (this expands to the full Centennial Conference
later): use pos_team / def_pos_team, no CMU-specific "opponent" column.

The scrape -> classify -> play-type steps are already validated and DO NOT
change. This plan changes the final assembly (build_pbp) to emit the new schema,
and adds outcome/penalty/clock population. The 11 CMU 2025 per-game CSVs get
regenerated into the new schema (same rows, new columns).

## Conventions confirmed against cfbfastR and nflfastR

These are not our inventions — they match how cfbfastR handles the same StatCrew
source. Follow them exactly.

1. yards_gained is PLAY yards only. It is the play's own yardage clause (the
   "for N yards" of the rush/catch), never the net including penalty, never the
   penalty yardage. cfbfastR takes the carrier's play clause as-is.

2. Penalty yardage lives in its own column, signed. Use penalty_yards_signed:
   POSITIVE means the offense gained (the DEFENSE was flagged); NEGATIVE means
   the offense lost (the OFFENSE was flagged). Also keep penalized_team (which
   team committed it) and penalty_text (raw clause). Example: offensive delay of
   game 5 yards -> penalty_yards_signed = -5, penalized_team = offense.
   Defensive face mask 11 yards -> +11, penalized_team = defense.

3. No-play penalties gate ALL yardage and outcome flags. This is the critical
   rule and the exact bug cfbfastR had to patch on this same source. The d3 page
   PRINTS the wiped-out attempt in full (e.g. "pass complete ... for 54 yards ...
   TOUCHDOWN nullified by penalty ... PENALTY ... NO PLAY."). When
   penalty_no_play is TRUE, FORCE yards_gained to NA and every outcome flag
   (rush, pass, completion, sack, int, touchdown, etc.) to FALSE, REGARDLESS of
   what the play text says. Do not credit the negated attempt.

4. A penalty on a play that COUNTS keeps the play. One row, yards_gained = the
   play's yards, penalty fields also populated, penalty_no_play = FALSE. Example
   (face mask on a 10-yard completion, ball ends 21 yards downfield):
   yards_gained = 10, penalty_yards_signed = +11, penalty_no_play = FALSE. Never
   sum to 21 in yards_gained.

5. Two different number patterns in one string. On a penalty-on-a-play row, the
   play yardage reads "for N yards" and the penalty enforcement reads "N yard
   from X to Y". Parse the play yards from "for N yards" and the penalty yards
   from "N yard from X to Y" — do not confuse them.

## Target schema (36 columns, in order)

Populate what d3 supports; the flag/penalty/clock columns start empty in Task 2
and get filled in Task 3.

| # | column | type | definition / how to populate | task |
|---|--------|------|------------------------------|------|
| 1 | game_id | chr | boxscore id, constant per game | have |
| 2 | play_index | int | sequential 1..N over kept rows, per game | have |
| 3 | drive_play_number | int | play's position within its current drive; reset at each drive boundary | T2 |
| 4 | period | int | quarter 1-4 (or OT) | rename |
| 5 | half | int | 1 for period 1-2, 2 for period 3-4 | T2 |
| 6 | clock_known | chr | stated game clock "MM:SS" on rows that carry one, else NA | T3 |
| 7 | clock_prev_known | chr | most recent stated clock at/before this row | T3 |
| 8 | clock_next_known | chr | next stated clock at/after this row | T3 |
| 9 | pos_team | chr | team with the ball (offense) | rename |
| 10 | def_pos_team | chr | the other team (defense) | T2 |
| 11 | down | int | 1-4 for scrimmage plays; NA for kickoff/extra_point/two_point | have |
| 12 | distance | int | yards to go; NA where not applicable | have |
| 13 | yards_to_goal | int | distance to opponent's end zone (0-100). From yardline token + which side pos_team is on. Own 25 -> 75; opp 25 -> 25. NA if pos_team NA | T2 |
| 14 | Goal_To_Go | lgl | TRUE on "and Goal" situations | T1 |
| 15 | play_type | chr | scrimmage category (rush, pass_complete, pass_incomplete, pass_intercepted, sack, punt_no_return, punt_with_return, punt_blocked, field_goal_good, field_goal_missed, field_goal_blocked, kneel); for non-scrimmage kept rows the row_type (kickoff, extra_point, two_point, penalty_no_play) | have |
| 16 | yards_gained | int | PLAY yards only (convention 1). NA on no-play (convention 3) | T3 |
| 17 | rush | lgl | TRUE if a rush (NCAA charges a sack to rushing — note, but keep sack its own play_type for now) | T3 |
| 18 | pass | lgl | TRUE if a pass attempt (complete/incomplete/intercepted; NCAA excludes sacks) | T3 |
| 19 | completion | lgl | TRUE if a completed pass | T3 |
| 20 | sack | lgl | TRUE if a sack | T3 |
| 21 | int | lgl | TRUE if intercepted | T3 |
| 22 | fumble_vec | lgl | TRUE if a fumble occurred | T3 |
| 23 | turnover | lgl | TRUE if possession changed via turnover (int, lost fumble, downs) | T3 |
| 24 | downs_turnover | lgl | TRUE on turnover on downs | T3 |
| 25 | touchdown | lgl | TRUE if the play scored a TD that COUNTS (nullified TD -> FALSE, convention 3) | T3 |
| 26 | safety | lgl | TRUE if a safety | T3 |
| 27 | penalty_flag | lgl | TRUE if any penalty is mentioned on the play | T3 |
| 28 | penalty_yards_signed | int | signed penalty yardage: + = defense flagged (offense gains), - = offense flagged (offense loses). NA if none | T3 |
| 29 | penalized_team | chr | team that committed the penalty (offense/defense or team token). NA if none | T3 |
| 30 | penalty_no_play | lgl | TRUE if the penalty nullified the snap (NO PLAY) | T3 |
| 31 | penalty_declined | lgl | TRUE if the penalty was declined | T3 |
| 32 | penalty_text | chr | the raw penalty clause, else NA | T3 |
| 33 | situation | chr | raw down-and-distance text, verbatim (audit) | have |
| 34 | play_text | chr | raw play description, verbatim (audit) | have |
| 35 | row_type | chr | classifier label (audit): play, kickoff, extra_point, two_point, penalty_no_play | have |
| 36 | drive_id | int | sequential drive number within the game (optional but cheap; increments at each drive boundary) | T2 |

## Clock rule (critical ordering)

Derive all three clock columns from the FULL classified row set BEFORE the
kept-row filter, exactly like quarter and possession are derived. The clock is
stated on rows that mostly get DROPPED:
- quarter starts: "Start of Nth quarter, clock M:SS"
- drive starts: "TEAM at M:SS" and "TEAM drive start at M:SS"
- timeouts: "Timeout TEAM, clock M:SS"
- plus some KEPT rows: scoring plays and field goals carry "clock M:SS" in text

Steps: on the full set, set clock_known from any row stating a clock; compute
clock_prev_known (last known at/before, directional fill) and clock_next_known
(next known at/after); THEN apply the kept-row filter. Each kept play then
carries a time bracket from the surrounding dropped anchor rows.

NEVER interpolate a single point clock between anchors — the clock doesn't tick
uniformly (stops on incompletions, out of bounds, penalties). The bracket
(prev/next) is the honest representation.

## Build order (do in sequence, commit after each; surface checks and wait)

### Task 1 — Fix Goal_To_Go (isolated, quick)
Rename goal_to_go -> Goal_To_Go. Fix detection so every "and Goal" situation is
TRUE (currently FALSE on some, e.g. game 1 plays 57 and 158, "1st and goal at
1"). SHOW me all goal-to-go situation strings across the 11 games to confirm the
fix catches every one. Wait for confirmation. Commit.

### Task 2 — Reshape to the target schema (structure only, NO new extraction logic)
Rename existing columns to cfbfastR names (quarter->period, possession->pos_team).
Add def_pos_team, half, drive_play_number, drive_id, and yards_to_goal (compute
from yardline + pos_team side; DROP yard_side/yard_num). Add all boolean flag
columns, penalty columns, and clock columns as empty placeholders (NA/FALSE) so
the schema is complete. Keep situation, play_text, row_type as trailing audit
columns. Regenerate all 11 per-game CSVs. CONFIRM the column set matches this
spec exactly and row counts are IDENTICAL to the pre-reshape checkpoint (same
rows, new shape). Commit.

### Task 3 — Populate the new columns from the play text (incremental)
Fill in this order, with a CHECK CSV after each sub-part (parsed values next to
raw play_text) and wait for confirmation before the next:

- 3a Outcome flags (rush, pass, completion, sack, int, fumble_vec, turnover,
  downs_turnover, touchdown, safety). Show per-flag counts across 11 games + a
  sample. Remember: on penalty_no_play rows these are all FALSE (convention 3).
- 3b Penalties (penalty_flag, penalty_yards_signed, penalized_team,
  penalty_no_play, penalty_declined, penalty_text) per conventions 1-5 above, and
  extend yards_gained to respect them (play yards only; NA on no-play).
- 3c Clock (clock_known, clock_prev_known, clock_next_known) per the clock rule
  above — derived before the kept-row filter.

Commit after each sub-part.

## Spot-checks I will run
- T1: every "and Goal" row is Goal_To_Go TRUE.
- T2: column set matches this spec; row counts identical to checkpoint.
- T3: flag counts football-sane; the week-1 scan rows now correct —
  - play 4 (offensive delay of game, no play): yards_gained NA,
    penalty_no_play TRUE, penalty_yards_signed -5.
  - play 66: fumble_vec TRUE.
  - play 101: downs_turnover TRUE, turnover TRUE.
  - play 105 (punt, running into kicker declined, UC keeps ball): penalty_flag
    TRUE, penalty handled; possession/flags sensible.
  - play 135 (54-yd TD called back, CMU OPI): touchdown FALSE, yards_gained NA,
    penalty_no_play TRUE, penalty_yards_signed -15.
  - the face-mask play: yards_gained 10, penalty_yards_signed +11,
    penalty_no_play FALSE.
  - plays 114, 124, 126, 133: penalty fields populated, yardage gated correctly.
  - play 158: Goal_To_Go TRUE.

## Do NOT build yet
EPA / win probability / any modeled field; player-name extraction; drive-level
rollups beyond drive_id/drive_play_number. Play-level schema only.
