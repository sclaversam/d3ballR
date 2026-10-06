# Change log

Earlier history: `analysis/CHANGELOG_v3.md` (the v3 schema batch) and the git
log.

## First-down flags moved to the snap that starts the series

The five columns keep their cfbfastR names (63 columns total) but now sit on
the **first snap of the new series** (the 1st-and-10 / 1st-and-goal snap), not
on the play that caused it. This replaces the earlier causing-row placement
described in the next section.
- **`firstD_by_kickoff`:** first snap after a kickoff, whichever team
  recovered.
- **`firstD_by_poss`:** first snap after a change of possession or a regained
  punt / FG, and the first snap of every overtime possession.
- **`firstD_by_yards` / `firstD_by_penalty`:** same offense, from the previous
  play.
- **Exclusivity:** mutually exclusive, with precedence kickoff > poss >
  yards > penalty when two causes point at one snap. `new_series` is any of
  them.
- **Other rows:** kickoffs, tries, dead-ball penalty rows and mid-series
  snaps are FALSE in all five.

### Divergences from cfbfastR (3.0.0)

1. **Kickoff flag moved off the kickoff row.** cfbfastR sets
   `firstD_by_kickoff` on the kickoff row (`kickoff_play == 1 & down == 1`)
   and also flags the first snap after it `firstD_by_poss`
   (`drive_event_number == 2` after a kickoff). Here the kickoff row has no
   flag and the first snap after it is `firstD_by_kickoff`. The other three
   flags are on the same row as cfbfastR (the snap that starts the series).
2. **Mutually exclusive.** cfbfastR computes the four independently, so they
   can overlap. Here exactly one is TRUE per new series (2 snaps in 2025 had
   two different causes; precedence applied).
3. **Declined penalties.** cfbfastR's `first_by_penalty` includes a
   penalty-type play with a declined penalty whose yardage reached the line.
   Here a declined penalty never counts; that series start is
   `firstD_by_yards`.

### Validation (2025, 62 games, cache only)

- **Totals:** 3,534 series starts, each a snap with exactly one flag. No
  kickoff, try or dead-ball penalty row is flagged.
- **Every flagged snap is a 1st down:** all but 1. The exception is a d3
  quirk: after a lost fumble, d3 printed "3rd and 1" for the new offense.
- **Every 1st-down snap is flagged:** 3,533 of 3,623. Of the rest, 89 are
  replays of the same 1st down (76 after a no-play penalty, 13 after an
  accepted penalty on a live play). The 1 real exception follows the lateral
  play whose `yards_gained` reads only the first yardage segment (known
  issue).
- **Reconciliation and tests:** all 62 games reconcile with their boxscore
  finals; 377 tests pass.

## First-down / new-series flags (60 -> 63 columns): superseded placement

**New columns:** `firstD_by_kickoff`, `firstD_by_poss`, `new_series`, next to
`firstD_by_yards` and `firstD_by_penalty` (cfbfastR names). Built from the
cache only; all 62 games in `analysis/pbp/2025/` rebuilt, all 62 still
reconcile with their boxscore finals, and 379 tests pass. Report:
`analysis/checks/2025/first_downs.md`.

### What cfbfastR does (cfbfastR 3.0.0, `prep_epa_df_after()`, read from the installed package)

- **`firstD_by_kickoff`** = `kickoff_play == 1 & down == 1`, on the kickoff
  row itself.
- **`firstD_by_poss`** is on the NEXT snap. It is set when the previous play
  was a punt, turnover on downs, or turnover with a change of possession;
  on the first snap after a kickoff (`drive_event_number == 2`) or after a
  scoring play; and on any play that opens a drive
  (`drive_event_number == 1`).
- **`firstD_by_yards` / `firstD_by_penalty`** are on the NEXT snap. They are
  set from the previous play's `first_by_yards` (normal play with
  `yards_gained >= distance`) or `first_by_penalty` (penalty-type play with
  `penalty_1st_conv`, or a declined penalty where the play gained the
  distance), and both require no change of possession.
- **`new_series`** = drive changed OR previous `first_by_yards` OR previous
  `first_by_penalty`.
- **Precedence:** none explicit; the four are computed independently.
  - Possession effectively outranks yards and penalty (no change of
    possession is required for those).
  - Yards vs penalty is decided by play type, not by an order.
  - Flags can overlap: a kickoff row is `firstD_by_kickoff` and the next snap
    `firstD_by_poss`.

### Divergences from cfbfastR

1. **Which row.** Flags sit on the row that CAUSES the new series, consistent
   with this package's existing `firstD_by_yards` / `firstD_by_penalty`.
   cfbfastR puts all but `firstD_by_kickoff` on the snap that starts the
   series.
2. **Mutually exclusive.** Precedence is kickoff > poss > yards > penalty;
   `new_series` is their union. cfbfastR can count one series twice (the
   kickoff and the next snap).
3. **Yards before penalty, including declined penalties.** A play that
   reaches the line is `firstD_by_yards` even with a penalty that also
   awarded a first down (game 1 play 11: 10-yard catch + face mask). 25 rows
   in 2025 had both. cfbfastR labels a penalty-type play with a *declined*
   penalty and enough yards as `first_by_penalty`, which is semantically
   wrong: a declined penalty awards nothing.
4. **No flag after a score, and none at the first overtime possession.**
   cfbfastR flags the snap after a scoring play and the first snap of every
   drive, including the first OT possession. Here scoring plays, tries, and
   plays with no connected next snap (end of half / game / OT period; the last
   regulation play does not lead into OT) carry no flag.
5. **Kicks regained by the kicking team.** A punt or field goal the kicking
   team gets back after a muff / return fumble is `firstD_by_poss` on the kick
   row (4 rows in 2025). cfbfastR would give `firstD_by_poss` to the next snap
   (a new drive). A kickoff the kicking team recovers stays
   `firstD_by_kickoff` (6 rows); cfbfastR would also flag the next snap
   `firstD_by_poss`.

### Rule changes made while validating

- **Offensive penalty during a play.** An accepted offensive penalty (e.g.
  holding) can take a first down away even when the yardage reached the line,
  and even when d3 printed "1ST DOWN" before the penalty clause.
  `firstD_by_yards` now stands only if the same offense's next snap is a new
  series, not the same 1st down moved back by the enforcement. This fixed
  about 10 rows.
- **Penalty with no yardage.** A penalty printed with no yardage ("PENALTY
  FMC Pass Interference, 1ST DOWN. NO PLAY.") is now parsed as an accepted
  0-yard infraction, so it gets `penalized_team` and can award
  `firstD_by_penalty`.
- **Negative distance.** A situation with a negative distance (d3 printed "4th
  and -2" once) now keeps its down instead of losing it.

### Consistency check results (2025, 62 games)

- **Agreement:** 8,965 of 8,969 checkable rows agree with the next snap's
  situation.
- **The 4 mismatches:** 3 d3 quirks where the flag is right, plus 1 known
  issue.
  - A lost fumble, after which d3 kept the old down for the new offense.
  - Two dead-ball offensive penalties, after which d3 printed 1st & 10 instead
    of a longer distance.
  - A completion with a lateral, where `yards_gained` reads only the first
    yardage segment (−1 instead of +17), so the first down is missed.
    `yards_gained` on laterals is a known issue to fix separately.
