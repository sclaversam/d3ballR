#' Build a season's play-by-play: every game, or the games involving some teams
#'
#' One pipeline for every stage of the roadmap. The games come from
#' ncaa.com's scoreboards ([ncaa_season_games()]): with `teams =
#' NULL`, every game in the list; with `teams`, only games involving one of them (e.g. a
#' conference's members: any of their games, including non-conference,
#' playoff and bowl games). Games already in `out_dir` are always rebuilt
#' too, so `out_dir` and the reports in `check_dir` always cover every game
#' built so far for the season.
#'
#' The play-by-play comes from ncaa.com, requested directly from R (see
#' [fetch_ncaa_json()]; an ncaa-api server is optional): each game's
#' (contest's) play-by-play is fetched ([prefetch_ncaa_games()]) and rebuilt
#' into the play table the parser reads ([fetch_ncaa_game()]). Games
#' ncaa.com can't give are built from stats.ncaa.org pages saved by hand
#' ([stats_ncaa_games()]).
#'
#' Steps: fetch every game not yet cached, then the team-to-conference
#' table ([ncaa_conference_table()]), then
#' build each game ([build_all_pbp()]), then the build report
#' ([write_build_report()]). Conference columns are NA for teams not yet
#' looked up and fill in on a later run.
#'
#' Fetching is cached (nothing is requested twice), throttled (`delay`
#' seconds apart) and capped (`max_requests` new requests per call).
#' Anything not fetched is reported as pending, so calling `build_season()`
#' again picks up where the last call stopped.
#'
#' @param season Season year.
#' @param teams Team names (scoreboard spelling) to filter to, or NULL for
#'   the whole season.
#' @param max_requests Maximum new network requests in this call.
#' @param delay Seconds between requests.
#' @param out_dir Per-game CSVs. NULL means `pbp/{season}/`.
#' @param check_dir Reports. NULL means `checks/{season}/`.
#' @return Invisibly, the list of built games.
#' @export
build_season <- function(season, teams = NULL, max_requests = Inf, delay = 6,
                         out_dir = NULL, check_dir = NULL) {
  if (is.null(out_dir)) out_dir <- file.path("pbp", season)
  if (is.null(check_dir)) check_dir <- file.path("checks", season)
  reset_fetch_state()
  old <- options(d3ballR.delay = delay, d3ballR.max_requests = max_requests)
  on.exit(options(old), add = TRUE)

  # the game list: ncaa.com's scoreboards (game_id = contest id)
  idx <- ncaa_season_games(season)
  in_scope <- !is.na(idx$game_id) & (is.null(teams) | idx$home %in% teams | idx$away %in% teams)
  existing <- sub("\\.csv$", "", list.files(out_dir, pattern = "\\.csv$"))
  games <- idx[in_scope | idx$game_id %in% existing, ]
  message(season, ": ", nrow(games), " games in scope (", sum(games$game_id %in% existing), " already built)")

  contests <- ncaa_contest_table(idx)
  # games ncaa.com can't give, built from a stats.ncaa.org page Sam saved
  stats_games <- stats_ncaa_games(season, idx)
  prefetch_ncaa_games(contests$contest[contests$game_id %in% games$game_id & !contests$game_id %in% names(stats_games)])
  conf <- ncaa_conference_table(season, idx)
  loader <- function(id) {
    if (id %in% names(stats_games)) fetch_stats_ncaa_game(id, stats_games[[id]], idx) else fetch_ncaa_game(id, contests, idx)
  }
  built <- build_all_pbp(games$game_id, season = season, out_dir = out_dir, check_dir = check_dir, conf = conf,
                         loader = loader, index = idx)
  write_build_report(season, teams, games, built, conf, check_dir, out_dir = out_dir, stats_games = stats_games)
  write_first_down_report(built, check_dir)
  invisible(built)
}

#' Fetch (and cache) the ncaa.com play-by-play of games not yet cached
#'
#' Stops when the request budget is reached or the run is offline. A game
#' ncaa.com has no play-by-play for (HTTP 500 / 502) is skipped, stays
#' pending, and is not requested again in the same run (see
#' [fetch_ncaa_json()]). Right after a game's play-by-play is in the cache,
#' if it has no running score (some host schools' files), its scoring
#' summary is fetched too, within the same budget: [fetch_ncaa_game()]
#' needs it to tell which extra points were good. Games cached by earlier
#' runs that still lack their summary get it here as well.
#'
#' @param contests ncaa.com contest ids.
#' @return Invisibly, the number of play-by-play pages fetched.
#' @keywords internal
prefetch_ncaa_games <- function(contests) {
  contests <- unique(stats::na.omit(contests))
  cache_dir <- getOption("d3ballR.ncaa_cache_dir", "data-raw/cache/ncaa")
  cached <- function(p) file.exists(file.path(cache_dir, ncaa_cache_key(p)))
  pbp <- paste0("/game/", contests, "/play-by-play")
  summ <- paste0("/game/", contests, "/scoring-summary")
  message(sum(!vapply(pbp, cached, logical(1))), " ncaa.com games not yet cached")
  stop_now <- function() n_requests() >= getOption("d3ballR.max_requests", Inf) ||
    isTRUE(getOption("d3ballR.offline", FALSE)) || grepl("unreachable", geterrmessage())
  try_fetch <- function(p) tryCatch({ fetch_ncaa_json(p); TRUE }, error = function(e) { message(conditionMessage(e)); FALSE })
  got <- 0L
  for (k in seq_along(contests)) {
    if (!cached(pbp[k])) {
      ok <- try_fetch(pbp[k])
      if (!ok && stop_now()) break
      if (!ok) next
      got <- got + 1L
      if (got %% 25L == 0L) message(format(Sys.time(), "%H:%M:%S"), " fetched ", got, " games")
    }
    if (!cached(summ[k]) && !ncaa_has_running_score(fetch_ncaa_json(pbp[k]))) {
      if (!try_fetch(summ[k]) && stop_now()) break
    }
  }
  message("fetched ", got, " ncaa.com games this run")
  invisible(got)
}

#' Write a season's build report
#'
#' `{check_dir}/build_report.md`: scope, how many games are built / pending
#' (not fetched yet) / failed (fetched but did not parse), the score
#' reconciliation (every game's points by team vs the final score), and
#' each built game's conferences (`conference_check.csv`). Per-game detail is in
#' `score_reconciliation.csv` and `build_failures.csv`.
#'
#' @param season Season year.
#' @param teams Filter used, or NULL.
#' @param games Game-list rows in scope.
#' @param built Output of [build_all_pbp()].
#' @param conf Output of [ncaa_conference_table()].
#' @param check_dir Report directory.
#' @param out_dir Where the per-game CSVs are (named in the report).
#' @param stats_games Games built from saved stats.ncaa.org pages: file
#'   paths named by game id ([stats_ncaa_games()]).
#' @keywords internal
write_build_report <- function(season, teams, games, built, conf, check_dir,
                               out_dir = file.path("pbp", season), stats_games = character()) {
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
  utils::write.csv(cc, file.path(check_dir, "conference_check.csv"), row.names = FALSE, na = "")

  unclassified <- do.call(rbind, lapply(built, attr, "unclassified"))
  if (is.null(unclassified)) unclassified <- data.frame()
  rec <- utils::read.csv(file.path(check_dir, "score_reconciliation.csv"), na.strings = "")
  exc <- load_known_exceptions()
  not_ok <- rec[!(rec$score_reconciled %in% TRUE), , drop = FALSE]
  is_known <- not_ok$game_id %in% exc$game_id
  rec_fail <- not_ok[!is_known, , drop = FALSE]
  rec_known <- not_ok[is_known, , drop = FALSE]
  rec_known$reason <- exc$reason[match(rec_known$game_id, exc$game_id)]
  fail <- utils::read.csv(file.path(check_dir, "build_failures.csv"), na.strings = "")
  pending <- fail[grepl("^Not fetched", fail$error), ]
  absent <- fail[grepl("^Not on ncaa", fail$error), ]
  broken <- fail[!grepl("^Not fetched|^Not on ncaa", fail$error), ]

  src <- if (is.null(ncaa_api_base())) "ncaa.com" else "ncaa.com (via ncaa-api)"
  scope <- if (is.null(teams)) "every game on ncaa.com's scoreboards" else
    paste0("games involving: ", paste(sort(teams), collapse = ", "))
  out <- c(
    paste0("# ", season, " build report"), "",
    paste0("Generated by `build_season()`. Per-game CSVs are in `", out_dir, "/`."), "",
    "## Scope", "",
    paste0("- **Requested:** ", scope, "."),
    paste0("- **Games in scope:** ", nrow(games), " (includes every game already built for the season)."),
    paste0("- **Source:** ", src, "."),
    paste0("- **Built:** ", length(built), ". **Pending** (not fetched yet, or ncaa.com had no play-by-play): ", nrow(pending),
           ". **Not on ncaa.com:** ", nrow(absent),
           ". **Failed** (fetched but did not parse): ", nrow(broken), "."),
    {
      tm <- unique(c(games$home, games$away))
      paste0("- **Teams:** ", length(tm), " in these games; conferences from ncaa.com's scoreboards (`data-raw/ncaa/",
             season, "_conferences.csv`); ", sum(is.na(conf$table$conference[match(tm, conf$table$team)])),
             " have no D3 conference (non-D3 opponents and independents).")
    },
    "",
    "## Score reconciliation", "",
    paste0("Points by team from `score_pts` (positive to `pos_team`, negative to `def_pos_team`) vs the final score (",
           "ncaa.com scoreboard", "). Per-game results: `score_reconciliation.csv`."), "",
    # NA (no points could be parsed) counts as not passing
    paste0("**", sum(rec$score_reconciled %in% TRUE), " of ", nrow(rec), " built games pass.**",
           if (any(is.na(rec$score_reconciled))) paste0(" ", sum(is.na(rec$score_reconciled)),
             " could not be checked (blank `score_reconciled`: no points parsed for a team).") else "",
           if (nrow(rec_known)) paste0(" ", nrow(rec_known), " of the rest are known source gaps (listed below).") else "",
           " Failing games:"), "",
    md_table(rec_fail), "",
    if (nrow(rec_known)) c("Known source exceptions (`data-raw/ncaa/known_exceptions.csv`: ncaa.com's data is incomplete or inconsistent, not a parser error):", "",
                           md_table(rec_known), "") else NULL,
    if (length(stats_games)) c("## Built from stats.ncaa.org", "",
      "Games ncaa.com can't give (no play-by-play, or a file that can't be built), built from a stats.ncaa.org page saved by hand in `data-raw/stats_ncaa/` (see `stats_ncaa_games()`):", "",
      md_table(data.frame(game_id = names(stats_games), file = basename(unname(stats_games)),
                          built = names(stats_games) %in% vapply(built, function(g) g$game_id[1], character(1)))), "") else NULL,
    "## Failed games", "",
    md_table(broken), "",
    "## Pending games", "",
    md_table(pending), "",
    "## Not on ncaa.com", "",
    "Games with no ncaa.com contest.", "",
    md_table(absent), "",
    "## Unclassified rows", "",
    "Rows the classifier couldn't type (its `other` bucket). They are dropped, so any here may hide a play: each needs a classifier rule.", "",
    md_table(unclassified), ""
  )
  writeLines(out, file.path(check_dir, "build_report.md"))
  invisible(out)
}
