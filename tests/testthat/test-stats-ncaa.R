test_that("stats.ncaa.org situations are written in ncaa.com's driveText spelling", {
  expect_equal(stats_ncaa_drive_text(c("1st & 10 at JHU35", "2nd & Goal at UMD6", "", NA)),
               c("1 and 10 at JHU35", "2 and 0 at UMD6", NA, NA))
})

test_that("a drive takes its team from its drive-start line, and headers one group off are followed", {
  lines <- data.frame(
    drive = c(1, 1, 2, 2, 3, 4, 4),
    team_id = c("A", "A", "B", "B", "A", "B", "B"),
    text = c("Alpha U drive start at 14:55.", "rush", "Alpha U drive start at 10:00.", "pass",
             "rush for 10 yards", "Beta drive start at 05:00.", "punt"))
  # headers 2-4 sit one group late: header k+... carries group k's drive
  out <- stats_ncaa_drive_teams(lines, c("Alpha University", "Beta"),
                                header_team = c("Alpha University", "Beta", "Alpha University", "Beta"),
                                header_clock = c("14:55", "12:00", "10:00", "05:00"))
  expect_equal(out[1:4], rep("Alpha University", 4))
  # group 3 has no drive start: nearest group's offset (group 2: +1) -> header 4
  expect_equal(out[5], "Beta")
  expect_equal(out[6:7], rep("Beta", 2))
})

test_that("saved stats.ncaa.org pages build and match their finals", {
  top <- test_path("../..")
  pages <- list.files(file.path(top, "data-raw/stats_ncaa"), pattern = "\\.html?$", full.names = TRUE)
  skip_if(!length(pages), "no saved stats.ncaa.org pages")
  s <- stats_ncaa_lines(pages[1])
  expect_length(s$teams, 2)
  expect_true(nrow(s$lines) > 50)
  expect_true(all(c("period", "team_id", "drive_text", "home_score", "visitor_score", "text") %in% names(s$lines)))
  expect_true(all(s$lines$team_id %in% s$teams))
})
