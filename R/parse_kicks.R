#' Return yards from a kick or interception description
#'
#' Reads the first return in the text: "return 21 yards", "return 1 yard",
#' "return for loss of 7 yards", "return for no gain". A second return later
#' in the same text (after a fumble) is ignored.
#'
#' @param text Character vector, play text with the penalty clause removed.
#' @return Integer vector; NA where the text has no return.
#' @keywords internal
parse_return_yards <- function(text) {
  ic <- function(pattern) stringr::regex(pattern, ignore_case = TRUE)
  m <- stringr::str_match(text, ic("return (?:for )?(loss of )?(-?\\d+) yards?"))
  yds <- suppressWarnings(as.integer(m[, 3]))
  yds <- ifelse(!is.na(m[, 2]), -yds, yds)
  yds[is.na(yds) & stringr::str_detect(text, ic("return for no gain"))] <- 0L
  as.integer(yds)
}

#' Kickoff, punt and field-goal distances from the play text
#'
#' Five cfbfastR-named yardage columns: kick and return distance for
#' kickoffs and punts, and field goal distance. Only the text before the
#' first "PENALTY" is read, as in [parse_yards_gained()], so enforcement
#' yardage never lands here.
#'
#' No-play gating as in `docs/schema.md`: on a `penalty_no_play` row every
#' yardage is NA.
#'
#' @param play_text Character vector, the raw play description.
#' @param play_type Character vector, from [parse_play_type()].
#' @param no_play Logical vector, `penalty_no_play`.
#' @return A data frame with one row per input row: `yds_kickoff`,
#'   `yds_kickoff_return`, `yds_punted`, `yds_punt_return`, `yds_fg`.
#'   Integer; NA on other rows and when not printed.
#' @keywords internal
parse_kick_details <- function(play_text, play_type, no_play) {
  ic <- function(pattern) stringr::regex(pattern, ignore_case = TRUE)
  text <- stringr::str_remove(play_text, "PENALTY .*$")
  int_or_na <- function(keep, x) ifelse(keep, x, NA_integer_)

  ko <- play_type == "kickoff" & !no_play
  pu <- play_type %in% c("punt_no_return", "punt_with_return", "punt_blocked") & !no_play
  fg <- play_type %in% c("field_goal_good", "field_goal_missed", "field_goal_blocked") & !no_play

  punted <- stringr::str_match(text, ic("punt (loss of )?(-?\\d+) yards?"))
  punted_yds <- suppressWarnings(as.integer(punted[, 3]))
  punted_yds <- ifelse(!is.na(punted[, 2]), -punted_yds, punted_yds)
  returned <- parse_return_yards(text)

  data.frame(
    yds_kickoff = int_or_na(ko, suppressWarnings(as.integer(stringr::str_match(text, ic("kickoff (-?\\d+) yards?"))[, 2]))),
    yds_kickoff_return = int_or_na(ko, returned),
    yds_punted = int_or_na(pu, punted_yds),
    yds_punt_return = int_or_na(pu, returned),
    yds_fg = int_or_na(fg, suppressWarnings(as.integer(stringr::str_match(text, ic("attempt from (\\d+)"))[, 2])))
  )
}
