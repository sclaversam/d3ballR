# Shared state for every network request d3ballR makes (ncaa.com, see
# [fetch_ncaa_json()]): a request counter for the `d3ballR.max_requests`
# budget, the throttle's last-request time, and the ncaa.com paths that
# returned an HTTP error this run.
.d3_state <- new.env(parent = emptyenv())

#' Number of network requests made since the last [reset_fetch_state()]
#' @keywords internal
n_requests <- function() if (is.null(.d3_state$n_requests)) 0L else .d3_state$n_requests

#' Reset the request counter and the list of ncaa.com paths that returned
#' an HTTP error (start of a run)
#' @export
reset_fetch_state <- function() {
  .d3_state$n_requests <- 0L
  .d3_state$http_failed <- character()
  invisible(NULL)
}

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
