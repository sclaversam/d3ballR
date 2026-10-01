#' Write the validation reports for a set of built games
#'
#' Writes CSVs to `check_dir` from the per-game tibbles returned by
#' [build_pbp()] (their attributes carry the intermediate decisions):
#' - `kickoff_possession.csv`: every kickoff with kicking / receiving team,
#'   the rule that decided it (header / override / fallback), and any
#'   disagreement between the drive header, the recovery text, and the
#'   pre-kick context.
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

  for (nm in names(reports)) {
    utils::write.csv(reports[[nm]], file.path(check_dir, paste0(nm, ".csv")), row.names = FALSE, na = "")
  }
  invisible(reports)
}
