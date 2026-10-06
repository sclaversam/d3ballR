# Data test: every built game's points by team (from score_pts) must equal
# the boxscore's line-score final, recorded in
# analysis/checks/{season}/pbp_row_counts.csv by build_all_pbp(). Runs on
# every season folder in analysis/pbp/.

test_that("sum of score_pts by team equals the boxscore final score, for every built game", {
  root <- test_path("../..")
  seasons <- list.files(file.path(root, "analysis/pbp"), pattern = "^\\d{4}$")
  skip_if(!length(seasons), "no built seasons")
  for (season in seasons) {
    counts_file <- file.path(root, "analysis/checks", season, "pbp_row_counts.csv")
    expect_true(file.exists(counts_file), label = paste(season, "pbp_row_counts.csv exists"))
    if (!file.exists(counts_file)) next
    counts <- utils::read.csv(counts_file, na.strings = "", colClasses = c(game_id = "character"))
    built <- sub("\\.csv$", "", list.files(file.path(root, "analysis/pbp", season), pattern = "\\.csv$"))
    expect_setequal(counts$game_id, built)
    for (i in seq_len(nrow(counts))) {
      g <- utils::read.csv(file.path(root, "analysis/pbp", season, paste0(counts$game_id[i], ".csv")), na.strings = "")
      expect_identical(team_points(g, counts$away[i]), as.integer(counts$away_final[i]),
                       label = paste(counts$game_id[i], counts$away[i], "points"))
      expect_identical(team_points(g, counts$home[i]), as.integer(counts$home_final[i]),
                       label = paste(counts$game_id[i], counts$home[i], "points"))
    }
  }
})

test_that("team_points credits negative score_pts to the defense", {
  g <- data.frame(pos_team = c("A", "A", "B", "B"), def_pos_team = c("B", "B", "A", "A"),
                  score_pts = c(6L, 1L, -6L, 3L))
  expect_equal(team_points(g, "A"), 13L)
  expect_equal(team_points(g, "B"), 3L)
})

test_that("team page parsing: season conference code and '*' markers", {
  html <- xml2::read_html('<html><body>
    <table><tr><td>9/6</td><td>at <a href="/teams/Chicago/2025">Chicago</a> &bull;</td>
      <td>W, 20-0</td><td><a href="/seasons/2025/boxscores/20250906_e064.xml">BX</a></td></tr>
    <tr><td>10/4</td><td>vs. <a href="/teams/McDaniel/2025">McDaniel</a> * &bull;</td>
      <td>W, 56-7</td><td><a href="/seasons/2025/boxscores/20251004_gwn0.xml">BX</a></td></tr></table>
    <table><tr><td>10/4</td><td>vs. McDaniel *</td><td><a href="/seasons/2025/boxscores/20251004_gwn0.xml">BX</a></td></tr></table>
    <a href="/conf/CC/2025/standings">CC</a> <a href="/conf/PAC/2024/standings">PAC</a>
  </body></html>')
  expect_equal(parse_team_conference_code(html, 2025), "CC")
  expect_equal(parse_team_conference_code(html, 2024), "PAC")
  expect_true(is.na(parse_team_conference_code(html, 2019)))
  s <- parse_team_schedule(html, "Carnegie Mellon", 2025)
  expect_equal(s$conference_marker[match(c("20250906_e064", "20251004_gwn0"), s$game_id)], c(FALSE, TRUE))
  expect_equal(nrow(s), 2)
  expect_equal(team_slug("Franklin and Marshall"), "Franklin_and_Marshall")
})

test_that("game_conferences uses the marker, not shared membership", {
  conf <- list(
    table = data.frame(team = c("Johns Hopkins", "Franklin and Marshall"), conference = "Centennial Conference"),
    markers = data.frame(game_id = c("g_conf", "g_playoff"), conference_marker = c(TRUE, FALSE))
  )
  reg <- game_conferences("g_conf", "Johns Hopkins", "Franklin and Marshall", conf)
  po <- game_conferences("g_playoff", "Johns Hopkins", "Franklin and Marshall", conf)
  expect_true(reg$conference_game)
  expect_false(po$conference_game)
  expect_true(po$shared_conference)
  expect_true(is.na(game_conferences("g_x", "Johns Hopkins", "Nobody", conf)$away_team_conference))
})
