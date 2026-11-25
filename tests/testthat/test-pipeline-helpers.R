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

test_that("classify_plays keeps an accepted dead-ball foul before a kickoff (blank situation)", {
  plays <- tibble::tibble(
    situation = c("", "", ""),
    play = c(
      "PENALTY MON UNS: Unsportsmanlike Conduct (J.Samuels) 15 yards from MON35 to MON20. NO PLAY",
      "PENALTY CROWN Personal Foul (T.Nelson) 15 yards from WHEIL35 to WHEIL50. NO PLAY",
      "PENALTY WHE Holding declined."
    )
  )
  expect_equal(classify_plays(plays)$row_type, c("penalty_no_play", "penalty_no_play", "penalty_note"))
})

test_that("classify_plays types scorer's notes", {
  plays <- tibble::tibble(
    situation = c(rep("1st and 10 at MAR35", 12), ""),
    play = c(
      "Lewis,Brayden injured on the play", "TWO MINUTE TIME OUT", "2:00 minute timeout",
      "17 sec on clock", "MuskCap:5 C Gurney 9 G Gurney 56 Page", "Ripon Smith,Joe has been disqualified",
      "QB hurry by J. Laureano.", "Weather Delay (8:20 on 3rd quarter clock)", "MCMURRY 5 now wearing 1.",
      "Olivet won toss, defers. Trine receive and defend south goal.", "Castleton Challenges TD - Upheld",
      "sweep right", "#7/8 Bethel (MN) 14, Augsburg 0"
    )
  )
  expect_equal(classify_plays(plays)$row_type, c(
    "injury", "two_minute_timeout", "two_minute_timeout", "clock_note", "captains", "disqualification",
    "qb_hurry", "game_delay", "jersey_change", "coin_toss", "replay_review", "other", "score_banner"
  ))
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

test_that("derive_td_team names the scorer and flags return touchdowns", {
  kept <- data.frame(
    play_type = c("pass_complete", "pass_intercepted", "kickoff", "punt_no_return", "punt_blocked", "rush"),
    pos_team = c("CMU", "Ursinus", "Dickinson", "St. Olaf", "Gettysburg", "CMU"),
    def_pos_team = c("Ursinus", "CMU", "Waynesburg", "UNW", "CNU", "F&M"),
    touchdown = c(TRUE, TRUE, TRUE, TRUE, TRUE, FALSE),
    score_pts = c(6L, -6L, 6L, 6L, -6L, 0L)
  )
  out <- derive_td_team(kept)
  # passing TD, pick-six, kickoff-return TD, kicking-team muff recovery TD,
  # blocked-punt TD, no TD
  expect_equal(out$td_team, c("CMU", "CMU", "Dickinson", "St. Olaf", "CNU", NA))
  expect_equal(out$return_touchdown, c(FALSE, TRUE, TRUE, FALSE, TRUE, FALSE))
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

test_that("infer_own_side: plays that settle it decide, losses don't vote", {
  # A owns AA, B owns BB. A's offense mostly loses ground (sacks), which
  # would mislead a plain yardline vote.
  df <- data.frame(
    pos_team = c("B", "A", "A", "A", "A", "A", "A", "A"),
    yard_side = c(NA, "AA", "AA", "AA", "AA", "AA", "AA", "AA"),
    yard_num = c(NA, 25L, 18L, 12L, 7L, 9L, 4L, 4L),
    down = c(NA, 1L, 2L, 3L, 1L, 2L, 2L, 3L),
    play_text = c("Kick kickoff 65 yards to the AA0, Touchback.",
                  "Smith sacked for loss of 7 yards to the AA18.",
                  "Smith sacked for loss of 6 yards to the AA12.",
                  "Smith rush for 5 yards loss to the AA7.",
                  "Smith rush for 2 yards to the AA9.",
                  "PENALTY AA False Start 5 yards from AA9 to AA4. NO PLAY.",
                  "Smith pass incomplete.",
                  "Smith punt 40 yards.")
  )
  # one extra row so the pairing has a second team token
  df <- rbind(df, data.frame(pos_team = "B", yard_side = "BB", yard_num = 30L, down = 1L, play_text = "Doe rush for 3 yards."))
  expect_equal(infer_own_side(df), c(A = "AA", B = "BB"))
})

test_that("a replay-review note doesn't hide a fumble recovery (6461675)", {
  txt <- c(
    "Henrich,Luke pass complete to Rodriguez,Alex for 5 yards to the MSU46 fumbled by Rodriguez,Alex at MSU46 recovered by SALIS Mack,Kilo at MSU46 Mack,Kilo return 46 yards to the MSU00 TOUCHDOWN, clock 01:05. MSU is challenging the ruling on the field - \"Fumble\". PLAY STANDS.",
    "Romano,Caleb pass incomplete short right. WIDU is challenging the ruling on the field - \"Incomplete pass\". PLAY OVERTURNED. (Original Play: Romano pass complete).",
    "Tremba,Ty rush middle for 6 yards. play is under automatic review - \"Targeting\". PLAY STANDS.",
    "Smith rush for 3 yards to the AA40."
  )
  expect_equal(strip_review_note(txt), c(
    "Henrich,Luke pass complete to Rodriguez,Alex for 5 yards to the MSU46 fumbled by Rodriguez,Alex at MSU46 recovered by SALIS Mack,Kilo at MSU46 Mack,Kilo return 46 yards to the MSU00 TOUCHDOWN, clock 01:05.",
    "Romano,Caleb pass incomplete short right.",
    "Tremba,Ty rush middle for 6 yards.",
    "Smith rush for 3 yards to the AA40."
  ))
  df <- data.frame(play_text = txt[1], play_type = "pass_complete", pos_team = "Montclair State",
                   def_pos_team = "Salisbury", down = 1L, distance = 10L, yards_gained = 5L,
                   penalty_no_play = FALSE, kicker_recovered = FALSE)
  out <- parse_outcome_flags(df, c(SALIS = "Salisbury", MSU = "Montclair State"))
  expect_true(out$turnover)
  expect_equal(out$recovering_team, "Salisbury")
})

test_that("a player name ending in 'no' doesn't make a good try 'no good' (6462271)", {
  t <- c("Daniel Avila pass attempt to Julian Toscano good.", "Avila pass attempt failed.",
         "Grwinski kick attempt no good.", "Moreno kick attempt good.")
  k <- data.frame(play_type = c("two_point", "two_point", "extra_point", "extra_point"), play_text = t,
                  touchdown = FALSE, turnover = FALSE, safety = FALSE, kicker_recovered = FALSE,
                  penalty_no_play = FALSE, recovering_team = NA, pos_team = "a")
  expect_equal(score_points(k), c(2L, 0L, 0L, 1L))
})

test_that("a touchdown overturned on review is not a touchdown (6461573)", {
  x <- c(
    "pass incomplete short left to Balson,Xavier thrown to HEID00. HEID is challenging the ruling on the field - \"Incomplete pass\". PLAY OVERTURNED. (Original Play: pass complete short left to X.Balson caught at HEID00, for 14 yards to the HEID00 TOUCHDOWN, clock 06:27, 1ST DOWN).",
    "rush middle for 1 yard gain to the HEID00 TOUCHDOWN, clock 10:57.",
    "rush for 3 yards TOUCHDOWN nullified by penalty",
    "Penalty after touchdown before PAT"
  )
  expect_equal(has_touchdown(x), c(FALSE, TRUE, FALSE, FALSE))
})

test_that("a dead-ball penalty belongs to the team that snaps next (6461790)", {
  kept <- data.frame(
    play_type = c("kickoff", "penalty_no_play", "pass_incomplete", "rush", "penalty_no_play", "kickoff"),
    pos_team = c("UPS", "LC", "UPS", "UPS", "UPS", "LC"), period = 1L,
    try_phase = c(FALSE, FALSE, FALSE, FALSE, TRUE, FALSE),
    play_text = c("kickoff", "PENALTY UPS False Start", "pass", "rush", "PENALTY LC UNS", "kickoff"))
  expect_equal(dead_ball_penalty_team(kept), c("UPS", "UPS", "UPS", "UPS", "UPS", "LC"))
})

test_that("a penalty's team code can be glued to the infraction name", {
  x <- split_infractions("PENALTY CCHolding (Duncan,Jeremy) 10 yards from CC27 to CC17.", c("CC", "MC"))[[1]]
  expect_equal(x$token, "CC")
  expect_equal(x$yards, 10L)
})

test_that("yards_gained on laterals and recovered fumbles is the net from the snap to the last spot", {
  tt <- c(WESTFIEL = "Westfield St.", ANNAMAR = "Anna Maria", MUHL = "Muhlenberg", UNION = "Union (NY)", WIDU = "Widener", MOR = "Moravian")
  k <- data.frame(
    play_text = c(
      # 6462082 play 130: fumble recovered by a teammate and advanced (25 -> 19)
      "Nikolay Boyce rush for loss of 3 yards to the WESTFIEL28, fumble by Nikolay Boyce recovered by ANNAMAR Jeremiah Cadet at WESTFIEL28, Jeremiah Cadet for 9 yards to the WESTFIEL19 (Tafari Proctor).",
      # 6529845 play 111: catch, then a lateral (30 -> 13)
      "Patch Flanagan pass complete to Joe Curran for loss of 1 yard to the MUHL31, Michael Dinardo for 18 yards to the MUHL13 (George Europe).",
      # one carrier: unchanged
      "Dj Wright rush for 1 yard to the MUHL12 (George Europe), PENALTY MUHL face mask (George Europe) 6 yards to the MUHL06.",
      # 6461772 play 76: a review's overturned original play is ignored
      "Romano,Caleb pass complete short left to Tyson,Seth caught at WIDU16, for 7 yards to the WIDU08, out of bounds at WIDU08. WIDU is challenging the ruling on the field - \"Incomplete pass\". PLAY OVERTURNED. (Original Play: C.Romano pass complete short right to K.Baker caught at WIDU00, for 0 yards to the WIDU15, End Of Play)."),
    play_type = c("rush", "pass_complete", "rush", "pass_complete"),
    pos_team = c("Anna Maria", "Union (NY)", "Union (NY)", "Moravian"),
    yards_to_goal = c(25L, 30L, 13L, 15L), yards_gained = c(-3L, -1L, 1L, 7L),
    penalty_no_play = FALSE, turnover = c(TRUE, FALSE, FALSE, FALSE), downs_turnover = c(TRUE, FALSE, FALSE, FALSE))
  expect_equal(net_multi_carrier_yards(k, tt), c(6L, 17L, 1L, 7L))
  # a lost fumble keeps the yards to the fumble
  k$downs_turnover[1] <- FALSE
  expect_equal(net_multi_carrier_yards(k, tt)[1], -3L)
})

test_that("split_infractions: glued codes, accepted + declined, yard lines with a space, 12 men", {
  tk <- c("BEL", "GRE", "MC", "SEW", "OBER", "HIRAM", "FITCHBUR", "LU", "RU", "CMU", "UCHI")
  x <- split_infractions(c(
    "PENALTY BEL Roughing The Passer (Chaffier,Tre) BEL Offside declined 15 yards from GRE36 to BEL49, 1ST DOWN. NO PLAY.",
    "PENALTY MCUNR: Unnecessary Roughness (Boutan,Zabian) 15 yards from SEW31 to SEW46, 1ST DOWN. NO PLAY.",
    "PENALTY LU Face Mask 20 yards from RU 48 to LU32, 1ST DOWN.",
    "PENALTY FITCHBUR 12 men on the field 5 yards to the FITCHBUR13, NO PLAY.",
    "PENALTY OBER UNS: Unsportsmanlike Conduct (Eaton,Jayden) HIRAM Offside (Shellman,Tony) 20 yards from OBER49 to OBER39. NO PLAY",
    "PENALTY CMU Holding declined CMU Running Into The Kicker (Smith) 5 yards from UCHI47 to CMU48"), tk)
  expect_equal(x[[1]]$status, c("accepted", "declined")); expect_equal(x[[1]]$yards[1], 15L)
  expect_equal(x[[2]]$token, "MC"); expect_equal(x[[2]]$yards, 15L)
  expect_equal(x[[3]]$token, "LU")
  expect_equal(x[[4]]$token, "FITCHBUR"); expect_equal(x[[4]]$yards, 5L)
  expect_equal(x[[5]]$token, "OBER"); expect_equal(x[[5]]$yards, 20L)
  expect_equal(x[[6]]$status, c("declined", "accepted")); expect_equal(x[[6]]$yards[2], 5L)
})
