#' Load pre-built Division III play-by-play
#'
#' Downloads the released play-by-play for one or more seasons: every game
#' on ncaa.com's Division III scoreboards, regular season through the Stagg
#' Bowl, one row per play. The file is downloaded once (about 15 MB a
#' season) and kept in `tools::R_user_dir("d3ballR", "cache")`, so later
#' calls read it from disk.
#'
#' The 68 columns follow cfbfastR's names where an equivalent exists.
#' Each is defined in `docs/schema.md` in the package's GitHub repository.
#' Two to know about:
#' - `situation_suspect`: TRUE where ncaa.com's down, distance or spot
#'   contradicts the plays before it (a skipped down, a missing line). The
#'   printed values are kept; leave these rows out when grouping by down
#'   or distance.
#' - `situation` and `play_text`: ncaa.com's raw text, so every derived
#'   value can be checked against its source.
#'
#' @param seasons Season years (the fall the season starts in). Released so
#'   far: 2025.
#' @param teams Team names to keep games of, as ncaa.com spells them
#'   ("Carnegie Mellon", "Trinity (TX)"; see [load_d3_games()]), or NULL
#'   for every game.
#' @param refresh Download again even if a copy is saved (to pick up a
#'   corrected release).
#' @return A tibble, one row per play.
#' @examples
#' \dontrun{
#' pbp <- load_d3_pbp(2025)
#' cmu <- load_d3_pbp(2025, teams = "Carnegie Mellon")
#' }
#' @export
load_d3_pbp <- function(seasons = 2025, teams = NULL, refresh = FALSE) {
  pbp <- tibble::as_tibble(dplyr::bind_rows(lapply(seasons, function(s) readRDS(release_file(paste0("pbp_", s, ".rds"), s, refresh)))))
  if (!is.null(teams)) {
    check_team_names(teams, c(pbp$home, pbp$away))
    pbp <- pbp[pbp$home %in% teams | pbp$away %in% teams, , drop = FALSE]
  }
  pbp
}

#' Load a season's Division III game list
#'
#' One row per game on ncaa.com's Division III scoreboards, with the
#' teams' conferences. Use it to find a game's `game_id` or a team's exact
#' name, or to pick games (a conference's, the playoffs) before loading
#' their plays. Released seasons ship with the package; a season built
#' with [build_season()] is read from where that saved it.
#'
#' @param seasons Season years.
#' @return A tibble: `game_id` (ncaa.com's contest id), `season`,
#'   `game_date`, `week` (ncaa.com's scoreboard week), `season_type`
#'   ("regular" or "postseason"), `bracket_round` (NCAA tournament round,
#'   1 for the first; NA otherwise), `home`, `away`, `home_score`,
#'   `away_score`, `home_team_conference`, `away_team_conference` (NA for
#'   non-D3 teams and independents).
#' @examples
#' games <- load_d3_games(2025)
#' games[games$bracket_round %in% 6, ]  # the Stagg Bowl
#' @export
load_d3_games <- function(seasons = 2025) {
  dplyr::bind_rows(lapply(seasons, function(s) {
    g <- utils::read.csv(game_list_file(s, "games"), colClasses = c(game_id = "character"), na.strings = "")
    conf <- utils::read.csv(game_list_file(s, "conferences"), na.strings = "")
    g$bracket_round <- suppressWarnings(as.integer(g$bracket_round))
    g$home_team_conference <- conf$conference[match(g$home, conf$team)]
    g$away_team_conference <- conf$conference[match(g$away, conf$team)]
    tibble::as_tibble(g[, c("game_id", "season", "game_date", "week", "season_type", "bracket_round",
                            "home", "away", "home_score", "away_score",
                            "home_team_conference", "away_team_conference")])
  }))
}

#' Where a season's game list or conference table is
#'
#' A copy built by [build_season()] (`data-raw/ncaa/` under [d3_root()])
#' if there is one, since it is the newest; else the copy shipped in
#' `inst/extdata/games/`.
#'
#' @param season Season year.
#' @param what "games" or "conferences".
#' @keywords internal
game_list_file <- function(season, what) {
  name <- paste0(season, "_", what, ".csv")
  built <- d3_dir("data-raw", "ncaa", name)
  if (file.exists(built)) return(built)
  shipped <- system.file("extdata", "games", name, package = "d3ballR")
  if (nzchar(shipped)) return(shipped)
  stop("No ", season, " game list: it isn't released yet. Build it with build_season(", season, ").", call. = FALSE)
}

#' Download a released data file (once) and return its local path
#'
#' Files are assets of the d3ballR GitHub release `pbp_data`
#' (`getOption("d3ballR.release_url")` overrides the address) and are kept
#' in `tools::R_user_dir("d3ballR", "cache")/release/`.
#'
#' @param name File name ("pbp_2025.rds").
#' @param season Season, for the error message.
#' @param refresh Download even if saved.
#' @keywords internal
release_file <- function(name, season, refresh = FALSE) {
  dir <- file.path(tools::R_user_dir("d3ballR", "cache"), "release")
  f <- file.path(dir, name)
  if (file.exists(f) && !refresh) return(f)
  base <- getOption("d3ballR.release_url", "https://github.com/sclaversam/d3ballR/releases/download/pbp_data")
  message("Downloading ", name, " ...")
  resp <- tryCatch(
    httr2::request(paste0(base, "/", name)) |>
      httr2::req_user_agent("d3ballR") |>
      httr2::req_error(is_error = function(r) FALSE) |>
      httr2::req_timeout(300) |>
      httr2::req_perform(),
    error = function(e) stop("Couldn't download ", name, ": ", conditionMessage(e), call. = FALSE))
  status <- httr2::resp_status(resp)
  if (status == 404) {
    stop("No pre-built play-by-play for ", season, ". Build it with build_season(", season, ").", call. = FALSE)
  }
  if (status != 200) stop("Couldn't download ", name, ": HTTP ", status, call. = FALSE)
  dir.create(dir, showWarnings = FALSE, recursive = TRUE)
  tmp <- tempfile(tmpdir = dir)
  writeBin(httr2::resp_body_raw(resp), tmp)
  file.rename(tmp, f)
  f
}
