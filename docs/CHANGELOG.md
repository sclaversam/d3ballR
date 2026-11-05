# Changelog

How the play-by-play got to its current form, with the decisions that matter
for reading it. Newest first. Current definitions are in
[`schema.md`](schema.md); how to run and check the pipeline is in
[`pipeline.md`](pipeline.md).

## Learning from batch 1: fetching, clocks, known source exceptions

Asked by Sam (2026-11-05): fold each batch's fixes into the pipeline so
later batches make fewer mistakes. "Lessons from each batch" in
`pipeline.md` now lists every quirk, its generic rule and where it was
first seen.

- `prefetch_ncaa_games()` fetches ncaa.com's scoring summary for any game
  whose play-by-play has no running score, right after that game, within
  the same request budget (and for cached games still missing it). With it,
  `20250913_5ivd` (Albion 45, Bluffton 39) and `20250913_8l2c` (Western New
  England 28, Salve Regina 34) reconcile.
- `fetch_ncaa_json()` doesn't retry a path that returned an HTTP error
  earlier in the run (ncaa.com's 500 / 502: no play-by-play yet); the game
  stays pending for the next run. In batch 1 the retries used up the budget.
- Per-play printed clocks: when most of a game's are "(00:00)"
  (`20250906_pzhf` prints it on nearly every play), every 00:00 reading in
  that game is dropped. Only `20250906_pzhf` changes.
- `data-raw/ncaa/known_exceptions.csv` lists source gaps:
  `20250906_hbla` (play-by-play ends after Q3) and `20250906_wk1h` (called
  off for storms; ncaa.com's final matches neither the plays nor its own
  scoring summary). The build report lists them apart from failures; the
  score test skips them with the reason and fails if one starts to
  reconcile.

## ncaa.com play table: possession after kickoffs and in overtime, nullified and repeated lines

Fixing the score misses from the first all-D3 batch (2026-11-05, asked by
Sam). All in `R/ncaa.R`; the parser is unchanged.

- **Drives open after a kickoff, on the game's first snap, and in
  overtime.** In games that have "drive start" lines, a drive used to open
  only at such a line or after a snap that can end a possession (punt,
  turnover, 4th down). Some files have "drive start" lines for only a few
  drives (Lewis & Clark at Puget Sound, `20250906_pzhf`), or none for the
  first drive (`20250913_2k0r`), so possession carried over from the
  previous drive. Now a different team snapping also opens a drive when a
  kickoff came since the last snap, on the game's first snap, when the
  previous snap scored a touchdown, and on the first snap of each overtime
  period (no kickoff there). Fixes `20250906_pzhf`, `20250913_2k0r`,
  `20250913_c7zf`, and the overtime possessions of `20250913_5ivd`. It also
  corrects possession in four games that already reconciled: an onside kick
  recovered by the kicking team (`20250905_0otb`, `20250913_8x3b`, whose
  first drive had no team), and drives after a kickoff credited to the
  kicking team (`20250906_dcg5`, `20250913_b286`).
- **"TOUCHDOWN nullified by penalty" is not a touchdown** when deciding
  whether ncaa.com dropped an extra point. A kickoff "return 89 yards ...
  TOUCHDOWN nullified by penalty" right after a touchdown stopped the missing
  kick from being added (`20250906_8o5p`).
- **Lines ncaa.com repeats verbatim are dropped** (same text, clock, down and
  distance and score as the line before). A repeated safety counted twice in
  `20250904_zik0`. 12 such repeats in 12 games of the batch; in the other 11
  only `drive_play_number` shifts.
- The build report counts games whose `score_reconciled` is blank (no points
  parsed) as not passing, instead of printing "NA of N".

Still not reconciling, all source gaps rather than parser errors:
- `20250906_hbla` (CWRU 17, Rowan 17): ncaa.com's play-by-play stops at the
  end of the 3rd quarter; CWRU's last 3 points aren't in it.
- `20250906_wk1h` (Vermont State Castleton 16, Westfield State 12): the game
  was called off for storms partway through; the plays give Castleton 14.
  Left as is.
- `20250913_5ivd` (Albion 45, Bluffton 39) and `20250913_8l2c` (Western New
  England 28, Salve Regina 34): no running score and touchdowns with no try
  line; which tries were good is in ncaa.com's scoring summary, which isn't
  cached (one request per game).

## Yardline sides: plays that settle it first, then the vote

Decided by Sam (2026-11-05). `infer_own_side()` works out which yardline
token ("GCP", "GCQ") is each team's own side. It used to rely only on a
vote: on consecutive snaps by one offense, the yard number goes up on its
own side. Greensboro at Guilford (`20250906_nidd`) failed that vote's 2-to-1
safety bar (47 vs 27) because Greensboro was sacked 8 or 9 times; every
loss of yards votes the wrong way.

Now plays that settle it come first:
- after a touchback, the next snap is the receiving team's 1st down at its
  own 25 (kickoff) or 20 (punt);
- a false start (always on the offense) moves the ball back.

They decide when a game has them (56 of the 58 ncaa.com Centennial games
do) and they agree at least 3 to 1; a decisive vote that contradicts them
stops the game with an error. When there are none, or they split (games
where ncaa.com credits stretches of plays to the wrong team, such as
`20250906_pzhf` and `20250913_c7zf`), the vote decides, with sacks,
losses, kneel-downs and penalty plays left out. A touchback on a line that
also has a penalty (running into the kicker) doesn't count. Rebuilding the 58
ncaa.com Centennial games and the 133 d3football games gives identical
CSVs.

## Source switched to ncaa.com (Centennial 2025 rebuilt)

Decided by Sam (2026-11-04): d3football's firewall now serves scripts a
bot challenge, so the play-by-play comes from ncaa.com, read as JSON
through a local `henrygd/ncaa-api` server. Sam will reassess the columns
and accuracy later. The 71 columns are unchanged.

**How:** ncaa.com's play text is the same StatCrew text as d3football's,
so the parser is unchanged. New `R/ncaa.R` maps each season-index game to
its ncaa.com contest (`map_ncaa_contests()`) and rebuilds d3football's
(situation, play) table from the JSON (`fetch_ncaa_game()`,
`ncaa_play_table()`). `build_season()` gains `source = c("ncaa",
"d3football")`. `game_id` is still d3football's id.

**Layout:** ncaa.com builds go to `pbp/{season}/` and `checks/{season}/`.
The 133 d3football games moved to `pbp/d3football/2025/` and
`checks/d3football/2025/` (`season_index.md` stays in `checks/2025/`).

**Labelled additions:** ncaa.com drops many extra-point lines. When the
running score rises by exactly one point more than the try lines account
for, an extra point is added after the touchdown, with `play_text` "kick
attempt good [added by d3ballR: ...]". Some host schools' files (CMU home
games) have no running score at all. For those, Sam suggested checking
ncaa.com's box score and scoring summary. The scoring summary lists every
good try after its touchdown, so it decides: a good kick or two-point try is
added when it lists one, and nothing when it doesn't. A final-score rule
(short by exactly one point per try-less touchdown) is kept only as a
fallback for touchdowns the summary doesn't list. The box score's
`patAttempted` was 0 next to 5 made, so it isn't used. Centennial 2025 has
100 added extra points: 91 from the running score and 9 from the scoring
summary. d3football's copies agree on all 8 of those 9 it has.

**Conferences from ncaa.com** (asked by Sam): d3football's team pages
are blocked, so for ncaa.com builds each team's conference comes from
ncaa.com's scoreboards, which tag every team in every game (29 D3
conferences; every team has the same tag all season). Names and codes
follow d3football's (`data-raw/ncaa/conference_names.csv`). ncaa.com has
no conference-game marker, so `conference_game` is a regular-season game
between two teams of the same conference. It matches d3football's "*"
marker on all 58 Centennial games, and on 292 of the 293 games with a
cached marker. The exception is Gallaudet, which ncaa.com tags SCAC while
d3football counted its game with Randolph-Macon (ODAC) as a conference
game. NJAC teams, whose name was pending a d3football fetch, now read
"NJAC".

**Shared parser changes** (both sources):
- `try_phase_team()` (rule 1) uses a kickoff only if it comes before the
  next live snap. Otherwise, when ncaa.com dropped a kickoff, the try was
  given the team of a kickoff much later in the half.
- `derive_clock()`: a play also opens a new drive's clock when its
  possession differs from the last play's, not only after a drive footer
  or kickoff. ncaa.com has no drive footers ("N plays, Y yards").
- Rebuilding the 133 cached d3football games with both changes gives
  byte-identical CSVs.

**Centennial 2025 from ncaa.com:** 58 of 62 games built, and all 58 match
ncaa.com's final scores. Not built:
- one is pending (ncaa.com 502);
- two are non-NCAA bowls that ncaa.com doesn't have;
- the national semifinal at UW-River Falls (`20251220_vlfc`), whose
  ncaa.com file tags every line with one team.

On the 7,136 rows whose play text matches the d3football build:
- `pos_team`, `score_pts`, `yards_gained`, the penalty columns and
  `td_team` agree 100%;
- down, distance, yards to goal, drive number and `clock_start` agree
  99.5-99.7%.

The `first_downs.md` series check has 21 exceptions in 58 games. 5 are
the same as in the d3football build. The other 16 are not yet explained:
the one traced follows a kickoff ncaa.com dropped, and most are in games
whose ncaa.com file differs from d3football's.

## Return-touchdown columns (69 → 71 columns)

Decided by Sam (2026-11-04). Added nflfastR's `return_touchdown` and
`td_team`, after `touchdown`. No existing column changed.

Why: on a pick-six or fumble-return touchdown `pos_team` is the team that
lost the ball and `score_pts` is −6, as in cfbfastR / nflfastR, but nothing
named the scorer, so counting `touchdown` by `pos_team` credited the
touchdown to the team that threw the interception. `play_type` and
`drive_result` still describe the offense's play (`pass_intercepted`,
`INT`); cfbfastR instead renames the play ("Interception Return
Touchdown") and adds `int_td`. We kept our labels and added the two
columns.

Kickoff-return touchdowns differ from cfbfastR: our `pos_team` on a
kickoff is the receiving team (since v3), so the returner's touchdown is
+6 with `td_team == pos_team`; cfbfastR treats the kicking team as the
offense and the return as a defensive score. `return_touchdown` follows
nflfastR and is TRUE for both kinds; "the defense scored" is
`td_team == def_pos_team`.

2025 (133 games): 51 return touchdowns, 43 defensive (27 interception,
10 fumble, 5 blocked punt, 1 punt return) and 8 kickoff returns.

## Kick flags removed (77 → 69 columns)

Decided by Sam (2026-11-04): of the 13 kick columns, keep only the
yardage. Removed the eight TRUE/FALSE flags `kickoff_tb`, `kickoff_oob`,
`kickoff_fair_catch`, `kickoff_onside`, `punt_tb`, `punt_oob`,
`punt_fair_catch`, `punt_downed`. Kept `yds_kickoff`,
`yds_kickoff_return`, `yds_punted`, `yds_punt_return`, `yds_fg`. How a
kick ended is still in `play_text`, and an onside kick the kicking team
recovered still shows as `drive_result == "ONSIDE"`.

This came up from a miss Sam spotted in `20250904_e307`: "kickoff 30 yards
to the AUG35, on-side kick, recovered by VCSU TEAM" had `kickoff_onside`
FALSE, because the flag matched "onside" but not the hyphenated "on-side"
(9 rows in 8 games). That flag is now gone with the others. No other
column's values changed.

## Two renames to cfbfastR names

Decided by Sam from the cfbfastR column comparison (2026-10-29). Both kept
names that cfbfastR uses for something else, so cfbfastR code run on our
files would have given wrong answers without an error.

- **`pass` → `pass_attempt`.** Ours never counted sacks; cfbfastR's `pass`
  does (it is a dropback flag), and `pass_attempt` is its name for ours.
- **`penalty_text` → `penalty_play_text`.** cfbfastR's `penalty_text` is a
  TRUE/FALSE flag; `penalty_play_text` is its column for the text.

**Kept as is:** `score_diff`, `pos_team_score`, `def_pos_team_score`. All
three are the score before the play. cfbfastR's columns of the same name are
after the play, but we have no `_end` / after-play columns, so nothing in our
files reads the other way. The after-play margin is `score_diff + score_pts`.

Values are unchanged; only the two header names changed in the built CSVs.

## Kick details (77 columns)

Thirteen cfbfastR-named columns, placed after `punt`: `yds_kickoff`,
`yds_kickoff_return`, `kickoff_tb`, `kickoff_oob`, `kickoff_fair_catch`,
`kickoff_onside`, `yds_punted`, `yds_punt_return`, `punt_tb`, `punt_oob`,
`punt_fair_catch`, `punt_downed`, `yds_fg`. Chosen by Sam from the cfbfastR
column comparison (2026-10-29). All are read from the play text before any
`PENALTY` clause, and a no-play row credits none of them.

- **Kick flags read the kick only.** cfbfastR searches the whole play text,
  so a returner running out of bounds counts as `punt_oob` there. Here the
  flags read the text up to the first return, muff, fumble, recovery, block
  or lateral: 43 punts in the 133 games say "return ... out of bounds", and
  none of them is `punt_oob`.
- **No return is NA, not 0.** `yds_kickoff_return` / `yds_punt_return` are
  NA on a touchback, fair catch or kick out of bounds, so an average over
  the column is an average over real returns. A return "for no gain" is 0.
- **Not included:** `kickoff_downed`, `kickoff_safety`, `punt_safety`,
  `punt_blocked` (already `play_type == "punt_blocked"`).

**Classifier fix: coin tosses that say "will kickoff".** Four games
(Dickinson at Randolph-Macon, St. John Fisher at FDU-Florham, Alfred State at
Anderson, Johns Hopkins at Susquehanna) print the toss as "X wins toss and will
kickoff; Y will defend ...". The word "kickoff" sent both halves' toss rows to
`kickoff`, so each of those games had two phantom kickoff rows, and the real
opening kickoffs were read as re-kicks. Coin tosses are now checked before
the kickoff rule.

## All of D3 2025: second batch

50 more game pages, fetched 15 s apart with no refusal (the first batch, 6 s
apart, was refused after 21). Now 133 games are built, and all 133 reconcile.

- **Defensive try returns score.** "kick attempt failed (blocked by ...) ...
  defensive PAT Successful." is −2 for the trying team, i.e. 2 points to the
  defense (Nichols at MIT; Bethel (Tenn.) at Mary Hardin-Baylor).
- **Kicking-team muff touchdowns.** A punt the returner muffs and the kicking
  team recovers in the end zone is a touchdown for the kicking team, +6
  (Northwestern (Minn.) at St. Olaf). It was credited to the return team. The
  row keeps `turnover = TRUE` (the returner lost the muff), as before.
- **Games stopped early.** Case Western Reserve at Rowan ended in the 3rd
  quarter ("3rd QTR - 04:19" in place of a "Final" column). The line score is
  found by its "Scoring" header, and the last column is the final.
- **Drive rows:** a drive header with no clock ("Virginia-Lynchburg at"), and
  a drive start after a clock ("clock 09:08, LaGrange College drive start
  at 09:08."). The bogus "drive start at 00:00" on that Virginia-Lynchburg
  drive is discarded by the clock cleaning.
- **Two-minute stops:** "2-Minute Timeout" and "2:00 Officials Timeout" are
  `annotation` rows, like "2:00 minute warning": printed at exactly 2:00 with
  no team named, so they're not team timeouts.

## All of D3 2025: first batch (branch `all-d3-2025`)

The first 21 pages of the full-season fetch (stopped by d3football's rate
limit, as designed) brought new games, and new StatCrew shapes with them. Now
83 games are built, and all 83 reconcile with their final scores.

- **Kicker and passer names decide teams.** A name-to-team map, learned from
  each game's snaps and ordinary kickoffs, now decides:
  - who kicked a kickoff. An onside kick the kicking team recovered without
    the text saying "recovered by" was credited to the wrong team (Wheaton at
    Mount Union);
  - whose try it is, ahead of the next-kickoff and score-line rules.
- **Score before the play is summed from parsed points.** Previously it came
  from d3's score lines. A stat crew skipped one after a touchdown at 00:00
  (Dean at Fitchburg), and every later line lagged by a try.
- **Team codes with spaces and periods** ("MASS. MA") in situations and play
  text.
- **New play type `safety`:** a row reading only "N.C. Wesleyan SAFETY" is a
  play. It was dropped before, losing 2 points.
- **Classifier:** drive footers and clocks with one-digit minutes ("2:23
  elapsed", "clock 0:26"), and wording variants of the coin toss and
  substitutions. Three new non-play types:
  - `annotation`: "Spiked", "2:00 minute warning", "recovered by NAME";
  - `penalty_note`: a declined or offsetting penalty alone on a row with no
    situation;
  - `blank`: ".".

  Footers with one-digit minutes now parse, so 5 games gain clock-end readings.
- **Build report:** lists any row the classifier couldn't type. It's empty
  for all 83 games.
- **Clock test:** a printed play clock that contradicts an official reading is
  discarded. The test now allows up to 2% of a game's printed clocks to be
  discarded (Texas Lutheran at Trinity (TX) has 2 of 144), instead of 1.

## Removed `down_end`, `distance_end`, `yards_to_goal_end` (67 → 64 columns)

The three "end state" columns held the **next** snap's down, distance and
yards to goal, from **that** snap's offense view. Two things made them a trap:

- **The frame of reference flipped silently.** Across a change of possession
  the trio is measured toward the other end zone than the row's own
  `yards_to_goal`. In 2025 that was 737 of 8,993 filled rows (8.2%) —
  449 punts, 103 interceptions, and 185 others including 65 rushes and 50
  incompletions (fourth-down stops). A reader computing
  `yards_to_goal - yards_to_goal_end` as "yards the play gained" disagreed
  with `yards_gained` by more than 5 yards on 248 rows; the worst case, a
  goal-line stand at `yards_to_goal = 1` that turned the ball over, read as
  a 98-yard loss on an 0-yard rush.
- **The name promised something else.** `clock_start` / `clock_end` bracket
  one play, so `_end` reads as "this play, after". But a down doesn't change
  during a play, there was no `down_start` to pair with, and the value came
  from a different row — sometimes a different team. `derive_end_state()` was
  even documented as "the situation after the play", which it never was.

Also: 490 of those filled rows (5.4%) pointed at a dead-ball `penalty_no_play`
row rather than a real snap, so "next snap" was not quite true either.

Nothing in the package consumed them — `next_snap_index()` stays, because the
first-down and series flags need it. The next snap's situation is still
reported for auditing in `checks/{season}/end_state.csv`, where it is now
named `next_down` / `next_distance` / `next_yards_to_goal` and sits beside
`next_pos_team`, so the team whose view it is, is on the row. Values there are
unchanged.

**Not renamed to `*_next`.** That was considered and rejected: the columns had
no consumer, and a correctly-named column still invites the subtraction that
the possession flip makes wrong. `cfbfastR` does not expose these in its
public play-by-play either — the names come from its internal EPA prep
(`prep_epa_df_after()`), not from the user-facing schema, so dropping them
costs no compatibility. If EPA work later needs an "after" state, it should
be built inside that pipeline with the possession flip handled explicitly.

The 62 built 2025 CSVs had the three columns removed in place; every other
field is byte-identical (the cache was unavailable to rebuild, and a pure
column drop changes nothing else).

## `drive_result` moved after `score_pts`

Column order only: `drive_result` now sits with the scoring columns (after
`score_pts`) instead of near the end, for readability. Still 67 columns.

## Checkpoint: Centennial Conference 2025 (git tag `checkpoint-centennial-2025`)

**Repo reorganized:**
- **One reference doc each:** `docs/schema.md` (every column), `docs/pipeline.md`
  (build plan, runs, checks, roadmap), and this changelog. They replace two
  schema / plan documents, two build plans and two change logs.
- **Folders:** scripts in `scripts/`; output in `pbp/{season}/` and
  `checks/{season}/`.
- **Removed snapshots:** stale CSVs from earlier stages (v2 check files, the
  play-type inventory, the CMU-category mapping) and the CMU game list. They
  remain in git history; the CMU list is now
  `index_team_games(build_season_index(2025), "Carnegie Mellon")`.
- **Exports:** the package `NAMESPACE` is generated, so `library(d3ballR)`
  exports the documented functions.

**Team names are consistent across games.** Stat crews spell teams differently
from game to game ("Ursinus", "URSINUS", "URSINUS COLLEGE"). Name columns now
use the season index's spelling: 36 names for 36 teams, previously 42.

## Clock columns: clearer names, printed clocks, seconds remaining (63 → 67 columns)

- **Renamed:** `clock_upper` → `clock_start_max` and `clock_lower` →
  `clock_start_min`. "Upper" was easy to read backwards.
- **Printed per-play clocks are used.** Some stat crews print a clock with every
  play ("(11:25) Shotgun ..."): both McDaniel home games, and a few plays
  elsewhere.
  - **What it means:** checked against every other reading, it always falls
    between the play's snap and its end. So it's used as a bound, never as the
    snap time.
  - **Accuracy:** it's weighted below official readings in the out-of-order
    cleaning. One source typo, "(09:09)" between 02:32 and 01:59, is dropped.
  - **Exact values:** when a snap's range closes to one value, `clock_start` is
    set.
  - **Effect:** the median range narrows from ~90 s to 11-20 s in the two
    McDaniel games. No range got wider, and no exact value changed.
- **New `secs_remaining_*` columns:** the four clock columns as integer seconds
  left in the game.

## First-down flags on the snap that starts the series (60 → 63 columns)

- **Columns:** `firstD_by_kickoff`, `firstD_by_poss`, `firstD_by_yards`,
  `firstD_by_penalty`, `new_series` (cfbfastR names).
- **Placement:** on the first snap row of each new series. That row can be a
  penalty_no_play row, such as a false start right after a punt. A replay of
  the same down after a no-play penalty is never flagged.
- **Fix found by the series check:** 67 series starts were first placed on the
  replayed snap after a no-play row; corrected.
- **Precedence:** mutually exclusive, kickoff > poss > yards > penalty.
- **Divergences from cfbfastR 3.0.0** (`prep_epa_df_after()`, read from the
  installed source):
  1. **Kickoff flag moved.** cfbfastR puts `firstD_by_kickoff` on the kickoff
     row and also flags the next snap `firstD_by_poss`. Here the kickoff row
     carries nothing, and the next snap is `firstD_by_kickoff`.
  2. **Mutually exclusive.** cfbfastR computes the four flags independently,
     so they can overlap.
  3. **Declined penalties.** cfbfastR counts a penalty-type play with a
     *declined* penalty and enough yards as `first_by_penalty`. Here a declined
     penalty never counts; that's `firstD_by_yards`.
- **Fixes found along the way:**
  - An accepted offensive penalty (e.g. holding) can take a first down away
    even when d3 printed "1ST DOWN".
  - A penalty printed with no yardage ("PENALTY FMC Pass Interference, 1ST
    DOWN. NO PLAY.") is parsed as accepted.
  - A negative distance ("4th and -2") keeps its down.
  - The first snap of every overtime possession is `firstD_by_poss`.

## One pipeline, per-season folders

- **One call:** `build_season(season, teams = NULL)` replaced the Centennial
  script. Every roadmap stage is the same call with a different filter or
  season.
- **Folders:** output is per season, so every 2025 game will live in one
  folder.
- **Fetching:** a request budget, and a stop at the first sign of rate
  limiting.

## Centennial 2025 built (57 → 60 columns)

- **Conference columns:** `home_team_conference`, `away_team_conference`,
  `conference_game` (cfbfastR names).
  - **Membership** is read per season from each team's d3 page (CMU: PAC
    through 2024, Centennial in 2025), only for the teams in scope.
  - **`conference_game`** uses d3's "*" schedule marker, not shared
    membership, so playoff and bowl games between members aren't counted.
- **Score reconciliation:** every game's points by team must equal the
  boxscore final. All 62 Centennial games pass.
- **Fetching:** cached and throttled; a page is never requested twice.
- **Parser fixes from games beyond CMU:**
  - **Team codes:** play-text team codes are matched to down-and-distance
    codes by a yardline vote (handles "DCFB" vs "DCC", "McD28", "Wolves05").
  - **Overtime:** periods 5+, a drive per possession, an untimed clock, and
    the try phase ending at the next live snap.
  - **Try credit:** a try is credited to the team that kicks off next when a
    score line is missing.
  - **Clock across quarters:** a hand-over on a quarter's last play no longer
    takes the next quarter's 15:00 as its `clock_end`.

## Season index and calendar columns (53 → 57 columns)

- **Season index:** `build_season_index(season)` reads d3's weekly scoreboard
  pages into one row per game.
  - **Weeks:** d3 numbers weeks from the first Saturday in September and has
    no round or bowl labels. Postseason status comes from the regular-season
    end date, and postseason weeks restart at 1.
  - **Season:** comes from the boxscore URL, never the date.
- **Season dates:** `data-raw/season_dates.csv` (2019-2025) comes from the
  Wikipedia infoboxes, verified against NCAA selection announcements. A
  missing season is auto-added from Wikipedia and logged. A "two Saturdays
  before Thanksgiving" sanity check flags only 2023, which is harmless.
- **New columns:** `season`, `game_date`, `week`, `season_type`.
- **Generic:** the CMU-specific check in the fetch step was removed; any game
  builds.

## v3 schema (36 → 53 columns)

- **Kickoffs:** `pos_team` is the receiving team, decided by the next drive
  header. If the kicking team recovered (onside, return fumble) the play is a
  turnover. Otherwise pre-kick context decides (scorer kicks, coin toss,
  re-kick).
- **Drives:** `drive_number` / `drive_play_number` follow continuous
  possession. A kickoff starts the receiving team's drive. StatCrew's
  same-team split drives are merged.
- **New columns:** `home`, `away`, score before the play, `scrimmage_play`,
  field-goal / punt / scoring flags, `score_pts`, end-of-play situation
  (`*_end`), `drive_result`. `row_type` was dropped.
- **Clock:** an exact `clock_start` / `clock_end` where known, plus an
  always-filled range for the snap.
- **Classifier fix:** kickoffs carrying a return penalty were mislabeled as
  dead-ball penalties.

## v2 schema (36 columns)

- **Reference changed:** CMU's internal coaching data turned out to be
  hand-charted with errors. d3football's StatCrew feed is the reference, and
  the output follows cfbfastR / nflfastR conventions.
- **`Goal_To_Go`:** TRUE on literal "and Goal" and when `distance ==
  yards_to_goal`; d3 writes both.
- **`yards_to_goal`:** each team's own side is inferred by a per-game vote on
  yardline movement.
- **Outcome flags:** a no-play penalty credits nothing.
- **Penalty conventions:**
  - `yards_gained` is play yards only;
  - `penalty_yards_signed` is from the offense's view;
  - a penalty on a play that counts keeps the play;
  - play yards and penalty yards are parsed from their own text patterns
    ("for N yards" vs "N yards from X to Y").

## v1: scrape and classify

- **Source:** d3football.com. The play-by-play is a rendered HTML table, and
  there is no structured feed. ncaa.com's JSON endpoint is dead.
- **Classifier:** labels each row by positive identification. A play needs a
  real down-and-distance and a snap verb. Every non-play has its own label, so
  nothing lands in an unknown bucket.
- **Play types:** 12 snap categories, built from a hand-checked inventory of
  the 11 CMU 2025 games.
