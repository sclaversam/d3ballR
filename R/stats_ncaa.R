#' Read a stats.ncaa.org play-by-play page saved from a browser
#'
#' stats.ncaa.org blocks scripts (an Akamai 403 on the first request,
#' 2026-11-17), so for the few games ncaa.com can't give (no play-by-play,
#' or a file that can't be built; Sam's rule, 2026-11-17) Sam saves the
#' game's "Play By Play" page from his browser into `data-raw/stats_ncaa/`.
#' This reads such a file into the same line table [ncaa_lines()] makes from
#' ncaa.com's JSON, so [ncaa_play_table()] and the rest of the parser run
#' unchanged.
#'
#' The page lists each quarter (`<h1>1st Quarter</h1>`), then its drives.
#' Each drive has a header (`<h5>`: the team's logo, the result, "14:55,
#' JHU45, 5 plays, 45 yards, 01:29" and the score after the drive, away -
#' home) and its plays, each a bold situation ("1st & 10 at JHU35") and the
#' StatCrew play text. So:
#' - `team_id` is the drive's team (its logo's name). As on ncaa.com, the
#'   kickoff that opens a drive is grouped with the receiving team; the
#'   parser opens drives at the "drive start" lines, not at `team_id`.
#' - `drive_text` is the situation in ncaa.com's spelling ("1 and 10 at
#'   JHU35"); a blank or "-" situation becomes NA.
#' - The score after each drive becomes the running score on the drive's
#'   last line (`home_score`, `visitor_score`); other lines are NA.
#' - `clock` is NA (the page has no per-line clock; the play text keeps
#'   any "clock MM:SS").
#'
#' @param file Path to the saved page.
#' @return A list: `lines` (as [ncaa_lines()]: `period`, `team_id`,
#'   `clock`, `drive_text`, `home_score`, `visitor_score`, `text`),
#'   `teams` (`away`, `home`: the names on the page's logos), `finals`
#'   (named integer, away and home), `date` (Date).
#' @export
stats_ncaa_lines <- function(file) {
  doc <- xml2::read_html(file, encoding = "UTF-8")
  sq <- function(x) stringr::str_squish(x)
  logos <- rvest::html_attr(rvest::html_elements(doc, "img.large_logo_image"), "alt")
  if (length(logos) < 2) stop("Not a stats.ncaa.org game page (no team logos): ", file, call. = FALSE)
  teams <- c(away = logos[1], home = logos[2])
  big <- rvest::html_elements(doc, xpath = "//td[contains(@style, 'font-size:36px')]")
  finals <- suppressWarnings(as.integer(sq(rvest::html_text(big))))[1:2]
  names(finals) <- unname(teams)
  date_txt <- stringr::str_extract(rvest::html_text(doc), "\\d{2}/\\d{2}/\\d{4}")
  date <- as.Date(date_txt, format = "%m/%d/%Y")

  nodes <- rvest::html_elements(doc, xpath = paste(
    "//h1",
    "//div[contains(@class, 'drives')]/h5",
    "//div[contains(@class, 'drives')]/div/div[span]",
    sep = " | "))
  period <- NA_integer_
  team <- NA_character_
  drive <- 0L
  rows <- list()
  for (nd in nodes) {
    tag <- xml2::xml_name(nd)
    if (tag == "h1") {
      period <- ncaa_period_number(sq(rvest::html_text(nd)), fallback = if (is.na(period)) 1L else period + 1L)
    } else if (tag == "h5") {
      team <- rvest::html_attr(rvest::html_element(nd, "img"), "alt")
      sc <- stringr::str_match(sq(rvest::html_text(rvest::html_element(nd, "div.headerRight"))), "^(\\d+)\\s*-\\s*(\\d+)$")
      drive <- drive + 1L
      info <- sq(rvest::html_text(nd))
      rows[[length(rows) + 1]] <- list(drive_marker = TRUE, team = team, drive = drive,
                                       clock = stringr::str_match(info, "(\\d{1,2}:\\d{2}),")[, 2],
                                       away = as.integer(sc[, 2]), home = as.integer(sc[, 3]))
    } else {
      spans <- sq(rvest::html_text(rvest::html_elements(nd, "span")))
      if (!length(spans)) next
      rows[[length(rows) + 1]] <- list(drive_marker = FALSE, period = period, team = team, drive = drive,
                                       situation = if (length(spans) > 1) spans[1] else "",
                                       text = spans[length(spans)])
    }
  }
  headers <- Filter(function(r) isTRUE(r$drive_marker), rows)
  header_team <- vapply(headers, function(r) dplyr::coalesce(r$team, NA_character_), character(1))
  header_clock <- vapply(headers, function(r) dplyr::coalesce(r$clock, NA_character_), character(1))
  # a page whose drive headers all read 0 - 0 has no running score
  no_score <- all(vapply(headers, function(r) isTRUE(r$away == 0L && r$home == 0L), logical(1)))
  if (no_score) for (k in seq_along(rows)) if (isTRUE(rows[[k]]$drive_marker)) { rows[[k]]$away <- NA_integer_; rows[[k]]$home <- NA_integer_ }
  # each drive's score goes on that drive's last line
  out <- list()
  pending <- NULL
  for (r in rows) {
    if (isTRUE(r$drive_marker)) {
      if (!is.null(pending) && length(out)) {
        out[[length(out)]]$visitor_score <- pending$away
        out[[length(out)]]$home_score <- pending$home
      }
      pending <- r
      next
    }
    out[[length(out) + 1]] <- list(period = r$period, drive = r$drive, team_id = r$team, clock = NA_character_,
                                   drive_text = stats_ncaa_drive_text(r$situation),
                                   home_score = NA_integer_, visitor_score = NA_integer_, text = r$text)
  }
  if (!is.null(pending) && length(out)) {
    out[[length(out)]]$visitor_score <- pending$away
    out[[length(out)]]$home_score <- pending$home
  }
  lines <- do.call(rbind.data.frame, out)
  if (!nrow(lines)) stop("No plays found in ", file, call. = FALSE)
  lines$period <- as.integer(lines$period)
  lines$home_score <- as.integer(lines$home_score)
  lines$visitor_score <- as.integer(lines$visitor_score)
  lines$text <- stringr::str_squish(lines$text)
  # a drive header's logo can name the wrong team (6461614: several drives
  # carry the other team's logo); the drive's own "TEAM drive start" line
  # decides when it names one of the two teams
  fixed <- stats_ncaa_drive_teams(lines, unname(teams), header_team, header_clock)
  attr(lines, "drives_relabelled") <- sum(tapply(fixed != lines$team_id, lines$drive, any), na.rm = TRUE)
  lines$team_id <- fixed
  lines$drive <- NULL
  list(lines = lines, teams = teams, finals = finals, date = date)
}

#' Each drive's team, from its "drive start" line
#'
#' A drive header's team is wrong on some pages: from some point on, each
#' header sits one group of plays off (6461614, second half: the plays
#' under "Salve Regina PUNT 14:53" are UMass Dartmouth's, and "Salve Regina
#' drive start at 10:23" sits under the header before "Salve Regina TD
#' 10:23"). So:
#' 1. A group of plays whose "TEAM drive start at" line names exactly one
#'    of the two teams (names compared lower-case, letters and digits only,
#'    one contained in the other: "Mass.-Dartmouth" for "UMass Dartmouth")
#'    takes that team. Its offset to the headers is the header (this one,
#'    the next or the previous) with that team and a start clock equal to
#'    its "drive start at" clock.
#' 2. A group with no such line takes the team of the header at the
#'    offset of the nearest such group (the earlier one on a tie; offset 0
#'    when there is none).
#'
#' @param lines [stats_ncaa_lines()]'s lines, with a `drive` number (the
#'   group's header index).
#' @param teams The two team names on the page.
#' @param header_team,header_clock Each header's team and start clock.
#' @return The corrected `team_id` vector.
#' @keywords internal
stats_ncaa_drive_teams <- function(lines, teams, header_team = character(), header_clock = character()) {
  norm <- function(x) gsub("[^a-z0-9]", "", tolower(x))
  starts <- stringr::str_match(lines$text, stringr::regex("^(.*?) drive start at ?(\\d{1,2}:\\d{2})?", ignore_case = TRUE))
  named <- vapply(norm(starts[, 2]), function(s) {
    if (is.na(s) || !nzchar(s)) return(NA_character_)
    hit <- vapply(norm(teams), function(k) grepl(s, k, fixed = TRUE) || grepl(k, s, fixed = TRUE), logical(1))
    if (sum(hit) == 1L) teams[hit] else NA_character_
  }, character(1))
  groups <- sort(unique(lines$drive))
  one <- function(v) { v <- unique(stats::na.omit(v)); if (length(v) == 1L) v else NA_character_ }
  g_team <- vapply(groups, function(g) one(named[lines$drive == g]), character(1))
  g_clock <- vapply(groups, function(g) one(starts[lines$drive == g & !is.na(named), 3]), character(1))
  clean <- function(x) sub("^0", "", x)
  offset <- vapply(seq_along(groups), function(k) {
    g <- groups[k]
    if (is.na(g_clock[k])) return(NA_integer_)
    for (o in c(0L, 1L, -1L)) {
      h <- g + o
      if (h >= 1 && h <= length(header_clock) && isTRUE(clean(header_clock[h]) == clean(g_clock[k])) &&
          isTRUE(header_team[h] == g_team[k])) return(o)
    }
    NA_integer_
  }, integer(1))
  team <- g_team
  for (k in which(is.na(team))) {
    known <- which(!is.na(offset))
    o <- if (length(known)) offset[known[which.min(abs(known - k))]] else 0L
    h <- groups[k] + o
    if (h >= 1 && h <= length(header_team)) team[k] <- header_team[h]
  }
  d <- team[match(lines$drive, groups)]
  ifelse(is.na(d), lines$team_id, d)
}

#' A stats.ncaa.org situation in ncaa.com's `driveText` spelling
#'
#' "1st & 10 at JHU35" -> "1 and 10 at JHU35"; "1st & Goal at JHU3" -> "1
#' and 0 at JHU3" (ncaa.com's goal-to-go); a blank or "-" situation -> NA.
#' @param x Situation strings.
#' @keywords internal
stats_ncaa_drive_text <- function(x) {
  m <- stringr::str_match(x, "^([1-4])(?:st|nd|rd|th) & (\\S+) at (.*)$")
  dist <- ifelse(tolower(m[, 3]) == "goal", "0", m[, 3])
  ifelse(is.na(m[, 1]), NA_character_, paste0(m[, 2], " and ", dist, " at ", m[, 4]))
}

#' Build one game from a saved stats.ncaa.org page, in [fetch_game()]'s shape
#'
#' The stats.ncaa.org counterpart of [fetch_ncaa_game()]: the page is read
#' with [stats_ncaa_lines()] and rebuilt with [ncaa_play_table()]. Home and
#' away follow the game list; the page's two teams are matched to them by
#' name ([ncaa_to_index_name()], then the order on the page: away first). The
#' final score is the game list's, else the page's.
#'
#' @param game_id Our game id (the ncaa.com contest id).
#' @param file The saved page.
#' @param index The game list ([ncaa_season_games()]).
#' @return A list like [fetch_ncaa_game()]'s, with `source = "stats.ncaa.org"`.
#' @export
fetch_stats_ncaa_game <- function(game_id, file, index) {
  s <- stats_ncaa_lines(file)
  lines <- s$lines
  row <- index[!is.na(index$game_id) & index$game_id == game_id, ]
  if (!is.na(s$date) && nrow(row) && abs(as.numeric(s$date - as.Date(row$game_date))) > 1) {
    stop("Saved page ", file, " is a game on ", s$date, ", not ", row$game_date, call. = FALSE)
  }
  starts <- stringr::str_match(lines$text, stringr::regex("^(.*?) drive start at", ignore_case = TRUE))[, 2]
  ids <- unname(s$teams)
  teams <- data.frame(team_id = ids, short = ids, ncaa_home = c(FALSE, TRUE))
  teams$is_home <- teams$ncaa_home
  teams$name <- vapply(ids, function(id) {
    st <- starts[!is.na(starts) & lines$team_id == id]
    if (length(st)) names(sort(table(st), decreasing = TRUE))[1] else id
  }, character(1))
  if (anyDuplicated(teams$name)) teams$name <- teams$short
  home <- teams$name[teams$is_home]
  away <- teams$name[!teams$is_home]
  fin <- c(away = unname(s$finals[1]), home = unname(s$finals[2]))
  if (nrow(row) && !is.na(row$away_score) && !is.na(row$home_score)) {
    fin <- c(away = as.integer(row$away_score), home = as.integer(row$home_score))
  }
  list(
    game_id = game_id,
    season = if (nrow(row)) as.integer(row$season) else as.integer(format(s$date, "%Y")),
    teams = c(away, home),
    finals = stats::setNames(as.integer(fin), c(away, home)),
    matchup = c(away = away, home = home),
    header_date = if (nrow(row)) as.Date(row$game_date) else s$date,
    plays = ncaa_play_table(ncaa_move_late_touchdowns(lines), teams, final_total = sum(fin)),
    contest = game_id,
    source = "stats.ncaa.org"
  )
}

#' Saved stats.ncaa.org pages in a folder, by the game they belong to
#'
#' Sam saves pages under stats.ncaa.org's own contest id (`6489674.html`)
#' or ours; either is fine. Each page is matched to a game in the game list
#' by date (at most a day apart) and teams ([ncaa_to_index_name()] on the
#' page's names, either order).
#'
#' @param games The game list ([ncaa_season_games()]).
#' @param dir Folder of saved pages (`.html` / `.htm`).
#' @return Named character vector: names are our game ids, values file
#'   paths. Pages that match no game, or more than one, are reported and
#'   left out.
#' @export
stats_ncaa_files <- function(games, dir = "data-raw/stats_ncaa") {
  fs <- list.files(dir, pattern = "\\.html?$", full.names = TRUE)
  out <- character()
  for (f in fs) {
    s <- tryCatch(stats_ncaa_lines(f), error = function(e) { message(conditionMessage(e)); NULL })
    if (is.null(s)) next
    t <- ncaa_to_index_name(unname(s$teams))
    d <- abs(as.numeric(as.Date(games$game_date) - s$date))
    hit <- which(d <= 1 & ((games$away == t[1] & games$home == t[2]) | (games$away == t[2] & games$home == t[1])))
    if (length(hit) != 1) {
      message("Saved page ", basename(f), " (", paste(t, collapse = " at "), ", ", s$date, ") matches ",
              length(hit), " games in the list; skipped")
      next
    }
    out[games$game_id[hit]] <- f
  }
  out
}

#' Games to build from saved stats.ncaa.org pages
#'
#' Sam's rule (2026-11-17): stats.ncaa.org is used only for games ncaa.com
#' can't give: no play-by-play, or a file that can't be built. Those are the
#' rows of `{dir}/{season}_stats_ncaa_candidates.csv` with
#' `pull_from_stats_ncaa` TRUE. A game is built from stats.ncaa.org when it
#' is such a row and a saved page for it is in `pages_dir`
#' ([stats_ncaa_files()]). Every other saved page is ignored.
#'
#' @param season Season year.
#' @param games The game list ([ncaa_season_games()]).
#' @param dir Folder of the candidate list.
#' @param pages_dir Folder of saved pages.
#' @return Named character vector: our game ids -> saved page paths.
#' @export
stats_ncaa_games <- function(season, games, dir = "data-raw/ncaa", pages_dir = "data-raw/stats_ncaa") {
  f <- file.path(dir, paste0(season, "_stats_ncaa_candidates.csv"))
  if (!file.exists(f) || !dir.exists(pages_dir)) return(character())
  cand <- utils::read.csv(f, colClasses = "character", na.strings = "")
  pull <- cand$game_id[cand$pull_from_stats_ncaa %in% "TRUE"]
  pages <- stats_ncaa_files(games, pages_dir)
  pages[names(pages) %in% pull]
}
