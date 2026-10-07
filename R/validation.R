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
#' - `clock_bounds.csv`: any regulation row whose `clock_start_max` /
#'   `clock_start_min` is NA, max < min, or `clock_start` (when known) falls
#'   outside them (should be
#'   empty; overtime is untimed, so its clock columns are NA by design).
#'
#' @param games List of tibbles from [build_pbp()].
#' @param check_dir Output directory.
#' @return Invisibly, a named list of the report data frames.
#' @export
write_pbp_checks <- function(games, check_dir = "checks") {
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
  mx <- clock_secs(b$clock_start_max)
  mn <- clock_secs(b$clock_start_min)
  st <- clock_secs(b$clock_start)
  bad <- reg & (is.na(mx) | is.na(mn) | mx < mn | (!is.na(st) & (st > mx | st < mn)))
  reports$clock_bounds <- as.data.frame(b[bad, c("game_id", "play_index", "period", "clock_start", "clock_end",
                                                 "clock_start_max", "clock_start_min", "play_text")])

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
  good <- clk$anchors[clk$anchors$kind != "printed", ]  # official readings only, one per row
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
    el <- clock_secs(stringr::str_match(full$play[f], "(\\d{1,2}:\\d{2}) elapsed")[, 2])
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

#' Split a game's snap rows into series, independently of the flags
#'
#' Snap rows are rows with a down that aren't part of a try: snaps and
#' penalty_no_play rows (dead-ball penalties, nullified snaps). A new series
#' begins at a snap row when it is the first of its half (or overtime
#' period), a kickoff came since the previous snap row, the offense changed,
#' or the situation shows a fresh 1st down: 1st down after a later down, or
#' 1st down again with a distance that isn't just the old one moved by the
#' net yardage (a replay of the same 1st down after a penalty, e.g. 1st & 10
#' -> false start -> 1st & 15, stays in the series). When "moved" and "fresh"
#' give the same distance (1st & 25 -> 1st & 10 at the 10), the situation
#' can't tell; the row's own `new_series` decides, so that case can't create
#' a violation.
#'
#' @param g One built game (data frame).
#' @param try_phase Logical, per row.
#' @return Integer series id per row (NA on rows that aren't snap rows).
#' @keywords internal
segment_series <- function(g, try_phase) {
  snap <- !is.na(g$down) & !try_phase
  rows <- which(snap)
  id <- rep(NA_integer_, nrow(g))
  cur <- 0L
  prev <- NA_integer_
  for (j in rows) {
    start <- is.na(prev) || g$half[j] != g$half[prev] ||
      (g$period[j] > 4L | g$period[prev] > 4L) && g$period[j] != g$period[prev] ||
      any(g$play_type[seq_len(j - 1)][seq_len(j - 1) > prev] == "kickoff") ||
      !identical(g$pos_team[j], g$pos_team[prev])
    if (!start && g$down[j] %in% 1L) {
      moved <- g$distance[prev] - (g$yards_to_goal[prev] - g$yards_to_goal[j])
      fresh <- min(10L, g$yards_to_goal[j])
      if (!(g$down[prev] %in% 1L)) {
        start <- TRUE
      } else if (!isTRUE(g$distance[j] == moved)) {
        start <- TRUE
      } else if (isTRUE(moved == fresh)) {
        start <- isTRUE(g$new_series[j])  # ambiguous: defer to the flag
      }
    }
    if (start) cur <- cur + 1L
    id[j] <- cur
    prev <- j
  }
  id
}

#' Write the first-down / new-series report
#'
#' `{check_dir}/first_downs.md`: the flag definitions, cfbfastR's rules and
#' where this package diverges, per-flag counts, and the validation: series
#' are formed independently of the flags ([segment_series()]); every series
#' must have exactly one row with `new_series = TRUE`, on its first snap row,
#' and no row outside a series may be flagged. Every violation is listed.
#' Also: snaps where different causes pointed (precedence applied) and the
#' edge-case series starts (regained kicks, overtime possessions).
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
  series_rows <- list()
  violations <- list()
  outside <- list()
  all_rows <- list()
  for (g in built) {
    d <- attr(g, "series_detail")
    g <- as.data.frame(g)
    sid <- segment_series(g, d$try_phase)
    x <- cbind(g[, c("game_id", "play_index", "period", "pos_team", "play_type", "down", "distance",
                     "penalty_no_play", flags, "play_text")], d, series_id = sid)
    x$play_text <- substr(x$play_text, 1, 110)
    all_rows[[length(all_rows) + 1]] <- x
    outside[[length(outside) + 1]] <- x[is.na(sid) & x$new_series, ]
    for (k in unique(stats::na.omit(sid))) {
      r <- x[which(sid == k), ]
      flagged <- which(r$new_series)
      ok <- length(flagged) == 1 && flagged == 1
      series_rows[[length(series_rows) + 1]] <- data.frame(ok = ok)
      if (!ok) {
        p_i <- r$play_index[1] - 1
        prev_text <- if (p_i >= 1) g$play_text[p_i] else ""
        prev_deadball_off_pen <- p_i >= 1 && g$play_type[p_i] == "penalty_no_play" && isTRUE(g$new_series[p_i]) &&
          identical(g$pos_team[p_i], r$pos_team[1]) && isTRUE(g$penalized_team[p_i] == g$pos_team[p_i]) &&
          r$down[1] %in% 1L && r$distance[1] %in% 10L
        n_seg <- stringr::str_count(stringr::str_remove(prev_text, "PENALTY .*$"), "\\bfor (loss of )?\\d+ yards?")
        violations[[length(violations) + 1]] <- data.frame(
          game_id = r$game_id[1], first_play_index = r$play_index[1],
          last_play_index = r$play_index[nrow(r)], offense = r$pos_team[1],
          first_situation = paste0(r$down[1], " & ", r$distance[1]),
          flagged_rows = if (length(flagged)) paste(r$play_index[flagged], collapse = ", ") else "none",
          problem = if (!length(flagged)) "no new_series row" else if (length(flagged) > 1) "more than one new_series row" else "new_series not on the first snap row",
          likely_cause = dplyr::case_when(
            !length(flagged) & n_seg > 1 ~ "previous play has more than one yardage segment (a lateral): yards_gained reads only the first, so its first down is missed",
            !length(flagged) & prev_deadball_off_pen ~ "previous row is a dead-ball penalty on the offense that started the series (flagged); d3 printed 1st & 10 after it instead of a longer distance, so the replay looks like a fresh series (source quirk)",
            length(flagged) == 1 & r$down[1] != 1L ~ "series starts with a down other than 1st: d3 kept the old down for the new offense after a change of possession (source quirk)",
            TRUE ~ "unexplained"),
          first_row_text = r$play_text[1]
        )
      }
    }
  }
  a <- do.call(rbind, all_rows)
  viol <- if (length(violations)) do.call(rbind, violations) else data.frame()
  out_flagged <- do.call(rbind, outside)
  n_series <- length(series_rows)

  counts <- data.frame(flag = flags, rows = vapply(flags, function(f) sum(a[[f]]), integer(1)))
  exclusive <- all(rowSums(a[, flags[1:4]]) == a$new_series)
  n_distinct_causes <- vapply(strsplit(ifelse(is.na(a$series_causes), "", a$series_causes), " \\+ "),
                              function(x) length(unique(x)), integer(1))
  multi <- a[n_distinct_causes > 1, ]
  ot <- a[a$firstD_by_poss & a$period > 4L, ]
  replays <- sum(!is.na(a$series_id) & !a$new_series &
                   c(FALSE, a$penalty_no_play[-nrow(a)]) & c(FALSE, a$series_id[-1] == a$series_id[-nrow(a)])[seq_len(nrow(a))],
                 na.rm = TRUE)

  out <- c(
    "# First downs and new series", "",
    "Generated by `build_season()` from every game in this season's folder.", "",
    "## The flags", "",
    "Each flag is on the **first snap row of a new series**: the first row with a down for the new series, which can be a penalty_no_play row (a dead-ball penalty or a nullified snap). A snap that replays the same down after a no-play penalty is never a series start. At most one flag is TRUE; `new_series` is any of them. Kickoffs, tries and every other row are FALSE in all five.", "",
    "- **`firstD_by_kickoff`:** first snap row after a kickoff (including an onside kick, whichever team recovered).",
    "- **`firstD_by_poss`:** first snap row after a change of possession (punt, interception, lost fumble, downs, missed / blocked FG, or a punt / FG the kicking team regains after a muff or return fumble), and the first snap row of each overtime possession.",
    "- **`firstD_by_yards`:** same offense; the previous play reached the line to gain.",
    "- **`firstD_by_penalty`:** same offense; the previous play didn't, and an accepted penalty awarded the first down (a declined penalty never counts).",
    "",
    "## cfbfastR (3.0.0, `prep_epa_df_after()`) and how this differs", "",
    "cfbfastR also puts `firstD_by_poss`, `firstD_by_yards`, `firstD_by_penalty` on the row that starts the series, computed from the previous row's values. Differences:", "",
    "- **Kickoff flag moved off the kickoff row:** cfbfastR sets `firstD_by_kickoff` on the kickoff row itself (`kickoff_play == 1 & down == 1`) and also flags the first snap after it `firstD_by_poss` (`drive_event_number == 2` after a kickoff). Here the kickoff row has no flag, and the first snap row after it is `firstD_by_kickoff`.",
    "- **Mutually exclusive:** cfbfastR computes the four independently, so they can overlap. Here precedence kickoff > poss > yards > penalty leaves exactly one.",
    "- **Declined penalties:** cfbfastR's `first_by_penalty` includes a penalty-type play whose penalty was declined but whose yardage reached the line. Here a declined penalty never counts; that play is `firstD_by_yards`.",
    "",
    "## Counts", "",
    md_table(counts), "",
    paste0("Exactly one of the four whenever `new_series` is TRUE: **", if (exclusive) "yes" else "NO", "**."), "",
    "## Validation: one `new_series` row per series, on its first snap row", "",
    "Series are formed from the situation alone, not from the flags (`segment_series()`). A new series begins at the first snap row of a half / OT period, after a kickoff, when the offense changes, or when the next row shows a fresh 1st down rather than the same down moved by a penalty. Replays of the same down after a no-play penalty stay in their series.", "",
    paste0("**", n_series, " series; ", n_series - nrow(viol), " have exactly one `new_series` row on their first snap row; ",
           nrow(viol), " violations.** Flagged rows outside any series (kickoffs, tries): **", nrow(out_flagged), "**. ",
           "Replays after a no-play penalty inside a series (correctly unflagged): ", replays, "."), "",
    md_table(viol), "",
    if (nrow(out_flagged)) md_table(out_flagged[, c("game_id", "play_index", "play_type", flags, "play_text")]) else NULL,
    "## Snaps where different causes pointed (precedence applied)", "",
    md_table(multi[, c("game_id", "play_index", "series_causes", flags[1:4], "play_text")]), "",
    "## Edge cases", "",
    paste0("First snap row of an overtime possession (`firstD_by_poss`): ", nrow(ot), "."), "",
    md_table(ot[, c("game_id", "play_index", "period", "pos_team", "play_type", "play_text")]), ""
  )
  writeLines(out, file.path(check_dir, "first_downs.md"))
  invisible(list(counts = counts, violations = viol, outside = out_flagged, multi = multi))
}
