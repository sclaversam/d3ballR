#' Conference columns for one game
#'
#' `home_team_conference` / `away_team_conference` from the season's
#' conference table (NA for a team in no conference: an independent or a
#' non-D3 opponent, or a team not in the table). `conference_game` from
#' the game's conference marker ([ncaa_conference_markers()]: same
#' conference and regular season), so a playoff or bowl game between two
#' members isn't counted; NA if the game has no marker.
#' `shared_conference` (both teams in the same conference) is returned for
#' the conference report.
#'
#' @param game_id Game id.
#' @param home,away Team names in the game list's spelling.
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

#' Every game involving a set of teams, from a game list
#'
#' Any game with one of the teams as home or away: conference,
#' non-conference, playoff and bowl games.
#'
#' @param index The season's game list ([ncaa_season_games()]).
#' @param teams Team names (scoreboard spelling).
#' @return The matching index rows.
#' @export
index_games_for_teams <- function(index, teams) {
  index[index$home %in% teams | index$away %in% teams, ]
}
