# PBP Build Plan v3: batch changes

Apply ALL changes below in one pass. No intermediate stops: implement, regenerate
all 11 CMU 2025 per-game CSVs, update docs, commit, and push. I will review the
CSVs afterward. Where something is ambiguous, make the most cfbfastR-consistent
choice and record it in the change log (Section 9) rather than stopping.

The scrape -> classify -> play_type logic stays as is except where noted.

---

## 1. Kickoff possession (match cfbfastR)

On kickoff rows, `pos_team` = the RECEIVING team, `def_pos_team` = the KICKING
team. Never infer it from inheritance of the previous drive.

Determine the receiving team per kickoff:
1. Default: the team named in the next drive header ("TEAM at MM:SS") /
   drive start row.
2. Override: if the kickoff text shows the KICKING team recovered (onside kick
   or muffed return recovered by the kicker), the receiving team is the other
   team. Set `turnover = TRUE` (and `fumble_vec = TRUE` for a muff), and the
   next drive belongs to the kicking team.
3. Fallback when no drive header follows before the next kickoff or end of half
   (e.g. a kickoff return TD, or a missing header like Ursinus play 49 to 51):
   use pre-kick context. After a TD/FG the scoring team kicks; after a safety
   the team that conceded kicks; at the start of a half use the coin toss row
   ("X will receive"); a re-kick uses the same kicking team as the replayed kick.

Effects:
- `penalty_yards_signed` on kickoffs is from the receiving team's view
  (positive = kicking team flagged).
- The opening kickoff of each game is no longer NA for `pos_team`.
- Punts are unchanged: the punting team is `pos_team` (offense).

Also fix the two classifier mislabels so kickoffs are detected correctly:
Dickinson (20251101_dlys) play 191 and Ursinus (20251115_h3wh) play 73 are
kickoffs with a return penalty and must be typed `kickoff`, not
`penalty_no_play`. Fix this in R/classify.R (a row whose text is a kickoff is a
kickoff even if it contains a penalty).

## 2. Drives

- Rename `drive_id` to `drive_number` and place it immediately before
  `drive_play_number`.
- A kickoff is `drive_play_number = 1` of the RECEIVING team's drive (matches
  cfbfastR). PATs and two-point tries stay on the scoring team's drive.
- The opening kickoff gets drive 1. No NA `drive_number` / `drive_play_number`.

## 3. Drop `row_type`, add `scrimmage_play`

- Remove `row_type` from the output (it's redundant with `play_type`).
- Add `scrimmage_play` (logical): TRUE for down-and-distance snaps (any play
  with a non-NA `down`, including penalty_no_play snaps), FALSE for kickoff,
  extra_point, two_point.
- Use the `penalty_no_play` column, not any label, for no-play logic.

## 4. New Tier 1 columns

| column | definition |
|---|---|
| `home`, `away` | from the boxscore header "Away at Home"; constant per game; use the same team spelling as `pos_team` |
| `pos_team_score`, `def_pos_team_score` | score BEFORE the play, from each team's view, forward-filled from score update rows |
| `score_diff` | `pos_team_score - def_pos_team_score`, before the play |
| `field_goal_attempt` | TRUE for field_goal_good / missed / blocked; FALSE on NO PLAY |
| `field_goal_made` | TRUE for field_goal_good only; FALSE on NO PLAY |
| `punt` | TRUE for any punt play_type; FALSE on NO PLAY |
| `scoring_play` | TRUE if points were scored on the play (TD, FG, safety, PAT, two-point) |
| `score_pts` | points scored on the play from `pos_team`'s view: TD +6, FG +3, PAT +1, two-point +2; defensive TD -6, safety conceded -2; 0 otherwise |
| `firstD_by_yards` | "1ST DOWN" appears in the play clause (before any PENALTY clause); FALSE on NO PLAY |
| `firstD_by_penalty` | "1ST DOWN" appears in the penalty clause and the penalty was accepted |
| `down_end`, `distance_end`, `yards_to_goal_end` | the situation of the next scrimmage snap in the same half, expressed from THAT snap's offense view (so on a change of possession it is the new offense's perspective, matching cfbfastR). NA if the play is a scoring play, or no scrimmage snap follows in the half. On PAT/two-point rows: NA. On kickoffs: the receiving team's first snap. |
| `drive_result` | how the row's drive ended, repeated on every row of the drive: TD, FG, MISSED FG, BLOCKED FG, PUNT, BLOCKED PUNT, INT, FUMBLE, DOWNS, SAFETY, END OF HALF, END OF GAME |

No-play gating applies to all new outcome flags: on `penalty_no_play = TRUE`
rows, `field_goal_attempt`, `field_goal_made`, `punt`, `firstD_by_yards`,
`scoring_play` are FALSE and `score_pts` is 0.

## 5. Clock (replace clock_known / clock_prev_known / clock_next_known)

Remove the three old clock columns. Add:

| column | definition |
|---|---|
| `clock_start` | exact game clock at the snap when known, else NA: first snap of each drive = drive start time; the snap right after a timeout = timeout clock; first play of each quarter = 15:00; PAT / two-point / kickoff after a score = that score's stated clock; opening kickoff = 15:00; second-half kickoff = 15:00 |
| `clock_end` | game clock when the play ended, when known, else NA: scoring plays = their stated "clock M:SS"; the last play of a drive ending in a punt, turnover, or downs = the next drive's start time |
| `clock_upper` | always filled: latest known clock at or before the snap (most time it could be) |
| `clock_lower` | always filled: earliest known clock at or after the snap (least time it could be) |

Rules:
- Derive anchors from the FULL classified row set before the kept-row filter
  (drive headers/starts, timeouts, quarter starts, score clocks).
- Bounds stay within the quarter: use 15:00 at quarter start and 00:00 at
  quarter end (every quarter ends at 00:00, so this is a fact, not an
  inference).
- A play's own `clock_end` must NOT bound itself; it only bounds later plays.
  (A scoring play's range is its drive start down to its scoring clock.)
- When the snap is exactly known: `clock_upper == clock_lower == clock_start`.
- Never interpolate a point estimate.
- Discard stated clocks that contradict their neighbors (e.g. game 1 play 135's
  "clock 00:00" on a nullified TD mid-4th) and log them.
- Format all clock columns as zero-padded "MM:SS".

## 6. Final column order (53 columns)

```
game_id, home, away, play_index, drive_number, drive_play_number,
period, half, clock_start, clock_end, clock_upper, clock_lower,
pos_team, def_pos_team, pos_team_score, def_pos_team_score, score_diff,
down, distance, yards_to_goal, Goal_To_Go,
down_end, distance_end, yards_to_goal_end,
play_type, scrimmage_play, yards_gained,
rush, pass, completion, sack, int, fumble_vec, turnover, downs_turnover,
touchdown, safety,
field_goal_attempt, field_goal_made, punt,
scoring_play, score_pts, firstD_by_yards, firstD_by_penalty,
penalty_flag, penalty_yards_signed, penalized_team, penalty_no_play,
penalty_declined, penalty_text,
drive_result, situation, play_text
```

## 7. Regenerate and document

- Regenerate all 11 CSVs in analysis/pbp/. Row counts per game must be
  unchanged from the current version except where the two classifier fixes in
  Section 1 legitimately change nothing about kept rows (they change type, not
  count). Update analysis/pbp_row_counts.csv.
- Rewrite analysis/pbp_schema.md for the 53-column schema: every column with
  type, definition, NA behavior, and notes; key conventions (yards_gained
  play-only, penalty sign, no-play gating, kickoff possession, clock start/end
  and upper/lower bounds, end-state perspective, Goal_To_Go numeric rule);
  updated Known issues (remove the fixed kickoff and mislabel items; keep the
  UW-La Crosse "penalty after touchdown before PAT" marker rows 106 and 161 as a
  known issue); Source quirks.
- Update CLAUDE.md "What is built" to reflect the current schema.
- Update or retire analysis/pbp_schema_and_build_plan.md (mark it superseded by
  this v3 plan).

## 8. Validation reports (write files, do not stop)

Write these to analysis/checks/ and summarize them in the change log:
- `kickoff_possession.csv`: every kickoff with kicking team, receiving team,
  which rule decided it (header / override / fallback), and any disagreement
  between the header, recovery text, and pre-kick context.
- `drive_footer_clock.csv`: for every drive, start clock minus the footer's
  "MM:SS elapsed" vs the next drive's start clock (handle drives that cross a
  quarter). Flag mismatches.
- `clock_bounds.csv`: any row where clock_upper or clock_lower is NA or
  upper < lower in time remaining (should be empty).
- `end_state.csv`: every change-of-possession row with yards_to_goal,
  yards_to_goal_end, and the next play_text.

## 9. Change log, commit, push

- Write analysis/CHANGELOG_v3.md: what changed, any judgment calls made, any
  clocks discarded, and a one-line summary of each validation report.
- Commit in logical commits (kickoff + drives, Tier 1 columns, clock, docs) and
  git push all of them.
