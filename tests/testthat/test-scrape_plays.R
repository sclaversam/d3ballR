test_that("find_plays picks the down-and-distance table and cleans whitespace", {
  tbls <- list(
    data.frame(a = "header", b = "block"),
    data.frame(
      X1 = c("1st\n and 10 at CMU35", "Chicago at 15:00"),
      X2 = c("Shotgun rush for 3 yards", "UChicago drive start at 15:00.")
    )
  )
  out <- find_plays(tbls)
  expect_named(out, c("situation", "play"))
  expect_equal(out$situation[1], "1st and 10 at CMU35")  # newline squished
})

test_that("find_plays errors when no play table is present", {
  expect_error(find_plays(list(data.frame(a = 1, b = 2))),
               "No play-by-play table found")
})
