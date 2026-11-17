# Build a season's play-by-play into pbp/{season}/ with reports in
# checks/{season}/. Thin wrapper around build_season(). The play-by-play
# is requested from ncaa.com directly (no server needed; see
# fetch_ncaa_json()).
#
#   Rscript scripts/build_season.R 2025                      # every game
#   Rscript scripts/build_season.R 2025 --conference CC      # games involving Centennial teams
#   Rscript scripts/build_season.R 2025 --max-requests 20    # cap new requests this run
#   Rscript scripts/build_season.R 2025 --delay 15           # seconds between requests (default 6)
#   OFFLINE=1 Rscript scripts/build_season.R 2025            # cache only, no requests
#
# Every call rebuilds all games already in the output folder as well, and
# anything not fetched (budget reached, or no play-by-play on ncaa.com yet) is listed
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
# conference members: the saved team-to-conference table, else one built
# from ncaa.com's (cached) scoreboards
members <- function(code) {
  conf <- load_cached_conferences(season)
  if (is.null(conf)) conf <- ncaa_conference_table(season, ncaa_season_games(season))
  hit <- conf$table$team[conf$table$conference_code %in% code]
  if (!length(hit)) stop("No teams in conference ", code, " for ", season, call. = FALSE)
  hit
}
teams <- if (is.null(code)) NULL else members(code)
max_requests <- if (is.null(opt("--max-requests"))) Inf else as.numeric(opt("--max-requests"))

delay <- if (is.null(opt("--delay"))) 6 else as.numeric(opt("--delay"))

build_season(season, teams = teams, max_requests = max_requests, delay = delay)
cat(readLines(file.path("checks", season, "build_report.md")), sep = "\n")
