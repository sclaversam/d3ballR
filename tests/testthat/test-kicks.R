test_that("classify_plays types a coin toss that says 'will kickoff' as coin_toss", {
  plays <- tibble::tibble(
    situation = c("1st and 10 at DCC35", "1st and 10 at RMC35", "1st and 10 at DCC35"),
    play = c(
      "Dickinson wins toss and will kickoff; RMC will defend South end-zone.",
      "RMC will kickoff; DCC will defend North end-zone.",
      "Nahon,Eliott kickoff 57 yards to the RMCFB08 Ross,Gracyn return 21 yards to the RMCFB29 (Boyer,Kelle)."
    )
  )
  expect_equal(classify_plays(plays)$row_type, c("coin_toss", "coin_toss", "kickoff"))
})

test_that("parse_return_yards reads gains, losses and no gain", {
  expect_equal(
    parse_return_yards(c(
      "Sauer,Carter kickoff 55 yards to the MCD10 Bolden,Bernard return 21 yards to the MCD31.",
      "Kruse,Nolan kickoff 50 yards to the FMC15 Marx,Oscar return 1 yard to the FMC16.",
      "Corley,William punt 35 yards to the MAN30 Moody,Frank return for loss of 1 yard to the MAN29.",
      "X punt 40 yards to the Y20 Z return for no gain to the Y20.",
      "Worobel,Justin kickoff 65 yards to the F&M00, Touchback."
    )),
    c(21L, 1L, -1L, 0L, NA)
  )
})

test_that("parse_kick_details reads kickoffs", {
  text <- c(
    "Worobel,Justin kickoff 65 yards to the F&M00, Touchback.",
    "Fritz,Braden kickoff 52 yards to the JUN13, out of bounds at JUN13.",
    "Nolan Kruse kickoff 43 yards to the CMU22, out-of-bounds, CMU ball on CMU35, clock 11:25.",
    "Harlamov,Ivan kickoff 32 yards to the JHU33 fair catch by Bechtle,John at JHU33.",
    "Wayt,Kaleb kickoff 57 yards to the URS08 Roselle,Aidan return 17 yards to the URS25 (Stone,Zack), out of bounds.",
    "Jesch,Mateo onside kickoff 12 yards to the WHE47.",
    "Carr,Jordan onside kickoff 10 yards to the UCB45 PENALTY UCB Offside (McAuliffe,Tavian) 5 yards from UCB35 to UCB30. NO PLAY."
  )
  k <- parse_kick_details(text, rep("kickoff", 7), c(rep(FALSE, 6), TRUE))
  expect_equal(k$yds_kickoff, c(65L, 52L, 43L, 32L, 57L, 12L, NA))
  expect_equal(k$yds_kickoff_return, c(NA, NA, NA, NA, 17L, NA, NA))
  expect_equal(k$kickoff_tb, c(TRUE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE))
  # the returner running out of bounds (row 5) is not a kick out of bounds
  expect_equal(k$kickoff_oob, c(FALSE, TRUE, TRUE, FALSE, FALSE, FALSE, FALSE))
  expect_equal(k$kickoff_fair_catch, c(FALSE, FALSE, FALSE, TRUE, FALSE, FALSE, FALSE))
  # a no-play onside kick credits nothing
  expect_equal(k$kickoff_onside, c(FALSE, FALSE, FALSE, FALSE, FALSE, TRUE, FALSE))
  expect_true(all(is.na(k$yds_punted)) && !any(k$punt_tb) && all(is.na(k$yds_fg)))
})

test_that("parse_kick_details reads punts and field goals", {
  text <- c(
    "Cleary,Spencer punt 32 yards to the CUW30 Crowell,Nick return 13 yards to the CUW43 (White,Brian).",
    "Kiedrowski,Ben punt 71 yards to the JHU00, Touchback.",
    "Kiedrowski,Ben punt 18 yards to the JHU25, out of bounds at JHU25.",
    "Passey,Alex punt 42 yards to the APP20 Petty,T.K. return 13 yards to the APP33 (Kroeger,Joseph), out of bounds.",
    "Hoekstra,Reichen punt 37 yards to the HAM36 fair catch by Schaffer,Dawson at HAM36.",
    "John Norell punt 23 yards to the GC15, downed.",
    "Noah Workman punt loss of 7 yards to the HIL21, Tristan Doy return 0 yards to the HIL21 (Shawn Roberts), PENALTY HIL illegal block 8 yards to the HIL13.",
    "Kiedrowski,Ben punt BLOCKED, recovered by GC TEAM at GC42 (blocked by Scott Sabol).",
    "Caputo,Justin field goal attempt from 35 yards GOOD (H: Salters,Jackson, LS: Orlando,Joey), clock 14:51.",
    "Michael Fleming field goal attempt from 24 GOOD, clock 03:10."
  )
  type <- c("punt_with_return", "punt_no_return", "punt_no_return", "punt_with_return", "punt_no_return",
            "punt_no_return", "punt_with_return", "punt_blocked", "field_goal_good", "field_goal_good")
  k <- parse_kick_details(text, type, rep(FALSE, 10))
  expect_equal(k$yds_punted, c(32L, 71L, 18L, 42L, 37L, 23L, -7L, NA, NA, NA))
  expect_equal(k$yds_punt_return, c(13L, NA, NA, 13L, NA, NA, 0L, NA, NA, NA))
  expect_equal(which(k$punt_tb), 2L)
  expect_equal(which(k$punt_oob), 3L)
  expect_equal(which(k$punt_fair_catch), 5L)
  expect_equal(which(k$punt_downed), 6L)
  expect_equal(k$yds_fg, c(rep(NA, 8), 35L, 24L))
  expect_true(all(is.na(k$yds_kickoff)) && !any(k$kickoff_onside))
})
