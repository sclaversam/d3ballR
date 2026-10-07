#' Read the regular-season end dates
#'
#' One row per season: `season`, `regular_season_end` (Date; NA for 2020,
#' played in spring 2021 with no postseason), `source` (where the date came
#' from: `"wikipedia (verified vs NCAA)"` for the seeded seasons,
#' `"wikipedia"` for seasons added automatically by
#' [ensure_season_dates()], which still need a human check).
#'
#' @param path CSV path (default `data-raw/season_dates.csv`).
#' @return A data frame.
#' @keywords internal
read_season_dates <- function(path = "data-raw/season_dates.csv") {
  d <- utils::read.csv(path, colClasses = c("integer", "character", "character"), na.strings = "")
  d$regular_season_end <- as.Date(d$regular_season_end)
  d
}

#' Read the regular-season end date off a Wikipedia season infobox
#'
#' The "{season} NCAA Division III football season" infobox has a line like
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
#' Reads the infobox of "{season} NCAA Division III football season" via
#' the Wikipedia API (one request).
#'
#' @param season Season year.
#' @return Date, or NA if not found.
#' @keywords internal
fetch_wikipedia_regular_season_end <- function(season) {
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
#' so it can be verified. Then compares every date with the Thanksgiving
#' rule ([check_season_dates()]), warning on disagreements.
#'
#' @param seasons Integer vector of seasons needed.
#' @param path CSV path.
#' @return The (possibly extended) season-dates table.
#' @export
ensure_season_dates <- function(seasons, path = "data-raw/season_dates.csv") {
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
#' @param season Integer vector (from the boxscore URL path, never the date).
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

#' Date-based week number (Sunday-to-Saturday)
#'
#' The fallback when a game isn't in the season index, and the cross-check
#' against the scoreboard's week in the index report. Weeks run Sunday to
#' Saturday. Regular-season week 1 is the week of the season's first
#' Saturday in September (d3's own week 1 in 2019, 2024 and 2025).
#' Postseason weeks restart at 1 (cfbfastR) with the week of the first
#' Saturday after `regular_season_end`. For a season whose games aren't in
#' the fall (2020, played in spring 2021), pass `regular_anchor`: the
#' earliest game date of the season.
#'
#' @param game_date Date vector.
#' @param season Integer vector.
#' @param season_type "regular" / "postseason".
#' @param season_dates Output of [read_season_dates()].
#' @param regular_anchor Optional Date: overrides the first-Saturday-of-
#'   September anchor for regular-season weeks.
#' @return Integer vector.
#' @keywords internal
date_based_week <- function(game_date, season, season_type, season_dates, regular_anchor = NULL) {
  sunday_on_or_before <- function(d) d - as.integer(format(d, "%w"))
  first_sat_sept <- function(y) {
    d <- as.Date(sprintf("%d-09-01", y))
    d + ((6L - as.integer(format(d, "%w"))) %% 7L)
  }
  reg_anchor <- if (!is.null(regular_anchor)) {
    rep(sunday_on_or_before(regular_anchor), length(game_date))
  } else {
    sunday_on_or_before(first_sat_sept(season))
  }
  end <- season_dates$regular_season_end[match(season, season_dates$season)]
  first_post_sat <- end + ((6L - as.integer(format(end, "%w"))) %% 7L)
  first_post_sat <- ifelse(!is.na(end) & first_post_sat <= end, first_post_sat + 7L, first_post_sat)
  post_anchor <- sunday_on_or_before(as.Date(first_post_sat, origin = "1970-01-01"))
  anchor <- as.Date(ifelse(season_type == "postseason", post_anchor, reg_anchor), origin = "1970-01-01")
  as.integer(floor(as.numeric(game_date - anchor) / 7)) + 1L
}

#' Parse one d3football weekly scoreboard page
#'
#' The composite scoreboard (`/scoreboard/{season}/composite?view=N`) lists
#' one week's games in a single table: Date ("Sep. 6", no year), Away
#' (optional "No. N" ranking + team link), away score, Home, home score,
#' status, and links ("BX" = boxscore). A row with an empty date cell is a
#' note on the game above it ("@ Canton, Ohio" = neutral site). There are no
#' round or bowl labels: NCAA playoff and bowl games share the table.
#'
#' @param html Parsed page.
#' @param season Season the page belongs to.
#' @param view The page's `view=` number.
#' @return Data frame, one row per game (may be zero rows).
#' @keywords internal
parse_scoreboard_page <- function(html, season, view) {
  rows <- rvest::html_elements(html, xpath = "//div[contains(@class,'schedule')]//table//tr[td]")
  if (!length(rows)) return(NULL)
  cells <- lapply(rows, function(r) rvest::html_elements(r, xpath = "./td"))
  team_of <- function(td) {
    a <- rvest::html_element(td, "a")
    nm <- if (!is.na(a)) rvest::html_text(a) else rvest::html_text(td)
    stringr::str_squish(stringr::str_remove(stringr::str_squish(nm), "^No\\. \\d+\\s*"))
  }
  out <- list()
  for (i in seq_along(cells)) {
    td <- cells[[i]]
    first <- stringr::str_squish(rvest::html_text(td[[1]]))
    if (length(td) < 7 || first == "") {
      # note row: attach to the previous game (neutral-site location)
      if (length(out)) out[[length(out)]]$site_note <- stringr::str_squish(rvest::html_text(rows[[i]]))
      next
    }
    links <- rvest::html_attr(rvest::html_elements(td[[7]], "a"), "href")
    bx <- links[grepl("/boxscores/", links)][1]
    out[[length(out) + 1]] <- data.frame(
      date_text = first,
      away = team_of(td[[2]]),
      away_score = suppressWarnings(as.integer(stringr::str_squish(rvest::html_text(td[[3]])))),
      home = team_of(td[[4]]),
      home_score = suppressWarnings(as.integer(stringr::str_squish(rvest::html_text(td[[5]])))),
      status = stringr::str_squish(rvest::html_text(td[[6]])),
      boxscore_path = if (is.na(bx)) NA_character_ else bx,
      site_note = NA_character_,
      scoreboard_view = as.integer(view),
      page_season = as.integer(season)
    )
  }
  do.call(rbind, out)
}

#' Turn scoreboard rows into the season index
#'
#' - `game_id` and `boxscore_url` from the boxscore link (NA when d3 has no
#'   boxscore, e.g. a cancelled game).
#' - `season` from the `/seasons/{year}/` URL path, never from the date, so
#'   January games and the spring-2021 "2020" season are labelled right.
#' - `game_date` from the boxscore id (YYYYMMDD); without a boxscore, from
#'   the "Sep. 6" text, with the year taken as `season` for July-December
#'   and `season + 1` for January-June.
#' - `season_type` by [classify_season_type()].
#' - `week`: the scoreboard view number for regular-season games;
#'   postseason weeks restart at 1 (cfbfastR): `view - first_postseason_view
#'   + 1`.
#'
#' @param raw Rows from [parse_scoreboard_page()].
#' @param season_dates Output of [read_season_dates()].
#' @return The index data frame.
#' @keywords internal
finalize_season_index <- function(raw, season_dates) {
  base <- "https://www.d3football.com"
  path <- raw$boxscore_path
  game_id <- stringr::str_match(path, "/boxscores/([^./]+)\\.xml")[, 2]
  url_season <- as.integer(stringr::str_match(path, "/seasons/(\\d{4})/")[, 2])
  season <- dplyr::coalesce(url_season, raw$page_season)

  id_date <- as.Date(stringr::str_match(game_id, "^(\\d{8})")[, 2], format = "%Y%m%d")
  m <- stringr::str_match(raw$date_text, "^([A-Za-z]+)\\.? (\\d{1,2})")
  mon <- match(substr(tolower(m[, 2]), 1, 3), tolower(month.abb))
  yr <- ifelse(mon >= 7, season, season + 1L)
  text_date <- as.Date(sprintf("%d-%02d-%02d", yr, mon, as.integer(m[, 3])))
  game_date <- dplyr::coalesce(id_date, text_date)

  season_type <- classify_season_type(game_date, season, season_dates)
  first_post_view <- tapply(raw$scoreboard_view[season_type == "postseason"],
                            season[season_type == "postseason"], min)
  fpv <- first_post_view[as.character(season)]
  week <- ifelse(season_type == "postseason", raw$scoreboard_view - fpv + 1L, raw$scoreboard_view)

  idx <- data.frame(
    game_id = game_id, season = season, game_date = format(game_date, "%Y-%m-%d"),
    week = as.integer(week), season_type = season_type,
    home = raw$home, away = raw$away,
    boxscore_url = ifelse(is.na(path), NA_character_, paste0(base, path)),
    scoreboard_view = raw$scoreboard_view, status = raw$status,
    away_score = raw$away_score, home_score = raw$home_score, site_note = raw$site_note,
    date_text = raw$date_text, text_date = format(text_date, "%Y-%m-%d")
  )
  idx <- idx[is.na(idx$game_id) | !duplicated(idx$game_id), ]
  idx[order(idx$game_date, idx$game_id), ]
}

#' Build (or load) the index of every game in a d3football season
#'
#' Loops over the weekly composite scoreboard pages
#' (`https://www.d3football.com/scoreboard/{season}/composite?view=N`),
#' starting at view 1 and stopping after two consecutive views with no
#' games (pages past the season's last week come back empty), and returns
#' one row per game. Requests are throttled (`delay` seconds apart) and
#' sent with a browser User-Agent. The result is cached to
#' `{cache_dir}/{season}.csv` and the cache is reused unless
#' `refresh = TRUE`.
#'
#' @param season Season year, e.g. 2025 (the 2020 season was played in
#'   spring 2021).
#' @param refresh Re-scrape even if a cached index exists.
#' @param cache_dir Cache directory.
#' @param delay Seconds to wait between requests.
#' @param max_views Safety cap on the number of views tried.
#' @param season_dates_path Path to `season_dates.csv`.
#' @return Data frame: `game_id`, `season`, `game_date` (ISO), `week`,
#'   `season_type`, `home`, `away`, `boxscore_url`, then provenance columns
#'   `scoreboard_view`, `status`, `away_score`, `home_score`, `site_note`
#'   (e.g. "@ Canton, Ohio" for a neutral site), `date_text`, `text_date`.
#'   `game_id` / `boxscore_url` are NA for games d3 has no boxscore for.
#' @export
build_season_index <- function(season, refresh = FALSE, cache_dir = "data-raw/index",
                               delay = 3, max_views = 30,
                               season_dates_path = "data-raw/season_dates.csv") {
  cache <- file.path(cache_dir, paste0(season, ".csv"))
  if (!refresh && file.exists(cache)) {
    return(utils::read.csv(cache, na.strings = "", colClasses = c(game_id = "character")))
  }
  old <- options(d3ballR.delay = delay)
  on.exit(options(old), add = TRUE)
  pages <- list()
  empties <- 0L
  for (v in seq_len(max_views)) {
    url <- sprintf("https://www.d3football.com/scoreboard/%d/composite?view=%d", season, v)
    html <- tryCatch(fetch_html(url, refresh = refresh), error = function(e) NULL)
    rows <- if (is.null(html)) NULL else parse_scoreboard_page(html, season, v)
    if (is.null(rows) || !nrow(rows)) {
      empties <- empties + 1L
      if (empties >= 2L) break
      next
    }
    empties <- 0L
    pages[[length(pages) + 1]] <- rows
    message("season ", season, " view ", v, ": ", nrow(rows), " games")
  }
  if (!length(pages)) stop("No scoreboard games found for season ", season)
  idx <- finalize_season_index(do.call(rbind, pages), ensure_season_dates(season, season_dates_path))
  dir.create(cache_dir, showWarnings = FALSE, recursive = TRUE)
  utils::write.csv(idx, cache, row.names = FALSE, na = "")
  idx
}

#' Games involving a team, from a season index
#'
#' @param index Output of [build_season_index()].
#' @param team Team name as the scoreboard spells it (e.g. "Carnegie Mellon").
#' @return The matching index rows.
#' @export
index_team_games <- function(index, team) {
  index[index$home == team | index$away == team, ]
}
