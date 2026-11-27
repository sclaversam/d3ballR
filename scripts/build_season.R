# Build a season's play-by-play into pbp/{season}/ with reports in
# checks/{season}/. Thin wrapper around build_season(). The play-by-play is
# requested from ncaa.com directly (no server needed; see fetch_ncaa_json()).
#
#   Rscript scripts/build_season.R 2025                      # every game
#   Rscript scripts/build_season.R 2025 --conference CC      # games involving Centennial teams
#   Rscript scripts/build_season.R 2025 --max-requests 20    # cap new requests this run
#   Rscript scripts/build_season.R 2025 --delay 15           # seconds between requests (default 6)
#   OFFLINE=1 Rscript scripts/build_season.R 2025            # cache only, no requests
#
# Every call rebuilds all games already in the output folder as well, and
# anything not fetched (budget reached, or no play-by-play on ncaa.com yet)
# is listed as pending in the report, so rerunning continues where the last
# run stopped.

devtools::load_all(quiet = TRUE)
options(d3ballR.dir = ".")  # the repo's data-raw/ (see d3_root())

args <- commandArgs(trailingOnly = TRUE)
season <- as.integer(args[1])
opt <- function(name) {
  i <- match(name, args)
  if (is.na(i)) NULL else args[i + 1]
}
if (nzchar(Sys.getenv("OFFLINE"))) options(d3ballR.offline = TRUE)

code <- opt("--conference")
# conference members: the team-to-conference table read off ncaa.com's
# scoreboards (data-raw/ncaa/{season}_conferences.csv)
members <- function(code) {
  f <- file.path("data-raw", "ncaa", paste0(season, "_conferences.csv"))
  if (!file.exists(f)) ncaa_conference_table(season, ncaa_season_games(season))
  tab <- utils::read.csv(f, na.strings = "")
  hit <- tab$team[tab$conference_code %in% code]
  if (!length(hit)) stop("No teams with conference code ", code, " in ", f)
  hit
}
teams <- if (is.null(code)) NULL else members(code)
max_requests <- if (is.null(opt("--max-requests"))) Inf else as.numeric(opt("--max-requests"))
delay <- if (is.null(opt("--delay"))) 6 else as.numeric(opt("--delay"))

build_season(season, teams = teams, max_requests = max_requests, delay = delay,
             out_dir = file.path("pbp", season), check_dir = file.path("checks", season))
cat(readLines(file.path("checks", season, "build_report.md")), sep = "\n")
