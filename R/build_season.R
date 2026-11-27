#' Build a season's play-by-play from ncaa.com
#'
#' Scrapes ncaa.com and builds the play-by-play yourself: a whole season,
#' or the games involving some teams. For seasons already released,
#' [load_d3_pbp()] gives the same table without scraping.
#'
#' The games come from ncaa.com's Division III scoreboards (one request per
#' week). With `teams`, only games involving one of them are built: all
#' their games, including non-conference and playoff games. Each game's
#' play-by-play is then requested from ncaa.com and built with the same
#' rules as the released data (68 columns; see the schema in the package's
#' GitHub repository, `docs/schema.md`).
#'
#' **Requests are cached, throttled and capped.** Every response is saved
#' (by default in `tools::R_user_dir("d3ballR", "cache")`; see the
#' `d3ballR.dir` option) and never requested again, so a second call is
#' quick and an interrupted call continues where it stopped. Requests are
#' `delay` seconds apart: one team's season is about 35 requests (about 4
#' minutes), a whole season about 1,300 (about 2 hours). A game ncaa.com
#' has no play-by-play for yet is skipped and reported as pending.
#'
#' Only the 2025 season has been validated. Other seasons run with the
#' same rules, but ncaa.com's files vary by host school, so check the
#' result (with `check_dir`, the score reconciliation shows any game whose
#' plays don't add up to its final score).
#'
#' In the d3ballR repository: steps are [prefetch_ncaa_games()],
#' [ncaa_conference_table()], [build_all_pbp()], [write_build_report()] and
#' [write_first_down_report()]; the few games ncaa.com can't give are built
#' from stats.ncaa.org pages saved by hand ([stats_ncaa_games()]).
#'
#' @param season Season year (the fall it starts in: 2025 for 2025-26).
#' @param teams Team names to filter to, as ncaa.com spells them
#'   ("Carnegie Mellon", "Trinity (TX)"; see [load_d3_games()]), or NULL
#'   for every game.
#' @param max_requests Maximum new requests to ncaa.com in this call.
#' @param delay Seconds between requests (at least 6 is polite).
#' @param out_dir Folder to also write one CSV per game to, or NULL for
#'   none. Games already in it are rebuilt too.
#' @param check_dir Folder to write the validation reports to
#'   (`build_report.md`, `score_reconciliation.csv`, ...), or NULL for none.
#' @return A tibble, one row per play (see [load_d3_pbp()]). Games that
#'   could not be fetched or built are left out, with a message.
#' @examples
#' \dontrun{
#' cmu <- build_season(2025, teams = "Carnegie Mellon")
#' }
#' @export
build_season <- function(season, teams = NULL, max_requests = Inf, delay = 6,
                         out_dir = NULL, check_dir = NULL) {
  reset_fetch_state()
  old <- options(d3ballR.delay = delay, d3ballR.max_requests = max_requests)
  on.exit(options(old), add = TRUE)
  # the reports are needed internally (write_build_report() reads them
  # back); without check_dir they go to a temporary folder
  keep_checks <- !is.null(check_dir)
  if (!keep_checks) {
    check_dir <- tempfile("d3ballR_checks_")
    on.exit(unlink(check_dir, recursive = TRUE), add = TRUE)
  }

  # the game list: ncaa.com's scoreboards (game_id = contest id)
  idx <- ncaa_season_games(season)
  if (!is.null(teams)) check_team_names(teams, c(idx$home, idx$away))
  in_scope <- !is.na(idx$game_id) & (is.null(teams) | idx$home %in% teams | idx$away %in% teams)
  existing <- if (is.null(out_dir)) character() else sub("\\.csv$", "", list.files(out_dir, pattern = "\\.csv$"))
  games <- idx[in_scope | idx$game_id %in% existing, ]
  message(season, ": ", nrow(games), " games in scope (", sum(games$game_id %in% existing), " already built)")

  contests <- ncaa_contest_table(idx)
  # games ncaa.com can't give, built from a stats.ncaa.org page saved by hand
  stats_games <- stats_ncaa_games(season, idx)
  prefetch_ncaa_games(contests$contest[contests$game_id %in% games$game_id & !contests$game_id %in% names(stats_games)])
  conf <- ncaa_conference_table(season, idx)
  loader <- function(id) {
    if (id %in% names(stats_games)) fetch_stats_ncaa_game(id, stats_games[[id]], idx) else fetch_ncaa_game(id, contests, idx)
  }
  built <- build_all_pbp(games$game_id, out_dir = out_dir, check_dir = check_dir, conf = conf,
                         loader = loader, season = season, index = idx)
  write_build_report(season, teams, games, built, conf, check_dir, out_dir = out_dir, stats_games = stats_games)
  write_first_down_report(built, check_dir)
  if (keep_checks) message("Reports: ", file.path(check_dir, "build_report.md"))
  pbp <- tibble::as_tibble(dplyr::bind_rows(unname(built)))
  pbp[order(pbp$game_date, pbp$game_id, pbp$play_index), , drop = FALSE]
}

#' Stop on team names that aren't in the game list, suggesting close ones
#'
#' @param teams Names asked for.
#' @param known Names in the data.
#' @keywords internal
check_team_names <- function(teams, known) {
  known <- sort(unique(stats::na.omit(known)))
  bad <- setdiff(teams, known)
  if (!length(bad)) return(invisible(TRUE))
  hints <- vapply(bad, function(b) {
    close <- known[agrepl(b, known, ignore.case = TRUE, max.distance = 0.2) |
                     grepl(b, known, ignore.case = TRUE, fixed = FALSE)]
    if (length(close)) paste0(" (did you mean ", paste0("\"", utils::head(close, 4), "\"", collapse = ", "), "?)") else ""
  }, character(1))
  stop("No games for: ", paste0("\"", bad, "\"", hints, collapse = "; "),
       ". Team names are ncaa.com's short names; see load_d3_games().", call. = FALSE)
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
  cache_dir <- getOption("d3ballR.ncaa_cache_dir", d3_dir("data-raw", "cache", "ncaa"))
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
#' reconciliation (every game's points by team vs the final), the games
#' built from stats.ncaa.org, and the unclassified rows. Also writes each
#' game's conference columns to `conference_check.csv`. Per-game detail is
#' in `score_reconciliation.csv` and `build_failures.csv`.
#'
#' @param season Season year.
#' @param teams Filter used, or NULL.
#' @param games Game-list rows in scope.
#' @param built Output of [build_all_pbp()].
#' @param conf Output of [ncaa_conference_table()].
#' @param check_dir Report directory.
#' @param out_dir Where the per-game CSVs are (named in the report), or NULL.
#' @param stats_games Output of [stats_ncaa_games()].
#' @keywords internal
write_build_report <- function(season, teams, games, built, conf, check_dir,
                               out_dir = NULL, stats_games = character()) {
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
    paste0("Generated by `build_season()`.", if (!is.null(out_dir)) paste0(" Per-game CSVs are in `", out_dir, "/`.") else ""), "",
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
    "Points by team from `score_pts` (positive to `pos_team`, negative to `def_pos_team`) vs the final score (ncaa.com scoreboard). Per-game results: `score_reconciliation.csv`.", "",
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
      "Games ncaa.com can't give (no play-by-play, a file that can't be built, or one that doesn't reconcile when the stats.ncaa.org version does), built from a stats.ncaa.org page saved by hand in `data-raw/stats_ncaa/` (see `stats_ncaa_games()`):", "",
      md_table(data.frame(game_id = names(stats_games), file = basename(unname(stats_games)),
                          built = names(stats_games) %in% vapply(built, function(g) g$game_id[1], character(1)))), "") else NULL,
    "## Failed games", "",
    md_table(broken), "",
    "## Pending games", "",
    md_table(pending), "",
    if (nrow(absent)) c("## Not on ncaa.com", "", "Games with no ncaa.com contest.", "", md_table(absent), "") else NULL,
    "## Unclassified rows", "",
    "Rows the classifier couldn't type (its `other` bucket). They are dropped, so any here may hide a play: each needs a classifier rule.", "",
    md_table(unclassified), ""
  )
  writeLines(out, file.path(check_dir, "build_report.md"))
  invisible(out)
}
