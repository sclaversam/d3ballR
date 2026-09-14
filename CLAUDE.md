# CLAUDE.md

Briefing for Claude Code working in this repo. Read this first.

## What this project is

`d3ballR` scrapes and parses **NCAA Division III** college football
play-by-play from d3football.com into tidy, per-play tables. It fills a real
gap: `cfbfastR` and the CollegeFootballData API cover only Division I (FBS/FCS,
division codes 11 and 12); D2 and D3 are absent from every published dataset.
That gap is documented and verified in
`analysis/cfbfastr_d2_d3_coverage_audit.Rmd`.

Near-term focus: Carnegie Mellon and the Centennial Conference. The immediate
milestone is parsing CMU's 2025 games and validating the output against CMU's
internal coaching data (see "CMU schema" below).

The author (Sam) is a CMU statistics and machine learning student. Long-term he
may extend this into projections work, but the current scope is strictly the
scraper: get accurate, tidy play-by-play out of d3football.

## Source facts (confirmed, do not re-litigate)

- **d3football.com is the source.** The play data is baked into the rendered
  HTML table. There is NO separate structured XML or JSON feed. This was checked
  directly in the browser Network tab: only a `scheduleRelatedLinks.json` helper
  loads, no play feed. The `.xml?view=plays` URL returns rendered HTML, not raw
  XML. So parsing the HTML table is the correct and only path. Do not spend time
  hunting for an API.
- **ncaa.com is not usable.** Its page is JavaScript-rendered, and the old
  `data.ncaa.com/casablanca/game/{id}/pbp.json` endpoint is dead (returns
  NoSuchKey). Don't build on it or on third-party wrappers.
- Boxscore URL pattern:
  `https://www.d3football.com/seasons/{year}/boxscores/{id}.xml`
  with `?view=plays` (play-by-play) and `?view=drives` (drive summary,
  carries QTR and drive-start clock).
- d3football blocks default user agents, so requests must send a browser
  User-Agent (already handled in `fetch_html`).
- The plays page has three tables: a header block, a line score (6 cols), and
  the play-by-play (2 cols: `situation`, `play`).
- **2025 markup quirk:** the situation text contains a newline, e.g.
  `"1st\n and 10 at CMU35"`. All parsing must `str_squish` first. Yardlines are
  written inconsistently: `"CMU35"` (no space) and `"UC 25"` (with a space), so
  any yardline pattern needs an optional space.

## Where things are

- `R/scrape_plays.R` — the current working file. Contains **Step 1 only**:
  `fetch_html`, `default_user_agent`, `tables_on`, `find_plays`, and the
  exported `scrape_plays(game_url)` wrapper that returns a clean 2-column tibble
  (`situation`, `play`).
- `data-raw/cmu_2025_games.R` — CMU 2025 boxscore URLs. Only game 1 (at Chicago,
  `20250906_e064`) is filled in; the other 10 need to be added from
  `https://www.d3football.com/teams/Carnegie_Mellon/2025/index`.
- `analysis/` — notebooks (the coverage audit; the single-game parser
  walkthrough lives outside the repo as `parse_game.Rmd`).
- `tests/testthat/` — unit tests. `find_plays` has starter tests.

## What is built vs. next

Built: **Step 1** (scrape + locate + clean the play table). That's all.

Next, in order:
1. **Step 2 — row classifier.** Label each row as a play or a specific non-play
   type. THIS IS THE CURRENT TASK. See "Classifier design" below.
2. Forward-fill quarter and possession from drive headers/quarter markers.
3. Parse the `situation` column (down, distance, yardline).
4. Parse the `play` column (play type, yards, outcome, penalties).
5. Map the parsed output onto CMU's internal schema for validation.

## Classifier design (Step 2 — the current task)

**Approach: positive identification.** A row is a `play` only if its situation
is a real down-and-distance AND its description contains a snap verb (rush,
pass, sacked, punt, field goal, kneel). Do NOT try to blocklist every kind of
non-play — that is what previously let the coin-toss and quarter-start rows leak
in. Those rows carry a valid down-and-distance in column 1 but no play verb in
the description, so a situation-only rule miscounts them.

Non-plays that carry a real down-and-distance (must NOT be counted as plays):
quarter start ("Start of 1st quarter, clock 15:00" — repeats the current
down-and-distance), coin toss, drive start ("... drive start at 15:00"),
timeout, spot corrections ("CMU ball on UC 19").

Every non-play still gets a labeled type (drive_start, drive_header,
drive_footer, quarter, kickoff, extra_point, score, timeout, admin, nav,
penalty_no_play). Nothing should land silently in `other` — `other` is the
unknown bucket and must come back empty.

Ordering matters in the `case_when`: the play rule first; `penalty_no_play`
after it (so nullified snaps, which have a verb, stay `play`, and only
dead-down penalties with no snap become `penalty_no_play`); `drive_start`
before `drive_header` (so "TEAM drive start at MM:SS" doesn't match the header
pattern).

Known refinement already identified: do NOT lump two-point conversions in with
extra points — a two-point try is a scrimmage snap, not a kick. Give it its own
`two_point` label. Game 1 has no two-point tries, so that rule is unvalidated
until we hit a game with one.

## How to build the classifier: surface, don't guess

The right way to harden the classifier is to run it over ALL eleven CMU 2025
games and collect what it can't classify, not to guess rules from one game.

- Fill in the 11 game URLs, run `scrape_plays()` on each, apply the classifier,
  and **show every row that lands in `other`, plus the row-type counts per
  game.** That output is what we design rules against.
- Do NOT finalize classification rules unsupervised. Surface the unclassified
  and ambiguous rows and propose rules; Sam confirms each against football
  reality and the CMU schema. Judgment calls (like the two-point/extra-point
  case) must be checked, not papered over.
- Sanity checks per game: `other` empty; play count in the rough range of a
  full game's combined scrimmage snaps for both teams (~130–160 incl. punts and
  field goals); first several `play` rows are actual snaps.

## CMU schema (the validation target)

CMU's internal data logs one row per play with these columns:
`side_of_ball, quarter, play_idx, down, ytg, field_pos, yards_gained,
play_category, play_result, opponent`.

Decoded from game 1:
- `side_of_ball` — from CMU's perspective: `K` (kicking unit), `O` (CMU
  offense), `D` (CMU defense). Derive by comparing the possessing team to CMU.
- `play_idx` — a continuous, whole-game counter over ALL rows (kickoffs,
  penalties, PATs included), does not reset.
- `field_pos` — signed yardline: negative on the offense's own side, positive on
  the opponent's side, from the ball-carrying offense's perspective (own 25 =
  -25, opponent 48 = +48). NOT distance-to-goal. Our yardline parse must
  reproduce this sign convention.
- `play_category` values seen: KO, Pass, Run, Penalty, Punt Rec, Extra Pt.
  Map our labels onto these (KO=kickoff, Run=rush, Extra Pt.=extra_point,
  Penalty=penalty_no_play, etc.).
- `play_result` — sub-detail (Fair Catch, Complete, Incomplete, Rush, Return,
  Good, "Complete, TD").

**CMU includes kickoffs as rows** (with NA down/ytg/field_pos), so keep kickoffs
as their own labeled type and include them in the comparison.

### Penalty convention (decided)

Match CMU's `yards_gained` convention: **play yards only, penalty enforcement
yards excluded.** (Example: a 10-yard catch plus an 11-yard face mask logs
`yards_gained = 10`.) But CMU's data DROPS the penalty entirely — no row, no
yardage — which is a gap in their data, not ours. So preserve penalty context in
our own columns that CMU lacks: `has_penalty` (logical), `penalty_yards`
(numeric, NA if none), `penalty_text` (raw penalty clause). This lets a
mismatch be attributed to a CMU recording gap rather than a parser error. These
fields are extracted in the play-description parse (step 4), not the classifier.

Open item, not yet built: whether to also record a penalty's effect on
down/distance for the next row. Flag when it causes a mismatch; don't build
speculatively.

## Conventions

- Package name is `d3ballR` (valid R name). The repo/folder may differ; keep the
  `Package:` line valid (no underscores/hyphens).
- Package code in `R/` uses explicit `pkg::fn()` calls and roxygen `#'` headers.
  As the package grows, put the classifier in its own file (e.g.
  `R/classify.R`) rather than overloading `scrape_plays.R`.
- Keep raw `situation`/`play` text in parsed output so any derived field can be
  traced back to its source, which is essential for the CMU comparison.
- Prefer vectorized transforms (one `mutate` per stage, forward-fill for state)
  over row-by-row loops — easier to read and debug.
- Commit at natural stopping points with clear messages.
- Sam maintains a separate companion doc explaining each function step by step;
  when you add a function, note what it does, its inputs/outputs, and any
  gotchas so that doc can be updated.

## Working style with Sam

- Sam is learning the tooling as he goes; explain what code does when it's new,
  don't just produce it.
- Run code and show the ACTUAL printed output (especially the `other` rows and
  counts), don't just summarize what it would do.
- Be honest when the parser vs. CMU disagree — it is sometimes CMU's data that
  is wrong or lossy, not the parser.
