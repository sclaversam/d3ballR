# New-series flags sit on the FIRST SNAP of the new series, are mutually
# exclusive by cause (kickoff > poss > yards > penalty), and are FALSE on
# every other row. Built on small synthetic sequences of kept rows.

series_rows <- function(...) {
  d <- data.frame(...)
  defaults <- list(penalty_no_play = FALSE, scoring_play = FALSE, try_phase = FALSE, fumble_vec = FALSE,
                   firstD_by_yards = FALSE, firstD_by_penalty = FALSE, half = 1L, period = 1L,
                   down = 1L, distance = 10L, yards_to_goal = 75L)
  for (nm in names(defaults)) if (!nm %in% names(d)) d[[nm]] <- defaults[[nm]]
  d$scrimmage_play <- !d$play_type %in% c("kickoff", "extra_point", "two_point")
  d$down[!d$scrimmage_play] <- NA
  d
}
flags_of <- function(d) {
  out <- derive_series_flags(d, next_snap_index(d))
  vapply(seq_len(nrow(out)), function(i) {
    f <- c("kickoff", "poss", "yards", "penalty")[c(out$firstD_by_kickoff[i], out$firstD_by_poss[i],
                                                     out$firstD_by_yards[i], out$firstD_by_penalty[i])]
    stopifnot(out$new_series[i] == (length(f) == 1), length(f) <= 1)
    if (length(f)) f else "-"
  }, character(1))
}

test_that("yards outranks penalty, on the next snap (catch past the line + face mask)", {
  d <- series_rows(play_type = c("pass_complete", "pass_incomplete"), pos_team = "A",
                   firstD_by_yards = c(TRUE, FALSE), firstD_by_penalty = c(TRUE, FALSE))
  expect_equal(flags_of(d), c("-", "yards"))
})

test_that("kickoff: the kickoff row carries nothing; the first snap after it is firstD_by_kickoff, whoever recovered", {
  d <- series_rows(play_type = c("kickoff", "rush", "rush", "kickoff", "rush"),
                   pos_team = c("B", "B", "B", "B", "A"), down = c(NA, 1L, 2L, NA, 1L))
  # row 4: B's onside kick recovered by A (A snaps next) -- still kickoff
  expect_equal(flags_of(d), c("-", "kickoff", "-", "-", "kickoff"))
})

test_that("possession: after a punt, and after a punt the kicking team regains after a muff", {
  d <- series_rows(play_type = c("punt_no_return", "rush", "punt_with_return", "rush"),
                   pos_team = c("A", "B", "B", "B"), fumble_vec = c(FALSE, FALSE, TRUE, FALSE),
                   down = c(4L, 1L, 4L, 1L))
  expect_equal(flags_of(d), c("-", "poss", "-", "poss"))
})

test_that("penalty: a no-play penalty awarding a first down flags the next snap row; the replay after a dead-ball penalty gets nothing", {
  d <- series_rows(play_type = c("pass_incomplete", "penalty_no_play", "rush"), pos_team = "A",
                   penalty_no_play = c(TRUE, TRUE, FALSE), firstD_by_penalty = c(TRUE, FALSE, FALSE),
                   down = c(3L, 1L, 1L))
  expect_equal(flags_of(d), c("-", "penalty", "-"))
})

test_that("a series can start on a penalty_no_play row: punt, then a dead-ball false start, then the replayed 1st down", {
  d <- series_rows(play_type = c("punt_with_return", "penalty_no_play", "pass_complete", "rush"),
                   pos_team = c("A", "B", "B", "B"), penalty_no_play = c(FALSE, TRUE, FALSE, FALSE),
                   down = c(4L, 1L, 1L, 2L))
  expect_equal(flags_of(d), c("-", "poss", "-", "-"))
})

test_that("no flag from a scoring play or a try; the next series starts at the kickoff", {
  d <- series_rows(play_type = c("rush", "extra_point", "kickoff", "rush"),
                   pos_team = c("A", "A", "B", "B"), scoring_play = c(TRUE, FALSE, FALSE, FALSE),
                   try_phase = c(FALSE, TRUE, FALSE, FALSE), firstD_by_yards = c(TRUE, FALSE, FALSE, FALSE))
  expect_equal(flags_of(d), c("-", "-", "-", "kickoff"))
})

test_that("overtime: the first snap of each OT possession is firstD_by_poss (including the hand-over)", {
  d <- series_rows(play_type = c("field_goal_blocked", "rush", "pass_incomplete", "rush", "pass_complete"),
                   pos_team = c("A", "A", "A", "B", "B"), period = c(4L, 5L, 5L, 5L, 5L), half = 2L,
                   down = c(4L, 1L, 4L, 1L, 2L))
  expect_equal(flags_of(d), c("-", "poss", "-", "poss", "-"))
})

test_that("built games: game 1 play 11 -> play 12, placement, exclusivity", {
  dir <- test_path("../../analysis/pbp")
  files <- list.files(dir, pattern = "\\.csv$", recursive = TRUE, full.names = TRUE)
  skip_if(!length(files), "no built games")
  g1 <- files[basename(files) == "20250906_e064.csv"]
  if (length(g1)) {
    g <- utils::read.csv(g1, na.strings = "")
    # play 11 (10-yard catch + face mask) causes a new series; play 12 starts
    # it. (Play 11 is itself flagged: play 10 reached the line to gain.)
    r <- g[g$play_index == 12, ]
    expect_true(r$firstD_by_yards)
    expect_false(r$firstD_by_penalty)
    expect_equal(r$down, 1L)
  }
  hz <- files[basename(files) == "20250904_hz19.csv"]
  if (length(hz)) {
    g <- utils::read.csv(hz, na.strings = "")
    # play 15: F&M punt; play 16: LVC false start (NO PLAY) = first snap row of
    # LVC's series; play 17: the replayed 1st down
    expect_true(g$firstD_by_poss[g$play_index == 16])
    expect_true(g$new_series[g$play_index == 16])
    r17 <- g[g$play_index == 17, c("firstD_by_kickoff", "firstD_by_poss", "firstD_by_yards", "firstD_by_penalty", "new_series")]
    expect_false(any(unlist(r17)))
  }
  for (f in files) {
    g <- utils::read.csv(f, na.strings = "")
    k <- g[, c("firstD_by_kickoff", "firstD_by_poss", "firstD_by_yards", "firstD_by_penalty")]
    expect_identical(g$new_series, rowSums(k) == 1, label = paste(basename(f), "exactly one flag when new_series"))
    expect_true(all(rowSums(k) <= 1), label = paste(basename(f), "at most one flag"))
    expect_false(any(g$new_series[g$play_type %in% c("kickoff", "extra_point", "two_point")]),
                 label = paste(basename(f), "no flag on kickoffs or tries"))
    expect_false(any(g$new_series[is.na(g$down)]), label = paste(basename(f), "flags only on snap rows"))
  }
})
