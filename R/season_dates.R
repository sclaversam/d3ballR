#' Path to a lookup table that ships with the package
#'
#' The tables the code needs at run time (season dates, ncaa.com team and
#' conference names) are in `inst/extdata/`, which is installed with the
#' package (`data-raw/` is not).
#'
#' @param name File name, e.g. "team_names.csv".
#' @return A file path; an error if the file isn't there.
#' @keywords internal
d3_extdata <- function(name) system.file("extdata", name, package = "d3ballR", mustWork = TRUE)

#' Where the season-dates table is
#'
#' The table ships with the package in `inst/extdata/season_dates.csv`
#' (`data-raw/` is left out of the built package, so it can't live there).
#' Seasons [ensure_season_dates()] adds on an installed copy of d3ballR are
#' written to a user copy instead (`tools::R_user_dir("d3ballR", "data")`),
#' because the installed package's files shouldn't be changed; once that
#' copy exists it is the one read. `options(d3ballR.season_dates = path)`
#' overrides both.
#'
#' @return A file path.
#' @keywords internal
season_dates_path <- function() {
  opt <- getOption("d3ballR.season_dates")
  if (!is.null(opt)) return(opt)
  user <- season_dates_user_path()
  if (file.exists(user)) return(user)
  d3_extdata("season_dates.csv")
}

#' The user copy of the season-dates table (see [season_dates_path()])
#' @keywords internal
season_dates_user_path <- function() file.path(tools::R_user_dir("d3ballR", "data"), "season_dates.csv")

#' Is a file inside an installed package library?
#' @param path File path.
#' @keywords internal
in_installed_library <- function(path) {
  p <- normalizePath(path, winslash = "/", mustWork = FALSE)
  libs <- normalizePath(.libPaths(), winslash = "/", mustWork = FALSE)
  any(startsWith(p, paste0(libs, "/")))
}

#' Read the regular-season end dates
#'
#' One row per season: `season`, `regular_season_end` (Date; NA for 2020,
#' played in spring 2021 with no postseason), `source` (where the date came
#' from: `"wikipedia (verified vs NCAA)"` for the seeded seasons,
#' `"wikipedia"` for seasons added automatically by
#' [ensure_season_dates()], which still need a human check).
#'
#' @param path CSV path (default [season_dates_path()]).
#' @return A data frame.
#' @keywords internal
read_season_dates <- function(path = season_dates_path()) {
  d <- utils::read.csv(path, colClasses = c("integer", "character", "character"), na.strings = "")
  d$regular_season_end <- as.Date(d$regular_season_end)
  d
}

#' Read the regular-season end date off a Wikipedia season infobox
#'
#' The "YYYY NCAA Division III football season" infobox has a line like
#' `| regular_season = {{nowrap|September 1 – November 16, 2024}}`. The end
#' date is the last "Month Day (, Year)" in that value; a missing year means
#' the season year.
#'
#' @param wikitext Page wikitext.
#' @param season Season year.
#' @return Date, or NA if the field isn't there.
#' @keywords internal
parse_infobox_regular_season_end <- function(wikitext, season) {
  line <- stringr::str_match(wikitext, "\\|\\s*regular_season\\s*=\\s*([^\\n]*)")[, 2]
  if (is.na(line)) return(as.Date(NA))
  dates <- stringr::str_match_all(line, "([A-Z][a-z]+)\\s+(\\d{1,2})(?:,\\s*(\\d{4}))?")[[1]]
  if (!nrow(dates)) return(as.Date(NA))
  last <- dates[nrow(dates), ]
  yr <- if (!is.na(last[4])) as.integer(last[4]) else as.integer(season)
  as.Date(sprintf("%s %s %d", last[2], last[3], yr), format = "%B %d %Y")
}

#' Fetch a season's regular-season end date from Wikipedia
#'
#' Reads the infobox of "YYYY NCAA Division III football season" via
#' the Wikipedia API (one request).
#'
#' @param season Season year.
#' @return Date, or NA if not found.
#' @keywords internal
fetch_wikipedia_regular_season_end <- function(season) {
  throttle()
  .fetch_state$n_requests <- n_requests() + 1L
  resp <- httr2::request("https://en.wikipedia.org/w/api.php") |>
    httr2::req_url_query(action = "parse", page = paste(season, "NCAA Division III football season"),
                         prop = "wikitext", format = "json", formatversion = 2, redirects = 1) |>
    httr2::req_user_agent("d3ballR (R package; https://github.com/sclaversam/d3ballR)") |>
    httr2::req_retry(max_tries = 3) |>
    httr2::req_perform()
  w <- httr2::resp_body_json(resp)$parse$wikitext
  if (is.null(w)) return(as.Date(NA))
  parse_infobox_regular_season_end(w, season)
}

#' "Two Saturdays before Thanksgiving"
#'
#' Thanksgiving is the fourth Thursday of November; the rule date is the
#' Saturday 12 days before it (the Saturday before the Saturday before
#' Thanksgiving). Used only as a sanity check on the table.
#'
#' @param season Integer vector.
#' @return Date vector.
#' @keywords internal
two_saturdays_before_thanksgiving <- function(season) {
  nov1 <- as.Date(sprintf("%d-11-01", season))
  first_thu <- nov1 + ((4L - as.integer(format(nov1, "%w"))) %% 7L)
  thanksgiving <- first_thu + 21L
  thanksgiving - 12L
}

#' Compare every regular-season end date with the Thanksgiving rule
#'
#' Warns on each disagreement. Expected and harmless: 2023, whose infobox
#' lists Sunday Nov 12 while the last game day (and the rule) is Saturday
#' Nov 11. Both classify every game the same way, since nothing is played on
#' that Sunday.
#'
#' @param season_dates Output of [read_season_dates()].
#' @param warn Emit warnings for disagreements.
#' @return Data frame: `season`, `regular_season_end`, `rule_date`,
#'   `agrees`, `note`.
#' @export
check_season_dates <- function(season_dates = read_season_dates(), warn = TRUE) {
  rule <- two_saturdays_before_thanksgiving(season_dates$season)
  end <- season_dates$regular_season_end
  agrees <- is.na(end) | end == rule
  note <- ifelse(is.na(end), "no postseason (NA)",
                 ifelse(agrees, "",
                        ifelse(end == rule + 1L,
                               "table date is the Sunday after the rule Saturday (last game day); harmless",
                               "DISAGREES: verify")))
  out <- data.frame(season = season_dates$season, regular_season_end = end, rule_date = rule,
                    agrees = agrees, note = note)
  if (warn) {
    for (i in which(!out$agrees)) {
      warning("regular_season_end for ", out$season[i], " (", out$regular_season_end[i],
              ") differs from two Saturdays before Thanksgiving (", out$rule_date[i], "): ",
              out$note[i], call. = FALSE)
    }
  }
  out
}

#' Make sure the season-dates table covers the given seasons
#'
#' For each season missing from the table, fetches its Wikipedia page
#' ([fetch_wikipedia_regular_season_end()]), appends the date with
#' `source = "wikipedia"`, writes the CSV back, and logs that it was added
#' so it can be verified. Working from the source folder (`load_all()`),
#' "back" is `inst/extdata/season_dates.csv`, so the new season can be
#' committed; with an installed package it is the user copy (see
#' [season_dates_path()]). Then compares every date with the Thanksgiving
#' rule ([check_season_dates()]), warning on disagreements.
#'
#' @param seasons Integer vector of seasons needed.
#' @param path CSV path (default [season_dates_path()]).
#' @return The (possibly extended) season-dates table.
#' @export
ensure_season_dates <- function(seasons, path = season_dates_path()) {
  d <- read_season_dates(path)
  missing <- setdiff(unique(stats::na.omit(as.integer(seasons))), d$season)
  if (!length(missing)) return(d)
  for (s in missing) {
    end <- fetch_wikipedia_regular_season_end(s)
    if (is.na(end)) {
      stop("Could not read a regular season end date for ", s,
           " from Wikipedia; add it to ", path, " by hand.")
    }
    d <- rbind(d, data.frame(season = s, regular_season_end = end, source = "wikipedia"))
    message("Added season ", s, " to ", path, ": regular_season_end = ", end,
            " (source: wikipedia). Please verify against the NCAA championship selection announcement.")
  }
  d <- d[order(d$season), ]
  out <- d
  out$regular_season_end <- format(out$regular_season_end, "%Y-%m-%d")
  if (in_installed_library(path)) {
    path <- season_dates_user_path()
    dir.create(dirname(path), showWarnings = FALSE, recursive = TRUE)
    message("Saved the season dates to ", path, " (the installed package's copy is left as is).")
  }
  utils::write.csv(out, path, row.names = FALSE, na = "")
  check_season_dates(d)
  d
}

#' Regular season or postseason, from the game date
#'
#' "postseason" if `game_date > regular_season_end` for that season, else
#' "regular". A season with no end date (2020) is all "regular". Stops if
#' a season isn't in the table (see [ensure_season_dates()]).
#'
#' @param game_date Date vector.
#' @param season Integer vector (the season the game belongs to, never read
#'   off the date: January games belong to the season before).
#' @param season_dates Output of [read_season_dates()].
#' @return Character vector.
#' @keywords internal
classify_season_type <- function(game_date, season, season_dates) {
  end <- season_dates$regular_season_end[match(season, season_dates$season)]
  if (any(!season %in% season_dates$season)) {
    stop("No regular_season_end for season(s): ",
         paste(unique(season[!season %in% season_dates$season]), collapse = ", "),
         ". Call ensure_season_dates() first.")
  }
  ifelse(!is.na(end) & game_date > end, "postseason", "regular")
}

