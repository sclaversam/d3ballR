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
#'   snap belongs to the other team) with `yards_to_goal`, the next snap's
#'   own down / distance / yards to goal, and its team and text. The
#'   `next_*` values are from the next snap's offense view, so across a
#'   change of possession they are measured toward the other end zone.
#' - `clock_bounds.csv`: any regulation row whose `clock_start_at_most` /
#'   `clock_start_at_least` is NA, max < min, or `clock_start` (when known) falls
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
    # the next snap's own situation, from THAT snap's offense view -- a
    # diagnostic only, which is why it is not an output column: on a change of
    # possession it is measured toward the other end zone than `yards_to_goal`
    na_next <- g$scoring_play | attr(g, "series_detail")$try_phase |
      g$play_type %in% c("extra_point", "two_point") | is.na(nxt)
    nx_down <- ifelse(na_next, NA_integer_, g$down[nxt])
    nx_distance <- ifelse(na_next, NA_integer_, g$distance[nxt])
    nx_yards_to_goal <- ifelse(na_next, NA_integer_, g$yards_to_goal[nxt])
    change <- g$play_type %in% c("kickoff", "punt_no_return", "punt_with_return", "punt_blocked",
                                 "field_goal_missed", "field_goal_blocked") |
      g$turnover | (!is.na(next_team) & next_team != g$pos_team & !g$play_type %in% c("extra_point", "two_point"))
    change <- change & !g$penalty_no_play
    data.frame(
      game_id = g$game_id[change], play_index = g$play_index[change], period = g$period[change],
      play_type = g$play_type[change], pos_team = g$pos_team[change],
      yards_to_goal = g$yards_to_goal[change], next_down = nx_down[change],
      next_distance = nx_distance[change], next_yards_to_goal = nx_yards_to_goal[change],
      next_pos_team = next_team[change], scoring_play = g$scoring_play[change],
      play_text = g$play_text[change], next_play_text = g$play_text[nxt][change]
    )
  }))

  b <- dplyr::bind_rows(games)
  reg <- b$period <= 4L  # overtime is untimed: clock columns NA by design
  mx <- clock_secs(b$clock_start_at_most)
  mn <- clock_secs(b$clock_start_at_least)
  st <- clock_secs(b$clock_start)
  bad <- reg & (is.na(mx) | is.na(mn) | mx < mn | (!is.na(st) & (st > mx | st < mn)))
  reports$clock_bounds <- as.data.frame(b[bad, c("game_id", "play_index", "period", "clock_start", "clock_end",
                                                 "clock_start_at_most", "clock_start_at_least", "play_text")])

  for (nm in names(reports)) {
    utils::write.csv(reports[[nm]], file.path(check_dir, paste0(nm, ".csv")), row.names = FALSE, na = "")
  }
  invisible(reports)
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
#' a violation. Dead-ball personal fouls before the ball is ready for play
#' ([pre_ready_foul_row()]) belong to no series.
#'
#' @param g One built game (data frame).
#' @param try_phase Logical, per row.
#' @return Integer series id per row (NA on rows that aren't snap rows).
#' @keywords internal
segment_series <- function(g, try_phase) {
  # a dead-ball personal foul before the ball is ready for play is in no
  # series (Rule 5-2-7; see pre_ready_foul_row())
  snap <- !is.na(g$down) & !try_phase & !pre_ready_foul_row(g)
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
  flags <- "new_series"
  series_rows <- list()
  violations <- list()
  outside <- list()
  all_rows <- list()
  for (g in built) {
    d <- attr(g, "series_detail")
    g <- as.data.frame(g)
    sid <- segment_series(g, d$try_phase)
    x <- cbind(g[, c("game_id", "play_index", "period", "pos_team", "play_type", "down", "distance",
                     "penalty_no_play", flags, "situation_suspect", "play_text")], d, series_id = sid)
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
            !length(flagged) & prev_deadball_off_pen ~ "previous row is a dead-ball penalty on the offense that started the series (flagged); the source printed 1st & 10 after it instead of a longer distance, so the replay looks like a fresh series (source quirk)",
            length(flagged) == 1 & r$down[1] != 1L ~ "series starts with a down other than 1st: the source kept the old down for the new offense after a change of possession (source quirk)",
            length(flagged) > 1 & all(r$down[flagged[-1]] > 1L, na.rm = TRUE) ~ "the play earned a first down (its text or yardage), but the source's next situation isn't a 1st down: its down counter skipped the 1st down, or it dropped a 1st-down play that gained nothing (source quirk; the flag follows the play)",
            TRUE ~ "unexplained"),
          situation_suspect = any(r$situation_suspect),
          first_row_text = r$play_text[1]
        )
      }
    }
  }
  a <- do.call(rbind, all_rows)
  viol <- if (length(violations)) do.call(rbind, violations) else data.frame()
  out_flagged <- do.call(rbind, outside)
  n_series <- length(series_rows)

  causes <- c("kickoff", "poss", "yards", "penalty", "situation")
  counts <- data.frame(cause = c(causes, "all (new_series)"),
                       rows = c(vapply(causes, function(k) sum(a$series_cause %in% k), integer(1)),
                                sum(a$new_series)))
  exclusive <- all(!is.na(a$series_cause) == a$new_series)
  n_distinct_causes <- vapply(strsplit(ifelse(is.na(a$series_causes), "", a$series_causes), " \\+ "),
                              function(x) length(unique(x)), integer(1))
  multi <- a[n_distinct_causes > 1, ]
  ot <- a[a$series_cause %in% "poss" & a$period > 4L, ]
  replays <- sum(!is.na(a$series_id) & !a$new_series &
                   c(FALSE, a$penalty_no_play[-nrow(a)]) & c(FALSE, a$series_id[-1] == a$series_id[-nrow(a)])[seq_len(nrow(a))],
                 na.rm = TRUE)

  out <- c(
    "# First downs and new series", "",
    "Generated by `build_season()` from every game in this season's folder.", "",
    "## The flag", "",
    "`new_series` is TRUE on the **first snap row of a new series**: the first row with a down for the new series, which can be a penalty_no_play row (a dead-ball penalty or a nullified snap). A snap that replays the same down after a no-play penalty is never a series start. Kickoffs, tries and every other row are FALSE.", "",
    "Internally each new series has one cause (not in the output; precedence kickoff > poss > yards > penalty):", "",
    "- **kickoff:** first snap row after a kickoff (including an onside kick, whichever team recovered), or of a regulation half with no kickoff line.",
    "- **poss:** first snap row after a change of possession (punt, interception, lost fumble, downs, missed / blocked FG, or a punt / FG the kicking team regains after a muff or return fumble), and the first snap row of each overtime possession.",
    "- **yards:** same offense; the previous play reached the line to gain.",
    "- **penalty:** same offense; the previous play didn't, and an accepted penalty awarded the first down (a declined penalty never counts).",
    "- **situation:** same offense; ncaa.com shows a 1st down right after a 2nd / 3rd / 4th down and no line causes it (the line is missing). Regulation only.",
    "",
    "cfbfastR has four `firstD_by_*` columns instead (computed independently, so they can overlap); d3ballR keeps only `new_series` (decided 2026-11-25).", "",
    "## Counts", "",
    md_table(counts), "",
    paste0("Every `new_series` row has exactly one cause, and no other row has one: **", if (exclusive) "yes" else "NO", "**."), "",
    "## Validation: one `new_series` row per series, on its first snap row", "",
    "Series are formed from the situation alone, not from the flags (`segment_series()`). A new series begins at the first snap row of a half / OT period, after a kickoff, when the offense changes, or when the next row shows a fresh 1st down rather than the same down moved by a penalty. Replays of the same down after a no-play penalty stay in their series.", "",
    paste0("**", n_series, " series; ", n_series - nrow(viol), " have exactly one `new_series` row on their first snap row; ",
           nrow(viol), " violations.** Flagged rows outside any series (kickoffs, tries): **", nrow(out_flagged), "**. ",
           "Replays after a no-play penalty inside a series (correctly unflagged): ", replays, "."), "",
    paste0("Violations whose series has `situation_suspect` rows (the source's down / distance contradicts the play before): **",
           if (nrow(viol)) sum(viol$situation_suspect) else 0L, "**. Rows with `situation_suspect`: **", sum(a$situation_suspect), "**."), "",
    md_table(viol), "",
    if (nrow(out_flagged)) md_table(out_flagged[, c("game_id", "play_index", "play_type", "new_series", "series_cause", "play_text")]) else NULL,
    "## Snaps where different causes pointed (precedence applied)", "",
    md_table(multi[, c("game_id", "play_index", "series_causes", "series_cause", "play_text")]), "",
    "## Edge cases", "",
    paste0("First snap row of an overtime possession (cause poss): ", nrow(ot), "."), "",
    md_table(ot[, c("game_id", "play_index", "period", "pos_team", "play_type", "play_text")]), ""
  )
  writeLines(out, file.path(check_dir, "first_downs.md"))
  invisible(list(counts = counts, violations = viol, outside = out_flagged, multi = multi))
}
