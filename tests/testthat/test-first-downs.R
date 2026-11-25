# New-series flags sit on the FIRST SNAP of the new series, are mutually
# exclusive by cause (kickoff > poss > yards > penalty), and are FALSE on
# every other row. Built on small synthetic sequences of kept rows.

series_rows <- function(...) {
  d <- data.frame(...)
  defaults <- list(penalty_no_play = FALSE, scoring_play = FALSE, try_phase = FALSE, fumble_vec = FALSE,
                   turnover = FALSE, downs_turnover = FALSE,
                   firstD_by_yards = FALSE, firstD_by_penalty = FALSE, half = 1L, period = 1L,
                   down = 1L, distance = 10L, yards_to_goal = 75L)
  for (nm in names(defaults)) if (!nm %in% names(d)) d[[nm]] <- defaults[[nm]]
  d$scrimmage_play <- !d$play_type %in% c("kickoff", "extra_point", "two_point")
  d$down[!d$scrimmage_play] <- NA
  d
}
# Each sequence is the middle of a half: a lead-in (a kickoff, then a
# 1st-down snap by the first row's team, in the first row's half and period)
# goes in front, so the first row isn't the first snap of a half (which, with
# no kickoff before it, is a series by kickoff), and is dropped from the result.
flags_of <- function(d, lead_in = TRUE) {
  if (lead_in) {
    lead <- d[c(1, 1), ]
    lead$play_type <- c("kickoff", "rush")
    lead$down <- c(NA, 1L)
    lead$scrimmage_play <- c(FALSE, TRUE)
    for (nm in c("penalty_no_play", "scoring_play", "try_phase", "fumble_vec", "firstD_by_yards", "firstD_by_penalty",
                 "turnover", "downs_turnover")) lead[[nm]] <- FALSE
    d <- rbind(lead, d)
  }
  out <- derive_series_flags(d, next_snap_index(d))
  if (lead_in) out <- out[-(1:2), ]
  vapply(seq_len(nrow(out)), function(i) {
    f <- c("kickoff", "poss", "yards", "penalty")[c(out$firstD_by_kickoff[i], out$firstD_by_poss[i],
                                                     out$firstD_by_yards[i], out$firstD_by_penalty[i])]
    if (out$series_cause[i] %in% "situation") f <- "situation"
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

test_that("overtime: ncaa.com's single OT period -- the same team twice in a row after its try is a new possession", {
  # OT1: A scores, B scores; OT2: B goes first (all filed under period 5)
  d <- series_rows(play_type = c("rush", "rush", "extra_point", "rush", "rush", "extra_point", "rush", "rush"),
                   pos_team = c("A", "A", "A", "B", "B", "B", "B", "B"), period = 5L, half = 2L,
                   down = c(1L, 2L, NA, 1L, 2L, NA, 1L, 2L), scoring_play = c(FALSE, TRUE, FALSE, FALSE, TRUE, FALSE, FALSE, FALSE))
  expect_equal(flags_of(d, lead_in = FALSE), c("poss", "-", "-", "poss", "-", "-", "poss", "-"))
})

test_that("ot_periods numbers overtime 5, 6, 7 from possessions (two per period)", {
  ot_rows <- function(...) {
    d <- data.frame(...)
    d$period <- 5L
    d$distance <- ifelse(is.na(d$down), NA, 10L)
    for (nm in c("scoring_play", "turnover", "try_phase")) if (!nm %in% names(d)) d[[nm]] <- FALSE
    if (!"play_text" %in% names(d)) d$play_text <- ""
    d
  }
  # OT1: A scores (TD + try); B scores; OT2: B first (team tag wrong on its
  # first snap), B misses a field goal, then A; a converted 4th down goes on
  d <- ot_rows(
    play_type = c("rush", "rush", "extra_point", "rush", "pass_complete", "extra_point",
                  "pass_incomplete", "rush", "field_goal_missed", "rush", "pass_complete", "rush"),
    pos_team = c("A", "A", "A", "B", "B", "B", "A", "B", "B", "A", "A", "A"),
    down = c(1L, 2L, NA, 1L, 2L, NA, 1L, 2L, 4L, 1L, 4L, 1L),
    yards_to_goal = c(25L, 10L, NA, 25L, 12L, NA, 75L, 25L, 20L, 25L, 21L, 11L),
    scoring_play = c(FALSE, TRUE, TRUE, FALSE, TRUE, TRUE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE),
    try_phase = c(FALSE, FALSE, TRUE, FALSE, FALSE, TRUE, TRUE, FALSE, FALSE, FALSE, FALSE, FALSE)
  )
  expect_equal(ot_periods(d), c(5L, 5L, 5L, 5L, 5L, 5L, 6L, 6L, 6L, 6L, 6L, 6L))
  # 3rd OT on: alternating two-point tries with no snap
  d3 <- ot_rows(play_type = c("rush", "extra_point", "rush", "extra_point", "rush", "two_point", "rush", "two_point",
                              "two_point", "two_point"),
                pos_team = c("A", "A", "B", "B", "A", "A", "B", "B", "A", "B"),
                down = c(1L, NA, 1L, NA, 1L, NA, 1L, NA, NA, NA), yards_to_goal = c(25L, NA, 25L, NA, 25L, NA, 25L, NA, NA, NA),
                scoring_play = c(TRUE, FALSE, TRUE, FALSE, TRUE, FALSE, TRUE, FALSE, FALSE, FALSE))
  expect_equal(ot_periods(d3), c(5L, 5L, 5L, 5L, 6L, 6L, 6L, 6L, 7L, 7L))
  # a try replayed after a penalty is the same possession; a second good try
  # by the same team with no penalty is its 3rd-OT try (6461698)
  d4 <- ot_rows(play_type = c("rush", "two_point", "two_point", "rush", "two_point", "two_point", "two_point"),
                pos_team = c("A", "A", "A", "B", "B", "B", "A"),
                down = c(1L, NA, NA, 1L, NA, NA, NA), yards_to_goal = c(25L, NA, NA, 25L, NA, NA, NA),
                scoring_play = c(TRUE, FALSE, FALSE, TRUE, FALSE, FALSE, FALSE),
                play_text = c("", "pass attempt failed PENALTY B Holding", "rush attempt failed", "",
                              "pass attempt Successful.", "pass attempt Successful.", "rush attempt failed."))
  expect_equal(ot_periods(d4), c(5L, 5L, 5L, 5L, 5L, 6L, 6L))
})

test_that("a half with no kickoff line: its first snap is firstD_by_kickoff", {
  d <- series_rows(play_type = c("rush", "rush", "rush", "pass_complete"), pos_team = c("A", "A", "B", "B"),
                   half = c(1L, 1L, 2L, 2L), period = c(2L, 2L, 3L, 3L), down = c(1L, 2L, 1L, 2L))
  expect_equal(flags_of(d, lead_in = FALSE), c("kickoff", "-", "kickoff", "-"))
})

test_that("built games: game 1 play 11 -> play 12, placement, exclusivity", {
  dir <- test_path("../../pbp")
  files <- list.files(dir, pattern = "\\.csv$", recursive = TRUE, full.names = TRUE)
  skip_if(!length(files), "no built games")
  # ncaa.com contest 6461445 (old id 6461445, Carnegie Mellon at Chicago)
  g1 <- files[basename(files) == "6461445.csv"]
  if (length(g1)) {
    g <- utils::read.csv(g1, na.strings = "")
    # play 11 (10-yard catch + face mask) causes a new series; play 12 starts
    # it. (Play 11 is itself flagged: play 10 reached the line to gain.)
    r <- g[g$play_index == 12, ]
    expect_true(r$new_series)
    expect_equal(r$down, 1L)
  }
  # 6462069 (old id 6462069, Franklin and Marshall at Lebanon Valley)
  hz <- files[basename(files) == "6462069.csv"]
  if (length(hz)) {
    g <- utils::read.csv(hz, na.strings = "")
    # play 15: F&M punt; play 16: LVC false start (NO PLAY) = first snap row of
    # LVC's series; play 17: the replayed 1st down
    expect_true(g$new_series[g$play_index == 16])
    expect_false(g$new_series[g$play_index == 17])
  }
  for (f in files) {
    g <- utils::read.csv(f, na.strings = "")
    expect_false(any(c("firstD_by_kickoff", "firstD_by_poss", "firstD_by_yards", "firstD_by_penalty") %in% names(g)),
                 label = paste(basename(f), "only new_series in the output"))
    expect_false(anyNA(g$new_series), label = paste(basename(f), "new_series never NA"))
    expect_false(anyNA(g$situation_suspect), label = paste(basename(f), "situation_suspect never NA"))
    expect_false(any(g$situation_suspect & is.na(g$down)), label = paste(basename(f), "situation_suspect only on rows with a down"))
    expect_false(any(g$new_series[g$play_type %in% c("kickoff", "extra_point", "two_point")]),
                 label = paste(basename(f), "no flag on kickoffs or tries"))
    expect_false(any(g$new_series[is.na(g$down)]), label = paste(basename(f), "flags only on snap rows"))
  }
})

test_that("a kickoff the source left out: the other team's snap after a try starts a kickoff series", {
  d <- series_rows(play_type = c("rush", "extra_point", "rush", "rush"),
                   pos_team = c("A", "A", "B", "B"), scoring_play = c(TRUE, FALSE, FALSE, FALSE),
                   down = c(1L, NA, 1L, 2L))
  d$try_phase <- c(FALSE, TRUE, FALSE, FALSE)
  expect_equal(flags_of(d), c("-", "-", "kickoff", "-"))
})

test_that("a first down that an offensive penalty after the play didn't take away still counts (6462261)", {
  # 1st & 10 at own 30: 20-yard catch, 1ST DOWN, then offensive holding
  # enforced from the end of the run; next snap is a fresh 1st & 10 ten yards on
  k <- data.frame(
    play_text = c("pass complete for 20 yards to the COE50, 1ST DOWN, PENALTY COE Holding 10 yards from COE50 to COE40.",
                  "pass complete for 15 yards to the BVU45, 1ST DOWN."),
    play_type = "pass_complete", pos_team = "Coe", def_pos_team = "BV", down = 1L, distance = 10L,
    yards_to_goal = c(70L, 60L), yards_gained = c(20L, 15L), penalty_yards_signed = c(-10L, NA),
    penalty_declined = c(FALSE, NA), penalized_team = c("Coe", NA), Goal_To_Go = FALSE,
    scrimmage_play = TRUE, penalty_no_play = FALSE, turnover = FALSE, scoring_play = FALSE)
  out <- derive_first_downs(k, c(2L, NA))
  expect_true(out$firstD_by_yards[1])
  # the same holding with the next snap the same 1st down moved back: no first down
  k2 <- k; k2$yards_to_goal <- c(70L, 80L); k2$distance <- c(10L, 20L)
  expect_false(derive_first_downs(k2, c(2L, NA))$firstD_by_yards[1])
})

test_that("dead-ball personal fouls before the ball is ready for play are recognised (Rule 5-2-7)", {
  k <- data.frame(penalty_no_play = c(TRUE, TRUE, TRUE, TRUE, FALSE, TRUE),
                  play_text = c("PENALTY GFU Personal Foul (Iokia,Sheyden) 15 yards from WHTW45 to GFU40. NO PLAY.",
                                "PENALTY MC UNS: Unsportsmanlike Conduct (Brown,DaRell) 15 yards from MC49 to MC34. NO PLAY.",
                                "PENALTY TUF False Start 5 yards from TUF20 to TUF15. NO PLAY",
                                "pass incomplete, PENALTY BV personal foul 15 yards, NO PLAY.",
                                "PENALTY SUS UNR: Unnecessary Roughness 15 yards from SUS46 to SUS31.",
                                "PENALTY X UNS: Unsportsmanlike Conduct X False Start 20 yards. NO PLAY."))
  # a false start is after the ball is ready; a foul on a snap isn't a dead-ball
  # row; a row that names a foul of each kind isn't skipped
  expect_equal(pre_ready_foul_row(k), c(TRUE, TRUE, FALSE, FALSE, FALSE, FALSE))
})

test_that("a dead-ball personal foul between series: the new series starts at the snap after it", {
  # 6461954: roughing the passer gives George Fox a first down; George Fox's
  # personal foul (dead ball, before the ready) is enforced before the new
  # line to gain is set; the series starts at the snap after it
  d <- series_rows(play_type = c("pass_incomplete", "penalty_no_play", "pass_incomplete", "rush"),
                   pos_team = "A", down = c(3L, 1L, 1L, 2L),
                   penalty_no_play = c(TRUE, TRUE, FALSE, FALSE), firstD_by_penalty = c(TRUE, FALSE, FALSE, FALSE),
                   play_text = c("pass incomplete PENALTY B Roughing The Passer 15 yards, 1ST DOWN. NO PLAY.",
                                 "PENALTY A Personal Foul 15 yards from B45 to A40. NO PLAY.", "pass incomplete", "rush"))
  expect_equal(flags_of(d), c("-", "-", "penalty", "-"))
  # a false start in the same spot is part of the new series (it starts there)
  d$play_text[2] <- "PENALTY A False Start 5 yards from B45 to B50. NO PLAY."
  expect_equal(flags_of(d), c("-", "penalty", "-", "-"))
})

suspect_rows <- function(...) {
  d <- series_rows(...)
  if (is.null(d$penalized_team)) d$penalized_team <- NA_character_
  if (is.null(d$play_text)) d$play_text <- "play"
  d$try_phase <- FALSE
  d
}

test_that("situation_suspect: a new series printed as 2nd and 10, to the end of the series", {
  # 6462216: 7-yard rush on 2nd and 2 reaches the line; the source prints
  # 2nd and 10, then 3rd and 10; the next series is clean again
  d <- suspect_rows(play_type = c("rush", "rush", "pass_incomplete", "pass_incomplete", "rush"),
                    pos_team = "A", down = c(2L, 2L, 3L, 1L, 2L), distance = c(2L, 10L, 10L, 10L, 6L),
                    yards_to_goal = c(20L, 13L, 13L, 9L, 5L))
  d$new_series <- c(FALSE, TRUE, FALSE, TRUE, FALSE)
  expect_equal(flag_situation_suspect(d), c(FALSE, TRUE, TRUE, FALSE, FALSE))
})

test_that("situation_suspect: a false start on 1st and 10 followed by 1st and 10 again", {
  # 6529893: false start TUF20 -> TUF15, then "1st and 10 at TUF15" (should be 1st and 15)
  d <- suspect_rows(play_type = c("penalty_no_play", "rush", "rush"), pos_team = "A",
                    down = c(1L, 1L, 2L), distance = 10L, yards_to_goal = c(80L, 85L, 85L),
                    penalty_no_play = c(TRUE, FALSE, FALSE), penalized_team = c("A", NA, NA),
                    play_text = c("PENALTY TUF False Start 5 yards from TUF20 to TUF15. NO PLAY", "rush", "rush"))
  d$new_series <- c(TRUE, FALSE, FALSE)
  expect_equal(flag_situation_suspect(d), c(FALSE, TRUE, TRUE))
  # printed correctly (1st and 15): nothing suspect
  d$distance <- c(10L, 15L, 15L)
  expect_equal(flag_situation_suspect(d), c(FALSE, FALSE, FALSE))
  # a defensive foul isn't checked (it can carry an automatic first down)
  d$distance <- 10L; d$penalized_team[1] <- "B"
  expect_equal(flag_situation_suspect(d), c(FALSE, FALSE, FALSE))
})

test_that("situation_suspect: a dead-ball personal foul followed by 1st and 10 is not suspect (Rule 5-2-7)", {
  d <- suspect_rows(play_type = c("penalty_no_play", "pass_incomplete", "rush"), pos_team = "A",
                    down = c(1L, 1L, 2L), distance = 10L, yards_to_goal = c(45L, 60L, 60L),
                    penalty_no_play = c(TRUE, FALSE, FALSE), penalized_team = c("A", NA, NA),
                    play_text = c("PENALTY A Personal Foul 15 yards from B45 to A40. NO PLAY.", "pass", "rush"))
  d$new_series <- c(FALSE, TRUE, FALSE)
  expect_equal(flag_situation_suspect(d), c(FALSE, FALSE, FALSE))
})

test_that("situation_suspect: a distance of zero or less", {
  # 6529853: 15-yard catch on 1st and 10, the source keeps counting: 2nd and -5
  d <- suspect_rows(play_type = c("pass_complete", "rush", "rush"), pos_team = "A",
                    down = c(1L, 2L, 1L), distance = c(10L, -5L, 10L), yards_to_goal = c(81L, 66L, 56L))
  d$new_series <- c(TRUE, FALSE, TRUE)
  expect_equal(flag_situation_suspect(d), c(FALSE, TRUE, FALSE))
})

test_that("a change of offense with no causing play starts a series (6462412)", {
  # A's replayed 4th down is missing from the source; B snaps next
  d <- series_rows(play_type = c("pass_complete", "penalty_no_play", "pass_complete", "rush"),
                   pos_team = c("A", "A", "B", "B"), down = c(4L, 4L, 1L, 2L),
                   penalty_no_play = c(TRUE, TRUE, FALSE, FALSE))
  expect_equal(flags_of(d), c("-", "-", "poss", "-"))
})

test_that("an interception the offense gets back starts a new series (6461517)", {
  d <- series_rows(play_type = c("pass_intercepted", "rush", "rush"), pos_team = "A", down = c(3L, 1L, 2L))
  d$turnover <- c(TRUE, FALSE, FALSE); d$downs_turnover <- FALSE
  expect_equal(flags_of(d), c("-", "poss", "-"))
})

test_that("a blocked punt the kicking team recovers past the line to gain is its first down (6461248)", {
  d <- series_rows(play_type = c("punt_blocked", "rush", "rush"), pos_team = "A", down = c(4L, 1L, 2L))
  expect_equal(flags_of(d), c("-", "yards", "-"))
})

test_that("a missing kickoff after a try with a penalty on it (6462377)", {
  d <- series_rows(play_type = c("rush", "extra_point", "penalty_no_play", "pass_complete"),
                   pos_team = c("A", "A", "A", "B"), down = c(1L, NA, 1L, 1L),
                   scoring_play = c(TRUE, FALSE, FALSE, FALSE), penalty_no_play = c(FALSE, FALSE, TRUE, FALSE))
  d$try_phase <- c(FALSE, TRUE, TRUE, FALSE)
  expect_equal(flags_of(d), c("-", "-", "-", "kickoff"))
})

test_that("a fresh 1st down in the source after a later down, with no causing line, starts a series", {
  # 6461694: false start on 3rd and 4, then "1st and 10"
  d <- series_rows(play_type = c("rush", "penalty_no_play", "rush", "rush"), pos_team = "A",
                   down = c(2L, 3L, 1L, 2L), penalty_no_play = c(FALSE, TRUE, FALSE, FALSE))
  expect_equal(flags_of(d), c("-", "-", "situation", "-"))
})
