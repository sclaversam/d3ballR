#' Write the validation reports for a set of built games
#'
#' Writes CSVs to `check_dir` from the per-game tibbles returned by
#' [build_pbp()] (their attributes carry the intermediate decisions):
#' - `kickoff_possession.csv`: every kickoff with kicking / receiving team,
#'   the rule that decided it (header / override / fallback), and any
#'   disagreement between the drive header, the recovery text, and the
#'   pre-kick context.
#' - `end_state.csv`: every change-of-possession row (kickoffs, punts,
#'   turnovers, downs, missed/blocked field goals, or any row whose next
#'   snap belongs to the other team) with `yards_to_goal`, the end state,
#'   and the next snap's team and text.
#' - `drive_footer_clock.csv`: every d3 drive's start clock + footer
#'   "MM:SS elapsed" vs the drive's end reference (see
#'   [footer_clock_check()]); `flag` marks mismatches.
#' - `clock_bounds.csv`: any regulation row whose `clock_upper` /
#'   `clock_lower` is NA or upper < lower in time remaining (should be
#'   empty; overtime is untimed, so its clock columns are NA by design).
#'
#' @param games List of tibbles from [build_pbp()].
#' @param check_dir Output directory.
#' @return Invisibly, a named list of the report data frames.
#' @export
write_pbp_checks <- function(games, check_dir = "analysis/checks") {
  dir.create(check_dir, showWarnings = FALSE, recursive = TRUE)
  reports <- list()

  ko <- do.call(rbind, lapply(games, function(g) {
    k <- attr(g, "kickoffs")
    k$play_text <- g$play_text[k$play_index]
    k
  }))
  reports$kickoff_possession <- ko[, c(
    "game_id", "play_index", "period", "kicking_team", "receiving_team", "rule",
    "header_team", "context_kicker", "context_source", "recovered_by",
    "kicker_recovered", "disagreement", "play_text"
  )]

  reports$end_state <- do.call(rbind, lapply(games, function(g) {
    nxt <- attr(g, "next_snap")
    next_team <- g$pos_team[nxt]
    change <- g$play_type %in% c("kickoff", "punt_no_return", "punt_with_return", "punt_blocked",
                                 "field_goal_missed", "field_goal_blocked") |
      g$turnover | (!is.na(next_team) & next_team != g$pos_team & !g$play_type %in% c("extra_point", "two_point"))
    change <- change & !g$penalty_no_play
    data.frame(
      game_id = g$game_id[change], play_index = g$play_index[change], period = g$period[change],
      play_type = g$play_type[change], pos_team = g$pos_team[change],
      yards_to_goal = g$yards_to_goal[change], down_end = g$down_end[change],
      distance_end = g$distance_end[change], yards_to_goal_end = g$yards_to_goal_end[change],
      next_pos_team = next_team[change], scoring_play = g$scoring_play[change],
      play_text = g$play_text[change], next_play_text = g$play_text[nxt][change]
    )
  }))

  reports$drive_footer_clock <- do.call(rbind, lapply(games, attr, "footer_clock"))

  b <- dplyr::bind_rows(games)
  reg <- b$period <= 4L  # overtime is untimed: clock columns NA by design
  bad <- reg & (is.na(b$clock_upper) | is.na(b$clock_lower) |
                  clock_secs(b$clock_upper) < clock_secs(b$clock_lower))
  reports$clock_bounds <- as.data.frame(b[bad, c("game_id", "play_index", "period", "clock_start", "clock_end",
                                                 "clock_upper", "clock_lower", "play_text")])

  for (nm in names(reports)) {
    utils::write.csv(reports[[nm]], file.path(check_dir, paste0(nm, ".csv")), row.names = FALSE, na = "")
  }
  invisible(reports)
}

#' Check each d3 drive's "MM:SS elapsed" against the clock anchors
#'
#' For every StatCrew drive (opening drive row through its footer): start
#' clock + footer elapsed should land on the drive's end. The end reference
#' is the scoring play's stated clock if the drive scored, else the next
#' drive's start time, else 00:00 at the end of the half. Times are
#' compared as game seconds elapsed, so drives that cross a quarter are
#' handled.
#'
#' @param full Classified rows (full set).
#' @param clk Output of [derive_clock()].
#' @param kept Kept rows with `row`, `touchdown`, `field_goal_made`,
#'   `safety`.
#' @param game_id Game id.
#' @return Data frame, one row per drive footer.
#' @keywords internal
footer_clock_check <- function(full, clk, kept, game_id) {
  rt <- full$row_type
  q <- dplyr::coalesce(as.integer(full$quarter), 1L)
  half <- ifelse(q <= 2, 1L, 2L)
  good <- clk$anchors
  val <- stats::setNames(good$secs, good$row)
  game_secs <- function(quarter, secs) (quarter - 1L) * 900L + (900L - secs)
  opening <- clk$opening_rows
  scoring_rows <- kept$row[kept$touchdown | kept$field_goal_made | kept$safety]
  footers <- which(rt == "drive_footer")
  prev_f <- c(0L, footers[-length(footers)])
  out <- lapply(seq_along(footers), function(i) {
    f <- footers[i]
    starts <- opening[opening > prev_f[i] & opening < f]
    st <- if (length(starts)) starts[1] else NA_integer_
    team <- if (!is.na(st)) stringr::str_match(full$play[st], "^(.*?)(?: drive start)? at \\d")[, 2] else NA_character_
    el <- clock_secs(stringr::str_match(full$play[f], "(\\d{2}:\\d{2}) elapsed")[, 2])
    s_secs <- if (!is.na(st)) val[as.character(st)] else NA
    sc <- scoring_rows[scoring_rows > ifelse(is.na(st), prev_f[i], st) & scoring_rows < f]
    sc_val <- if (length(sc)) val[as.character(sc[length(sc)])] else NA
    nxt <- opening[opening > f]
    if (length(sc) && !is.na(sc_val)) {
      ref <- "score clock"; ref_q <- q[sc[length(sc)]]; ref_secs <- sc_val
    } else if (length(nxt) && !is.na(st) && half[nxt[1]] == half[st]) {
      ref <- "next drive start"; ref_q <- q[nxt[1]]; ref_secs <- val[as.character(nxt[1])]
    } else {
      ref <- "end of half"; ref_q <- if (!is.na(st) && half[st] == 1L) 2L else 4L; ref_secs <- 0L
    }
    expected <- if (!is.na(st)) game_secs(q[st], s_secs) + el else NA
    actual <- game_secs(ref_q, ref_secs)
    data.frame(
      game_id = game_id, footer_row = f, team = team,
      start_quarter = if (!is.na(st)) q[st] else NA, start_clock = fmt_clock(unname(s_secs)),
      elapsed = fmt_clock(el), reference = ref, ref_quarter = ref_q, ref_clock = fmt_clock(unname(ref_secs)),
      diff_seconds = unname(actual - expected),
      footer_text = full$play[f]
    )
  })
  res <- do.call(rbind, out)
  ot <- !is.na(res$start_quarter) & res$start_quarter > 4L
  res$reference[ot] <- "overtime (untimed)"
  res$diff_seconds[ot] <- NA
  res$flag <- !ot & (is.na(res$diff_seconds) | res$diff_seconds != 0)
  res
}

#' Write the first-down / new-series report
#'
#' `{check_dir}/first_downs.md`: cfbfastR's rules and where this package
#' diverges, per-flag counts, every edge-case row (kicks regained by the
#' kicking team, overtime hand-overs, kickoffs the kicking team recovers,
#' the play before each first overtime possession) with how cfbfastR would
#' have labeled it, rows where more than one rule applied before precedence,
#' and a consistency check of `new_series` against the next snap's
#' situation (a fresh 1st down, whether after a change of possession / drive
#' start or within a drive).
#'
#' @param built List of games from [build_all_pbp()].
#' @param check_dir Report directory.
#' @keywords internal
write_first_down_report <- function(built, check_dir) {
  md_table <- function(df) {
    if (!nrow(df)) return("None.")
    df[] <- lapply(df, function(x) ifelse(is.na(x), "", gsub("\\|", "/", as.character(x))))
    c(paste0("| ", paste(names(df), collapse = " | "), " |"),
      paste0("|", paste(rep("---", ncol(df)), collapse = "|"), "|"),
      apply(df, 1, function(r) paste0("| ", paste(r, collapse = " | "), " |")))
  }
  a <- do.call(rbind, lapply(built, function(g) {
    d <- attr(g, "series_detail")
    cbind(as.data.frame(g[, c("game_id", "play_index", "period", "pos_team", "play_type", "down", "distance",
                             "down_end", "distance_end", "turnover", "scoring_play", "penalty_no_play",
                             "firstD_by_kickoff", "firstD_by_poss", "firstD_by_yards", "firstD_by_penalty",
                             "new_series", "play_text")]), d)
  }))
  a$play_text <- substr(a$play_text, 1, 110)
  flags <- c("firstD_by_kickoff", "firstD_by_poss", "firstD_by_yards", "firstD_by_penalty", "new_series")
  counts <- data.frame(flag = flags, rows = vapply(flags, function(f) sum(a[[f]]), integer(1)))
  exclusive <- all(rowSums(a[, flags[1:4]]) <= 1)

  edge <- a[!is.na(a$series_edge), ]
  edge$label <- ifelse(edge$firstD_by_poss, "firstD_by_poss", "none")
  edge$cfbfastR <- ifelse(edge$series_edge == "kick regained by kicking team",
                          "none on this row; firstD_by_poss on the next snap (a new drive starts: drive_event_number == 1)",
                          "none on this row; firstD_by_poss on the second team's first snap (new drive)")
  ko_regained <- a[a$play_type == "kickoff" & a$turnover, ]
  if (nrow(ko_regained)) {
    ko_regained$series_edge <- "kickoff recovered by kicking team"
    ko_regained$label <- ifelse(ko_regained$firstD_by_kickoff, "firstD_by_kickoff", "none")
    ko_regained$cfbfastR <- "firstD_by_kickoff on this row (kickoff_play & down == 1) AND firstD_by_poss on the next snap (new drive)"
  }
  first_ot <- do.call(rbind, lapply(split(a, a$game_id), function(g) {
    i <- which(g$period > 4L)[1]
    if (is.na(i) || i == 1) return(NULL)
    r <- g[i - 1, ]
    r$series_edge <- "play before the first overtime possession"
    r$label <- if (r$new_series) "flagged (unexpected)" else "none"
    r$cfbfastR <- "firstD_by_poss on the first OT snap (new drive: drive_event_number == 1)"
    r
  }))
  edge_all <- rbind(edge, ko_regained, first_ot)

  n_raw <- rowSums(a[, c("raw_kickoff", "raw_poss", "raw_yards", "raw_penalty")])
  overlap <- a[a$new_series & n_raw > 1, ]
  overlap$rules_applied <- apply(overlap[, c("raw_kickoff", "raw_poss", "raw_yards", "raw_penalty")], 1,
                                 function(r) paste(c("kickoff", "poss", "yards", "penalty")[r], collapse = " + "))
  overlap$kept <- flags[1:4][apply(overlap[, flags[1:4]], 1, which.max)]

  chk <- !is.na(a$observed_new_series)
  mism <- a[chk & a$new_series != a$observed_new_series, ]
  mism$issue <- ifelse(mism$new_series, "flagged, but the next snap does not start a new series",
                       "not flagged, but the next snap starts a new series")
  n_for <- stringr::str_count(mism$play_text, "\\bfor (loss of )?\\d+ yards?")
  mism$likely_cause <- dplyr::case_when(
    mism$firstD_by_poss & !is.na(mism$down_end) & mism$down_end != 1L ~
      "d3 kept the old down for the new offense after the change of possession (source quirk)",
    mism$penalty_no_play & mism$play_type == "penalty_no_play" & !mism$new_series ~
      "dead-ball penalty on the offense; d3 prints 1st & 10 instead of a longer distance (source quirk)",
    n_for > 1 ~ "multiple yardage segments (a lateral): yards_gained reads only the first",
    TRUE ~ "unexplained"
  )

  out <- c(
    "# First downs and new series", "",
    "Generated by `build_season()` from every game in this season's folder.", "",
    "## cfbfastR's rules (cfbfastR 3.0.0, `prep_epa_df_after()`)", "",
    "- **`firstD_by_kickoff`:** on the kickoff row itself (`kickoff_play == 1 & down == 1`).",
    "- **`firstD_by_poss`:** on the NEXT snap. Set when the previous play was a punt, turnover on downs, or turnover with a change of possession; on the first snap after a kickoff or after a scoring play; and on any play that opens a drive (`drive_event_number == 1`).",
    "- **`firstD_by_yards` / `firstD_by_penalty`:** on the NEXT snap. Set when the previous play had `first_by_yards` (a normal play with `yards_gained >= distance`) or `first_by_penalty` (a penalty-type play with a first-down conversion, or a declined penalty where the play gained the distance), with no change of possession.",
    "- **`new_series`:** the drive changed, or the previous play had `first_by_yards` or `first_by_penalty`.",
    "- **Precedence:** none explicit; the four are computed independently. Possession outranks yards and penalty in effect (both need no change of possession). A normal play is yards; a penalty-type play is penalty, even if the penalty was declined and the play itself gained the distance. Flags can overlap: a kickoff row is `firstD_by_kickoff` and the next snap is also `firstD_by_poss`.",
    "",
    "## How this package differs", "",
    "- **Row:** flags sit on the row that CAUSES the new series (like the earlier `firstD_by_yards` / `firstD_by_penalty`), not on the next snap. Only `firstD_by_kickoff` is on the same row as in cfbfastR.",
    "- **Mutually exclusive:** precedence is kickoff > poss > yards > penalty, and `new_series` is their union. In cfbfastR a kickoff also flags the next snap as possession; here it is one series, flagged once.",
    "- **Yards before penalty:** a play that reaches the line to gain is `firstD_by_yards` even when a penalty also awarded a first down (e.g. a catch past the line plus a face mask). cfbfastR's declined-penalty case would call that penalty; that's semantically wrong, since a declined penalty awards nothing.",
    "- **No flag after a score or at the first OT possession:** cfbfastR flags the snap after a scoring play and the first snap of every drive, including the first OT possession. Here scoring plays, tries, plays followed by the end of a half / game / OT period, and the play before the first OT possession get no flag.",
    "- **Kick regained by the kicking team:** a punt or field goal where the kicking team gets the ball back after a muff or return fumble is `firstD_by_poss` on the kick row. A kickoff the kicking team recovers stays `firstD_by_kickoff`.",
    "",
    "## Counts", "",
    md_table(counts), "",
    paste0("At most one flag per row: **", if (exclusive) "yes" else "NO", "**."), "",
    "## Edge-case rows", "",
    paste0("Counts: kick regained by kicking team = ", sum(edge_all$series_edge == "kick regained by kicking team"),
           "; overtime hand-over (first team's OT possession ends without a score) = ", sum(edge_all$series_edge == "overtime hand-over"),
           "; kickoff recovered by kicking team = ", sum(edge_all$series_edge == "kickoff recovered by kicking team"),
           "; play before a first overtime possession = ", sum(edge_all$series_edge == "play before the first overtime possession"), "."), "",
    md_table(edge_all[, c("game_id", "play_index", "period", "pos_team", "play_type", "series_edge", "label", "cfbfastR", "play_text")]), "",
    "## Rows where more than one rule applied before precedence", "",
    md_table(overlap[, c("game_id", "play_index", "play_type", "down", "distance", "rules_applied", "kept", "play_text")]), "",
    "## Consistency: `new_series` vs the next snap's situation", "",
    "A new series is confirmed when the next connected snap is 1st down and either the ball changed hands (a drive start), the row wasn't a 1st down, or the distance was reset rather than just moved by the net gain (a within-drive first down). Every live kickoff with a following snap starts one; a kickoff nullified and re-kicked does not (the re-kick does).",
    "A 1st down followed by a 1st down where the reset and the moved distance coincide (e.g. 1st & 25 -> 1st & 10 at the 10 after a penalty) can't be confirmed from the situation and is left out.", "",
    paste0("Checked: the ", sum(chk), " rows that can carry a flag and whose next snap confirms or refutes a new series (not scoring plays, tries, plays with no connected next snap, or the ambiguous 1st -> 1st cases). ",
           "Scoring plays and tries are all FALSE: ", if (!any(a$new_series[a$scoring_play | a$play_type %in% c("extra_point", "two_point")])) "confirmed." else "**NOT all FALSE**.", ""),
    "",
    paste0("**", sum(a$new_series[chk] == a$observed_new_series[chk]), " of ", sum(chk), " rows agree; ", nrow(mism), " mismatches.**"), "",
    md_table(mism[, c("game_id", "play_index", "play_type", "down", "distance", "down_end", "distance_end", "issue", "likely_cause", "play_text")]), ""
  )
  writeLines(out, file.path(check_dir, "first_downs.md"))
  invisible(list(counts = counts, edge = edge_all, overlap = overlap, mismatches = mism))
}
