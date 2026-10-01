#' Flag the "try phase" between a score and the next kickoff
#'
#' Rows after a touchdown, field goal or safety and before the next kickoff
#' in the same half: the extra point / two-point try, plus any penalty or
#' marker rows d3 prints around it. They are untimed and belong to the
#' scoring sequence, not to a new possession.
#'
#' @param kept Kept rows in game order, with `play_type`, `play_text`,
#'   `penalty_no_play`, `half`.
#' @return Logical vector.
#' @keywords internal
flag_try_phase <- function(kept) {
  scoring <- is_scoring_snap(kept)
  n <- nrow(kept)
  out <- logical(n)
  open <- FALSE
  for (i in seq_len(n)) {
    if (i > 1 && kept$half[i] != kept$half[i - 1]) open <- FALSE
    if (kept$play_type[i] == "kickoff") open <- FALSE
    if (open) out[i] <- TRUE
    if (scoring[i]) open <- TRUE
  }
  out
}

#' Does the row's play score points that count (TD, FG, safety)?
#'
#' Used before the outcome flags exist (to place the try phase and the
#' kickoff context). TOUCHDOWN in upper case, not "nullified", not a
#' no-play; `field_goal_good`; or "safety".
#'
#' @param kept Kept rows with `play_type`, `play_text`, `penalty_no_play`.
#' @return Logical vector.
#' @keywords internal
is_scoring_snap <- function(kept) {
  txt <- kept$play_text
  td <- stringr::str_detect(txt, "\\bTOUCHDOWN\\b") &
    !stringr::str_detect(txt, stringr::regex("touchdown nullified", ignore_case = TRUE))
  sf <- stringr::str_detect(txt, stringr::regex("\\bsafety\\b", ignore_case = TRUE))
  (td | kept$play_type == "field_goal_good" | sf) & !kept$penalty_no_play &
    !kept$play_type %in% c("extra_point", "two_point")
}

#' Number drives and the plays within them
#'
#' A drive is one team's continuous possession (cfbfastR convention):
#' - a kickoff opens a new drive for the RECEIVING team and is its
#'   `drive_play_number` 1 (a re-kick, i.e. a kickoff right after another
#'   kickoff, stays on the same drive);
#' - otherwise a new drive opens whenever `pos_team` changes;
#' - try-phase rows (PAT, two-point try, and penalties between a score and
#'   the next kickoff) stay on the drive of the scoring play, even after a
#'   defensive touchdown where the try is by the other team.
#'
#' d3's own drive-footer boundaries are not used: StatCrew sometimes splits
#' one possession into two "drives" (a re-kick after a punt penalty, a
#' penalty on a field goal), and those are merged here because the same
#' team keeps the ball. The opening kickoff is drive 1; no NAs.
#'
#' @param kept Kept rows with `play_type`, `pos_team`, `half`, `try_phase`.
#' @return `kept` with integer `drive_number` and `drive_play_number`.
#' @keywords internal
assign_drives <- function(kept) {
  n <- nrow(kept)
  d <- integer(n)
  cur <- 0L
  team <- NA_character_
  for (i in seq_len(n)) {
    is_ko <- kept$play_type[i] == "kickoff"
    rekick <- is_ko && i > 1 && kept$play_type[i - 1] == "kickoff" && kept$half[i] == kept$half[i - 1]
    new_half <- i == 1 || kept$half[i] != kept$half[i - 1]
    if (cur == 0L || (is_ko && !rekick) || (new_half && !kept$try_phase[i])) {
      cur <- cur + 1L
      team <- kept$pos_team[i]
    } else if (!kept$try_phase[i] && !is_ko && !identical(kept$pos_team[i], team)) {
      cur <- cur + 1L
      team <- kept$pos_team[i]
    }
    d[i] <- cur
  }
  kept$drive_number <- d
  kept$drive_play_number <- stats::ave(seq_len(n), d, FUN = seq_along)
  kept
}
