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

test_that("fetch_html records an empty page as a refusal", {
  withr::local_options(d3ballR.cache_dir = withr::local_tempdir(), d3ballR.delay = 0,
                       d3ballR.offline = FALSE, d3ballR.max_requests = Inf)
  reset_fetch_state()
  withr::defer(reset_fetch_state())
  httr2::local_mocked_responses(function(req) httr2::response(status_code = 200, body = raw(0)))

  u <- "https://www.d3football.com/seasons/2025/boxscores/c.xml?view=plays"
  expect_error(fetch_html(u), "empty page")
  expect_equal(fetch_refusal(), paste("empty page at", u))
  reset_fetch_state()
  expect_true(is.na(fetch_refusal()))
})
