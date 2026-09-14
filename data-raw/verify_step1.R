# Step 1 verification: run scrape_plays() across every CMU 2025 game and report
# per game whether it succeeded, how many rows came back, and what the first
# rows look like. Flags games that error, return an out-of-range row count, or
# whose situation/play columns look malformed.
#
# Run from the repo root:  Rscript data-raw/verify_step1.R

options(width = 200)  # keep the sample rows and summary table on one line each

for (f in list.files("R", pattern = "[.]R$", full.names = TRUE)) source(f)
source("data-raw/cmu_2025_games.R")

# A full game's play table is roughly 130-160 scrimmage snaps plus kickoffs,
# scores, drive headers and admin rows, so the raw table runs well above the
# snap count. Anything outside this band is worth eyeballing by hand.
MIN_ROWS <- 150
MAX_ROWS <- 400

# A situation cell should either be a real down-and-distance or one of the
# non-play rows (drive headers, quarter markers). What we do NOT want to see is
# an embedded newline surviving str_squish, or an empty/NA cell.
check_shape <- function(df) {
  problems <- character()

  if (!identical(names(df), c("situation", "play"))) {
    problems <- c(problems, sprintf("columns are %s, expected situation/play",
                                    paste(names(df), collapse = "/")))
  }
  if (any(stringr::str_detect(df$situation, "\\n"), na.rm = TRUE) ||
      any(stringr::str_detect(df$play, "\\n"), na.rm = TRUE)) {
    problems <- c(problems, "newline survived str_squish")
  }
  if (anyNA(df$situation) || anyNA(df$play)) {
    problems <- c(problems, sprintf("%d NA situation / %d NA play",
                                    sum(is.na(df$situation)), sum(is.na(df$play))))
  }

  blank <- sum(!nzchar(df$play), na.rm = TRUE)
  if (blank > 0) problems <- c(problems, sprintf("%d empty play cells", blank))

  dd <- sum(stringr::str_detect(df$situation, "[1-4](st|nd|rd|th)\\s+and\\s+"),
            na.rm = TRUE)
  if (dd == 0) problems <- c(problems, "no down-and-distance rows at all")

  list(problems = problems, down_distance = dd)
}

results <- list()

for (i in seq_along(cmu_2025_games)) {
  url <- cmu_2025_games[[i]]
  label <- sprintf("Game %2d  %s", i, basename(url))
  cat(strrep("=", 78), "\n", label, "\n", sep = "")

  df <- tryCatch(scrape_plays(url), error = function(e) e)

  if (inherits(df, "error")) {
    cat("  STATUS: ERROR -- ", conditionMessage(df), "\n\n", sep = "")
    results[[i]] <- data.frame(game = i, id = basename(url), ok = FALSE,
                               rows = NA_integer_, down_distance = NA_integer_,
                               flags = conditionMessage(df))
    next
  }

  shape <- check_shape(df)
  flags <- shape$problems
  if (nrow(df) < MIN_ROWS || nrow(df) > MAX_ROWS) {
    flags <- c(flags, sprintf("row count %d outside expected %d-%d",
                              nrow(df), MIN_ROWS, MAX_ROWS))
  }

  cat("  STATUS: ok\n")
  cat("  ROWS:  ", nrow(df), "   (", shape$down_distance,
      " with a down-and-distance)\n", sep = "")
  cat("  FLAGS: ", if (length(flags)) paste(flags, collapse = "; ") else "none",
      "\n", sep = "")
  cat("  FIRST 6 ROWS:\n")
  print(utils::head(df, 6))
  cat("\n")

  results[[i]] <- data.frame(
    game = i, id = basename(url), ok = TRUE, rows = nrow(df),
    down_distance = shape$down_distance,
    flags = if (length(flags)) paste(flags, collapse = "; ") else ""
  )
}

cat(strrep("=", 78), "\nSUMMARY\n", sep = "")
print(do.call(rbind, results), row.names = FALSE, right = FALSE)
