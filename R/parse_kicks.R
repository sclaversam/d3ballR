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

#' Kickoff, punt and field-goal details from the play text
#'
#' Thirteen cfbfastR-named columns: kick and return distance, how the kick
#' ended (touchback, out of bounds, fair catch, downed, onside), and field
#' goal distance. Only the text before the first "PENALTY" is read, as in
#' [parse_yards_gained()], so enforcement yardage never lands here.
#'
#' The end-of-kick flags (`*_tb`, `*_oob`, `*_fair_catch`, `punt_downed`)
#' read only the kick itself: the text up to the first return, muff, fumble,
#' recovery, block or lateral. So "return 13 yards to the APP33, out of
#' bounds" (the returner ran out) is not `punt_oob`; "punt 18 yards to the
#' JHU25, out of bounds" is.
#'
#' No-play gating as in `docs/schema.md`: on a `penalty_no_play` row every
#' yardage is NA and every flag FALSE.
#'
#' @param play_text Character vector, the raw play description.
#' @param play_type Character vector, from [parse_play_type()].
#' @param no_play Logical vector, `penalty_no_play`.
#' @return A data frame with one row per input row: `yds_kickoff`,
#'   `yds_kickoff_return`, `kickoff_tb`, `kickoff_oob`, `kickoff_fair_catch`,
#'   `kickoff_onside`, `yds_punted`, `yds_punt_return`, `punt_tb`, `punt_oob`,
#'   `punt_fair_catch`, `punt_downed`, `yds_fg`. Yardage is integer, NA on
#'   other rows and when not printed; flags are logical, never NA.
#' @keywords internal
parse_kick_details <- function(play_text, play_type, no_play) {
  ic <- function(pattern) stringr::regex(pattern, ignore_case = TRUE)
  text <- stringr::str_remove(play_text, "PENALTY .*$")
  kick <- stringr::str_remove(text, ic("(return|muff|fumble|recovered|blocked|lateral).*$"))
  has <- function(x, pattern) stringr::str_detect(x, ic(pattern))
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
    kickoff_tb = ko & has(kick, "touchback"),
    kickoff_oob = ko & has(kick, "out.of.bounds"),
    kickoff_fair_catch = ko & has(kick, "fair catch"),
    kickoff_onside = ko & has(text, "\\bonside\\b"),
    yds_punted = int_or_na(pu, punted_yds),
    yds_punt_return = int_or_na(pu, returned),
    punt_tb = pu & has(kick, "touchback"),
    punt_oob = pu & has(kick, "out.of.bounds"),
    punt_fair_catch = pu & has(kick, "fair catch"),
    punt_downed = pu & has(kick, "\\bdowned\\b"),
    yds_fg = int_or_na(fg, suppressWarnings(as.integer(stringr::str_match(text, ic("attempt from (\\d+)"))[, 2])))
  )
}
