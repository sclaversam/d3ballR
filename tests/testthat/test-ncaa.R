test_that("parse_ncaa_drive_text reads both driveText formats", {
  d <- parse_ncaa_drive_text(c("2 and 9 at 28", "1 and 0 at 4", "2 and  at JHU13",
                               "1 and true at DSON3", "- and - at JHU35", NA))
  expect_equal(d$down, c(2L, 1L, 2L, 1L, NA, NA))
  expect_equal(d$dist, c("9", "Goal", NA, "Goal", NA, NA))
  expect_equal(d$token, c(NA, NA, "JHU", "DSON", NA, NA))
  expect_equal(d$yard, c(28L, 4L, 13L, 3L, NA, NA))
})

test_that("ncaa_to_index_name maps through the crosswalk and keeps unknown names", {
  f <- withr::local_tempfile(fileext = ".csv")
  utils::write.csv(data.frame(ncaa_name = "Alfred St.", index_name = "Alfred State"), f, row.names = FALSE)
  expect_equal(ncaa_to_index_name(c("Alfred St.", "Carnegie Mellon"), f), c("Alfred State", "Carnegie Mellon"))
})

# A tiny ncaa.com-shaped game: Alpha (ncaa home) kicks off, Beta scores a
# touchdown whose extra point ncaa.com has no line for (the score still
# rises by 1), then Alpha starts a drive. driveText has no yardline team.
ncaa_toy <- function() {
  lines <- data.frame(
    period = 1L,
    team_id = c("1", "2", "2", "2", "2", "2", "1", "1"),
    clock = NA_character_,
    drive_text = c(NA, NA, "1 and 10 at 25", NA, "2 and 5 at 30", NA, NA, "1 and 10 at 25"),
    home_score = c(0L, 0L, 0L, NA, 0L, 0L, 0L, 0L),
    visitor_score = c(0L, 0L, 0L, NA, 6L, 7L, 7L, 7L),
    text = c("Smith kickoff 65 yards to the BB0 Jones return 25 yards to the BB25 (Lee).",
             "Beta drive start at 15:00.",
             "Doe rush for 5 yards to the BB30 (Roe).",
             "clock 14:30",
             "Doe rush for 70 yards to the AA0, TOUCHDOWN, clock 14:00.",
             "Kick kickoff 65 yards to the AA0, Touchback.",
             "Alpha drive start at 14:00.",
             "Smith pass complete to Lee for 10 yards to the AA35.")
  )
  teams <- data.frame(team_id = c("1", "2"), name = c("Alpha", "Beta"), ncaa_home = c(TRUE, FALSE))
  ncaa_play_table(lines, teams)
}

test_that("ncaa_play_table recovers the yardline side from spots in the text", {
  tab <- ncaa_toy()
  expect_equal(tab$situation[tab$play == "Doe rush for 5 yards to the BB30 (Roe)."], "1st and 10 at BB25")
  expect_equal(tab$situation[tab$play == "Smith pass complete to Lee for 10 yards to the AA35."], "1st and 10 at AA25")
})

test_that("ncaa_play_table adds a labelled extra point ncaa.com left out", {
  tab <- ncaa_toy()
  td <- which(grepl("TOUCHDOWN", tab$play))
  expect_equal(tab$play[td + 1], ncaa_added_try_text)
  expect_equal(tab$situation[td + 1], "")
  expect_equal(tab$play[td + 2], "Beta 7, Alpha 0")
  expect_equal(sum(grepl("added by d3ballR", tab$play)), 1L)
})

test_that("ncaa_play_table adds drive headers and quarter markers d3football-style", {
  tab <- ncaa_toy()
  expect_equal(tab$play[1], "1st")
  expect_true(all(c("Beta at 15:00", "Alpha at 14:00") %in% tab$play))
  expect_equal(which(tab$play == "Beta at 15:00") + 1L, which(tab$play == "Beta drive start at 15:00."))
})

test_that("a note with no driveText carries the situation before it and is classified", {
  tab <- ncaa_toy()
  i <- which(tab$play == "clock 14:30")
  expect_equal(tab$situation[i], "1st and 10 at BB25")
  expect_equal(classify_plays(tab[i, ])$row_type, "bare_clock")
  expect_false("other" %in% classify_plays(tab)$row_type)
})

test_that("with no running score, the final score decides the missing extra points", {
  lines <- data.frame(
    period = 1L, team_id = c("2", "2", "1"), clock = NA_character_,
    drive_text = c("1 and 10 at 30", NA, "1 and 10 at 25"),
    home_score = NA_integer_, visitor_score = NA_integer_,
    text = c("Doe rush for 70 yards to the AA0, TOUCHDOWN.",
             "Kick kickoff 65 yards to the AA0, Touchback.",
             "Smith rush for 3 yards to the AA28, out of bounds at the BB45.")
  )
  teams <- data.frame(team_id = c("1", "2"), name = c("Alpha", "Beta"), ncaa_home = c(TRUE, FALSE))
  expect_true(ncaa_added_try_text_final %in% ncaa_play_table(lines, teams, final_total = 7L)$play)
  expect_false(any(grepl("added by d3ballR", ncaa_play_table(lines, teams, final_total = 6L)$play)))
})

test_that("with no running score, the scoring summary decides each missing try", {
  lines <- data.frame(
    period = 1L, team_id = c("2", "2", "1", "1", "1", "2"), clock = NA_character_,
    drive_text = c("1 and 10 at 30", NA, "1 and 10 at 25", "1 and 10 at 40", NA, "1 and 10 at 25"),
    home_score = NA_integer_, visitor_score = NA_integer_,
    text = c("Doe rush for 70 yards to the AA0, TOUCHDOWN, clock 10:00.",
             "Kick kickoff 65 yards to the AA0, Touchback.",
             "Smith rush for 75 yards to the BB0, TOUCHDOWN, clock 08:12.",
             "Smith rush for 60 yards to the BB0, TOUCHDOWN, clock 5:01.",
             "Lee kickoff 65 yards to the BB0, Touchback.",
             "Doe rush for 3 yards to the BB28.")
  )
  teams <- data.frame(team_id = c("1", "2"), name = c("Alpha", "Beta"), ncaa_home = c(TRUE, FALSE))
  # Beta's 10:00 kick good, Alpha's 08:12 two-pointer good, Alpha's 05:01 try failed (not listed)
  scoring <- data.frame(period = 1L, team_id = c("2", "2", "1", "1", "1"),
                        time = c("10:00", "", "08:12", "", "05:01"),
                        type = c("TD", "XP", "TD", "TPC", "TD"), text = "")
  tab <- ncaa_play_table(lines, teams, final_total = 23L, scoring = scoring)
  after <- function(p) tab$play[which(startsWith(tab$play, p)) + 1L]
  expect_equal(after("Doe rush for 70"), ncaa_added_try_text_summary)
  expect_equal(after("Smith rush for 75"), ncaa_added_two_point_text)
  expect_false(startsWith(after("Smith rush for 60"), "kick attempt"))
  expect_false(ncaa_added_try_text_final %in% tab$play)
  expect_equal(classify_plays(tibble::tibble(situation = "", play = ncaa_added_two_point_text))$row_type, "two_point")
})

test_that("ncaa_scoring_entries flattens the scoring summary", {
  j <- list(periods = list(
    list(title = "1st Quarter", summary = list(
      list(teamId = "704", time = "11:10", scoreType = "TD", scoreText = "A runs 1 yard for a touchdown."),
      list(teamId = "704", time = "", scoreType = "XP", scoreText = "B extra point is good."))),
    list(title = "2nd Quarter", summary = list(
      list(teamId = "1806", time = "00:00", scoreType = "FG", scoreText = "C field goal is good.")))))
  e <- ncaa_scoring_entries(j)
  expect_equal(e$period, c(1L, 1L, 2L))
  expect_equal(e$type, c("TD", "XP", "FG"))
  expect_equal(e$time, c("11:10", "", "00:00"))
})

test_that("conf_seo reads a scoreboard team's conference tag", {
  expect_equal(conf_seo(list(conferences = list(list(conferenceName = "", conferenceSeo = "centennial")))), "centennial")
  expect_equal(conf_seo(list(conferences = list())), "")
})

test_that("the conference crosswalk covers every D3 conference tag with a unique code", {
  tab <- utils::read.csv(test_path("../../data-raw/ncaa/conference_names.csv"), na.strings = "")
  expect_false(anyDuplicated(tab$ncaa_seo) > 0)
  expect_false(anyDuplicated(tab$conference_code) > 0)
  expect_true(all(c("centennial", "wiac", "njac", "middle-atlantic") %in% tab$ncaa_seo))
})

test_that("ncaa_lines drops a line ncaa.com repeated verbatim", {
  pl <- function(t) list(clock = "06:36", driveText = "4 and 14 at 16", homeScore = "0", visitorScore = "0", playText = t)
  j <- list(periods = list(list(periodNumber = "2", playbyplayStats = list(
    list(teamId = "543", plays = list(pl("rush for 16 yards loss to the TLU00. SAFETY"),
                                      pl("rush for 16 yards loss to the TLU00. SAFETY"),
                                      pl("kickoff 62 yards")))))))
  l <- ncaa_lines(j)
  expect_equal(l$text, c("rush for 16 yards loss to the TLU00. SAFETY", "kickoff 62 yards"))
})

test_that("fetch_ncaa_json doesn't retry a path that returned an HTTP error this run", {
  reset_fetch_state()
  withr::local_options(d3ballR.offline = FALSE, d3ballR.ncaa_cache_dir = withr::local_tempdir())
  assign("http_failed", c("/game/1/play-by-play" = "502"), envir = d3ballR:::.d3_state)
  expect_error(fetch_ncaa_json("/game/1/play-by-play"), "earlier this run; not retried")
  expect_equal(n_requests(), 0L)
  reset_fetch_state()
})

test_that("parse_coin_deferrer reads the toss winner who defers", {
  expect_equal(parse_coin_deferrer("Martin Luther wins toss and defers; WEC will receive; MLC will defend West end-zone."), "Martin Luther")
  expect_true(is.na(parse_coin_deferrer("Westfield won the coin toss and elected to receive.")))
})

test_that("a try whose points ncaa.com gives to the defense is labelled a defensive conversion", {
  lines <- data.frame(
    period = 4L, team_id = c("A", "A", "A", "A", "B"), clock = NA_character_,
    drive_text = c("1 and 10 at 3", "1 and 0 at 3", "1 and 10 at 35", "- and - at 35", "1 and 10 at 25"),
    home_score = c(14L, 14L, 16L, 16L, 16L), visitor_score = c(14L, 20L, 20L, 20L, 20L),
    text = c("Shotgun Clark,Joseph rush middle for 3 yards gain to the IC03.",
             "Shotgun Clark,Joseph rush middle for 3 yards gain to the IC00 TOUCHDOWN, clock 04:04.",
             "Johnson,Jaylen rush attempt Successful.",
             "Schambach,Hudson kickoff 65 yards to the IC00, Touchback.",
             "Shotgun Elliott,Tyson rush right for 8 yards gain to the IC33."))
  teams <- data.frame(team_id = c("A", "B"), name = c("Lake Forest", "Illinois College"), ncaa_home = c(FALSE, TRUE))
  tab <- ncaa_play_table(lines, teams)
  hit <- tab$play[grepl("Johnson,Jaylen", tab$play)]
  expect_true(grepl("^Johnson,Jaylen rush attempt Successful\\.", hit))
  expect_true(grepl("defensive two-point conversion", hit, fixed = TRUE))
})

test_that("a SAFETY marked NO PLAY: running score, then scoring summary, then the safety kick decide", {
  mk <- function(kick_dt, vis = c(0L, 2L, 2L)) data.frame(
    period = 1L, team_id = "G", clock = NA_character_,
    drive_text = c("4 and 7 at 9", "4 and 7 at 9", kick_dt),
    home_score = c(0L, 0L, 0L), visitor_score = vis,
    text = c("Shotgun Romano,Caleb pass incomplete short left thrown to GEN14.",
             "Baker,Evan pass incomplete short middle to Baker,Evan thrown to GEN00. Shenandoah SAFETY, clock 13:50 PENALTY GEN Illegal Forward Pass (Baker,Evan). NO PLAY.",
             "Reitler,Ryan kickoff 52 yards to the SHE28 Walker,Roge't return 12 yards to the SHE40."))
  teams <- data.frame(team_id = c("S", "G"), name = c("Shenandoah", "Geneva"), ncaa_home = c(FALSE, TRUE))
  labelled <- function(lines, scoring = NULL) {
    tab <- ncaa_play_table(lines, teams, scoring = scoring)
    grepl(ncaa_safety_label, tab$play[grepl("Illegal Forward Pass", tab$play)], fixed = TRUE)
  }
  # 1. running score: decides on its own
  expect_true(labelled(mk("1 and 10 at 35", vis = c(0L, 2L, 2L))))
  expect_false(labelled(mk("1 and 10 at 20", vis = c(1L, 1L, 1L))))
  # 2. no running score: the scoring summary's safety at the same period and clock
  none <- c(0L, 0L, 0L)
  summ <- data.frame(period = 1L, quarter = 1L, team_id = "S", time = "13:50", type = "", text = "Team safety.")
  expect_true(labelled(mk("1 and 10 at 35", vis = none), scoring = summ))
  # 3. last resort: the safety kick from the 20
  expect_true(labelled(mk("1 and 10 at 20", vis = none)))
  expect_false(labelled(mk("1 and 10 at 35", vis = none)))
})

test_that("ncaa_period_number reads the period title", {
  expect_equal(ncaa_period_number("3rd Quarter", 2), 3L)
  expect_equal(ncaa_period_number("OT", 4), 5L)
  expect_equal(ncaa_period_number("2OT", 5), 6L)
  expect_equal(ncaa_period_number(NULL, 2), 2L)
})

test_that("a scoring summary missing a team's tries isn't evidence that a try failed", {
  lines <- data.frame(
    period = 3L, team_id = c("A", "A", "A", "A", "B"), clock = NA_character_,
    drive_text = c("1 and 10 at 5", "1 and 10 at 35", "1 and 10 at 5", "1 and 0 at 3", "1 and 10 at 25"),
    home_score = 0L, visitor_score = 0L,
    text = c("Hill rush for 5 yards to the BATES00, TOUCHDOWN, clock 03:00.",
             "Fulcher kickoff 65 yards to the BATES00, touchback.",
             "Hill pass complete to Jung for 5 yards to the BATES00, TOUCHDOWN, clock 01:56.",
             "Fulcher kick attempt good.",
             "Perry rush for 4 yards to the AMHERST29."))
  teams <- data.frame(team_id = c("A", "B"), name = c("Amherst", "Bates"), ncaa_home = c(FALSE, TRUE))
  # the summary lists both touchdowns but neither try, though the text has one good kick
  summ <- data.frame(period = 1L, quarter = 3L, team_id = "A", time = c("03:00", "01:56"), type = "TD", text = "")
  tab <- ncaa_play_table(lines, teams, final_total = 14L, scoring = summ)
  expect_true(any(tab$play == ncaa_added_try_text_final))
})
