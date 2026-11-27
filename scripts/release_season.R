# Make a season's release files: what load_d3_pbp() and load_d3_games()
# serve to users.
#
#   Rscript scripts/release_season.R 2025
#
# 1. Rebuilds the season from the cache (offline: no ncaa.com requests),
#    the same build as pbp/{season}/ and checks/{season}/.
# 2. Saves every game in one file, release/pbp_{season}.rds (gitignored).
# 3. Copies the game list and conference table into inst/extdata/games/,
#    which ship with the package.
#
# Then upload release/pbp_{season}.rds to the GitHub release "pbp_data"
# (the command is printed at the end). Rerun after any change to the
# output, and upload with --clobber to replace the old file.

devtools::load_all(quiet = TRUE)
options(d3ballR.dir = ".", d3ballR.offline = TRUE)

season <- as.integer(commandArgs(trailingOnly = TRUE)[1])
if (is.na(season)) stop("Usage: Rscript scripts/release_season.R <season>")

pbp <- build_season(season, out_dir = file.path("pbp", season), check_dir = file.path("checks", season))
stopifnot(identical(names(pbp), pbp_columns))

dir.create("release", showWarnings = FALSE)
out <- file.path("release", paste0("pbp_", season, ".rds"))
saveRDS(pbp, out, compress = "xz")

dir.create(file.path("inst", "extdata", "games"), showWarnings = FALSE, recursive = TRUE)
for (what in c("games", "conferences")) {
  file.copy(file.path("data-raw", "ncaa", paste0(season, "_", what, ".csv")),
            file.path("inst", "extdata", "games", paste0(season, "_", what, ".csv")), overwrite = TRUE)
}

cat(sprintf("\n%s: %d plays in %d games, %.1f MB\n", out, nrow(pbp), length(unique(pbp$game_id)),
            file.size(out) / 1e6))
cat("Upload (first time: gh release create pbp_data --title 'Play-by-play data' --notes '...'):\n")
cat(sprintf("  gh release upload pbp_data %s --clobber\n", out))
