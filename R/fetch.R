# Shared request bookkeeping for every network call d3ballR makes
# (ncaa.com's data server in R/ncaa.R, Wikipedia in R/season_dates.R): a
# per-run request counter, the list of paths that failed this run, and a
# throttle. Moved here from the old d3football scraper (2026-11-17).

.fetch_state <- new.env(parent = emptyenv())

#' Number of network requests made since the last [reset_fetch_state()]
#' @keywords internal
n_requests <- function() if (is.null(.fetch_state$n_requests)) 0L else .fetch_state$n_requests

#' Start a run: reset the request counter and the list of ncaa.com paths
#' that returned an HTTP error
#'
#' [build_season()] calls this at the start of each run, so its
#' `max_requests` cap counts this run's requests only, and a path that
#' failed in an earlier run is asked again.
#' @export
reset_fetch_state <- function() {
  .fetch_state$n_requests <- 0L
  .fetch_state$http_failed <- character()
  invisible(NULL)
}

#' Wait so network requests are at least `d3ballR.delay` seconds apart
#'
#' Package-wide: the time of the last request is kept between calls, so
#' requests from different functions are spaced too. Default 3 seconds;
#' [build_season()] sets 6.
#' @keywords internal
throttle <- function() {
  delay <- getOption("d3ballR.delay", 3)
  last <- .fetch_state$last_request
  if (!is.null(last)) {
    wait <- delay - as.numeric(difftime(Sys.time(), last, units = "secs"))
    if (wait > 0) Sys.sleep(wait)
  }
  .fetch_state$last_request <- Sys.time()
}
