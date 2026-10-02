sd <- data.frame(season = c(2020L, 2024L, 2025L),
                 regular_season_end = as.Date(c(NA, "2024-11-16", "2025-11-15")))

test_that("season comes from the URL path, not the date", {
  expect_equal(extract_season("https://www.d3football.com/seasons/2020/boxscores/20210313_abcd.xml"), 2020L)
  expect_equal(extract_season("https://www.d3football.com/seasons/2025/boxscores/20251122_xsab.xml"), 2025L)
})

test_that("season_type uses regular_season_end; 2020 is all regular", {
  expect_equal(
    classify_season_type(as.Date(c("2025-11-15", "2025-11-22", "2021-04-10")), c(2025L, 2025L, 2020L), sd),
    c("regular", "postseason", "regular")
  )
})

test_that("date-based week: first Saturday of September is week 1; postseason restarts at 1", {
  d <- as.Date(c("2025-09-04", "2025-09-06", "2025-09-13", "2025-11-15", "2025-11-22", "2025-12-20"))
  st <- classify_season_type(d, 2025L, sd)
  expect_equal(date_based_week(d, 2025L, st, sd), c(1L, 1L, 2L, 11L, 1L, 5L))
  # 2024: d3's week 1 includes Sunday Sep 8, which a Sun-Sat count puts in week 2
  expect_equal(date_based_week(as.Date(c("2024-09-07", "2024-09-08")), 2024L, "regular", sd), c(1L, 2L))
})

test_that("parse_scoreboard_page reads game rows and attaches neutral-site notes", {
  html <- xml2::read_html('<div class="schedule tabular-data"><table>
    <tr><th>Date</th><th>Away</th><th></th><th>Home</th><th></th><th>Time/Status</th><th>Links</th></tr>
    <tr><td> Nov. 22</td><td><a href="/teams/Misericordia/2025">Misericordia</a></td><td><span> 17 </span></td>
        <td>No. 9 <a href="/teams/Carnegie%20Mellon/2025">Carnegie Mellon</a></td><td><span> 24 </span></td>
        <td>Final</td><td><a href="/seasons/2025/boxscores/20251122_xsab.xml">BX</a></td></tr>
    <tr><td></td><td colspan="6">@ Canton, Ohio</td></tr>
  </table></div>')
  rows <- parse_scoreboard_page(html, 2025, 12)
  expect_equal(nrow(rows), 1)
  expect_equal(rows$home, "Carnegie Mellon")
  expect_equal(rows$away_score, 17L)
  expect_equal(rows$site_note, "@ Canton, Ohio")
  idx <- finalize_season_index(rows, sd)
  expect_equal(idx$game_id, "20251122_xsab")
  expect_equal(idx$season_type, "postseason")
  expect_equal(idx$week, 1L)
})
