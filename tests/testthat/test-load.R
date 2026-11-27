test_that("d3_root: the option, else the source folder, else R's user cache", {
  withr::local_options(d3ballR.dir = "/some/where")
  expect_equal(d3_root(), "/some/where")
  expect_equal(d3_dir("data-raw", "ncaa"), file.path("/some/where", "data-raw", "ncaa"))

  withr::local_options(d3ballR.dir = NULL)
  src <- withr::local_tempdir()
  writeLines(c("Package: d3ballR", "Version: 0.1.0"), file.path(src, "DESCRIPTION"))
  withr::with_dir(src, expect_equal(d3_root(), "."))
  other <- withr::local_tempdir()
  withr::with_dir(other, expect_equal(d3_root(), tools::R_user_dir("d3ballR", "cache")))
})

test_that("check_team_names passes known names and suggests close ones", {
  known <- c("Carnegie Mellon", "Trinity (TX)", "Trinity (CT)", "Case Western Reserve")
  expect_true(check_team_names("Carnegie Mellon", known))
  expect_error(check_team_names("Carnegie Melon", known), "did you mean \"Carnegie Mellon\"")
  expect_error(check_team_names("Trinity", known), "Trinity \\(CT\\)")
  expect_error(check_team_names("Nowhere State", known), "No games for: \"Nowhere State\"\\. ")
})

test_that("load_d3_games: the shipped 2025 list, with conferences and integer rounds", {
  withr::local_options(d3ballR.dir = withr::local_tempdir())  # no built copy, so the shipped one
  g <- load_d3_games(2025)
  expect_s3_class(g, "tbl_df")
  expect_equal(nrow(g), 1263)
  expect_type(g$game_id, "character")
  expect_equal(as.vector(table(g$bracket_round)), c(8, 16, 8, 4, 2, 1))
  stagg <- g[g$bracket_round %in% 6, ]
  expect_equal(stagg$game_id, "6534822")
  cmu <- g[g$home == "Carnegie Mellon", ]
  expect_true(all(cmu$home_team_conference == "Centennial Conference"))
  expect_error(load_d3_games(1999), "isn't released yet")
})

test_that("release_file downloads once, then reads the saved copy; 404 says to build", {
  cache <- withr::local_tempdir()
  local_mocked_bindings(R_user_dir = function(...) cache, .package = "tools")
  calls <- 0L
  httr2::local_mocked_responses(function(req) {
    calls <<- calls + 1L
    if (grepl("pbp_2025", req$url)) httr2::response(200, body = charToRaw("data")) else httr2::response(404)
  })
  f <- suppressMessages(release_file("pbp_2025.rds", 2025))
  expect_equal(readBin(f, "raw", 10), charToRaw("data"))
  suppressMessages(release_file("pbp_2025.rds", 2025))
  expect_equal(calls, 1L)
  suppressMessages(release_file("pbp_2025.rds", 2025, refresh = TRUE))
  expect_equal(calls, 2L)
  expect_error(suppressMessages(release_file("pbp_1999.rds", 1999)), "Build it with build_season\\(1999\\)")
})
