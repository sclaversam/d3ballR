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
#' diverges, per-flag counts, and the validation:
#' - every snap with `new_series = TRUE` is a 1st down in its situation;
#' - every 1st-down snap has `new_series = TRUE`, except replays of the same
#'   1st down (after a no-play penalty, or after an accepted penalty on a
#'   live play that replays the down);
#' plus snaps where more than one cause pointed (precedence applied) and the
#' edge-case snaps (regained kicks, overtime possessions).
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
  flags <- c("firstD_by_kickoff", "firstD_by_poss", "firstD_by_yards", "firstD_by_penalty", "new_series")
  a <- do.call(rbind, lapply(built, function(g) {
    d <- attr(g, "series_detail")
    x <- as.data.frame(g[, c("game_id", "play_index", "period", "half", "pos_team", "play_type", "down", "distance",
                             "penalty_no_play", "penalty_flag", "penalty_yards_signed", "penalty_declined",
                             flags, "play_text")])
    # previous kept row (not a try), same half: what came right before this one
    is_try <- g$play_type %in% c("extra_point", "two_point")
    prev <- vapply(seq_len(nrow(g)), function(i) {
      j <- which(seq_len(nrow(g)) < i & !is_try & g$half == g$half[i])
      if (length(j)) j[length(j)] else NA_integer_
    }, integer(1))
    x$prev_down <- g$down[prev]
    x$prev_same_team <- !is.na(prev) & g$pos_team[prev] == g$pos_team
    x$prev_no_play <- g$penalty_no_play[prev] %in% TRUE
    x$prev_accepted_penalty <- !is.na(g$penalty_yards_signed[prev]) & !(g$penalty_declined[prev] %in% TRUE)
    x$prev_play_type <- g$play_type[prev]
    x$prev_yard_segments <- stringr::str_count(stringr::str_remove(g$play_text[prev], "PENALTY .*$"),
                                               "\\bfor (loss of )?\\d+ yards?")
    x$prev_other_team <- !is.na(prev) & g$pos_team[prev] != g$pos_team
    cbind(x, d)
  }))
  a$play_text <- substr(a$play_text, 1, 110)
  counts <- data.frame(flag = flags, rows = vapply(flags, function(f) sum(a[[f]]), integer(1)))
  exclusive <- all(rowSums(a[, flags[1:4]]) == a$new_series)
  snap <- a$play_type %in% play_type_categories & !a$try_phase  # a snap in a try (e.g. a nullified two-point run) isn't a series snap
  non_snap_flagged <- a[!snap & a$new_series, ]

  bad_flag <- a[snap & a$new_series & !(a$down %in% 1L), ]
  bad_flag$likely_cause <- ifelse(bad_flag$firstD_by_poss,
                                  "d3 kept the old down for the new offense after the change of possession (source quirk)",
                                  "unexplained")
  missing <- a[snap & a$down %in% 1L & !a$new_series, ]
  same_first <- missing$prev_same_team & missing$prev_down %in% 1L
  missing$category <- dplyr::case_when(
    same_first & missing$prev_no_play ~ "replay after a no-play penalty (same 1st down)",
    same_first & missing$prev_accepted_penalty ~ "replay after an accepted penalty on a live play (same 1st down)",
    TRUE ~ "EXCEPTION"
  )
  missing$likely_cause <- ifelse(missing$category != "EXCEPTION", "",
    ifelse(missing$prev_yard_segments > 1,
           "previous play has more than one yardage segment (a lateral): yards_gained reads only the first, so its first down is missed",
           "unexplained"))
  expected <- missing[missing$category != "EXCEPTION", ]
  exceptions <- missing[missing$category == "EXCEPTION", ]

  n_distinct_causes <- vapply(strsplit(ifelse(is.na(a$series_causes), "", a$series_causes), " \\+ "),
                              function(x) length(unique(x)), integer(1))
  multi <- a[n_distinct_causes > 1, ]  # e.g. "kickoff + kickoff" after a re-kick is one cause, not a conflict
  ot <- a[a$firstD_by_poss & a$period > 4L, ]
  regained <- a[a$firstD_by_poss & a$prev_play_type %in% c("punt_no_return", "punt_with_return", "punt_blocked",
                                                            "field_goal_missed", "field_goal_blocked") &
                  a$prev_same_team & a$period <= 4L, ]

  out <- c(
    "# First downs and new series", "",
    "Generated by `build_season()` from every game in this season's folder.", "",
    "## The flags", "",
    "Each flag is on the **first snap of a new series** (the 1st-and-10 or 1st-and-goal snap), never on the play that caused it. At most one is TRUE; `new_series` is any of them. Kickoffs, tries, dead-ball penalty rows and mid-series snaps are FALSE in all five.", "",
    "- **`firstD_by_kickoff`:** first snap after a kickoff (including an onside kick, whichever team recovered).",
    "- **`firstD_by_poss`:** first snap after a change of possession (punt, interception, lost fumble, downs, missed / blocked FG, or a punt / FG the kicking team regains after a muff or return fumble), and the first snap of each overtime possession.",
    "- **`firstD_by_yards`:** same offense; the previous play reached the line to gain.",
    "- **`firstD_by_penalty`:** same offense; the previous play didn't, and an accepted penalty awarded the first down (a declined penalty never counts).",
    "",
    "## cfbfastR (3.0.0, `prep_epa_df_after()`) and how this differs", "",
    "cfbfastR also puts `firstD_by_poss`, `firstD_by_yards`, `firstD_by_penalty` on the snap that starts the series, computed from the previous row's values. Differences:", "",
    "- **Kickoff flag moved off the kickoff row:** cfbfastR sets `firstD_by_kickoff` on the kickoff row itself (`kickoff_play == 1 & down == 1`) and then also flags the first snap after it `firstD_by_poss` (`drive_event_number == 2` after a kickoff). Here the kickoff row has no flag, and the first snap after it is `firstD_by_kickoff`.",
    "- **Mutually exclusive:** cfbfastR computes the four independently, so they can overlap. Here precedence kickoff > poss > yards > penalty leaves exactly one.",
    "- **Declined penalties:** cfbfastR's `first_by_penalty` includes a penalty-type play whose penalty was declined but whose yardage reached the line. Here a declined penalty never counts; that play is `firstD_by_yards`.",
    "",
    "## Counts", "",
    md_table(counts), "",
    paste0("Exactly one of the four whenever `new_series` is TRUE: **", if (exclusive) "yes" else "NO", "**. ",
           "Non-snap rows (kickoffs, tries, dead-ball penalties) flagged: **", nrow(non_snap_flagged), "**."), "",
    "## Validation", "",
    paste0("**Every `new_series` snap is a 1st down:** ", sum(snap & a$new_series), " flagged snaps, ",
           nrow(bad_flag), " not a 1st down in their situation."), "",
    md_table(bad_flag[, c("game_id", "play_index", "play_type", "down", "distance", "series_causes", "cause_play_index", "likely_cause", "play_text")]), "",
    paste0("**Every 1st-down snap has `new_series`, except replays:** ", sum(snap & a$down %in% 1L), " 1st-down snaps; ",
           sum(snap & a$down %in% 1L & a$new_series), " flagged, ", nrow(expected), " replays of the same 1st down (expected), ",
           nrow(exceptions), " exceptions."), "",
    "Replays by kind:", "",
    md_table(as.data.frame(table(category = expected$category), responseName = "snaps")), "",
    "Exceptions:", "",
    md_table(exceptions[, c("game_id", "play_index", "play_type", "down", "distance", "prev_play_type", "prev_down", "likely_cause", "play_text")]), "",
    "## Snaps where different causes pointed (precedence applied)", "",
    md_table(multi[, c("game_id", "play_index", "series_causes", flags[1:4], "play_text")]), "",
    "## Edge cases", "",
    paste0("First snap after a punt / field goal the kicking team regained (`firstD_by_poss`): ", nrow(regained), "."), "",
    md_table(regained[, c("game_id", "play_index", "pos_team", "prev_play_type", "play_text")]), "",
    paste0("First snap of an overtime possession (`firstD_by_poss`): ", nrow(ot), "."), "",
    md_table(ot[, c("game_id", "play_index", "period", "pos_team", "play_text")]), ""
  )
  writeLines(out, file.path(check_dir, "first_downs.md"))
  invisible(list(counts = counts, bad_flag = bad_flag, exceptions = exceptions, multi = multi))
}
