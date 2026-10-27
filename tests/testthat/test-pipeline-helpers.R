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

test_that("classify_plays types the all-D3 row shapes (no 'other')", {
  plays <- tibble::tibble(
    situation = c("3 plays, -12 yards, 2:23 elapsed", "2nd and 3 at AUG41", "1st and 10 at MUHL48",
                  "2nd and 10 at HOBART43", "1st and 10 at ALBFB35", "1st and 10 at UC35",
                  "2nd and 19 at GAL22", "4th and 8 at ALBFB22", "1st and 10 at DSON41",
                  "", "", "1st and 10 at GC35", "1st and 10 at X20", ""),
    play = c("3 plays, -12 yards, 2:23 elapsed", "Clock 02:00.", "clock 0:26",
             "Spiked", "Gallaudet wins the toss and will defer", "Ursinus to receive and defense the East goal",
             "D. Brown Jr at QB for Albright.", "2:00 minute warning", "recovered by Sorensen",
             "PENALTY MCD Pass Interference declined.",
             "PENALTY F&M UNS: Unsportsmanlike Conduct offsetting MCD UNS: Unsportsmanlike Conduct offsetting. NO PLAY.",
             ".", "(03:20). N.C. Wesleyan SAFETY, clock 03:20.",
             "PENALTY MCD Holding 10 yards from MCD20 to MCD10.")
  )
  expect_equal(classify_plays(plays)$row_type,
               c("drive_footer", "bare_clock", "bare_clock", "annotation", "coin_toss", "coin_toss",
                 "substitution", "annotation", "annotation", "penalty_note", "penalty_note", "blank",
                 "play", "other"))  # an accepted penalty with no situation still surfaces
})

test_that("play_actor reads the name before the verb", {
  expect_equal(play_actor(c("(04:23) No Huddle-Shotgun Booker,Jayden pass complete to X for 5 yards.",
                            "Jesch,Mateo onside kickoff 12 yards to the WHE47.",
                            "Kneel down by Andrew Deutsch at CMU30 for loss of 1 yard.",
                            "TEAM rush for loss of 2 yards.")),
               c("Booker,Jayden", "Jesch,Mateo", "Andrew Deutsch", NA))
})

test_that("drive_row_team reads drive headers and starts, with or without a clock", {
  expect_equal(drive_row_team(c("LaGrange at 09:08", "clock 09:08, LaGrange College drive start at 09:08.",
                                "Virginia-Lynchburg at", "Point drive start at 12:07.")),
               c("LaGrange", "LaGrange College", "Virginia-Lynchburg", "Point"))
})

test_that("a game stopped early: the line score's last column is the final", {
  ls <- data.frame(Scoring = c("Case Western Reserve (1-0)", "Rowan (0-1)"), `1` = c("14", "7"),
                   `2` = c("0", "0"), `3` = c("0", "10"), `3rd QTR - 04:19` = c("14", "17"), check.names = FALSE)
  expect_equal(unname(find_line_score_finals(list(ls))), c(14L, 17L))
  expect_equal(find_line_score_teams(list(ls)), c("Case Western Reserve", "Rowan"))
})

test_that("score_points: defensive try returns and kicking-team muff touchdowns", {
  kept <- data.frame(
    play_type = c("extra_point", "punt_no_return", "punt_with_return"),
    play_text = c("X kick attempt failed ( blocked by Y) recovered by MIT Y at MIT20 Y return 80 yards to the NIC00 Y defensive PAT Successful.",
                  "Z punt 39 yards to the UNW20 muffed by W at UNW20 recovered by STO V at UNW00 TOUCHDOWN, clock 14:00.",
                  "Z punt 40 yards to the UNW10, W return 90 yards to the STO00, TOUCHDOWN."),
    pos_team = c("Nichols", "St. Olaf", "St. Olaf"),
    touchdown = c(FALSE, TRUE, TRUE), turnover = c(FALSE, TRUE, FALSE), safety = FALSE,
    kicker_recovered = FALSE, penalty_no_play = FALSE,
    recovering_team = c("MIT", "St. Olaf", NA)
  )
  expect_equal(score_points(kept), c(-2L, 6L, -6L))
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
