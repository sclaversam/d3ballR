#' The folder d3ballR keeps its working files in
#'
#' Everything [build_season()] reads or writes by default (the ncaa.com
#' response cache in `data-raw/cache/ncaa/`, the game lists and conference
#' tables in `data-raw/ncaa/`, saved stats.ncaa.org pages in
#' `data-raw/stats_ncaa/`) lives under one root:
#' 1. `options(d3ballR.dir = path)`, if set;
#' 2. else the working directory, when it is the d3ballR source folder (a
#'    `DESCRIPTION` with `Package: d3ballR`), so the repo's `data-raw/` is
#'    used as before;
#' 3. else `tools::R_user_dir("d3ballR", "cache")`, R's per-user cache
#'    folder, for an installed copy of the package.
#'
#' @return A folder path.
#' @keywords internal
d3_root <- function() {
  opt <- getOption("d3ballR.dir")
  if (!is.null(opt)) return(opt)
  if (is_d3ballr_source(".")) return(".")
  tools::R_user_dir("d3ballR", "cache")
}

#' A path under [d3_root()]
#' @param ... Path parts, as in [file.path()].
#' @keywords internal
d3_dir <- function(...) file.path(d3_root(), ...)

#' Is a folder the d3ballR source folder?
#' @param dir Folder.
#' @keywords internal
is_d3ballr_source <- function(dir) {
  f <- file.path(dir, "DESCRIPTION")
  file.exists(f) && any(readLines(f, warn = FALSE) == "Package: d3ballR")
}
