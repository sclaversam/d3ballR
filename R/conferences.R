#' Parse one conference standings page into its member teams
#'
#' `/conf/{CODE}/{season}/standings` lists the members for that season, each
#' linked as `/teams/{Team}/{season}`; the link text is the team name in the
#' same spelling as the scoreboard (and so the season index). The
#' conference's name comes from the page title ("2025 Centennial Conference
#' football standings").
#'
#' @param html Parsed page.
#' @param season Season year.
#' @param code Conference code.
#' @return Data frame: `season`, `team`, `conference`, `conference_code`.
#' @keywords internal
parse_conference_standings <- function(html, season, code) {
  name <- conference_name_from_title(html, season)
  a <- rvest::html_elements(html, xpath = sprintf("//table//a[contains(@href, '/teams/') and contains(@href, '/%d')]", season))
  team <- unique(stringr::str_squish(rvest::html_text(a)))
  team <- team[nchar(team) > 0]
  data.frame(season = rep(as.integer(season), length(team)), team = team,
             conference = rep(name, length(team)), conference_code = rep(code, length(team)))
}

#' Conference name from a standings page title
#'
#' "2025 Centennial Conference football standings" -> "Centennial
#' Conference"; some titles omit "football" ("2025 Conference of New
#' England standings").
#'
#' @param html Parsed standings page.
#' @param season Season year.
#' @keywords internal
conference_name_from_title <- function(html, season) {
  title <- rvest::html_text(rvest::html_element(html, "title"))
  stringr::str_squish(stringr::str_match(title, paste0("^\\s*", season, " (.*?)(?: football)? standings"))[, 2])
}

#' Members of one conference in one season
#'
#' @param season Season year.
#' @param code Conference code (e.g. "CC").
#' @return Output of [parse_conference_standings()].
#' @export
conference_members <- function(season, code) {
  parse_conference_standings(
    fetch_html(sprintf("https://www.d3football.com/conf/%s/%d/standings", code, season)), season, code
  )
}

#' URL slug for a team page
#'
#' d3football team pages use underscores for spaces
#' (`/teams/Franklin_and_Marshall/2025/index`); the `%20` form returns a page
#' without the schedule.
#'
#' @param team Team name (scoreboard spelling).
#' @keywords internal
team_slug <- function(team) gsub(" ", "_", team)

#' A team's conference in a season, from its team page
#'
#' The team page's year-by-year table links each season's conference
#' standings (`/conf/CC/2025/standings`), which gives the season-specific
#' membership (Carnegie Mellon: PAC through 2024, CC in 2025). No such link
#' means no conference that season (an independent, or a non-D3 team).
#'
#' @param html Parsed team page.
#' @param season Season year.
#' @return Conference code, or NA.
#' @keywords internal
parse_team_conference_code <- function(html, season) {
  href <- rvest::html_attr(rvest::html_elements(html, "a"), "href")
  code <- stats::na.omit(stringr::str_match(href, sprintf("^/conf/([^/]+)/%d/standings", season))[, 2])
  if (length(code)) code[1] else NA_character_
}

#' Parse a team's schedule page: each game and its conference marker
#'
#' Each schedule row links the game's boxscore; a conference game carries
#' d3's "*" marker ("* Conference" in the page legend) next to the
#' opponent. The page repeats conference games in a second "Conference
#' Schedule" block, so rows are de-duplicated by `game_id`.
#'
#' @param html Parsed team page.
#' @param team Team name.
#' @param season Season year.
#' @return Data frame: `season`, `team`, `game_id`, `conference_marker`.
#' @keywords internal
parse_team_schedule <- function(html, team, season) {
  empty <- data.frame(season = integer(), team = character(), game_id = character(), conference_marker = logical())
  rows <- rvest::html_elements(html, xpath = sprintf("//tr[.//a[contains(@href,'/seasons/%d/boxscores/')]]", season))
  if (!length(rows)) return(empty)
  ids <- vapply(rows, function(r) {
    h <- rvest::html_attr(rvest::html_elements(r, "a"), "href")
    stringr::str_match(h[grepl("/boxscores/", h)][1], "/boxscores/([^./]+)\\.xml")[, 2]
  }, character(1))
  opp_cell <- vapply(rows, function(r) {
    td <- rvest::html_elements(r, xpath = "./td")
    if (length(td) >= 2) rvest::html_text(td[[2]]) else rvest::html_text(r)
  }, character(1))
  out <- data.frame(season = as.integer(season), team = team, game_id = ids,
                    conference_marker = stringr::str_detect(opp_cell, "\\*"))
  out <- out[!is.na(out$game_id), ]
  if (!nrow(out)) return(empty)
  stats::aggregate(conference_marker ~ season + team + game_id, data = out, FUN = any)
}

#' Build (or extend) a season's team-to-conference table for given teams
#'
#' Reads each listed team's page (`/teams/{Team}/{season}/index`, cached and
#' throttled by [fetch_html()]) once, for two things:
#' - its conference that season (from the year-by-year table), and
#' - d3's "*" conference marker on each of its games.
#'
#' Conference names come from each distinct conference's standings page
#' title. Only the teams asked for are fetched: e.g. a conference's members
#' plus every opponent they played. Results are cached to
#' `{cache_dir}/{season}.csv` (`season`, `team`, `conference`,
#' `conference_code`; NA conference = independent or non-D3) and
#' `{cache_dir}/{season}_schedule_markers.csv` (`season`, `team`,
#' `game_id`, `conference_marker`). Teams already cached are not re-fetched;
#' new teams are appended. A team page that fails to fetch is left out (with
#' a warning) so the next call retries it; it is never recorded as having no
#' conference. A conference whose standings page fails keeps its code with an
#' NA name until a later call fills it in.
#'
#' @param season Season year.
#' @param teams Team names (scoreboard spelling).
#' @param cache_dir Output directory.
#' @return A list: `table` (team-to-conference) and `markers`.
#' @export
build_conference_table <- function(season, teams, cache_dir = "data-raw/conferences") {
  tab_file <- file.path(cache_dir, paste0(season, ".csv"))
  mk_file <- file.path(cache_dir, paste0(season, "_schedule_markers.csv"))
  tab <- if (file.exists(tab_file)) utils::read.csv(tab_file, na.strings = "") else NULL
  mk <- if (file.exists(mk_file)) utils::read.csv(mk_file, na.strings = "", colClasses = c(game_id = "character")) else NULL
  todo <- setdiff(unique(teams), tab$team)

  new_tab <- list()
  new_mk <- list()
  failed <- character()
  for (t in todo) {
    url <- sprintf("https://www.d3football.com/teams/%s/%d/index", team_slug(t), season)
    html <- tryCatch(fetch_html(url), error = function(e) NULL)
    if (is.null(html)) {
      # not recorded: a failed fetch is retried on the next call, never cached as "no conference"
      failed <- c(failed, t)
      next
    }
    code <- parse_team_conference_code(html, season)
    new_tab[[t]] <- data.frame(season = as.integer(season), team = t, conference = NA_character_, conference_code = code)
    new_mk[[t]] <- parse_team_schedule(html, t, season)
  }
  if (length(failed)) {
    warning("Could not fetch ", length(failed), " team page(s) for ", season, " (left out; rerun to retry): ",
            paste(failed, collapse = ", "), call. = FALSE)
  }
  tab <- do.call(rbind, c(list(tab), new_tab))
  mk <- do.call(rbind, c(list(mk), new_mk))

  # names for codes not yet named, from each conference's standings title
  need <- if (is.null(tab)) character() else unique(stats::na.omit(tab$conference_code[is.na(tab$conference)]))
  for (code in need) {
    html <- tryCatch(fetch_html(sprintf("https://www.d3football.com/conf/%s/%d/standings", code, season)),
                     error = function(e) NULL)
    if (!is.null(html)) tab$conference[tab$conference_code %in% code] <- conference_name_from_title(html, season)
  }

  if (length(todo) > length(failed) || length(need)) {
    dir.create(cache_dir, showWarnings = FALSE, recursive = TRUE)
    utils::write.csv(tab[order(tab$conference_code, tab$team), ], tab_file, row.names = FALSE, na = "")
    utils::write.csv(mk, mk_file, row.names = FALSE, na = "")
  }
  list(table = tab, markers = mk)
}

#' Conference columns for one game
#'
#' `home_team_conference` / `away_team_conference` from the season's
#' conference table (NA for a team in no conference: an independent or a
#' non-D3 opponent, or a team not in the table). `conference_game` from
#' d3's "*" schedule marker, NOT from shared membership, so a playoff or
#' bowl game between two members isn't counted; NA if neither team's
#' schedule page has been read. `shared_conference` (both teams in the same
#' conference) is returned for the cross-check.
#'
#' @param game_id Game id.
#' @param home,away Team names in the scoreboard / index spelling.
#' @param conf Output of [build_conference_table()], or NULL.
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

#' Every game involving a set of teams, from a season index
#'
#' Any game with one of the teams as home or away: conference,
#' non-conference, playoff and bowl games.
#'
#' @param index Output of [build_season_index()].
#' @param teams Team names (scoreboard spelling).
#' @return The matching index rows.
#' @export
index_games_for_teams <- function(index, teams) {
  index[index$home %in% teams | index$away %in% teams, ]
}
