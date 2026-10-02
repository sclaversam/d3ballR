#' Fetch a d3football page as parsed HTML (cached, throttled)
#'
#' Sends a browser-like request (d3football blocks default agents) and returns
#' the parsed HTML document for rvest to query.
#'
#' Every page is cached on disk (`getOption("d3ballR.cache_dir")`, default
#' `data-raw/cache/`, which is gitignored) and served from the cache on
#' later calls, so a page is never requested twice. Network requests are
#' throttled package-wide to at least `getOption("d3ballR.delay")` seconds
#' apart (default 3). Set `refresh = TRUE` to bypass the cache, or the cache
#' option to `NULL` to disable caching. Empty or failed responses are not
#' cached. With `options(d3ballR.offline = TRUE)` nothing is requested: an
#' uncached page is an error (useful when d3football is refusing requests).
#'
#' @param url Full page URL, including the `?view=...` suffix when needed.
#' @param user_agent Browser User-Agent string.
#' @param refresh Re-fetch even if cached.
#' @return A parsed HTML document (`xml_document`).
#' @keywords internal
fetch_html <- function(url, user_agent = default_user_agent(), refresh = FALSE) {
  cache_dir <- getOption("d3ballR.cache_dir", "data-raw/cache")
  path <- if (!is.null(cache_dir)) file.path(cache_dir, cache_key(url)) else NULL
  if (!refresh && !is.null(path) && file.exists(path)) {
    return(xml2::read_html(path, encoding = "UTF-8"))
  }
  if (isTRUE(getOption("d3ballR.offline", FALSE))) {
    stop("Offline (option d3ballR.offline = TRUE) and not cached: ", url, call. = FALSE)
  }
  throttle()
  html <- httr2::request(url) |>
    httr2::req_user_agent(user_agent) |>
    httr2::req_retry(max_tries = 3) |>
    httr2::req_timeout(30) |>
    httr2::req_perform() |>
    httr2::resp_body_string()
  if (!is.null(path) && nchar(html) > 0) {
    dir.create(cache_dir, showWarnings = FALSE, recursive = TRUE)
    writeLines(html, path, useBytes = TRUE)
  }
  xml2::read_html(html)
}

#' File name for a cached URL
#' @param url URL.
#' @keywords internal
cache_key <- function(url) {
  key <- sub("^https?://(www\\.)?d3football\\.com/", "", url)
  paste0(gsub("[^A-Za-z0-9._-]+", "_", key), ".html")
}

.d3_state <- new.env(parent = emptyenv())

#' Wait so network requests are at least `d3ballR.delay` seconds apart
#' @keywords internal
throttle <- function() {
  delay <- getOption("d3ballR.delay", 3)
  last <- .d3_state$last_request
  if (!is.null(last)) {
    wait <- delay - as.numeric(difftime(Sys.time(), last, units = "secs"))
    if (wait > 0) Sys.sleep(wait)
  }
  .d3_state$last_request <- Sys.time()
}

#' Default browser User-Agent
#' @return A character scalar.
#' @keywords internal
default_user_agent <- function() {
  paste("Mozilla/5.0 (Windows NT 10.0; Win64; x64)",
        "AppleWebKit/537.36 (KHTML, like Gecko)",
        "Chrome/125.0.0.0 Safari/537.36")
}

#' Convert every HTML table on a page to a list of data frames
#'
#' @param html A parsed HTML document (from [fetch_html()]).
#' @return A list of data frames, one per `<table>` on the page.
#' @keywords internal
tables_on <- function(html) {
  lapply(rvest::html_elements(html, "table"), rvest::html_table, fill = TRUE)
}

#' Locate and return the play-by-play table
#'
#' Selects the play-by-play table from a page's tables by content (a
#' down-and-distance line in column 1), not by position. Squishes whitespace to
#' fix the newline the 2025 markup embeds in the situation text
#' (e.g. "1st\\n and 10 at CMU35").
#'
#' @param tbls A list of data frames (from [tables_on()]).
#' @return A tibble with columns `situation` and `play`, whitespace cleaned.
#'   Stops with an error if no table qualifies.
#' @keywords internal
find_plays <- function(tbls) {
  for (t in tbls) {
    if (ncol(t) >= 2) {
      col1 <- stringr::str_squish(as.character(t[[1]]))
      if (any(stringr::str_detect(col1, "[1-4](st|nd|rd|th)\\s+and\\s+.*\\bat\\b"),
              na.rm = TRUE)) {
        return(tibble::tibble(
          situation = stringr::str_squish(as.character(t[[1]])),
          play      = stringr::str_squish(as.character(t[[2]]))
        ))
      }
    }
  }
  stop("No play-by-play table found. Open the page and check the layout.")
}

#' Scrape one game's raw play-by-play table
#'
#' Convenience wrapper: fetch the plays view of a boxscore and return its
#' cleaned two-column table.
#'
#' @param game_url Boxscore URL without the `?view=` suffix.
#' @return A tibble with columns `situation` and `play`.
#' @export
scrape_plays <- function(game_url) {
  find_plays(tables_on(fetch_html(paste0(game_url, "?view=plays"))))
}
