test_that("classify_plays types a kickoff with a return penalty as kickoff", {
  plays <- tibble::tibble(
    situation = c("1st and 10 at CMU35", ""),
    play = c(
      "Godhard,Noah kickoff 64 yards to the DSON01 Schmidt,Kevin return 29 yards to the DSON30 (Lawler,Archie) PENALTY DSON Holding (Morgan,CJ) 10 yards from DSON30 to DSON20.",
      "Norell,John kickoff 65 yards to the UCHI00, Touchback."
    )
  )
  expect_equal(classify_plays(plays)$row_type, c("kickoff", "kickoff"))
})

test_that("is_no_play reads the text only", {
  expect_equal(
    is_no_play(c(
      "PENALTY UCHI Delay Of Game (Ruff,Jack) 5 yards from UCHI23 to UCHI18. NO PLAY.",
      "PENALTY CMU false start (Jack Korzeniows) 5 yards to the CMU34.",
      "Godhard,Noah kickoff 64 yards ... PENALTY DSON Holding 10 yards from DSON30 to DSON20.",
      "Penalty after touchdown before PAT"
    )),
    c(TRUE, TRUE, FALSE, FALSE)
  )
})

test_that("parse_coin_receiver handles the StatCrew wordings", {
  expect_equal(parse_coin_receiver("Carnegie Mellon wins toss and defers; UC will receive; CMU will defend South end-zone."), "UC")
  expect_equal(parse_coin_receiver("UWL wins toss will receive and defends west"), "UWL")
  expect_equal(parse_coin_receiver("Gettysburg wins toss, defers, CMU to receive and defend west"), "CMU")
  expect_equal(parse_coin_receiver("Carnegie Mellon to receive and defend the East end zone"), "Carnegie Mellon")
  expect_true(is.na(parse_coin_receiver("Muhlenberg won the toss and deferred")))
})

test_that("parse_matchup reads Away at Home", {
  tbls <- list(data.frame(X1 = "Carnegie Mellon at Chicago - Chicago Logo, Illinois 09/06/2025 - 12:00 PM"))
  expect_equal(parse_matchup(tbls), c(away = "Carnegie Mellon", home = "Chicago"))
})

test_that("clock helpers round-trip and pad", {
  expect_equal(clock_secs(c("15:00", "8:12", "00:04")), c(900L, 492L, 4L))
  expect_equal(fmt_clock(c(900L, 492L, NA)), c("15:00", "08:12", NA))
})

test_that("clean_clock_anchors drops the fewest readings to keep the clock running down", {
  anchors <- data.frame(
    row = 1:6, pos = 1:6, quarter = 4L,
    secs = clock_secs(c("12:59", "12:43", "00:00", "08:00", "05:10", "02:00")),
    kind = "timeout", text = ""
  )
  out <- clean_clock_anchors(anchors)
  expect_equal(out$keep, c(TRUE, TRUE, FALSE, TRUE, TRUE, TRUE))

  # two consecutive bad readings (Berry halftime)
  anchors2 <- data.frame(
    row = 1:5, pos = 1:5, quarter = 2L,
    secs = clock_secs(c("00:25", "00:00", "15:00", "15:00", "00:00")),
    kind = "bare_clock", text = ""
  )
  expect_equal(clean_clock_anchors(anchors2)$keep, c(TRUE, TRUE, FALSE, FALSE, TRUE))
})

test_that("assign_drives starts a drive at each kickoff and keeps tries on the scoring drive", {
  kept <- data.frame(
    play_type = c("kickoff", "rush", "pass_complete", "extra_point", "kickoff", "kickoff", "rush"),
    pos_team = c("A", "A", "A", "A", "B", "B", "B"),
    half = 1L, period = 1L,
    try_phase = c(FALSE, FALSE, FALSE, TRUE, FALSE, FALSE, FALSE)
  )
  out <- assign_drives(kept)
  expect_equal(out$drive_number, c(1L, 1L, 1L, 1L, 2L, 2L, 2L))  # second kickoff is a re-kick
  expect_equal(out$drive_play_number, c(1L, 2L, 3L, 4L, 1L, 2L, 3L))
})

test_that("overtime: each OT period starts a drive, and the try phase ends at the next live snap", {
  kept <- data.frame(
    play_type = c("field_goal_blocked", "rush", "pass_complete", "extra_point", "rush", "pass_complete", "two_point"),
    pos_team = c("JHU", "JHU", "JHU", "JHU", "FM", "FM", "FM"),
    play_text = c("FG BLOCKED", "rush", "pass complete TOUCHDOWN", "kick attempt good", "rush", "pass TOUCHDOWN", "pass attempt Successful"),
    penalty_no_play = FALSE,
    half = 2L, period = c(4L, 5L, 5L, 5L, 5L, 5L, 5L)
  )
  kept$try_phase <- flag_try_phase(kept)
  expect_equal(kept$try_phase, c(FALSE, FALSE, FALSE, TRUE, FALSE, FALSE, TRUE))
  expect_equal(assign_drives(kept)$drive_number, c(1L, 2L, 2L, 2L, 3L, 3L, 3L))
})

test_that("derive_quarter numbers overtime periods 5, 6", {
  cl <- data.frame(row_type = c("quarter", "play", "quarter", "quarter", "play", "quarter", "play"),
                   play = c("4th", "x", "OT", "Start of OT quarter, clock 15:00.", "y", "2OT", "z"))
  expect_equal(derive_quarter(cl)$quarter, c("4", "4", "5", "5", "5", "6", "6"))
})

test_that("play-text tokens map by yardline vote when no spelling matches", {
  df <- data.frame(
    play_text = c("rush for 9 yards to the WU34", "rush for 4 yards to the WU30", "punt 40 yards to the DSON20", "rush for 5 yards to the DSON25"),
    situation = c("1st and 10 at WAY43", "2nd and 1 at WAY34", "1st and 10 at WAY30", "1st and 10 at DIC20")
  )
  own <- c(Waynesburg = "WAY", Dickinson = "DIC")
  expect_equal(infer_text_team(df, own), c(WU = "Waynesburg", DSON = "Dickinson")[names(infer_text_team(df, own))])
})
