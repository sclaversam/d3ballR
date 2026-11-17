# the table that ships with the package (inst/extdata/), whichever way the
# tests run: from the source folder or from R CMD check's installed copy
shipped_dates <- function() system.file("extdata", "season_dates.csv", package = "d3ballR", mustWork = TRUE)

sd <- data.frame(season = c(2020L, 2024L, 2025L),
                 regular_season_end = as.Date(c(NA, "2024-11-16", "2025-11-15")))

test_that("season_type uses regular_season_end; 2020 is all regular", {
  expect_equal(
    classify_season_type(as.Date(c("2025-11-15", "2025-11-22", "2021-04-10")), c(2025L, 2025L, 2020L), sd),
    c("regular", "postseason", "regular")
  )
})

test_that("date-based week: first Saturday of September is week 1; postseason restarts at 1", {
  d <- as.Date(c("2025-09-04", "2025-09-06", "2025-09-13", "2025-11-15", "2025-11-22", "2025-12-20"))
  st <- classify_season_type(d, 2025L, sd)
  expect_equal(date_based_week(d, 2025L, st, sd), c(1L, 1L, 2L, 11L, 1L, 5L))
  # 2024: d3's week 1 includes Sunday Sep 8, which a Sun-Sat count puts in week 2
  expect_equal(date_based_week(as.Date(c("2024-09-07", "2024-09-08")), 2024L, "regular", sd), c(1L, 2L))
})

test_that("the Wikipedia infobox regular_season line parses to its end date", {
  w <- "{{Infobox college football season\n| type = NCAA Division III\n| year = 2024\n| regular_season = {{nowrap|September 1 – November 16, 2024}}\n| playoffs = {{nowrap|November 23 – January 5, 2025}}\n}}"
  expect_equal(parse_infobox_regular_season_end(w, 2024), as.Date("2024-11-16"))
  expect_equal(parse_infobox_regular_season_end("| regular_season = September 6 – November 15", 2025), as.Date("2025-11-15"))
  expect_true(is.na(parse_infobox_regular_season_end("{{Infobox}}", 2025)))
})

test_that("seeded dates match two Saturdays before Thanksgiving, except 2023 (harmless)", {
  chk <- suppressWarnings(check_season_dates(read_season_dates(shipped_dates())))
  expect_equal(chk$season[!chk$agrees], 2023L)
  expect_match(chk$note[chk$season == 2023], "Sunday after")
  expect_warning(check_season_dates(read_season_dates(shipped_dates())), "2023")
  expect_equal(two_saturdays_before_thanksgiving(c(2019L, 2023L, 2025L)), as.Date(c("2019-11-16", "2023-11-11", "2025-11-15")))
})

test_that("ensure_season_dates appends a missing season from Wikipedia and logs it", {
  path <- withr::local_tempfile(fileext = ".csv")
  file.copy(shipped_dates(), path)
  local_mocked_bindings(fetch_wikipedia_regular_season_end = function(season) as.Date("2018-11-10"))
  expect_message(d <- suppressWarnings(ensure_season_dates(2018L, path)), "Added season 2018")
  expect_equal(d$source[d$season == 2018], "wikipedia")
  expect_equal(read_season_dates(path)$regular_season_end[read_season_dates(path)$season == 2018], as.Date("2018-11-10"))
  expect_silent(ensure_season_dates(2025L, path))  # present: no fetch, no write
})

test_that("on an installed package, added seasons go to the user copy, not the package", {
  lib <- withr::local_tempdir()
  path <- file.path(lib, "d3ballR", "extdata", "season_dates.csv")
  dir.create(dirname(path), recursive = TRUE)
  file.copy(shipped_dates(), path)
  user <- file.path(withr::local_tempdir(), "season_dates.csv")
  withr::local_libpaths(lib, action = "prefix")
  local_mocked_bindings(fetch_wikipedia_regular_season_end = function(season) as.Date("2018-11-10"),
                        season_dates_user_path = function() user)
  expect_true(in_installed_library(path))
  suppressMessages(suppressWarnings(ensure_season_dates(2018L, path)))
  expect_false(2018L %in% read_season_dates(path)$season)   # shipped copy untouched
  expect_true(2018L %in% read_season_dates(user)$season)
  withr::local_options(d3ballR.season_dates = NULL)
  expect_equal(season_dates_path(), user)                   # and the user copy is read from now on
})
