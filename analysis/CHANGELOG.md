# Change log

Earlier history: `analysis/CHANGELOG_v3.md` (the v3 schema batch) and the git
log.

## First-down / new-series flags (60 -> 63 columns)

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
