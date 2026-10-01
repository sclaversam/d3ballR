# Change log: PBP build plan v3

Implements every section of `analysis/pbp_build_plan_v3.md` in one pass. The
per-game CSVs in `analysis/pbp/` go from the 36-column v2 schema to the
53-column v3 schema in the plan's exact order. Row counts are **unchanged** in
all 11 games (1,861 rows; `analysis/pbp_row_counts.csv` is identical). The data
dictionary is `analysis/pbp_schema.md`.

Source pages were re-fetched from d3football.com on 2026-10-01 (11 requests, 3
s apart) and cached locally for the build. Repeated full re-scrapes had
triggered d3football's rate limit (HTTP 459) before. Every v2 column that v3
keeps has the same `play_text` on the same rows.

## What changed, by plan section

### 1. Kickoff possession
- **Who has the ball on a kickoff:** `pos_team` is now the **receiving** team
  and `def_pos_team` the kicking team, decided per kickoff by
  `assign_kickoffs()` (`R/kickoffs.R`). The next drive header decides 111 of
  113 kickoffs. The other 2 are overrides where the kicking team recovered:
  McDaniel play 63 (CMU onside kick, recovered by CMU) and F&M play 117 (CMU
  fumbled the return, F&M recovered). Both are `turnover` TRUE. The fallback
  (pre-kick context) was never needed to decide a kickoff. It is still
  computed for every kickoff and agrees with the header on all of them.
- **Changes vs v2:** `pos_team` changed on 106 kickoffs, including the 11
  opening kickoffs that were NA. On the other 7 kickoffs v2's inherited team
  happened to be the receiver already.
- **Kickoff penalty signs:** now from the receiving team's view (positive =
  kicking team flagged). 5 rows flipped: Gettysburg 82, Dickinson 191, F&M 16
  and 166, Ursinus 73. Muhlenberg 51 nets to 0 either way.
- **Turnovers:** McDaniel 63 `turnover` FALSE -> TRUE. This is the only outcome
  flag that changed. F&M 117 was already TRUE.
- **Tries belong to the scoring team.** `pos_team` on a PAT / two-point try,
  and on any penalty or marker row between a score and the next kickoff, is
  the team that scored, read off the next score line. This fixes Ursinus play
  50, the PAT after CMU's pick-six, which v2 gave to Ursinus.
- **Classifier fix (`R/classify.R`).** A row whose text is a kickoff is typed
  `kickoff` even when it carries a return penalty and a stale down-and-distance
  in the situation column. Dickinson 191 and Ursinus 73 move from
  `penalty_no_play` to `kickoff`. Their `down` etc. are NA like every kickoff.
  The rule is checked right after the `play` rule. No other row changed type.
- **Team names.** d3 spells a team two ways on one page ("Chicago" /
  "UChicago"). `build_team_map()` maps every spelling (header, line score,
  score lines, drive rows) to one canonical name, the drive-start spelling v2
  already used for `pos_team`.

### 2. Drives
- **Rename and placement:** `drive_id` -> `drive_number`, placed before
  `drive_play_number`. Neither has NAs. The opening kickoff is drive 1.
- **Kickoffs and tries:** a kickoff is `drive_play_number` 1 of the receiving
  team's drive. Tries stay on the scoring play's drive.
- **New drive definition (`R/drives.R`):** a drive is one team's continuous
  possession. That gives 250 drives vs v2's footer-based count. StatCrew's
  same-team splits are merged (see Judgment calls).

### 3. `row_type` dropped, `scrimmage_play` added
- **Changes:** `row_type` is gone from the output. `scrimmage_play` = row has a
  `down` (1,673 TRUE).
- **No labels in the no-play rule:** `is_no_play()` and
  `parse_yards_gained()` no longer read the classifier label. `penalty_no_play`
  comes from the text alone.

### 4. Tier 1 columns
- **New file:** `R/game_state.R`, wired into `build_pbp()`.
- **Teams and score:** `home`, `away`, `pos_team_score`,
  `def_pos_team_score`, `score_diff`. The running score is checked against all
  92 printed score lines, and **all 92 match**.
- **Kick and scoring flags:** `field_goal_attempt` (24), `field_goal_made`
  (17), `punt` (90), `scoring_play` (159), `score_pts`.
- **First downs:** `firstD_by_yards` (373), `firstD_by_penalty` (39).
- **End state:** `down_end`, `distance_end`, `yards_to_goal_end`.
- **`drive_result`:** PUNT 88, TD 69, INT 19, DOWNS 19, FG 17, FUMBLE 11, END
  OF GAME 10, END OF HALF 8, BLOCKED FG 3, MISSED FG 3, BLOCKED PUNT 2,
  ONSIDE 1. No drive is unclassified.
- **No-play gating:** applies to every new outcome flag. Zero violations.

### 5. Clock
- **Removed:** `clock_known`, `clock_prev_known`, `clock_next_known`.
- **Added (`R/parse_clock.R`):** `clock_start` (exact on 541 rows, including
  all kickoffs and tries), `clock_end` (exact on 348), and `clock_upper` /
  `clock_lower` (never NA, never inverted).
- **Anchors:** derived from the full classified row set before the kept-row
  filter. 15:00 / 00:00 are pinned at each quarter's start and end.

### 6. Column order
53 columns, identical to the plan's list. This was checked programmatically
against the CSV header and the data dictionary.

### 7. Docs
- **`analysis/pbp_schema.md`:** rewritten for the 53-column schema.
- **`CLAUDE.md`:** "Where things are" and "What is built" updated.
- **`README.md`:** the Status section updated.
- **`analysis/pbp_schema_and_build_plan.md`:** marked superseded by v3.
- **Old check files:** `analysis/check_3a_outcome_flags.csv` and
  `analysis/check_3b_penalties.csv` are v2 review snapshots in the old schema.
  They're left as-is for history, and the live reports are now in
  `analysis/checks/`.

## Judgment calls (cfbfastR-consistent choices where the plan was ambiguous)

1. **Kicker recovery is judged against pre-kick context.** The "override"
   needs to know who kicked independently of the next header, because after
   an onside recovery the header names the kicker. The kicker comes from
   context (scorer kicks / coin toss / re-kick). A recovery by the
   *receiving* team (Muhlenberg 84, F&M 16, Gettysburg's onside) is not an
   override.
2. **Second-half kickoff with no coin-toss row.** Coin-toss rows exist in only
   8 games, in four wordings. When none covers the second half, the first
   half's receiving team is taken to kick. This was only used as a cross-check
   (7 kickoffs), since headers decided them all.
3. **Onside kick recovered by the kicker.** It is `turnover` TRUE with
   `fumble_vec` FALSE (no fumble occurred). Its one-play receiving-team drive
   gets `drive_result = "ONSIDE"`, a value added to the plan's list because no
   listed value fits. A return fumble recovered by the kicker is `FUMBLE`.
4. **Fumbling team on a kickoff** is now `pos_team` (the receiver), since
   `pos_team` flipped.
5. **Try-phase rows.** Penalty and marker rows between a score and the next
   kickoff are treated like the try: `pos_team` is the scoring team, they stay
   on the scoring drive, and their end state is NA. After a defensive TD the
   try therefore sits on the *offense's* drive with the *defense* as
   `pos_team`. This follows "PATs stay on the scoring team's drive"; the
   scorer has no drive of its own.
6. **Drives merge StatCrew's same-team splits.** Examples are a re-kick after
   a punt penalty (Berry) and a field goal nullified by penalty (McDaniel). A
   new drive starts only at a kickoff or when `pos_team` changes. A re-kick
   (kickoff right after a kickoff) stays on the same drive.
7. **Defensive scores in `drive_result`.** They are labelled by how the
   offense lost the ball (INT / FUMBLE / PUNT / BLOCKED FG ...), not "INT TD".
   The plan's list has no TD-return values; `touchdown` and `score_pts`
   carry the score.
8. **Blocked kick the kicking team gets back** (McDaniel 147) does not end the
   drive. The same team keeps the ball, and that drive ends in DOWNS later.
9. **Score before the play** = last printed score line + parsed points since,
   rather than a pure forward-fill of score lines. d3 prints the line after
   the try, so a pure fill would give the PAT a "before" score without its
   TD.
10. **First downs.** Only 4 of 11 games print "1ST DOWN", so each flag is
    the text OR a data rule. `firstD_by_yards` excludes goal-to-go plays:
    StatCrew does not credit a goal-to-go TD as a first down, and the first
    version of the rule disagreed with the text on exactly those 13 TDs.
    `firstD_by_penalty` requires a *new* series, so a 5-yard penalty on 1st &
    10 leaving 1st & 5 doesn't count (2 rows). After both refinements the rule
    and the text agree on all 600 snaps in the 4 text games, for both flags.
11. **`scrimmage_play` follows the plan literally** (non-NA `down`). It
    includes the 2 PAT-penalty rows with a placeholder down and the 2 marker
    rows.
12. **Untimed rows inherit `clock_start`.** A dead-ball penalty, PAT or
    two-point try before the snap that restarts the clock gets the same exact
    reading, since no time can run on them.
13. **Restated drive-start rows are bounds only.** A drive-start row repeated
    mid-drive after a penalty (e.g. McDaniel "drive start at 08:12, CMU ball
    on CMU46") is not treated as an exact `clock_start`.
14. **`clock_end` goes slightly beyond the plan's list.** It is the play's own
    stated clock on *any* kept row that prints one, not only scoring plays
    (e.g. a kickoff "CMU ball on CMU35, clock 11:25"). The hand-over rule also
    covers missed / blocked field goals and kickoffs, not only punts /
    turnovers / downs, since all of those give the ball to the other team and
    the next snap starts the clock.
15. **"A play's own clock_end must not bound itself."** This is read together
    with "a scoring play's range is its drive start down to its scoring clock".
    The own `clock_end` may be the play's `clock_lower` (the snap was no later
    than the end) but never its `clock_upper`.
16. **Discarding bad clock readings.** Per quarter, the longest non-increasing
    run of readings is kept, rather than a neighbor-only check. The Berry game
    has two consecutive bad readings, which a neighbor check can't catch.

## Clocks discarded

| game | row | reading | text |
|---|---|---|---|
| 20250906_e064 (Chicago) | play 135 | 00:00 (Q4) | "... TOUCHDOWN nullified by penalty, clock 00:00 PENALTY CMU Pass Interference ... NO PLAY." Previous reading 12:43, next 08:00. |
| 20250920_l58t (Berry) | dropped row (Q2) | 15:00 | "BERRY ball on BERRY35, clock 15:00." (between "clock 00:00." and "End of half, clock 00:00.") |
| 20250920_l58t (Berry) | dropped row (Q2) | 15:00 | "clock 15:00." (same spot) |

## Validation reports (`analysis/checks/`)

- **`kickoff_possession.csv`:** 113 kickoffs. 111 decided by the header, 2 by
  override (McDaniel 63 onside, F&M 117 return fumble), 0 by fallback, and
  **0 disagreements**. Pre-kick context was found for 110: 91 after a score,
  12 from a coin toss, 7 from the second-half rule. The other 3 are opening
  kickoffs in games with no coin-toss row (Berry, McDaniel, F&M), decided by
  the header.
- **`drive_footer_clock.csv`:** 259 d3 drives. 256 reconcile to the second: 92
  against the score clock, 144 against the next drive start, 20 against the
  end of half. The **3 flagged** are all 0-play drives whose footer says "00:00
  elapsed" while time did run: F&M footer row 28 (09:55 -> 09:47, 8 s),
  Ursinus row 136 (00:24 -> end of half, 24 s), Misericordia row 161 (12:23 ->
  12:18, 5 s). This is a source quirk, not a parser error.
- **`clock_bounds.csv`:** **empty**. No NA bounds and no upper < lower.
- **`end_state.csv`:** 343 change-of-possession rows.
  - Every kickoff's next snap is by its receiving team, except the 2
    overrides, which go to the kicking team as intended.
  - A non-kickoff's next snap is by the same team only on 5 of the 6
    defensive TDs (end state NA) and McDaniel 147 (blocked FG the kicker
    regained). The 6th defensive TD, McDaniel 61, is followed by CMU's
    recovered onside kick.
  - Implied net punt (`yards_to_goal + yards_to_goal_end - 100`) ranges from -1
    to 62. The -1 is real: Johns Hopkins play 129, a 36-yard punt with a
    37-yard return.

## Commits

1. Kickoff possession and cfbfastR drives (sections 1-2).
2. Tier 1 columns, `scrimmage_play`, `row_type` dropped (sections 3-4).
3. Clock columns (section 5).
4. Docs, change log, tests (sections 7-9).
