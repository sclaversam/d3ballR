test_that("find_plays picks the down-and-distance table and cleans whitespace", {
  tbls <- list(
    data.frame(a = "header", b = "block"),
    data.frame(
      X1 = c("1st\n and 10 at CMU35", "Chicago at 15:00"),
      X2 = c("Shotgun rush for 3 yards", "UChicago drive start at 15:00.")
    )
  )
  out <- find_plays(tbls)
  expect_named(out, c("situation", "play"))
  expect_equal(out$situation[1], "1st and 10 at CMU35")  # newline squished
})

test_that("find_plays errors when no play table is present", {
  expect_error(find_plays(list(data.frame(a = 1, b = 2))),
               "No play-by-play table found")
})

test_that("fetch_html records why d3football refused, and repeats it", {
  withr::local_options(d3ballR.cache_dir = withr::local_tempdir(), d3ballR.delay = 0,
                       d3ballR.offline = FALSE, d3ballR.max_requests = Inf)
  reset_fetch_state()
  withr::defer(reset_fetch_state())
  httr2::local_mocked_responses(function(req) httr2::response(status_code = 459))

  u1 <- "https://www.d3football.com/seasons/2025/boxscores/a.xml?view=plays"
  u2 <- "https://www.d3football.com/seasons/2025/boxscores/b.xml?view=plays"
  expect_error(fetch_html(u1), "refused the request \\(HTTP 459\\)")
  expect_true(fetch_refused())
  expect_equal(fetch_refusal(), paste("HTTP 459 at", u1))
  # later requests aren't sent, and their error names the first refusal
  expect_error(fetch_html(u2), paste0("refused an earlier request this run \\(HTTP 459 at .*a\\.xml"))
  expect_equal(n_requests(), 1L)
})

local_fetch_test <- function(env = parent.frame()) {
  withr::local_options(d3ballR.cache_dir = withr::local_tempdir(.local_envir = env), d3ballR.delay = 0,
                       d3ballR.offline = FALSE, d3ballR.max_requests = Inf,
                       d3ballR.max_empty_streak = 3, .local_envir = env)
  reset_fetch_state()
  withr::defer(reset_fetch_state(), envir = env)
}
page <- function(body) httr2::response(status_code = 200, body = charToRaw(body))
box <- function(id) paste0("https://www.d3football.com/seasons/2025/boxscores/", id, ".xml")

test_that("one empty page is skipped and remembered, not a refusal", {
  local_fetch_test()
  httr2::local_mocked_responses(function(req) {
    if (grepl("/a\\.xml", req$url)) httr2::response(status_code = 200, body = raw(0)) else page("<html><p>plays</p></html>")
  })
  expect_message(got <- prefetch_games(box(c("a", "b", "c"))), "Not fetched: empty page: .*a\\.xml")
  expect_equal(got, 2L)
  expect_false(fetch_refused())
  expect_equal(empty_pages(), paste0(box("a"), "?view=plays"))
  # asked again in the same run: no new request
  n <- n_requests()
  expect_error(fetch_html(paste0(box("a"), "?view=plays")), "already tried this run")
  expect_equal(n_requests(), n)
})

test_that("three empty pages in a row stop the run", {
  local_fetch_test()
  httr2::local_mocked_responses(function(req) httr2::response(status_code = 200, body = raw(0)))
  suppressMessages(got <- prefetch_games(box(c("a", "b", "c", "d", "e"))))
  expect_equal(got, 0L)
  expect_equal(n_requests(), 3L)
  expect_true(fetch_refused())
  expect_match(fetch_refusal(), "3 empty pages in a row, the last at .*c\\.xml")
})

test_that("a non-empty page resets the empty streak", {
  local_fetch_test()
  httr2::local_mocked_responses(function(req) {
    if (grepl("/[ab]\\.xml", req$url)) page("<html><p>plays</p></html>") else httr2::response(status_code = 200, body = raw(0))
  })
  suppressMessages(got <- prefetch_games(box(c("x", "y", "a", "z", "b"))))
  expect_equal(got, 2L)
  expect_false(fetch_refused())
  expect_length(empty_pages(), 3)
})

test_that("a 459 still stops the run at once", {
  local_fetch_test()
  httr2::local_mocked_responses(function(req) httr2::response(status_code = 459))
  suppressMessages(got <- prefetch_games(box(c("a", "b", "c"))))
  expect_equal(got, 0L)
  expect_equal(n_requests(), 1L)
  expect_equal(fetch_refusal(), paste0("HTTP 459 at ", box("a"), "?view=plays"))
})

test_that("prefetch_games tries earlier-empty pages last", {
  local_fetch_test()
  asked <- character()
  httr2::local_mocked_responses(function(req) { asked <<- c(asked, req$url); page("<html></html>") })
  suppressMessages(prefetch_games(box(c("a", "b", "c")), last = paste0(box("a"), "?view=plays")))
  expect_equal(asked, paste0(box(c("b", "c", "a")), "?view=plays"))
})

test_that("write_empty_pages adds, updates and drops games", {
  local_fetch_test()
  check_dir <- withr::local_tempdir()
  games <- data.frame(game_id = c("g1", "g2"), home = c("H1", "H2"), away = c("A1", "A2"),
                      game_date = c("2025-09-06", "2025-09-13"), boxscore_url = box(c("g1", "g2")))
  .d3_state$empty <- paste0(box(c("g1", "g2")), "?view=plays")
  out <- write_empty_pages(games, check_dir)
  expect_equal(out$game_id, c("g1", "g2"))
  first <- out$first_seen

  # next run: g2 came back with content (cached), g1 not retried
  reset_fetch_state()
  writeLines("<html></html>", file.path(getOption("d3ballR.cache_dir"), cache_key(paste0(box("g2"), "?view=plays"))))
  out <- write_empty_pages(games, check_dir)
  expect_equal(out$game_id, "g1")
  expect_equal(out$first_seen, first[1])
})
