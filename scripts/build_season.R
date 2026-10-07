# Build a season's play-by-play into pbp/{season}/ with reports in
# checks/{season}/. Thin wrapper around build_season().
#
#   Rscript scripts/build_season.R 2025                      # every game
#   Rscript scripts/build_season.R 2025 --conference CC      # games involving Centennial teams
#   Rscript scripts/build_season.R 2025 --max-requests 20    # cap new requests this run
#   Rscript scripts/build_season.R 2025 --delay 15           # seconds between requests (default 6)
#   OFFLINE=1 Rscript scripts/build_season.R 2025            # cache only, no requests
#
# Every call rebuilds all games already in pbp/{season}/ as well, and
# anything not fetched (budget reached, or d3football rate-limiting) is listed
# as pending in the report, so rerunning continues where the last run stopped.

devtools::load_all(quiet = TRUE)

args <- commandArgs(trailingOnly = TRUE)
season <- as.integer(args[1])
opt <- function(name) {
  i <- match(name, args)
  if (is.na(i)) NULL else args[i + 1]
}
if (nzchar(Sys.getenv("OFFLINE"))) options(d3ballR.offline = TRUE)

code <- opt("--conference")
teams <- if (is.null(code)) NULL else conference_members(season, code)$team
max_requests <- if (is.null(opt("--max-requests"))) Inf else as.numeric(opt("--max-requests"))

delay <- if (is.null(opt("--delay"))) 6 else as.numeric(opt("--delay"))

build_season(season, teams = teams, max_requests = max_requests, delay = delay)
cat(readLines(file.path("checks", season, "build_report.md")), sep = "\n")
