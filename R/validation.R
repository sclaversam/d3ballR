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
