test_that("cleaning drops a printed-clock typo rather than an official reading", {
  # official 03:23 drive start, printed 02:32, typo 09:09, official 01:59 timeout
  anchors <- data.frame(row = 1:4, pos = c(1, 2.25, 3.25, 4), quarter = 4L,
                        secs = clock_secs(c("03:23", "02:32", "09:09", "01:59")),
                        kind = c("drive_header", "printed", "printed", "timeout"), text = "")
  expect_equal(clean_clock_anchors(anchors)$keep, c(TRUE, TRUE, FALSE, TRUE))
  # with equal weights a lone official reading could lose to two printed ones;
  # weighting keeps the official reading
  anchors2 <- data.frame(row = 1:3, pos = c(1, 2, 3.25), quarter = 2L,
                         secs = clock_secs(c("10:00", "12:00", "11:50")),
                         kind = c("printed", "timeout", "printed"), text = "")
  expect_equal(clean_clock_anchors(anchors2)$keep, c(FALSE, TRUE, TRUE))
})

test_that("built games: clock columns are consistent and the seconds columns mirror them", {
  files <- list.files(test_path("../../pbp"), pattern = "\\.csv$", recursive = TRUE, full.names = TRUE)
  skip_if(!length(files), "no built games")
  for (f in files) {
    g <- utils::read.csv(f, na.strings = "")
    reg <- g$period <= 4
    st <- clock_secs(g$clock_start); en <- clock_secs(g$clock_end)
    mx <- clock_secs(g$clock_start_max); mn <- clock_secs(g$clock_start_min)
    expect_true(all(!is.na(mx[reg]) & !is.na(mn[reg]) & mx[reg] >= mn[reg]), label = paste(basename(f), "bounds"))
    expect_true(all(is.na(st) | (st <= mx & st >= mn)), label = paste(basename(f), "start inside bounds"))
    expect_true(all(is.na(st) | is.na(en) | en <= st), label = paste(basename(f), "end <= start"))
    gs <- function(x) ifelse(is.na(x), NA, (4L - g$period) * 900L + x)
    expect_equal(g$secs_remaining_start, gs(st), label = paste(basename(f), "secs start"))
    expect_equal(g$secs_remaining_end, gs(en), label = paste(basename(f), "secs end"))
    expect_equal(g$secs_remaining_start_max, gs(mx), label = paste(basename(f), "secs max"))
    expect_equal(g$secs_remaining_start_min, gs(mn), label = paste(basename(f), "secs min"))
    expect_true(all(is.na(g$clock_start_max[!reg])), label = paste(basename(f), "OT untimed"))
    p <- clock_secs(stringr::str_match(g$play_text, "^\\((\\d{1,2}:\\d{2})\\)")[, 2])
    # a printed clock that survived cleaning is a minimum for its own snap.
    # A printed clock that contradicts an official reading is discarded
    # (e.g. 20250904_zik0: printed 14:48, timeout 13:59, printed 14:15), so
    # allow a few: at most 1, or 2% of the game's printed clocks
    ok <- is.na(p) | !reg | p <= mx
    expect_true(sum(!ok) <= max(1, 0.02 * sum(!is.na(p))),
                label = paste(basename(f), "printed clocks within the snap range (allowing discarded typos)"))
  }
})

test_that("bounds meeting pins clock_start (McDaniel game: printed clocks tighten the range)", {
  f <- test_path("../../pbp/2025/20251025_mepx.csv")
  skip_if_not(file.exists(f))
  g <- utils::read.csv(f, na.strings = "")
  r <- g[g$play_index == 162, ]
  expect_equal(c(r$clock_start_max, r$clock_start_min), c("02:32", "01:59"))  # 09:09 typo ignored
  pinned <- !is.na(g$clock_start) & g$clock_start_max == g$clock_start_min
  expect_true(all(g$clock_start[pinned] == g$clock_start_max[pinned]))
})
