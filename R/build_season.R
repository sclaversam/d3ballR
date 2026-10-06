#' Build a season's play-by-play: every game, or the games involving some teams
#'
#' One pipeline for every stage of the roadmap. The games come from the
#' season index ([build_season_index()]): with `teams = NULL`, every game
#' with a d3football boxscore; with `teams`, only games involving one of
#' them (e.g. a conference's members: any of their games, including
#' non-conference, playoff and bowl games). Games already in `out_dir` are
#' always rebuilt too, so `out_dir` and the reports in `check_dir` always
#' cover every game built so far for the season.
#'
#' Steps: the team-to-conference table for every team in those games
#' ([build_conference_table()]), then each game ([build_all_pbp()]), then the
#' build report ([write_build_report()]).
#'
#' Fetching is cached (a page is never requested twice), throttled
#' (`delay` seconds apart), capped (`max_requests` new requests per call),
#' and stops at the first sign of rate limiting (after that the run builds
#' only from the cache). Anything not fetched is reported as pending, so
#' calling `build_season()` again picks up where the last call stopped.
#'
#' @param season Season year.
#' @param teams Team names (scoreboard spelling) to filter to, or NULL for
#'   the whole season.
#' @param max_requests Maximum new network requests in this call.
#' @param delay Seconds between requests.
#' @param out_dir Per-game CSVs (`analysis/pbp/{season}/`).
#' @param check_dir Reports (`analysis/checks/{season}/`).
#' @return Invisibly, the list of built games.
#' @export
build_season <- function(season, teams = NULL, max_requests = Inf, delay = 6,
                         out_dir = file.path("analysis/pbp", season),
                         check_dir = file.path("analysis/checks", season)) {
  reset_fetch_state()
  old <- options(d3ballR.delay = delay, d3ballR.max_requests = max_requests)
  on.exit(options(old), add = TRUE)

  idx <- build_season_index(season)
  in_scope <- !is.na(idx$game_id) & (is.null(teams) | idx$home %in% teams | idx$away %in% teams)
  existing <- sub("\\.csv$", "", list.files(out_dir, pattern = "\\.csv$"))
  games <- idx[in_scope | idx$game_id %in% existing, ]
  message(season, ": ", nrow(games), " games in scope (", sum(games$game_id %in% existing), " already built)")

  conf <- build_conference_table(season, unique(c(games$home, games$away)))
  built <- build_all_pbp(games$boxscore_url, out_dir = out_dir, check_dir = check_dir, conf = conf)
  write_build_report(season, teams, games, built, conf, check_dir)
  if (fetch_refused()) message("d3football refused a request; the rest of this run used the cache only. Rerun later to continue.")
  invisible(built)
}

#' Write a season's build report
#'
#' `{check_dir}/build_report.md`: scope, how many games are built / pending
#' (not fetched yet) / failed (fetched but did not parse), the score
#' reconciliation (every game's points by team vs the boxscore final), and
#' the conference cross-check (d3's "*" marker vs shared membership, also
#' written to `conference_check.csv`). Per-game detail is in
#' `score_reconciliation.csv` and `build_failures.csv`.
#'
#' @param season Season year.
#' @param teams Filter used, or NULL.
#' @param games Index rows in scope.
#' @param built Output of [build_all_pbp()].
#' @param conf Output of [build_conference_table()].
#' @param check_dir Report directory.
#' @keywords internal
write_build_report <- function(season, teams, games, built, conf, check_dir) {
  md_table <- function(df) {
    if (!nrow(df)) return("None.")
    df[] <- lapply(df, function(x) ifelse(is.na(x), "", as.character(x)))
    c(paste0("| ", paste(names(df), collapse = " | "), " |"),
      paste0("|", paste(rep("---", ncol(df)), collapse = "|"), "|"),
      apply(df, 1, function(r) paste0("| ", paste(r, collapse = " | "), " |")))
  }
  cc <- do.call(rbind, lapply(built, function(g) data.frame(
    game_id = g$game_id[1], game_date = g$game_date[1], season_type = g$season_type[1],
    away = g$away[1], home = g$home[1],
    away_team_conference = g$away_team_conference[1], home_team_conference = g$home_team_conference[1],
    conference_game = g$conference_game[1], shared_conference = attr(g, "shared_conference"))))
  if (is.null(cc)) cc <- data.frame()
  if (nrow(cc)) {
    known <- !is.na(cc$conference_game) & !is.na(cc$away_team_conference) & !is.na(cc$home_team_conference)
    cc$agree <- ifelse(known, cc$conference_game == cc$shared_conference, NA)
  }
  utils::write.csv(cc, file.path(check_dir, "conference_check.csv"), row.names = FALSE, na = "")

  rec <- utils::read.csv(file.path(check_dir, "score_reconciliation.csv"), na.strings = "")
  fail <- utils::read.csv(file.path(check_dir, "build_failures.csv"), na.strings = "")
  pending <- fail[grepl("^Not fetched", fail$error), ]
  broken <- fail[!grepl("^Not fetched", fail$error), ]
  pending_teams <- setdiff(unique(c(games$home, games$away)), conf$table$team)
  unnamed <- unique(stats::na.omit(conf$table$conference_code[is.na(conf$table$conference)]))

  scope <- if (is.null(teams)) "every game in the season index with a d3football boxscore" else
    paste0("games involving: ", paste(sort(teams), collapse = ", "))
  out <- c(
    paste0("# ", season, " build report"), "",
    paste0("Generated by `build_season()`. Per-game CSVs are in `analysis/pbp/", season, "/`."), "",
    "## Scope", "",
    paste0("- **Requested:** ", scope, "."),
    paste0("- **Games in scope:** ", nrow(games), " (includes every game already built for the season)."),
    paste0("- **Built:** ", length(built), ". **Pending** (page not fetched yet): ", nrow(pending),
           ". **Failed** (fetched but did not parse): ", nrow(broken), "."),
    paste0("- **Teams:** ", length(unique(c(games$home, games$away))), " in these games; ",
           nrow(conf$table), " in `data-raw/conferences/", season, ".csv`",
           if (length(pending_teams)) paste0(" (", length(pending_teams), " team pages pending; their conference is NA until fetched)") else "", "."),
    if (length(unnamed)) paste0("- **Conference names pending:** ", paste(unnamed, collapse = ", "),
                                " (standings page not fetched yet; those teams' conference columns are NA until it is).") else NULL,
    "",
    "## Score reconciliation", "",
    "Points by team from `score_pts` (positive to `pos_team`, negative to `def_pos_team`) vs the boxscore line-score final. Per-game results: `score_reconciliation.csv`.", "",
    paste0("**", sum(rec$score_reconciled), " of ", nrow(rec), " built games pass.** Failing games:"), "",
    md_table(rec[!rec$score_reconciled, , drop = FALSE]), "",
    "## Conference game: d3's \"*\" marker vs shared membership", "",
    paste0(if (nrow(cc)) sum(cc$agree, na.rm = TRUE) else 0, " of ", sum(!is.na(cc$agree)),
           " games with known conferences agree (", sum(is.na(cc$agree)), " not checkable yet). Disagreements:"), "",
    md_table(if (nrow(cc)) cc[cc$agree %in% FALSE, ] else cc), "",
    "## Failed games", "",
    md_table(broken), ""
  )
  writeLines(out, file.path(check_dir, "build_report.md"))
  invisible(out)
}
