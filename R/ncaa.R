#' Where ncaa.com's data is requested from
#'
#' By default d3ballR asks ncaa.com's own data server
#' (`https://sdataprod.ncaa.com/`) directly, the same requests ncaa.com's
#' game pages make (see [ncaa_direct_request()]). Nothing else needs to be
#' running. To go through an ncaa-api server instead
#' (github.com/henrygd/ncaa-api, e.g. run locally in Docker), set
#' `options(d3ballR.ncaa_api = "http://127.0.0.1:3000")`; both give the
#' same cached files.
#'
#' @return The ncaa-api server's address (no trailing slash), or NULL for
#'   direct requests.
#' @keywords internal
ncaa_api_base <- function() {
  api <- getOption("d3ballR.ncaa_api", NULL)
  if (is.null(api) || !nzchar(api)) return(NULL)
  sub("/+$", "", api)
}

#' Query ids of ncaa.com's data server
#'
#' ncaa.com's pages ask `sdataprod.ncaa.com` for named, pre-registered
#' ("persisted") GraphQL queries, each identified by a sha256 hash. These
#' are copied from ncaa.com's page source (via henrygd/ncaa-api's
#' `src/codes.ts`, 2026-11-08). When ncaa.com redeploys, a hash can change
#' and every request of that kind fails ("PersistedQueryNotFound"); the fix
#' is to update the hash here.
#' @keywords internal
ncaa_query_hashes <- c(
  scoreboard = "7287cda610a9326931931080cb3a604828febe6fe3c9016a7e4a36db99efdb7c",
  play_by_play = "47928f2cabc7a164f0de0ed535a623bdf5a852cce7c30d6a6972a38609ba46a2",
  scoring_summary = "7f86673d4875cd18102b7fa598e2bc5da3f49d05a1c15b1add0e2367ee890198"
)

#' File name for a cached ncaa.com path
#' @param path ncaa-api style path, e.g. "/game/6461399/play-by-play".
#' @keywords internal
ncaa_cache_key <- function(path) {
  paste0(gsub("[^A-Za-z0-9._-]+", "_", sub("^/+", "", path)), ".json")
}

#' Fetch an ncaa.com path as parsed JSON (cached, throttled)
#'
#' Paths are named the way ncaa-api names them (they are also the cache
#' file names): `/scoreboard/football/d3/{year}/{week}/all-conf`,
#' `/game/{contest}/play-by-play`, `/game/{contest}/scoring-summary`.
#' By default each is requested from ncaa.com directly
#' ([ncaa_direct_request()]); with `options(d3ballR.ncaa_api = ...)` from
#' an ncaa-api server ([ncaa_api_base()]). Both store the same JSON.
#'
#' Every response is cached on disk
#' (`getOption("d3ballR.ncaa_cache_dir")`, default `data-raw/cache/ncaa/`,
#' gitignored) and never requested twice; requests are at least
#' `d3ballR.delay` seconds apart and count against `d3ballR.max_requests`;
#' with `options(d3ballR.offline = TRUE)` nothing is requested. A failed
#' request (no play-by-play for the game yet: HTTP 502, as ncaa-api
#' reports it) is an error starting "Not fetched:" and is not cached.
#'
#' @param path Path, starting with "/".
#' @param refresh Re-fetch even if cached.
#' @return The parsed JSON (a list, from [jsonlite::fromJSON()] with
#'   `simplifyVector = FALSE`).
#' @keywords internal
fetch_ncaa_json <- function(path, refresh = FALSE) {
  cache_dir <- getOption("d3ballR.ncaa_cache_dir", "data-raw/cache/ncaa")
  file <- file.path(cache_dir, ncaa_cache_key(path))
  if (!refresh && file.exists(file)) return(jsonlite::fromJSON(file, simplifyVector = FALSE))
  if (isTRUE(getOption("d3ballR.offline", FALSE))) {
    stop("Not fetched: offline (option d3ballR.offline = TRUE): ", path, call. = FALSE)
  }
  # a path that already returned an HTTP error this run (no play-by-play
  # yet) is not requested again until the next run
  failed <- .fetch_state$http_failed
  if (!is.null(failed) && path %in% names(failed)) {
    stop("Not fetched: ncaa.com HTTP ", failed[[path]], " for ", path, " (earlier this run; not retried)", call. = FALSE)
  }
  budget <- getOption("d3ballR.max_requests", Inf)
  if (n_requests() >= budget) stop("Not fetched: request budget (", budget, ") reached: ", path, call. = FALSE)
  throttle()
  .fetch_state$n_requests <- n_requests() + 1L
  api <- ncaa_api_base()
  res <- if (is.null(api)) ncaa_direct_request(path) else ncaa_api_request(api, path)
  if (is.null(res$body)) {
    .fetch_state$http_failed <- c(.fetch_state$http_failed, stats::setNames(as.character(res$status), path))
    stop("Not fetched: ncaa.com HTTP ", res$status, " for ", path,
         if (!is.null(res$why)) paste0(" (", res$why, ")"), call. = FALSE)
  }
  dir.create(cache_dir, showWarnings = FALSE, recursive = TRUE)
  writeLines(res$body, file, useBytes = TRUE)
  jsonlite::fromJSON(res$body, simplifyVector = FALSE)
}

# one GET; a network failure is an error whose message contains
# "unreachable" (prefetch_ncaa_games() stops on it)
ncaa_get <- function(req, where) {
  tryCatch(
    req |>
      httr2::req_user_agent("d3ballR (CMU student research)") |>
      httr2::req_error(is_error = function(r) FALSE) |>
      httr2::req_timeout(60) |>
      httr2::req_perform(),
    error = function(e) stop("Not fetched: ", where, " unreachable: ", conditionMessage(e), call. = FALSE)
  )
}

#' Request a path from an ncaa-api server
#' @return A list: `body` (JSON text, or NULL on failure) and `status`.
#' @keywords internal
ncaa_api_request <- function(api, path) {
  resp <- ncaa_get(httr2::request(paste0(api, path)),
                   paste0("ncaa-api at ", api, " (is the Docker container running?)"))
  status <- httr2::resp_status(resp)
  list(body = if (status == 200) httr2::resp_body_string(resp), status = status)
}

#' Request a path from ncaa.com's data server directly
#'
#' Builds the request ncaa.com's own pages make: a GET to
#' `https://sdataprod.ncaa.com/` (option `d3ballR.ncaa_data_url`) with a
#' persisted-query id ([ncaa_query_hashes]) and the query's variables, no
#' cookies and no browser headers. The answer is reshaped exactly as
#' ncaa-api reshapes it, so caches from either are interchangeable:
#' - play-by-play: the reply's `data$playbyplay`;
#' - scoring summary: `data$scoringSummary`;
#' - scoreboard (`week`, `seasonYear`, sport "MFB", division 3): the
#'   contests as ncaa-api's older `games[].game` layout
#'   ([ncaa_gql_scoreboard()]).
#' An empty answer (a game with no play-by-play yet) is reported as HTTP
#' 502, the status ncaa-api gives it.
#'
#' @param path An ncaa-api style path (see [fetch_ncaa_json()]).
#' @return A list: `body` (JSON text, or NULL on failure), `status`, and
#'   `why` (why it failed, or NULL).
#' @keywords internal
ncaa_direct_request <- function(path) {
  m_game <- regmatches(path, regexec("^/game/([0-9]+)/(play-by-play|scoring-summary)$", path))[[1]]
  m_sb <- regmatches(path, regexec("^/scoreboard/football/d3/([0-9]{4})/([0-9]{1,2})/all-conf$", path))[[1]]
  if (length(m_game)) {
    kind <- if (m_game[3] == "play-by-play") "play_by_play" else "scoring_summary"
    vars <- list(contestId = m_game[2], staticTestEnv = NULL)
  } else if (length(m_sb)) {
    kind <- "scoreboard"
    vars <- list(sportCode = "MFB", division = 3L, seasonYear = as.integer(m_sb[2]), week = as.integer(m_sb[3]))
  } else {
    stop("ncaa_direct_request() doesn't know the path ", path, call. = FALSE)
  }
  js <- function(x) as.character(jsonlite::toJSON(x, auto_unbox = TRUE, null = "null"))
  url <- getOption("d3ballR.ncaa_data_url", "https://sdataprod.ncaa.com/")
  req <- httr2::request(url) |>
    httr2::req_url_query(
      extensions = js(list(persistedQuery = list(version = 1L, sha256Hash = ncaa_query_hashes[[kind]]))),
      variables = js(vars))
  resp <- ncaa_get(req, "ncaa.com")
  status <- httr2::resp_status(resp)
  if (status != 200) return(list(body = NULL, status = status, why = NULL))
  j <- tryCatch(jsonlite::fromJSON(httr2::resp_body_string(resp), simplifyVector = FALSE),
                error = function(e) NULL)
  errs <- vapply(j$errors, function(e) if (is.null(e$message)) "" else as.character(e$message), character(1))
  if (length(errs)) {
    # an unknown query id means ncaa.com changed it: update ncaa_query_hashes
    return(list(body = NULL, status = 502L, why = paste(unique(errs), collapse = "; ")))
  }
  out <- switch(kind,
    play_by_play = {
      p <- j$data$playbyplay
      # no periods at all (or an empty first one): no play-by-play yet
      first <- if (length(p$periods) && length(p$periods[[1]]$playbyplayStats)) p$periods[[1]]$playbyplayStats[[1]]
      if (length(first) < 2) NULL else p
    },
    scoring_summary = j$data$scoringSummary,
    scoreboard = if (is.list(j$data$contests)) ncaa_gql_scoreboard(j$data$contests)
  )
  if (is.null(out)) return(list(body = NULL, status = 502L, why = "no data in ncaa.com's answer"))
  list(body = ncaa_to_json(out), status = 200L, why = NULL)
}

# JSON text from a list parsed with simplifyVector = FALSE (round-trips:
# scalars stay scalars, NULLs stay null, numbers keep their digits)
ncaa_to_json <- function(x) {
  as.character(jsonlite::toJSON(x, auto_unbox = TRUE, null = "null", na = "null", digits = NA))
}

#' ncaa.com scoreboard contests in ncaa-api's `games[].game` layout
#'
#' Mirrors `convertToOldFormat()` in henrygd/ncaa-api
#' (`src/scoreboard/scoreboard.ts`) for the fields d3ballR reads:
#' `gameID`, `startDate` (as ncaa.com gives it, "MM/DD/YYYY"),
#' `bracketRound` (the contest's `roundNumber`, "" if none), and per team
#' `score` (text, "" if none), `names` (`short`, `char6`, `seo`), `winner`,
#' `seed`, `rank`, and `conferences[[1]]$conferenceSeo`. A contest without
#' both a home and an away team is dropped, as ncaa-api does.
#'
#' @param contests The reply's `data$contests` (a list).
#' @return A list with element `games`.
#' @keywords internal
ncaa_gql_scoreboard <- function(contests) {
  txt <- function(x) if (is.null(x)) "" else as.character(x)
  team <- function(t) list(
    score = txt(t$score),
    names = list(char6 = txt(t$name6Char), short = txt(t$nameShort), seo = txt(t$seoname), full = ""),
    winner = isTRUE(t$isWinner),
    seed = txt(t$seed),
    description = "",
    rank = txt(t$teamRank),
    conferences = list(list(conferenceName = "", conferenceSeo = txt(t$conferenceSeo)))
  )
  games <- lapply(contests, function(cn) {
    home <- Filter(function(t) isTRUE(t$isHome), cn$teams)
    away <- Filter(function(t) isFALSE(t$isHome) || is.null(t$isHome), cn$teams)
    if (!length(home) || !length(away)) return(NULL)
    list(game = list(
      gameID = txt(cn$contestId),
      away = team(away[[1]]),
      finalMessage = txt(cn$finalMessage),
      home = team(home[[1]]),
      gameState = switch(txt(cn$gameState), F = "final", I = "live", "pre"),
      startDate = txt(cn$startDate),
      bracketRound = txt(cn$roundNumber)
    ))
  })
  list(games = Filter(Negate(is.null), games))
}

#' One week of the ncaa.com Division III football scoreboard
#'
#' @param season Season year.
#' @param week ncaa.com week number (1, 2, ...). ncaa.com numbers weeks
#'   its own way: week 1 is the first scoreboard of the season and the
#'   count runs through the postseason (see [ncaa_season_games()]).
#' @return A data frame, one row per game: `contest` (ncaa.com contest id),
#'   `ncaa_week`, `date`, `away`, `home` (ncaa.com short names),
#'   `away_score`, `home_score` (integer, NA when ncaa.com shows none),
#'   `bracket_round` (non-empty for NCAA tournament games).
#' @keywords internal
ncaa_scoreboard_week <- function(season, week) {
  j <- fetch_ncaa_json(sprintf("/scoreboard/football/d3/%d/%02d/all-conf", season, week))
  g <- lapply(j$games, `[[`, "game")
  if (!length(g)) return(NULL)
  num <- function(x) suppressWarnings(as.integer(if (is.null(x)) NA else x))
  data.frame(
    contest = vapply(g, function(x) as.character(x$gameID), character(1)),
    ncaa_week = as.integer(week),
    date = as.Date(vapply(g, function(x) x$startDate, character(1)), format = "%m/%d/%Y"),
    away = vapply(g, function(x) x$away$names$short, character(1)),
    home = vapply(g, function(x) x$home$names$short, character(1)),
    away_score = vapply(g, function(x) num(x$away$score), integer(1)),
    home_score = vapply(g, function(x) num(x$home$score), integer(1)),
    bracket_round = vapply(g, function(x) as.character(if (is.null(x$bracketRound)) "" else x$bracketRound), character(1)),
    away_conference = vapply(g, function(x) conf_seo(x$away), character(1)),
    home_conference = vapply(g, function(x) conf_seo(x$home), character(1))
  )
}

# a scoreboard team's conference tag ("centennial", "wiac", ...; "" if none)
conf_seo <- function(team) {
  cf <- team$conferences
  if (!length(cf) || is.null(cf[[1]]$conferenceSeo)) "" else as.character(cf[[1]]$conferenceSeo)
}

#' Team-to-conference table and conference games, from ncaa.com
#'
#' ncaa.com's weekly scoreboards tag each team in each game with its
#' conference ("centennial", "wiac", ...). Each team's most common tag is
#' its conference, named through `inst/extdata/conference_names.csv`
#' (a readable name and a short code per tag, e.g. "Centennial Conference",
#' "CC").
#' Tags not in that table (non-D3 conferences such as "nec", and
#' "diii-independent") and blank tags give NA, as for an independent or a
#' non-D3 opponent. The scoreboards are the ones [ncaa_season_games()]
#' reads, so nothing new is fetched once they are cached.
#'
#' ncaa.com has no conference-game marker, so `conference_marker` is TRUE
#' for a regular-season game (the game list's `season_type`) between two
#' teams of the same conference. Playoff and bowl games are FALSE.
#'
#' @param season Season year.
#' @param index The game list ([ncaa_season_games()]).
#' @param weeks ncaa.com week numbers to read.
#' @param dir Where
#'   `{season}_conferences.csv` is written.
#' @return A list with
#'   `table` (`season`, `team`, `conference`, `conference_code`,
#'   `ncaa_conference`) and `markers` (`season`, `team`, `game_id`,
#'   `conference_marker`; one row per index game, `team` is the home team).
#' @export
ncaa_conference_table <- function(season, index, weeks = 1:20, dir = "data-raw/ncaa") {
  sb <- list()
  for (w in weeks) {
    x <- tryCatch(ncaa_scoreboard_week(season, w), error = function(e) NULL)
    if (!is.null(x)) sb[[length(sb) + 1]] <- x
  }
  sb <- do.call(rbind, sb)
  tags <- data.frame(team = c(sb$away, sb$home),
                     seo = c(sb$away_conference, sb$home_conference))
  tags <- tags[tags$seo != "", ]
  seo <- tapply(tags$seo, tags$team, function(v) names(sort(table(v), decreasing = TRUE))[1])
  names_tab <- utils::read.csv(d3_extdata("conference_names.csv"), na.strings = "")
  teams <- sort(unique(c(index$home, index$away)))
  tab <- data.frame(season = as.integer(season), team = teams,
                    ncaa_conference = unname(seo[teams]))
  k <- match(tab$ncaa_conference, names_tab$ncaa_seo)
  tab$conference <- names_tab$conference[k]
  tab$conference_code <- names_tab$conference_code[k]
  tab <- tab[, c("season", "team", "conference", "conference_code", "ncaa_conference")]
  utils::write.csv(tab[order(tab$conference_code, tab$team), ], file.path(dir, paste0(season, "_conferences.csv")),
                   row.names = FALSE, na = "")

  games <- index[!is.na(index$game_id), ]
  hc <- tab$conference_code[match(games$home, tab$team)]
  ac <- tab$conference_code[match(games$away, tab$team)]
  markers <- data.frame(season = as.integer(season), team = games$home, game_id = games$game_id,
                        conference_marker = games$season_type %in% "regular" & !is.na(hc) & !is.na(ac) & hc == ac)
  list(table = tab, markers = markers)
}

#' The season's game list from ncaa.com's Division III scoreboards
#'
#' Every contest on the season's weekly
#' scoreboards (`weeks`, cached) is one game; `game_id` is its ncaa.com
#' contest id ("6461490"). A contest listed in more than one week is kept
#' once. Dropped (listed in the result's `dropped` attribute, with why):
#' - a contest dated outside the season (before August 1 of `season` or
#'   after July 31 of the next year), a placeholder ncaa.com left in its
#'   scoreboard (2025: the Stagg Bowl's duplicate 6529906, dated
#'   2025-01-04);
#' - a second contest for the same game (same date, teams and final
#'   score): the tournament's contest (with a bracket round) is kept, else
#'   the lower id (2025: 6533522, beside 6529877).
#'
#' The columns:
#' - `home`, `away`: ncaa.com's home and away teams, by ncaa.com's short
#'   names ("Alfred St.", "Carnegie Mellon").
#' - `season_type`: "postseason" for NCAA tournament games (a
#'   `bracket_round` on the scoreboard) and for games after the regular
#'   season's end ([classify_season_type()]); "regular" otherwise.
#' - `week`: ncaa.com's scoreboard week (decided by Sam, 2026-11-17). It
#'   counts on through the postseason: in 2025 the regular season is weeks
#'   1-12 and the tournament weeks 13-17, with the Stagg Bowl in week 19.
#'
#' Writes `{dir}/{season}_games.csv`.
#'
#' @param season Season year.
#' @param weeks ncaa.com week numbers to read.
#' @param dir Folder for the game list.
#' @param season_dates Output of [read_season_dates()] (NULL: read it).
#' @return A data frame, one row per game: `game_id`, `season`,
#'   `game_date`, `week`, `season_type`, `home`, `away`, `home_score`,
#'   `away_score`, `bracket_round`.
#' @export
ncaa_season_games <- function(season, weeks = 1:20, dir = "data-raw/ncaa", season_dates = NULL) {
  sb <- list()
  for (w in weeks) {
    x <- tryCatch(ncaa_scoreboard_week(season, w), error = function(e) NULL)
    if (!is.null(x)) sb[[length(sb) + 1]] <- x
  }
  if (!length(sb)) stop("No ncaa.com scoreboard could be read for ", season, call. = FALSE)
  sb <- do.call(rbind, sb)
  sb <- sb[!duplicated(sb$contest), ]
  in_season <- !is.na(sb$date) & sb$date >= as.Date(sprintf("%d-08-01", season)) &
    sb$date <= as.Date(sprintf("%d-07-31", season + 1L))
  keep_cols <- c("contest", "ncaa_week", "date", "away", "home", "away_score", "home_score", "bracket_round")
  dropped <- sb[!in_season, keep_cols]
  dropped$why <- rep("dated outside the season", nrow(dropped))
  sb <- sb[in_season, ]
  # the same game listed twice (same date, teams and score; 2025: 6533522
  # beside the tournament's 6529877): keep the tournament's contest (with a
  # bracket round), else the lower contest id
  pair <- paste(sb$date, pmin(sb$away, sb$home), pmax(sb$away, sb$home),
                pmin(sb$away_score, sb$home_score), pmax(sb$away_score, sb$home_score))
  ord <- order(pair, sb$bracket_round == "", as.numeric(sb$contest))
  dup <- duplicated(pair[ord])
  dup_rows <- ord[dup & !is.na(sb$away_score[ord]) & !is.na(sb$home_score[ord])]
  if (length(dup_rows)) {
    d <- sb[dup_rows, keep_cols]
    d$why <- paste0("duplicate of contest ", sb$contest[ord][match(pair[dup_rows], pair[ord])])
    dropped <- rbind(dropped, d)
    sb <- sb[-dup_rows, ]
  }
  if (is.null(season_dates)) season_dates <- ensure_season_dates(season)

  tourney <- sb$bracket_round != ""
  st <- ifelse(tourney, "postseason", classify_season_type(sb$date, season, season_dates))

  out <- data.frame(
    game_id = sb$contest, season = as.integer(season), game_date = format(sb$date, "%Y-%m-%d"),
    week = as.integer(sb$ncaa_week), season_type = st,
    home = sb$home, away = sb$away,
    home_score = sb$home_score, away_score = sb$away_score,
    bracket_round = sb$bracket_round
  )
  out <- out[order(out$game_date, out$game_id), ]
  rownames(out) <- NULL
  dir.create(dir, showWarnings = FALSE, recursive = TRUE)
  utils::write.csv(out, file.path(dir, paste0(season, "_games.csv")), row.names = FALSE, na = "")
  if (nrow(dropped)) {
    message(season, ": dropped ", nrow(dropped), " ncaa.com contest(s): ",
            paste0(dropped$contest, " (", dropped$why, ")", collapse = ", "))
  }
  attr(out, "dropped") <- dropped
  out
}

#' The contest table for a game list from [ncaa_season_games()]
#'
#' [fetch_ncaa_game()] looks games up in a contest table. With ncaa.com's
#' game list the game id is the contest id and home / away are ncaa.com's,
#' so this is the identity mapping.
#'
#' @param games Output of [ncaa_season_games()].
#' @return A data frame: `game_id`, `contest`, `ncaa_away`, `ncaa_home`,
#'   `ncaa_away_score`, `ncaa_home_score`, `home_away_flip` (FALSE),
#'   `date_diff` (0).
#' @keywords internal
ncaa_contest_table <- function(games) {
  data.frame(game_id = games$game_id, contest = games$game_id,
             ncaa_away = games$away, ncaa_home = games$home,
             ncaa_away_score = games$away_score, ncaa_home_score = games$home_score,
             home_away_flip = FALSE, date_diff = 0)
}

#' Conference columns for one game
#'
#' `home_team_conference` / `away_team_conference` from the season's
#' conference table (NA for a team in no conference: an independent or a
#' non-D3 opponent, or a team not in the table). `conference_game` from
#' the game's marker ([ncaa_conference_table()]: same conference in the
#' regular season), NOT from shared membership alone, so a playoff game
#' between two members isn't counted; NA when the game has no marker.
#' `shared_conference` (both teams in the same conference) is returned for
#' the report.
#'
#' @param game_id Game id.
#' @param home,away Team names (the game list's spelling).
#' @param conf Output of [ncaa_conference_table()], or NULL.
#' @return A list: `home_team_conference`, `away_team_conference`,
#'   `conference_game`, `shared_conference`.
#' @keywords internal
game_conferences <- function(game_id, home, away, conf) {
  tab <- conf$table
  hc <- if (!is.null(tab)) tab$conference[match(home, tab$team)] else NA_character_
  ac <- if (!is.null(tab)) tab$conference[match(away, tab$team)] else NA_character_
  m <- if (!is.null(conf$markers)) conf$markers$conference_marker[conf$markers$game_id %in% game_id] else logical()
  list(
    home_team_conference = hc,
    away_team_conference = ac,
    conference_game = if (length(m)) any(m) else NA,
    shared_conference = !is.na(hc) & !is.na(ac) & hc == ac
  )
}

#' Flatten an ncaa.com play-by-play JSON into one row per line
#'
#' ncaa.com nests lines by period, then by "possession" block (each block
#' carries a `teamId`), then by play. Each play has `playText` (the
#' StatCrew text), `driveText` (the down,
#' distance and yardline *before* the play, e.g. "2 and 9 at 28"),
#' `homeScore` / `visitorScore` (the score *after* the play) and `clock`.
#' A line identical to the one before it in every field (ncaa.com
#' sometimes repeats one) is dropped.
#'
#' @param j Parsed JSON from [fetch_ncaa_json()].
#' @return A data frame: `period`, `team_id`, `clock`, `drive_text`,
#'   `home_score`, `visitor_score` (integer, NA where ncaa.com leaves them
#'   null), `text`.
#' @keywords internal
ncaa_lines <- function(j) {
  val <- function(x) if (is.null(x)) NA_character_ else as.character(x)
  rows <- list()
  for (p in j$periods) {
    for (s in p$playbyplayStats) {
      for (pl in s$plays) {
        rows[[length(rows) + 1]] <- list(
          period = as.integer(p$periodNumber), team_id = val(s$teamId),
          clock = dplyr::coalesce(val(pl$clock), val(s$clock)),
          drive_text = val(pl$driveText),
          home_score = suppressWarnings(as.integer(val(pl$homeScore))),
          visitor_score = suppressWarnings(as.integer(val(pl$visitorScore))),
          text = stringr::str_squish(val(pl$playText))
        )
      }
    }
  }
  out <- do.call(rbind.data.frame, rows)
  out$text[is.na(out$text)] <- ""
  # ncaa.com sometimes repeats a line verbatim (same text, clock, down and
  # distance, score); a play can't happen twice, so the copy is dropped
  key <- do.call(paste, c(out, sep = "\r"))
  dup <- c(FALSE, key[-1] == key[-nrow(out)]) & nzchar(out$text)
  ncaa_move_late_touchdowns(out[!dup, , drop = FALSE])
}

#' Label on a touchdown line moved in front of its try
#' @keywords internal
ncaa_moved_td_label <- "[d3ballR: moved up; ncaa.com listed this play after the lines that follow it]"

#' Put a touchdown ncaa.com printed after its own try back in front of it
#'
#' ncaa.com sometimes prints a touchdown a line or two late, after the try
#' and kickoff that follow it (`6529878`: "J.Runyan kick attempt
#' good", the kickoff, then the interception returned for the touchdown).
#' A try can't come before its touchdown, so when a try line does not follow
#' a touchdown, and a touchdown comes within the next three lines with only
#' kickoffs (or empty lines) in between, the touchdown line is moved in
#' front of the try and labelled ([ncaa_moved_td_label]).
#'
#' Where ncaa.com has a running score it must agree: the try raises one
#' team's score by 1 or 2 and the touchdown then raises the same team's by
#' 6. The two lines' scores are then swapped into play order (the
#' touchdown gets the score before the try plus 6, the try the total), so
#' the running score still only goes up. Without a running score the order
#' of the lines alone decides.
#'
#' @param lines Output of [ncaa_lines()] before this step.
#' @return `lines`, reordered where needed.
#' @keywords internal
ncaa_move_late_touchdowns <- function(lines) {
  ic <- function(pattern) stringr::regex(pattern, ignore_case = TRUE)
  txt <- lines$text
  is_td <- has_touchdown(txt)
  is_try <- stringr::str_detect(txt, ic("\\b(kick|pass|rush) attempt\\b")) &
    !stringr::str_detect(txt, ic("field goal"))
  is_kickoff <- stringr::str_detect(txt, ic("\\bkickoff\\b"))
  # the last line with a score before each line (NA if none)
  last_score <- function(i, col) {
    v <- lines[[col]][seq_len(i - 1)]
    v <- v[!is.na(v)]
    if (length(v)) v[length(v)] else NA_integer_
  }
  i <- 1L
  while (i <= nrow(lines)) {
    if (is_try[i]) {
      prev <- which(nzchar(lines$text[seq_len(i - 1)]))
      after_td <- length(prev) && is_td[prev[length(prev)]]
      later <- seq.int(i + 1L, length.out = min(3L, nrow(lines) - i))
      t <- later[is_td[later]]
      t <- if (length(t)) t[1] else NA_integer_
      between <- if (!is.na(t)) seq.int(i + 1L, length.out = t - i - 1L) else integer()
      ok <- !after_td && !is.na(t) &&
        all(is_kickoff[between] | !nzchar(lines$text[between]))
      if (ok) {
        sc <- c("home_score", "visitor_score")
        before <- vapply(sc, function(col) last_score(i, col), integer(1))
        at_try <- unlist(lines[i, sc])
        at_td <- unlist(lines[t, sc])
        has_score <- !anyNA(c(before, at_try, at_td))
        if (has_score) {
          d_try <- at_try - before
          d_td <- at_td - at_try
          ok <- sum(d_try > 0) == 1L && max(d_try) %in% 1:2 && all(d_td[d_try == 0] == 0) &&
            d_td[d_try > 0] == 6L
        }
        if (ok) {
          moved <- lines[t, ]
          moved$text <- paste(moved$text, ncaa_moved_td_label)
          if (has_score) {
            moved[sc] <- as.list(at_td - d_try)
            lines[i, sc] <- as.list(at_td)
          }
          lines <- rbind(lines[seq_len(i - 1), ], moved, lines[setdiff(seq.int(i, nrow(lines)), t), ])
          txt <- lines$text
          is_td <- c(is_td[seq_len(i - 1)], TRUE, is_td[setdiff(seq.int(i, length(is_td)), t)])
          is_try <- c(is_try[seq_len(i - 1)], FALSE, is_try[setdiff(seq.int(i, length(is_try)), t)])
          is_kickoff <- c(is_kickoff[seq_len(i - 1)], FALSE, is_kickoff[setdiff(seq.int(i, length(is_kickoff)), t)])
          i <- i + 1L
        }
      }
    }
    i <- i + 1L
  }
  rownames(lines) <- NULL
  lines
}

#' Games whose score can't reconcile because of a gap in the source
#'
#' `data-raw/ncaa/known_exceptions.csv` (`game_id`, `reason`) lists games
#' where ncaa.com's own data is incomplete or inconsistent (a play-by-play
#' that stops early, a game called off with a final that doesn't match its
#' plays). The build report lists them apart from real failures, and the
#' score test skips them with the reason. Only source gaps belong here;
#' anything the parser can fix gets a generic fix instead.
#'
#' @param file Path to the CSV.
#' @return A data frame with `game_id` and `reason` (no rows if the file is
#'   missing).
#' @keywords internal
load_known_exceptions <- function(file = "data-raw/ncaa/known_exceptions.csv") {
  if (!file.exists(file)) return(data.frame(game_id = character(), reason = character()))
  utils::read.csv(file, colClasses = "character")
}

#' Swap back team ids that a file attaches to the wrong team
#'
#' Compares each "TEAM drive start" line's name with ncaa.com's two team
#' names (`nameShort`, `name6Char`, `seoname`, ignoring case and
#' punctuation). If most of the lines that name a team clearly carry the
#' other team's id, every id in the game is swapped.
#'
#' @param team_id Line team ids.
#' @param starts Drive-start names per line (NA elsewhere).
#' @param tm ncaa.com's `teams` list from the play-by-play JSON.
#' @return `team_id`, swapped or unchanged.
#' @keywords internal
ncaa_unswap_team_ids <- function(team_id, starts, tm) {
  if (length(tm) != 2L) return(team_id)
  norm <- function(x) gsub("[^a-z0-9]", "", tolower(x))
  ids <- vapply(tm, function(t) as.character(t$teamId), character(1))
  keys <- lapply(tm, function(t) unique(norm(unlist(t[c("nameShort", "name6Char", "seoname")]))))
  named <- vapply(norm(starts), function(s) {
    if (is.na(s) || !nzchar(s)) return(NA_character_)
    hit <- vapply(keys, function(k) any(startsWith(s, k) | startsWith(k, s)), logical(1))
    if (sum(hit) == 1L) ids[hit] else NA_character_
  }, character(1))
  ok <- !is.na(named) & team_id %in% ids
  if (sum(ok) < 4L) return(team_id)
  if (mean(named[ok] != team_id[ok]) > 0.8) {
    out <- team_id
    out[team_id == ids[1]] <- ids[2]
    out[team_id == ids[2]] <- ids[1]
    return(out)
  }
  team_id
}

#' Does an ncaa.com play-by-play carry a running score?
#'
#' Some host schools' files leave `homeScore` / `visitorScore` at 0 or null
#' on every line; those games need the scoring summary to tell which extra
#' points were good (see [ncaa_play_table()]).
#'
#' @param j Parsed play-by-play JSON.
#' @return TRUE or FALSE.
#' @keywords internal
ncaa_has_running_score <- function(j) {
  l <- ncaa_lines(j)
  nrow(l) > 0 && any(l$home_score > 0L | l$visitor_score > 0L, na.rm = TRUE)
}

#' Parse ncaa.com's `driveText`
#'
#' Two formats occur. Most games: "2 and 9 at 28" (no team on the
#' yardline; distance 0 means goal to go). Some games, all NCAA
#' tournament games in 2025: "2 and  at JHU13" (yardline team given, the
#' distance usually blank; "true" means goal to go), and "- and - at ..."
#' on kickoffs and tries.
#'
#' @param x Character vector.
#' @return A data frame: `down` (integer), `dist` (character: digits,
#'   "Goal", or NA when blank), `token` (yardline team letters, NA when
#'   absent), `yard` (integer).
#' @keywords internal
parse_ncaa_drive_text <- function(x) {
  m <- stringr::str_match(x, "^\\s*([1-4]) and (\\S*) at ([A-Za-z&.' -]*?)\\s*(\\d{1,2})\\s*$")
  dist <- m[, 3]
  dist <- ifelse(dist %in% c("0", "true"), "Goal", ifelse(grepl("^-?\\d+$", dist), dist, NA_character_))
  # tokens can come padded ("at  TU35", "at   U35")
  tok <- trimws(m[, 4])
  tok <- ifelse(is.na(tok) | tok %in% c("", "-"), NA_character_, tok)
  data.frame(down = suppressWarnings(as.integer(m[, 2])), dist = dist, token = tok,
             yard = suppressWarnings(as.integer(m[, 5])))
}

#' Spot pattern: a yardline written with its team letters in play text
#'
#' "to the RMCFB29", "at DCFB47", "from JHU35". The letters are whatever the
#' stat crew uses (they can differ from the down-and-distance tokens).
#' @keywords internal
ncaa_spot_pattern <- "\\b(thrown to|caught at|to the|at the|at|from|to|on) (?!(?:at|to|the|on|from)\\b)([A-Za-z][A-Za-z&.'-]*?(?: [A-Z][A-Za-z&.'-]{0,9})?) ?(\\d{1,2})\\b"

#' Pair driveText's yardline tokens with the play text's spelling
#'
#' Some ncaa.com files (tournament games) name the field sides in
#' `driveText` with one code ("1 and 10 at CHA36", "WRF41", "  U35") and in
#' the play text with another ("to the CHAP36", "UWRF41", "UWP35"). The two
#' are paired by a vote, as [infer_text_team()] pairs play-text and
#' situation codes: when a
#' line's last spot is "CHAP36" and the next line's driveText reads "at
#' CHA36", the same yard number (not 50) pairs CHA with CHAP. Of the two
#' pairings of driveText's two tokens with the play text's two most frequent
#' ones, the one with at least 3 votes and at least 3 times the other's
#' wins, and driveText's tokens are renamed to the play text's (the
#' spelling the rest of the pipeline reads). When the two already agree,
#' or the vote isn't clear, nothing is renamed.
#'
#' @param spots `str_match_all(txt, ncaa_spot_pattern)`, one per line.
#' @param dt Output of [parse_ncaa_drive_text()] for the same lines.
#' @return Named character vector: names are driveText tokens, values the
#'   play-text token to use instead (empty when nothing is renamed).
#' @keywords internal
ncaa_spot_token_map <- function(spots, dt) {
  none <- stats::setNames(character(), character())
  d <- names(sort(table(stats::na.omit(dt$token)), decreasing = TRUE))
  if (length(d) < 2) return(none)
  d <- d[1:2]
  t <- names(sort(table(unlist(lapply(spots, function(s) s[, 3]))), decreasing = TRUE))
  if (length(t) < 2) return(none)
  t <- t[1:2]
  if (setequal(t, d)) return(none)
  last <- function(k) vapply(spots, function(s) if (nrow(s)) s[nrow(s), k] else NA_character_, character(1))
  end_tok <- last(3)
  end_num <- suppressWarnings(as.integer(last(4)))
  nxt_tok <- c(dt$token[-1], NA)
  nxt_num <- c(dt$yard[-1], NA)
  ok <- !is.na(end_tok) & !is.na(nxt_tok) & !is.na(end_num) & !is.na(nxt_num) &
    end_num == nxt_num & end_num != 50L & end_tok %in% t & nxt_tok %in% d
  same <- sum(ok & ((end_tok == t[1] & nxt_tok == d[1]) | (end_tok == t[2] & nxt_tok == d[2])))
  swap <- sum(ok & ((end_tok == t[1] & nxt_tok == d[2]) | (end_tok == t[2] & nxt_tok == d[1])))
  if (max(same, swap) < 3 || max(same, swap) < 3 * min(same, swap)) return(none)
  target <- if (same > swap) t else rev(t)
  keep <- d != target
  stats::setNames(target[keep], d[keep])
}

#' Rebuild the (situation, play) table from ncaa.com lines
#'
#' The rest of the pipeline reads a two-column play table (`situation`,
#' `play`), the layout of a StatCrew play-by-play page, so ncaa.com's lines
#' are turned into that table:
#'
#' - `situation` is rebuilt from `driveText`: "2 and 9 at 28" becomes
#'   "2nd and 9 at DCFB28". ncaa.com usually leaves the yardline's team
#'   out, so it is recovered from the play text. In order: a spot with
#'   that number in the row's own text ("PENALTY ... from JUN35 to ...");
#'   for rows between a score and its kickoff, the side the kickoff is
#'   kicked from; otherwise, of the two sides of the field ("DCFB28" or
#'   "RMCFB28"), the one that matches the last spot the text mentioned (the
#'   previous play's "to the DCFB28", a penalty's "... to DCFB28"), else
#'   the one nearer it. Spots a pass was only thrown to or caught at don't
#'   count, nor do spots of a play wiped out by a penalty ("NO PLAY"). The two team tokens are the two most common in the game's text.
#' - When the distance is blank (the tournament-game format), it is worked
#'   out from the line to gain: 10 yards past the spot where the series
#'   started, or goal to go. Snaps whose downs repeat with "NO PLAY" keep
#'   the same series.
#' - Kickoffs and tries get a blank situation, as in a StatCrew page.
#' - Rows a StatCrew page has and ncaa.com's lines don't are added: a quarter marker
#'   ("1st", ..., "OT") at the start of each period, a drive header
#'   ("TEAM at MM:SS") before each "drive start" line, and a score line
#'   ("AWAY 7, HOME 0") after each scoring sequence, from ncaa.com's running
#'   score. A header and a "TEAM drive start at." line are also added when
#'   a different team snaps: always in games with no "drive start" lines at
#'   all (the tournament format), otherwise only on the game's first snap,
#'   after a kickoff, on the first snap of an overtime period, or right after
#'   a snap that can end a possession (a punt, turnover, 4th down not
#'   converted, or
#'   touchdown); ncaa.com's `teamId` is wrong on some single lines, so it
#'   isn't trusted mid-drive.
#' - ncaa.com leaves out some extra-point kicks. When a touchdown is
#'   followed by no try line before the next kickoff or snap, and ncaa.com's
#'   score has risen by exactly 1 by then, a line "kick attempt good [...]"
#'   is added after the touchdown (after its last try line) and labelled as
#'   added (see `ncaa_added_try_text`). Some games (every Carnegie Mellon
#'   home game in 2025) have no running score at all. There, ncaa.com's
#'   scoring summary (`scoring`) decides: it lists every good try ("XP",
#'   "TPC") after its touchdown, matched here by period and clock, and
#'   leaves out tries that failed. A touchdown with no try line gets a good
#'   kick (`ncaa_added_try_text_summary`) or a good two-point try
#'   (`ncaa_added_two_point_text`) when the summary lists one, and nothing
#'   when it doesn't. Touchdowns the summary doesn't list (or every one,
#'   when there is no summary) fall back to the final score: when it is
#'   short by exactly one point per such touchdown, a good kick is added
#'   after each (`ncaa_added_try_text_final`). Anything else is left alone
#'   and shows up in the score reconciliation.
#'
#' Team names are each team's own drive-start spelling (the most common
#' "TEAM drive start" name on lines with its `teamId`), else ncaa.com's
#' short name.
#'
#' @param lines Output of [ncaa_lines()].
#' @param teams A data frame with `team_id`, `name` (canonical name) and
#'   `ncaa_home` (ncaa.com's home team, whose score is `homeScore`) for the
#'   two teams.
#' @param final_total Both teams' final points together, for games with no
#'   running score (see above), or NULL.
#' @param scoring ncaa.com's scoring summary as [ncaa_scoring_entries()]
#'   returns it, for games with no running score, or NULL.
#' @return A tibble with `situation` and `play`: the (situation, play)
#'   table the parser reads ([classify_plays()]).
#' @keywords internal
ncaa_play_table <- function(lines, teams, final_total = NULL, scoring = NULL) {
  n <- nrow(lines)
  txt <- lines$text
  dt <- parse_ncaa_drive_text(lines$drive_text)
  is_toss <- stringr::str_detect(txt, stringr::regex(toss_pattern, ignore_case = TRUE))
  is_kickoff <- stringr::str_detect(txt, stringr::regex("\\bkickoff\\b", ignore_case = TRUE)) & !is_toss
  is_try <- stringr::str_detect(txt, stringr::regex("\\b(kick|pass|rush) attempt\\b", ignore_case = TRUE)) &
    !stringr::str_detect(txt, stringr::regex("field goal", ignore_case = TRUE))
  is_start <- stringr::str_detect(txt, stringr::regex("drive start", ignore_case = TRUE))
  has_verb <- stringr::str_detect(txt, stringr::regex(verb_pattern, ignore_case = TRUE))
  is_snap <- !is.na(dt$down) & has_verb & !is_kickoff & !is_try
  team_name <- stats::setNames(teams$name, teams$team_id)

  # --- the two yardline tokens and every row's last spot ----------------
  spots <- stringr::str_match_all(txt, ncaa_spot_pattern)
  # on a play wiped out by a penalty only the enforcement counts
  no_play <- stringr::str_detect(txt, stringr::regex("\\bNO PLAY\\b", ignore_case = TRUE))
  end_spots <- stringr::str_match_all(ifelse(no_play, stringr::str_extract(txt, "PENALTY.*$"), txt), ncaa_spot_pattern)
  # tournament files can spell the sides one way in driveText ("CHA36")
  # and another in the play text ("CHAP36"): use the play text's spelling
  tok_map <- ncaa_spot_token_map(spots, dt)
  renamed <- dt$token %in% names(tok_map)
  dt$token[renamed] <- unname(tok_map[dt$token[renamed]])
  all_tok <- unlist(lapply(spots, function(s) s[, 3]))
  tokens <- names(sort(table(c(all_tok, stats::na.omit(dt$token))), decreasing = TRUE))[1:2]
  if (anyNA(tokens)) stop("Could not find two yardline team tokens in the ncaa.com text.")
  to_x <- function(tok, yard) ifelse(tok == tokens[1], yard, 100L - yard)
  end_x <- vapply(end_spots, function(s) {
    s <- s[s[, 3] %in% tokens & !s[, 2] %in% c("thrown to", "caught at"), , drop = FALSE]
    if (!nrow(s)) return(NA_real_)
    k <- nrow(s)
    to_x(s[k, 3], as.integer(s[k, 4]))
  }, numeric(1))

  # --- yardline side for every situation ---------------------------------
  blank_sit <- is_kickoff | is_try | is.na(dt$down) | is.na(dt$yard)
  # a penalty's "from" spot in the row's own text with the situation's yard
  # number ("PENALTY ... from JUN35 to ...") names its side directly
  own_tok <- vapply(seq_len(n), function(i) {
    s <- spots[[i]]
    s <- s[s[, 2] == "from" & s[, 3] %in% tokens & !is.na(dt$yard[i]) & as.integer(s[, 4]) == dt$yard[i], , drop = FALSE]
    if (nrow(s)) s[1, 3] else NA_character_
  }, character(1))
  # rows between a score and the kickoff that follows it (a dead-ball
  # penalty, a timeout) sit at the kicking team's spot: the side the
  # kickoff is kicked from, i.e. not the side it lands on
  kick_tok <- rep(NA_character_, n)
  for (j in which(is_kickoff)) {
    land <- spots[[j]]
    land <- land[land[, 3] %in% tokens, , drop = FALSE]
    if (!nrow(land)) next
    from <- setdiff(tokens, land[1, 3])
    k <- j - 1L
    while (k >= 1L && !is_snap[k] && !is_kickoff[k]) {
      kick_tok[k] <- from
      k <- k - 1L
    }
  }
  # overtime has no kickoffs to carry the spot to the next possession: after
  # a possession ends (a try, a touchdown, a field goal, a turnover), the
  # last spot is the old possession's, at the other end of the field from
  # the new one's 25 (6461689: Albion's touchdown at BUFB00, then Bluffton
  # "1 and 10 at 25" was put at BUFB25 for "rush for 4 yards to the
  # ALBION21"). The new possession's first situation, a 1st and 10 right
  # after a possession ended or at the start of overtime, takes the
  # side nearest the next spot the text mentions in that possession (its own
  # play's, or a later one's, up to the next possession end) instead.
  in_ot <- lines$period >= 5L
  ends_possession <- is_try | (is_snap & stringr::str_detect(txt, stringr::regex(
    "TOUCHDOWN|field goal|intercepted|fumble.*recovered by|TURNOVER ON DOWNS", ignore_case = TRUE)))
  # the first spot at or after each row, not past the next possession end
  # nor past a snap by the other team (a 4th down that didn't convert has no
  # end marker: 6461987 play 172)
  next_x <- rep(NA_real_, n)
  val <- NA_real_
  later_team <- NA_character_
  for (i in rev(seq_len(n))) {
    if (ends_possession[i]) val <- NA_real_
    if (is_snap[i]) {
      if (!is.na(later_team) && !identical(lines$team_id[i], later_team)) val <- NA_real_
      later_team <- lines$team_id[i]
    }
    if (!is.na(end_x[i])) val <- end_x[i]
    next_x[i] <- val
  }
  # a 1st and 10 (usually at the 25; at the 35 after a foul, 6462402 play 159)
  ot_start <- in_ot & !blank_sit & dt$down %in% 1L & dt$dist %in% 10L
  tok_out <- rep(NA_character_, n)
  x_out <- rep(NA_real_, n)
  cur <- NA_real_
  ot_reset <- FALSE
  spot_since_reset <- FALSE
  last_snap_team <- NA_character_
  for (i in seq_len(n)) {
    # overtime starts, or a snap by the other team (the line that ended the
    # last possession can be missing: 6461313's field goal before play 164)
    team_changed <- is_snap[i] && !is.na(last_snap_team) && !identical(lines$team_id[i], last_snap_team)
    if (in_ot[i] && ((i == 1L || !in_ot[i - 1L]) || team_changed)) {
      ot_reset <- TRUE
      spot_since_reset <- FALSE
    }
    if (is_snap[i]) last_snap_team <- lines$team_id[i]
    if (!blank_sit[i]) {
      y <- dt$yard[i]
      if (!is.na(dt$token[i]) && dt$token[i] %in% tokens) {
        tok_out[i] <- dt$token[i]
      } else if (y == 50L) {
        tok_out[i] <- ""
      } else if (!is.na(own_tok[i])) {
        tok_out[i] <- own_tok[i]
      } else if (!is.na(kick_tok[i])) {
        tok_out[i] <- kick_tok[i]
      } else {
        cand_x <- c(y, 100L - y)
        # a spot stated after the possession ended ("Change of possession,
        # CSS ball on MAC20", 6461987) is the new possession's: keep `cur`
        ref <- if (ot_reset && !spot_since_reset && ot_start[i] && !is.na(next_x[i])) next_x[i] else cur
        pick <- if (is.na(ref)) 1L else which.min(abs(cand_x - ref))
        tok_out[i] <- tokens[pick]
      }
      x_out[i] <- if (tok_out[i] == "") 50 else to_x(tok_out[i], y)
      cur <- x_out[i]
      if (is_snap[i] || ot_start[i]) ot_reset <- FALSE
    }
    if (ot_reset && !is.na(end_x[i]) && !ends_possession[i] && !is_snap[i]) spot_since_reset <- TRUE
    if (in_ot[i] && ends_possession[i]) {
      ot_reset <- TRUE
      spot_since_reset <- FALSE
    }
    if (!is.na(end_x[i])) cur <- end_x[i]
  }

  # --- distance when ncaa.com leaves it blank ---------------------------
  dist <- dt$dist
  need <- !blank_sit & is.na(dist)
  if (any(need)) {
    own <- ncaa_own_token(lines$team_id[is_snap], tok_out[is_snap], dt$yard[is_snap], tokens)
    ytg <- ifelse(tok_out == "", 50L, ifelse(tok_out == own[lines$team_id], 100L - dt$yard, dt$yard))
    ltg <- NA_integer_
    prev <- NA_integer_
    for (i in which(is_snap | need)) {
      # a replay of the same 1st down after a no-play penalty keeps the line
      # to gain, unless the penalty awarded a first down ("Pass Interference
      # ... 1ST DOWN. NO PLAY", 6529887): that is a new series
      no_play_prev <- !is.na(prev) && stringr::str_detect(txt[prev], stringr::regex("NO PLAY", ignore_case = TRUE)) &&
        !stringr::str_detect(txt[prev], stringr::regex("1ST DOWN", ignore_case = TRUE))
      new_series <- is.na(prev) || lines$team_id[i] != lines$team_id[prev] ||
        (dt$down[i] == 1L && !(dt$down[prev] %in% 1L && no_play_prev))
      if (new_series && !is.na(ytg[i])) ltg <- max(ytg[i] - 10L, 0L)
      if (need[i] && !is.na(ltg) && !is.na(ytg[i])) {
        dist[i] <- if (ltg == 0L) "Goal" else as.character(ytg[i] - ltg)
      }
      if (is_snap[i]) prev <- i
    }
  }

  ord <- c("1st", "2nd", "3rd", "4th")
  situation <- ifelse(blank_sit | is.na(dist), "",
                      paste0(ord[pmin(pmax(dt$down, 1L), 4L)], " and ", dist, " at ", tok_out, dt$yard))
  situation[!blank_sit & is.na(dist)] <- ""
  # a note with no driveText of its own ("clock 0:26", "Spang in at QB",
  # "previous play upheld by review") carries the situation before it, as
  # a StatCrew page prints it, so the classifier can type it
  carry <- is.na(dt$down) & !has_verb & !is_kickoff & !is_try & !is_toss & !is_start
  last_sit <- ""
  for (i in seq_len(n)) {
    if (situation[i] != "") last_sit <- situation[i]
    else if (carry[i]) situation[i] <- last_sit
    if (is_kickoff[i] || is_try[i]) last_sit <- ""
  }

  # --- running score, after each line ------------------------------------
  hs <- lines$home_score
  vs <- lines$visitor_score
  known <- !is.na(hs) & !is.na(vs)
  hs <- cummax(ifelse(known, hs, 0L))
  vs <- cummax(ifelse(known, vs, 0L))
  hs_raw <- hs
  vs_raw <- vs
  # homeScore / visitorScore follow ncaa.com's own home team
  home <- teams$name[teams$ncaa_home]
  away <- teams$name[!teams$ncaa_home]
  score_line <- function(i) paste0(away, " ", vs[i], ", ", home, " ", hs[i])

  # --- extra points ncaa.com left out -----------------------------------
  # A touchdown's try lines are the ones before the next kickoff (ncaa.com
  # can put the other team's "drive start" line, or a two-point snap that
  # drew a penalty, in between). Compare the score at that kickoff with
  # the points the try lines account for. One point short,
  # for the scoring team only: a good kick whose line ncaa.com dropped (or
  # a re-kick after a "NO PLAY" try). The added line goes after the
  # touchdown's last try line, and the running score is raised from there.
  # "TOUCHDOWN nullified by penalty" is not a touchdown
  live_td <- function(x) has_touchdown(x) &
    !stringr::str_detect(x, stringr::regex("NO PLAY", ignore_case = TRUE))
  is_td <- live_td(txt)
  ic <- function(p) stringr::regex(p, ignore_case = TRUE)
  # a safety on a try ("[Hampden-Sydney PAT safety]") is 1 point for the
  # trying team (6461660)
  try_safety <- is_try & stringr::str_detect(txt, ic("\\bsafety\\b"))
  try_pts <- ifelse(try_safety, 1L, 0L) + ifelse(!try_safety & is_try & !stringr::str_detect(txt, ic("NO PLAY")) &
                      stringr::str_detect(txt, ic("\\b(good|successful)\\b")) &
                      !stringr::str_detect(txt, ic("\\b(no good|failed)\\b")),
                    ifelse(stringr::str_detect(txt, ic("kick attempt")), 1L, 2L), 0L)
  # A try line where ncaa.com's running score rises by 2 for the defending
  # team and not at all for the scoring team was returned by the defense,
  # whatever the text says (6462421: "rush attempt Successful", but
  # the 2 points went to the other team, which is what the overtime needs).
  # Such lines get `ncaa_defensive_try_label` appended, which the parser
  # reads as a defensive conversion; the raw text stays in front of it.
  def_try <- rep(FALSE, n)
  if (any(hs_raw > 0L | vs_raw > 0L)) {
    already <- stringr::str_detect(txt, ic("\\bdefensive\\b"))
    for (i in which(is_try & !already & !stringr::str_detect(txt, ic("NO PLAY")))) {
      td <- utils::tail(which(is_td & seq_len(n) < i), 1L)
      if (!length(td)) next
      before_td <- if (td > 1L) c(hs_raw[td - 1L], vs_raw[td - 1L]) else c(0L, 0L)
      ti <- which(c(hs_raw[td], vs_raw[td]) - before_td >= 6L)
      if (length(ti) != 1L) next
      prev <- c(hs_raw[i - 1L], vs_raw[i - 1L])
      up <- c(hs_raw[i], vs_raw[i]) - prev
      if (up[ti] == 0L && up[3L - ti] == 2L) def_try[i] <- TRUE
    }
  }
  # a defensive try earns the scoring team nothing
  try_pts[def_try] <- 0L
  # A safety the text also marks "NO PLAY": a foul by the offense in its own
  # end zone (6461773: illegal forward pass from the end zone) is a
  # safety, and "NO PLAY" only wipes out the pass. Decided by Sam
  # (2026-11-05): ncaa.com's running score decides when the game has one (2
  # for the defense on that line, 0 for the offense); without one, a safety
  # entry in the scoring summary at the same period and clock; as a last
  # resort, the next kickoff (no snap in between) being the safety kick from
  # the 20. Such lines get `ncaa_safety_label` appended.
  safety_np <- rep(FALSE, n)
  cand <- which(stringr::str_detect(txt, "\\bSAFETY\\b") & stringr::str_detect(txt, ic("\\bNO PLAY\\b")))
  for (i in cand) {
    if (any(hs_raw > 0L | vs_raw > 0L)) {
      off_home <- teams$ncaa_home[match(lines$team_id[i], teams$team_id)]
      if (is.na(off_home)) next
      prev <- if (i > 1L) c(hs_raw[i - 1L], vs_raw[i - 1L]) else c(0L, 0L)
      up <- c(hs_raw[i], vs_raw[i]) - prev
      safety_np[i] <- (if (off_home) up[2] else up[1]) == 2L && (if (off_home) up[1] else up[2]) == 0L
      next
    }
    clk <- dplyr::coalesce(stringr::str_match(txt[i], "clock (\\d{1,2}:\\d{2})")[, 2], lines$clock[i])
    if (!is.null(scoring) && nrow(scoring)) {
      norm <- function(x) sub("^0", "", x)
      q <- if (is.null(scoring$quarter)) scoring$period else scoring$quarter
      hit <- q == lines$period[i] & !is.na(clk) & norm(scoring$time) == norm(clk) &
        stringr::str_detect(paste(scoring$type, scoring$text), ic("safety|\\bSF\\b"))
      if (any(hit)) { safety_np[i] <- TRUE; next }
    }
    k <- which(is_kickoff & seq_len(n) > i)[1]
    if (!is.na(k) && !any(is_snap[seq_len(n) > i & seq_len(n) < k]) && dt$yard[k] %in% 20L) safety_np[i] <- TRUE
  }
  action <- which(is_kickoff)
  # the rows to add, keyed by the row they follow
  added <- character()
  has_running_score <- any(hs > 0L | vs > 0L)
  tryless <- integer()
  for (i in which(is_td)) {
    j <- action[action > i][1]
    # ... or before the other team's next snap, when ncaa.com dropped the kickoff too
    other_snap <- which(is_snap & seq_len(n) > i & lines$team_id != lines$team_id[i])[1]
    if (!is.na(other_snap) && (is.na(j) || other_snap < j)) j <- NA
    end <- if (is.na(j)) (if (is.na(other_snap)) n else other_snap - 1L) else j - 1L
    # ... and at the next touchdown: when ncaa.com drops a try and the
    # kickoff after it, the other team's try must not count for this one
    # (6462271: Albion's punt-return touchdown, then Olivet's)
    next_td <- which(is_td & seq_len(n) > i)[1]
    if (!is.na(next_td) && next_td <= end) end <- next_td - 1L
    between <- if (end > i) (i + 1L):end else integer()
    tries <- between[is_try[between]]
    if (!length(tries)) tryless <- c(tryless, i)
    # the score is compared at the next kickoff or, when ncaa.com dropped the
    # kickoff too, on the last line before the other team's first snap
    # (6461664)
    ref <- if (!is.na(j)) j else if (!is.na(other_snap)) other_snap - 1L else NA_integer_
    if (!has_running_score || is.na(ref) || ref <= i) next
    # the touchdown's team: the one whose running score jumped by 6 on it
    before <- if (i > 1L) c(hs[i - 1L], vs[i - 1L]) else c(0L, 0L)
    ti <- which(c(hs[i], vs[i]) - before >= 6L)
    if (length(ti) != 1L) next
    up <- c(hs[ref] - hs[i], vs[ref] - vs[i])
    # the next kickoff may itself be returned for a touchdown by the other team
    # (or recovered by the kicking team, a muff or fumble, and scored)
    if (!is.na(j) && live_td(txt[j])) {
      if (up[3L - ti] >= 6L) up[3L - ti] <- up[3L - ti] - 6L
      else if (up[ti] >= 6L) up[ti] <- up[ti] - 6L
      else next
    }
    # missing points: 1 = a kick; 2 = a two-point conversion, only when the
    # touchdown has no try line at all (6461897: 16 to 18 on the
    # kickoff line)
    missing <- up[ti] - sum(try_pts[tries])
    if (up[3L - ti] != 0L || !(missing == 1L || (missing == 2L && !length(tries)))) next
    at <- max(c(i, tries))
    added[as.character(at)] <- if (missing == 2L) ncaa_added_two_point_text_score else ncaa_added_try_text
    gap <- at:(if (!is.na(j)) j - 1L else ref)
    if (ti == 1L) hs[gap] <- hs[gap] + missing else vs[gap] <- vs[gap] + missing
  }
  # No running score at all (some host schools' files): when the final
  # score is short by exactly one point per touchdown with no try line, a
  # good kick is added after each of those touchdowns.
  if (!has_running_score && length(tryless)) {
    # the scoring summary, matched to each try-less touchdown by period and clock
    unmatched <- tryless
    if (!is.null(scoring) && nrow(scoring)) {
      td_clock <- dplyr::coalesce(stringr::str_match(txt, "clock (\\d{1,2}:\\d{2})")[, 2], lines$clock)
      norm <- function(x) sub("^0", "", x)
      # A summary that leaves out a team's scores (6461828 lists none of
      # Amherst's tries or its field goal, though the text has them) says
      # nothing by leaving out a try: for such a team only a listed try counts
      # as evidence. Complete for a team = it lists at least as many good
      # tries and field goals for it as the play text has.
      fg_good <- stringr::str_detect(txt, ic("field goal.*\\bGOOD\\b")) & !stringr::str_detect(txt, ic("\\b(NO GOOD|NO PLAY)\\b"))
      complete <- function(tid) {
        sum(scoring$team_id == tid & scoring$type %in% c("XP", "TPC")) >= sum(try_pts > 0L & lines$team_id %in% tid) &&
          sum(scoring$team_id == tid & scoring$type %in% "FG") >= sum(fg_good & lines$team_id %in% tid)
      }
      s_qtr <- if (is.null(scoring$quarter)) scoring$period else scoring$quarter
      for (i in tryless) {
        # quarter, not position: a quarter with no scoring is left out of
        # the summary (see ncaa_scoring_entries())
        k <- which(scoring$type == "TD" & s_qtr == lines$period[i] &
                     norm(scoring$time) == norm(td_clock[i]))
        if (length(k) != 1L) next
        nxt <- scoring$type[k + 1L]
        if (nxt %in% "XP") added[as.character(i)] <- ncaa_added_try_text_summary
        if (nxt %in% "TPC") added[as.character(i)] <- ncaa_added_two_point_text
        if (nxt %in% c("XP", "TPC") || complete(scoring$team_id[k])) unmatched <- setdiff(unmatched, i)
      }
    }
    if (length(unmatched) && !is.null(final_total)) {
      text_pts <- 6L * sum(is_td) +
        3L * sum(stringr::str_detect(txt, ic("field goal.*\\bGOOD\\b")) & !stringr::str_detect(txt, ic("\\b(NO GOOD|NO PLAY)\\b"))) +
        2L * sum(stringr::str_detect(txt, "\\bSAFETY\\b") & !stringr::str_detect(txt, ic("NO PLAY"))) +
        sum(try_pts) + sum(ifelse(added %in% c(ncaa_added_two_point_text, ncaa_added_two_point_text_score), 2L, 1L))
      if (final_total - text_pts == length(unmatched)) {
        added[as.character(unmatched)] <- ncaa_added_try_text_final
      }
    }
  }

  # --- field goals ncaa.com left out --------------------------------------
  # Decided by Sam (2026-11-05, 6461313: La Crosse's first-overtime
  # field goal has no line; the running score rises by 3 on the next,
  # Whitewater, snap). With a running score: a line that isn't a scoring
  # play on which one team's score rises by exactly 3 and the other's not
  # at all gets a labelled "field goal ... GOOD" row added before it, for
  # the team in possession, which must be the team whose score rose. The
  # kicker comes from the scoring summary when it lists that field goal
  # (same quarter and team). Without a running score: a summary field goal
  # with no field-goal line at its quarter and clock, only when the final
  # score is short by exactly 3 per such field goal.
  fg_line <- stringr::str_detect(txt, ic("field goal.*\\bGOOD\\b")) & !stringr::str_detect(txt, ic("\\b(NO GOOD|NO PLAY)\\b"))
  score_line_txt <- is_td | fg_line | is_try | stringr::str_detect(txt, "\\bSAFETY\\b")
  s_qtr_all <- if (!is.null(scoring) && nrow(scoring)) (if (is.null(scoring$quarter)) scoring$period else scoring$quarter) else integer()
  summary_kicker <- function(per, tid) {
    if (!length(s_qtr_all)) return(NA_character_)
    k <- which(scoring$type %in% "FG" & s_qtr_all == per & scoring$team_id == tid)
    if (length(k) < 1L) return(NA_character_)
    stringr::str_trim(stringr::str_match(scoring$text[k[1]], "^(.*?)\\s+field goal")[, 2])
  }
  dropped_fg <- character()   # keyed by the line it goes before; value = team id
  if (any(hs_raw > 0L | vs_raw > 0L)) {
    for (i in which(!score_line_txt)[-1]) {
      if (i < 2L) next
      up <- c(hs_raw[i], vs_raw[i]) - c(hs_raw[i - 1L], vs_raw[i - 1L])
      if (!(sort(up)[1] == 0L && max(up) == 3L)) next
      # ncaa.com's score can lag a line behind: a field-goal line since the
      # last score change already accounts for these 3 (6529845)
      changed <- which(c(FALSE, diff(hs_raw) != 0L | diff(vs_raw) != 0L) & seq_len(n) < i)
      last_change <- if (length(changed)) max(changed) else 0L
      if (any(fg_line[seq_len(n) > last_change & seq_len(n) <= i])) next
      home_up <- up[1] == 3L
      tid <- teams$team_id[teams$ncaa_home == home_up]
      if (length(tid) == 1L) dropped_fg[as.character(i)] <- tid
    }
  } else if (length(s_qtr_all) && !is.null(final_total)) {
    clk <- dplyr::coalesce(stringr::str_match(txt, "clock (\\d{1,2}:\\d{2})")[, 2], lines$clock)
    norm <- function(x) sub("^0", "", x)
    cand <- which(scoring$type %in% "FG")
    cand <- cand[!vapply(cand, function(k) any(fg_line & lines$period == s_qtr_all[k] & norm(clk) %in% norm(scoring$time[k])), logical(1))]
    text_pts <- 6L * sum(is_td) + 3L * sum(fg_line) +
      2L * sum(stringr::str_detect(txt, "\\bSAFETY\\b") & !stringr::str_detect(txt, ic("NO PLAY"))) +
      sum(try_pts) + sum(ifelse(added %in% c(ncaa_added_two_point_text, ncaa_added_two_point_text_score), 2L, 1L))
    if (length(cand) && final_total - text_pts == 3L * length(cand)) {
      secs <- function(x) { p <- strsplit(x, ":"); vapply(p, function(v) if (length(v) == 2) as.integer(v[1]) * 60L + as.integer(v[2]) else NA_integer_, integer(1)) }
      for (k in cand) {
        t_k <- secs(norm(scoring$time[k]))
        later <- which(lines$period == s_qtr_all[k] & !is.na(clk) & secs(norm(clk)) < t_k)
        at <- if (length(later)) later[1] else utils::tail(which(lines$period == s_qtr_all[k]), 1L) + 1L
        if (length(at) && !is.na(at) && at <= n) dropped_fg[as.character(at)] <- scoring$team_id[k]
      }
    }
  }

  # --- drive starts that name the wrong team ----------------------------
  normn <- function(x) gsub("[^a-z0-9]", "", tolower(x))
  start_name <- normn(stringr::str_match(txt, stringr::regex("^(.*?) drive start at", ignore_case = TRUE))[, 2])
  name_id <- function(x) {
    hit <- vapply(seq_len(nrow(teams)), function(k)
      x %in% normn(c(teams$name[k], if (!is.null(teams$short)) teams$short[k])), logical(1))
    if (sum(hit) == 1L) teams$team_id[hit] else NA_character_
  }
  wrong_start <- rep(FALSE, n)
  for (i in which(is_start)) {
    said <- name_id(start_name[i])
    nxt <- which(is_snap & seq_len(n) > i)[1]
    wrong_start[i] <- !is.na(said) && !is.na(nxt) && !identical(said, lines$team_id[i]) &&
      identical(lines$team_id[nxt], lines$team_id[i])
  }

  # --- safeties ncaa.com's score gives to the team that started the play ---
  # On a change of possession (a blocked field goal recovered by the
  # defense, which then fouls in its own end zone: 6462142) the safety
  # is the original offense's. When the running score rises by 2 for the
  # line's own team and 0 for the other, `ncaa_offense_safety_label` is
  # appended and the parser credits the 2 points to `pos_team`.
  off_safety <- rep(FALSE, n)
  if (any(hs_raw > 0L | vs_raw > 0L)) {
    for (i in which(stringr::str_detect(txt, "\\bSAFETY\\b") & !stringr::str_detect(txt, ic("NO PLAY")) & !is_try & !is_kickoff)) {
      # (not kickoffs: there pos_team is already the receiving team, so the
      # usual -2 credits the kicking team: 6461603)
      own_home <- teams$ncaa_home[match(lines$team_id[i], teams$team_id)]
      if (is.na(own_home) || i < 2L) next
      up <- c(hs_raw[i], vs_raw[i]) - c(hs_raw[i - 1L], vs_raw[i - 1L])
      if ((if (own_home) up[1] else up[2]) == 2L && (if (own_home) up[2] else up[1]) == 0L) off_safety[i] <- TRUE
    }
  }

  # --- assemble the play table -------------------------------------------
  out_sit <- character()
  out_play <- character()
  add <- function(s, p) {
    out_sit[length(out_sit) + 1] <<- s
    out_play[length(out_play) + 1] <<- p
  }
  period_label <- function(p) if (p <= 4L) ord[p] else if (p == 5L) "OT" else paste0(p - 4L, "OT")
  # ncaa.com's teamId is unreliable on single lines (a punt can carry the
  # receiving team's id), so when the game has "drive start" lines they
  # alone open drives; otherwise a drive opens when another team snaps.
  has_starts <- any(is_start)
  # ... except after a snap that can end a possession (a 4th down, a field
  # goal try, a punt, an interception or fumble), where ncaa.com sometimes
  # has no "drive start" line (a blocked field goal recovered by the defense)
  last_snap <- NA_integer_
  last_kick <- NA_integer_
  # a 4th down the offense converted ("..., 1ST DOWN." before any penalty
  # clause) keeps the ball: it doesn't open a new drive even when the next
  # line carries the other team's id (6462090: MIT's id on Salve Regina's
  # interception right after Salve converted 4th and 1)
  converted <- function(k) {
    stringr::str_detect(stringr::str_remove(txt[k], "PENALTY .*$"), "1ST DOWN") &&
      !stringr::str_detect(txt[k], stringr::regex("intercepted|fumble", ignore_case = TRUE))
  }
  ends_possession <- function(k) {
    !is.na(k) && ((dt$down[k] %in% 4L && !converted(k)) || stringr::str_detect(
      txt[k], stringr::regex("field goal|\\bpunt\\b|intercepted|fumble|blocked", ignore_case = TRUE)) ||
      live_td(txt[k]))
  }
  cur_team <- NA_character_
  last_period <- 0L
  last_hs <- 0L
  last_vs <- 0L
  for (i in seq_len(n)) {
    if (!is.na(lines$period[i]) && lines$period[i] != last_period) {
      last_period <- lines$period[i]
      add(period_label(last_period), period_label(last_period))
    }
    fg_before <- FALSE
    if (as.character(i) %in% names(dropped_fg)) {
      tid <- dropped_fg[[as.character(i)]]
      if (identical(cur_team, tid) || !has_running_score) {
        kicker <- summary_kicker(lines$period[i], tid)
        add(ncaa_next_situation(situation, txt, which(is_snap & seq_len(n) < i)),
            paste0(if (!is.na(kicker)) paste0(kicker, " ") else "", "field goal attempt GOOD ", ncaa_added_fg_text))
        fg_before <- TRUE
      }
    }
    switch_team <- is_snap[i] && !identical(lines$team_id[i], cur_team) &&
      !stringr::str_detect(txt[i], stringr::regex("\\bpunt\\b", ignore_case = TRUE))
    # a kickoff since the last snap also hands the ball over (some files
    # have "drive start" lines for only a few drives), and so does the
    # game's first snap
    kicked <- !is.na(last_kick) && (is.na(last_snap) || last_kick > last_snap)
    # each overtime period starts a new possession, with no kickoff
    new_ot <- lines$period[i] >= 5L && (is.na(last_snap) || lines$period[last_snap] != lines$period[i])
    new_drive <- is_start[i] ||
      (switch_team && (!has_starts || is.na(cur_team) || kicked || new_ot || fg_before || ends_possession(last_snap)))
    if (new_drive && !is.na(lines$team_id[i])) {
      nm <- team_name[[lines$team_id[i]]]
      clk <- stringr::str_match(txt[i], "drive start at (\\d{1,2}:\\d{2})")[, 2]
      add(paste0(nm, " at", if (!is.na(clk)) paste0(" ", clk) else ""),
          paste0(nm, " at", if (!is.na(clk)) paste0(" ", clk) else ""))
      if (!is_start[i]) add(situation[i], paste0(nm, " drive start at."))
      cur_team <- lines$team_id[i]
    }
    if (is_snap[i]) last_snap <- i
    if (is_kickoff[i]) last_kick <- i
    add(situation[i], if (def_try[i]) paste(txt[i], ncaa_defensive_try_label) else
      if (safety_np[i]) paste(txt[i], ncaa_safety_label) else
        if (off_safety[i]) paste(txt[i], ncaa_offense_safety_label) else txt[i])
    # a "drive start" line naming the other team than its own id and the
    # next snap's id (6461812: "Chris. Newport drive start at 15:00"
    # opens Rowan's overtime possession): the raw line is kept and a drive
    # start for the team that snaps is added after it
    if (is_start[i] && wrong_start[i]) {
      nm <- team_name[[lines$team_id[i]]]
      add(paste0(nm, " at"), paste0(nm, " at"))
      add(situation[i], paste0(nm, " drive start at. ", ncaa_wrong_start_label))
    }
    if (as.character(i) %in% names(added)) add("", added[[as.character(i)]])
    changed <- hs[i] != last_hs || vs[i] != last_vs
    if (changed && (i == n || !is_try[i + 1])) {
      add("", score_line(i))
      last_hs <- hs[i]
      last_vs <- vs[i]
    }
  }
  tibble::tibble(situation = out_sit, play = out_play)
}

#' Label appended to a try line that ncaa.com's score shows the defense returned
#'
#' The parser's defensive-conversion rule reads "returned by ... for a
#' defensive two-point conversion" (see [score_points()]).
#' @keywords internal
ncaa_defensive_try_label <- "[d3ballR: ncaa.com's running score gives these 2 points to the defense, so this try was returned by the defense for a defensive two-point conversion]"

#' Label appended to a "SAFETY ... NO PLAY" line that was a safety
#'
#' A foul by the offense in its own end zone is a safety; the stat crew marks
#' the play "NO PLAY" because the play itself doesn't count. The parser
#' scores a row carrying this label as a safety even though it is a no-play
#' (see [score_points()]).
#' @keywords internal
ncaa_safety_label <- "[d3ballR: a safety on a foul in the end zone; the play is a no-play but the safety counts]"

#' Label appended to a safety ncaa.com's score gives to the team that started the play
#' @keywords internal
ncaa_offense_safety_label <- "[d3ballR: ncaa.com's running score gives this safety to the team that started the play]"

#' Label on a drive start added when ncaa.com's names the wrong team
#' @keywords internal
ncaa_wrong_start_label <- "[added by d3ballR: the drive start line before names the other team; this team snaps]"

#' The down, distance and spot after the last snap (for an added play)
#'
#' The next down at the spot where the last snap ended (its last "to the
#' XX21" spot, else its own spot), with the distance shortened by the gain;
#' "Goal" stays "Goal". Used for a field goal ncaa.com left out, which
#' otherwise has no situation.
#' @param situation Rebuilt situations ("3rd and 6 at UWW21").
#' @param txt Line texts.
#' @param prev Indices of earlier snaps.
#' @return A situation string, or "" when there is no earlier snap.
#' @keywords internal
ncaa_next_situation <- function(situation, txt, prev) {
  if (!length(prev)) return("")
  k <- prev[length(prev)]
  m <- stringr::str_match(situation[k], "^([1-4])(?:st|nd|rd|th) and (Goal|\\d+) at ([A-Za-z&.' -]*?)(\\d+)$")
  if (is.na(m[1, 1])) return("")
  down <- min(as.integer(m[1, 2]) + 1L, 4L)
  tok <- m[1, 4]
  yard <- as.integer(m[1, 5])
  end <- stringr::str_match_all(txt[k], paste0("to the ", stringr::str_replace_all(tok, "([.&])", "\\\\\\1"), "(\\d{1,2})\\b"))[[1]]
  new_yard <- if (nrow(end)) as.integer(end[nrow(end), 2]) else yard
  dist <- if (m[1, 3] == "Goal") "Goal" else as.character(max(1L, as.integer(m[1, 3]) - (yard - new_yard)))
  paste0(c("1st", "2nd", "3rd", "4th")[down], " and ", dist, " at ", tok, new_yard)
}

#' Label of a field goal added because ncaa.com left it out
#' @keywords internal
ncaa_added_fg_text <- "[added by d3ballR: ncaa.com has no line for this field goal; its running score (or, without one, its scoring summary and the final score) shows it. Down, distance and spot are rebuilt from the previous snap]"

#' Play text of an extra point added because ncaa.com left it out
#' @keywords internal
ncaa_added_try_text <- "kick attempt good [added by d3ballR: ncaa.com has no line for this try; its score rose by 1 after the touchdown]."

#' Play text of an extra point added from the final score
#' @keywords internal
ncaa_added_try_text_final <- "kick attempt good [added by d3ballR: ncaa.com has no line for this try and no running score; the final score is one point short for each such touchdown]."

#' Play text of an extra point added from ncaa.com's scoring summary
#' @keywords internal
ncaa_added_try_text_summary <- "kick attempt good [added by d3ballR: ncaa.com has no line for this try and no running score; its scoring summary lists the extra point as good]."

#' Play text of a two-point try added from ncaa.com's running score
#'
#' The touchdown has no try line and the running score rose by 2 before the
#' next kickoff. It doesn't say whether it was a run or a pass.
#' @keywords internal
ncaa_added_two_point_text_score <- "two-point attempt good [added by d3ballR: ncaa.com has no line for this try; its score rose by 2 after the touchdown]."

#' Play text of a two-point try added from ncaa.com's scoring summary
#'
#' The summary doesn't say whether it was a run or a pass.
#' @keywords internal
ncaa_added_two_point_text <- "two-point attempt good [added by d3ballR: ncaa.com has no line for this try and no running score; its scoring summary lists a two-point conversion as good]."

#' ncaa.com's scoring summary as one row per entry
#'
#' @param j Parsed JSON of `/game/{contest}/scoring-summary`.
#' @return A data frame: `period` (1, 2, ... in the summary's order),
#'   `quarter` (the real period, from the title: 1-4, OT = 5, 2OT = 6;
#'   differs from `period` when a quarter had no scoring), `team_id`, `time` ("MM:SS", blank on tries), `type` ("TD", "XP",
#'   "TPC", "FG", ...), `text`. Only good tries are listed.
#' @keywords internal
ncaa_scoring_entries <- function(j) {
  val <- function(x) if (is.null(x)) NA_character_ else as.character(x)
  rows <- list()
  for (p in seq_along(j$periods)) {
    # `period` is the position in the summary; `quarter` is read from the
    # title ("3rd Quarter", "OT", "2OT"). They differ when a quarter had no
    # scoring (6462421 goes 1st, 3rd, 4th, OT).
    qtr <- ncaa_period_number(j$periods[[p]]$title, p)
    for (e in j$periods[[p]]$summary) {
      rows[[length(rows) + 1]] <- data.frame(
        period = p, quarter = qtr, team_id = val(e$teamId), time = dplyr::coalesce(val(e$time), ""),
        type = val(e$scoreType), text = dplyr::coalesce(val(e$scoreText), ""))
    }
  }
  if (!length(rows)) return(data.frame(period = integer(), quarter = integer(), team_id = character(), time = character(),
                                      type = character(), text = character()))
  do.call(rbind, rows)
}

#' Period number from an ncaa.com period title
#'
#' "1st Quarter" .. "4th Quarter" give 1-4, "OT" 5, "2OT" 6, and so on.
#' @param title Period title.
#' @param fallback Number to use when the title can't be read.
#' @keywords internal
ncaa_period_number <- function(title, fallback) {
  t <- if (is.null(title)) "" else as.character(title)
  q <- suppressWarnings(as.integer(stringr::str_match(t, "^(\\d)(?:st|nd|rd|th) Quarter")[, 2]))
  if (!is.na(q)) return(q)
  ot <- stringr::str_match(t, "^(\\d*)\\s*OT\\b")
  if (!is.na(ot[, 1])) return(4L + if (nzchar(ot[, 2])) as.integer(ot[, 2]) else 1L)
  as.integer(fallback)
}

#' Which yardline token is each team's own side (ncaa.com lines)
#'
#' Same vote as [infer_own_side()]: on consecutive snaps by one team on one
#' token, the yard number goes up on the team's own side.
#'
#' @param team_id,token,yard Snap rows.
#' @param tokens The game's two tokens.
#' @return Named character vector: names are team ids, values tokens.
#' @keywords internal
ncaa_own_token <- function(team_id, token, yard, tokens) {
  ids <- sort(unique(stats::na.omit(team_id)))
  k <- length(team_id)
  ok <- team_id[-1] == team_id[-k] & token[-1] == token[-k] & !is.na(yard[-1]) & yard[-1] != yard[-k]
  ok <- ok %in% TRUE
  up <- (yard[-1] - yard[-k])[ok] > 0
  t <- team_id[-k][ok]
  tk <- token[-k][ok]
  a <- sum((tk == ifelse(t == ids[1], tokens[1], tokens[2])) == up)
  b <- sum((tk == ifelse(t == ids[1], tokens[2], tokens[1])) == up)
  if (a >= b) stats::setNames(tokens, ids) else stats::setNames(rev(tokens), ids)
}

#' Fetch one game from ncaa.com, ready for [build_pbp()]
#'
#' Looks the game up in the contest table ([ncaa_contest_table()]), fetches
#' its play-by-play (cached), and rebuilds the (situation, play) table the
#' parser reads with [ncaa_play_table()]. Home and away follow the contest
#' table. The final score is ncaa.com's
#' scoreboard score, else its last running score.
#'
#' @param game_id Game id: the ncaa.com contest id, e.g. "6461490".
#' @param contests Contest table: [ncaa_contest_table()] of the game list.
#' @param index The game list ([ncaa_season_games()]).
#' @return A game list for [build_pbp()]: `game_id`, `season`, `teams`,
#'   `finals`, `matchup`, `header_date`, `plays`, plus `contest`.
#' @export
fetch_ncaa_game <- function(game_id, contests, index) {
  hit <- contests[contests$game_id == game_id, ]
  if (nrow(hit) != 1) stop("Not on ncaa.com: no ncaa.com contest matched to ", game_id, call. = FALSE)
  j <- fetch_ncaa_json(paste0("/game/", hit$contest, "/play-by-play"))
  if (is.null(j$periods) || !length(j$periods)) stop("ncaa.com play-by-play is empty for contest ", hit$contest)
  lines <- ncaa_lines(j)
  if (length(unique(stats::na.omit(lines$team_id))) < 2) {
    stop("ncaa.com tags every line of contest ", hit$contest, " with one team, so possession can't be read")
  }
  tm <- j$teams
  teams <- data.frame(
    team_id = vapply(tm, function(t) as.character(t$teamId), character(1)),
    short = vapply(tm, function(t) t$nameShort, character(1)),
    ncaa_home = vapply(tm, function(t) isTRUE(t$isHome), logical(1))
  )
  teams$is_home <- if (isTRUE(hit$home_away_flip)) !teams$ncaa_home else teams$ncaa_home
  starts <- stringr::str_match(lines$text, stringr::regex("^(.*?) drive start at", ignore_case = TRUE))[, 2]
  # Some files tag every line with the other team's teamId (6461392:
  # each "Dubuque drive start" line carries Central's id). When the
  # drive-start names match ncaa.com's team names the other way round on
  # most such lines, the ids are swapped back.
  lines$team_id <- ncaa_unswap_team_ids(lines$team_id, starts, tm)
  teams$name <- vapply(seq_len(nrow(teams)), function(k) {
    s <- starts[!is.na(starts) & lines$team_id == teams$team_id[k]]
    if (length(s)) names(sort(table(s), decreasing = TRUE))[1] else teams$short[k]
  }, character(1))
  if (anyDuplicated(teams$name)) teams$name <- teams$short

  # with no running score, ncaa.com's scoring summary says which tries were
  # good (one more request; NULL if it can't be had, e.g. offline and not cached)
  scoring <- NULL
  if (!ncaa_has_running_score(j)) {
    scoring <- tryCatch(ncaa_scoring_entries(fetch_ncaa_json(paste0("/game/", hit$contest, "/scoring-summary"))),
                        error = function(e) NULL)
  }

  row <- index[!is.na(index$game_id) & index$game_id == game_id, ]
  home <- teams$name[teams$is_home]
  away <- teams$name[!teams$is_home]
  fin_h <- if (isTRUE(hit$home_away_flip)) hit$ncaa_away_score else hit$ncaa_home_score
  fin_a <- if (isTRUE(hit$home_away_flip)) hit$ncaa_home_score else hit$ncaa_away_score
  if (is.na(fin_h) || is.na(fin_a)) {
    hs <- max(c(0L, lines$home_score), na.rm = TRUE)
    vs <- max(c(0L, lines$visitor_score), na.rm = TRUE)
    if (isTRUE(hit$home_away_flip)) { fin_h <- vs; fin_a <- hs } else { fin_h <- hs; fin_a <- vs }
  }
  list(
    game_id = game_id,
    season = if (nrow(row)) as.integer(row$season) else as.integer(substr(game_id, 1, 4)),
    teams = c(away, home),
    finals = stats::setNames(as.integer(c(fin_a, fin_h)), c(away, home)),
    matchup = c(away = away, home = home),
    header_date = if (nrow(row)) as.Date(row$game_date) else as.Date(substr(game_id, 1, 8), format = "%Y%m%d"),
    plays = ncaa_play_table(lines, teams, final_total = fin_a + fin_h, scoring = scoring),
    contest = hit$contest
  )
}
