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

  for (nm in names(reports)) {
    utils::write.csv(reports[[nm]], file.path(check_dir, paste0(nm, ".csv")), row.names = FALSE, na = "")
  }
  invisible(reports)
}
