# Build a season's play-by-play into pbp/{season}/ with reports in
# checks/{season}/ (pbp/d3football/{season}/ and checks/d3football/{season}/
# with --source d3football). Thin wrapper around build_season(). The play-by-play
# comes from ncaa.com through the local ncaa-api server (Docker container
# "ncaa-api" on 127.0.0.1:3000); add --source d3football to read cached
# d3football pages instead.
#
#   Rscript scripts/build_season.R 2025                      # every game
#   Rscript scripts/build_season.R 2025 --conference CC      # games involving Centennial teams
#   Rscript scripts/build_season.R 2025 --max-requests 20    # cap new requests this run
#   Rscript scripts/build_season.R 2025 --delay 15           # seconds between requests (default 6)
#   OFFLINE=1 Rscript scripts/build_season.R 2025            # cache only, no requests
#   Rscript scripts/build_season.R 2025 --source d3football  # old source (cached pages only)
#
# Every call rebuilds all games already in the output folder as well, and
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
# conference members: the cached team-to-conference table when it has the
# conference, else the d3football standings page
members <- function(code) {
  conf <- load_cached_conferences(season)
  hit <- if (!is.null(conf)) conf$table$team[conf$table$conference_code %in% code] else character()
  if (length(hit)) hit else conference_members(season, code)$team
}
teams <- if (is.null(code)) NULL else members(code)
max_requests <- if (is.null(opt("--max-requests"))) Inf else as.numeric(opt("--max-requests"))

delay <- if (is.null(opt("--delay"))) 6 else as.numeric(opt("--delay"))

source <- if (is.null(opt("--source"))) "ncaa" else opt("--source")

build_season(season, teams = teams, max_requests = max_requests, delay = delay, source = source)
check_dir <- if (source == "ncaa") file.path("checks", season) else file.path("checks", "d3football", season)
cat(readLines(file.path(check_dir, "build_report.md")), sep = "\n")
