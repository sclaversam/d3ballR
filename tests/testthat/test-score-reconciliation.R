# Data test: every built game's points by team (from score_pts) must equal
# the boxscore's line-score final, recorded in
# checks/{season}/pbp_row_counts.csv by build_all_pbp(). Runs on
# every season folder in pbp/.

test_that("sum of score_pts by team equals the boxscore final score, for every built game", {
  top <- test_path("../..")
  found <- list.files(file.path(top, "pbp"), pattern = "^\\d{4}$")
  skip_if(!length(found), "no built seasons")
  known <- load_known_exceptions(file.path(top, "data-raw/ncaa/known_exceptions.csv"))$game_id
  for (season in found) {
    pbp_dir <- file.path(top, "pbp", season)
    counts_file <- file.path(top, "checks", season, "pbp_row_counts.csv")
    expect_true(file.exists(counts_file), label = paste(season, "pbp_row_counts.csv exists"))
    if (!file.exists(counts_file)) next
    counts <- utils::read.csv(counts_file, na.strings = "", colClasses = c(game_id = "character"))
    built <- sub("\\.csv$", "", list.files(pbp_dir, pattern = "\\.csv$"))
    expect_setequal(counts$game_id, built)
    # games listed as known source gaps are checked in their own test below
    for (i in which(!counts$game_id %in% known)) {
      g <- utils::read.csv(file.path(pbp_dir, paste0(counts$game_id[i], ".csv")), na.strings = "")
      expect_identical(team_points(g, counts$away[i]), as.integer(counts$away_final[i]),
                       label = paste(counts$game_id[i], counts$away[i], "points"))
      expect_identical(team_points(g, counts$home[i]), as.integer(counts$home_final[i]),
                       label = paste(counts$game_id[i], counts$home[i], "points"))
    }
  }
})

# Known source exceptions (data-raw/ncaa/known_exceptions.csv): skipped with
# the reason, but a listed game that now reconciles fails, so the list
# doesn't go stale.
local({
  top <- test_path("../..")
  exc <- load_known_exceptions(file.path(top, "data-raw/ncaa/known_exceptions.csv"))
  for (k in seq_len(nrow(exc))) {
    id <- exc$game_id[k]
    test_that(paste("known source exception", id), {
      # game ids are ncaa.com contest ids (no season in them): find the
      # season folder that has the game
      seasons <- list.files(file.path(top, "pbp"), pattern = "^\\d{4}$")
      hit <- seasons[file.exists(file.path(top, "pbp", seasons, paste0(id, ".csv")))]
      skip_if(!length(hit), paste(id, "not built"))
      season <- hit[1]
      f <- file.path(top, "pbp", season, paste0(id, ".csv"))
      counts <- utils::read.csv(file.path(top, "checks", season, "pbp_row_counts.csv"), na.strings = "",
                                colClasses = c(game_id = "character"))
      r <- counts[counts$game_id == id, ]
      g <- utils::read.csv(f, na.strings = "")
      ok <- identical(team_points(g, r$away), as.integer(r$away_final)) &&
        identical(team_points(g, r$home), as.integer(r$home_final))
      expect_false(ok, label = paste(id, "reconciles now: remove it from known_exceptions.csv"))
      skip(paste0(id, " is a known source gap: ", exc$reason[k]))
    })
  }
})

test_that("team_points credits negative score_pts to the defense", {
  g <- data.frame(pos_team = c("A", "A", "B", "B"), def_pos_team = c("B", "B", "A", "A"),
                  score_pts = c(6L, 1L, -6L, 3L))
  expect_equal(team_points(g, "A"), 13L)
  expect_equal(team_points(g, "B"), 3L)
})

test_that("game_conferences uses the marker, not shared membership", {
  conf <- list(
    table = data.frame(team = c("Johns Hopkins", "Franklin and Marshall"), conference = "Centennial Conference"),
    markers = data.frame(game_id = c("g_conf", "g_playoff"), conference_marker = c(TRUE, FALSE))
  )
  reg <- game_conferences("g_conf", "Johns Hopkins", "Franklin and Marshall", conf)
  po <- game_conferences("g_playoff", "Johns Hopkins", "Franklin and Marshall", conf)
  expect_true(reg$conference_game)
  expect_false(po$conference_game)
  expect_true(po$shared_conference)
  expect_true(is.na(game_conferences("g_x", "Johns Hopkins", "Nobody", conf)$away_team_conference))
})
