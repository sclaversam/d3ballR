#' Map play-text team tokens to team names
#'
#' The play description names teams with its own short tokens ("recovered
#' by UCHI ...", "PENALTY DSON ...", "to the UCHI45"), which don't always
#' match the situation column's yardline tokens ("UC 25", "DIC5"). Every 2025
#' game uses exactly two play-text tokens. A token spelled the same as a
#' situation token maps straight across; if one of the two doesn't match, it
#' takes the leftover situation token by elimination (UCHI -> UC, DSON -> DIC).
#' The situation token is then mapped to a team name with [infer_own_side()]'s
#' output.
#'
#' @param df Kept rows with `play_text`.
#' @param own_side Output of [infer_own_side()] (team name -> own token).
#' @return Named character vector: names are play-text tokens, values are
#'   `pos_team` names. Stops if the mapping isn't clear-cut.
#' @keywords internal
infer_text_team <- function(df, own_side) {
  yardline <- stringr::str_match_all(df$play_text, "(?:to the|at the|at|from|to) ([A-Z&]{2,6}) ?\\d{1,2}\\b")
  text_tokens <- sort(unique(unlist(lapply(yardline, function(m) m[, 2]))))
  sit_tokens <- unname(own_side)
  if (length(text_tokens) != 2) {
    stop("Expected 2 play-text team tokens, got: ", paste(text_tokens, collapse = " / "))
  }
  exact <- text_tokens %in% sit_tokens
  if (!any(exact)) {
    stop("No play-text token matches a situation token: ",
         paste(text_tokens, collapse = " / "), " vs ", paste(sit_tokens, collapse = " / "))
  }
  mapped <- ifelse(exact, text_tokens, setdiff(sit_tokens, text_tokens[exact])[1])
  token_to_team <- stats::setNames(names(own_side), own_side)
  stats::setNames(unname(token_to_team[mapped]), text_tokens)
}

#' Detect rows whose snap was wiped out by a penalty
#'
#' Convention 3 in `analysis/pbp_schema_and_build_plan.md`: when a penalty
#' nullifies the snap, the page still prints the negated attempt in full, so
#' no outcome may be credited from that text. A row is no-play if the
#' classifier already typed it `penalty_no_play`, or its text says "NO
#' PLAY". Task 3b turns this into the `penalty_no_play` column.
#'
#' @param play_text,row_type Character vectors.
#' @return Logical vector.
#' @keywords internal
is_no_play <- function(play_text, row_type) {
  row_type == "penalty_no_play" |
    stringr::str_detect(play_text, stringr::regex("\\bno play\\b", ignore_case = TRUE))
}

#' Populate the outcome-flag columns
#'
#' Sets `rush`, `pass`, `completion`, `sack`, `int`, `fumble_vec`,
#' `turnover`, `downs_turnover`, `touchdown`, `safety`. All are FALSE on
#' no-play rows (see [is_no_play()]) regardless of what the text says.
#'
#' - `rush`: play_type `rush` or `kneel`. A sack is NOT a rush here (it has
#'   its own flag), even though NCAA stats charge sacks to rushing.
#' - `pass`: `pass_complete`, `pass_incomplete`, `pass_intercepted`.
#' - `completion`, `int`, `sack`: the matching play_type.
#' - Two-point tries (`two_point`) get no rush/pass flag; they aren't
#'   scrimmage plays in cfbfastR's counting.
#' - `fumble_vec`: text mentions "fumble"/"fumbled", on any row type.
#' - `turnover`: an interception, a lost fumble, or a turnover on downs. A
#'   fumble is lost when the LAST "recovered by TEAM" after the fumble is not
#'   the fumbling team. The fumbling team is the offense (`pos_team`) on a
#'   rush/pass/sack/kneel, and the receiving/returning side (`def_pos_team`)
#'   on kickoffs, punts, blocked kicks, and interception returns.
#' - `downs_turnover`: the text says "TURNOVER ON DOWNS", OR it's a 4th-down
#'   rush/pass/sack/kneel that fell short of the line to gain (by the loose
#'   `yards_gained`), wasn't a touchdown, interception, or lost fumble, had no
#'   penalty, and the next row with a down belongs to the other team. Some
#'   StatCrew formats never print the phrase, so the rule is needed.
#' - `touchdown`: text says "TOUCHDOWN" and wasn't nullified.
#' - `safety`: text says "safety". None in the 2025 CMU games.
#'
#' @param df Kept rows with `play_text`, `row_type`, `play_type`, `pos_team`,
#'   `def_pos_team`, `down`, `distance`, `yards_gained`.
#' @param text_team Output of [infer_text_team()].
#' @return `df` with the ten flag columns set (logical, never NA).
#' @keywords internal
parse_outcome_flags <- function(df, text_team) {
  ic <- function(pattern) stringr::regex(pattern, ignore_case = TRUE)
  txt <- df$play_text
  pt <- df$play_type
  no_play <- is_no_play(txt, df$row_type)
  scrimmage <- pt %in% c("rush", "kneel", "pass_complete", "pass_incomplete", "sack")

  rush <- pt %in% c("rush", "kneel")
  pass <- pt %in% c("pass_complete", "pass_incomplete", "pass_intercepted")
  completion <- pt == "pass_complete"
  sack <- pt == "sack"
  int <- pt == "pass_intercepted"
  fumble <- stringr::str_detect(txt, ic("\\bfumbled?\\b"))
  touchdown <- stringr::str_detect(txt, ic("\\btouchdown\\b")) &
    !stringr::str_detect(txt, ic("touchdown nullified"))
  safety <- stringr::str_detect(txt, ic("\\bsafety\\b"))

  # last recovery after the last mention of a fumble
  after_fumble <- stringr::str_replace(txt, ic("^.*\\bfumbled?\\b"), "")
  recov_token <- vapply(
    stringr::str_match_all(after_fumble, "recovered by ([A-Z&]{2,6})\\b"),
    function(m) if (nrow(m)) m[nrow(m), 2] else NA_character_, character(1)
  )
  recov_team <- unname(text_team[recov_token])
  fumbling_team <- ifelse(scrimmage, df$pos_team, df$def_pos_team)
  fumble_lost <- fumble & !is.na(recov_team) & !is.na(fumbling_team) & recov_team != fumbling_team

  # next row with a down (skips PATs/kickoffs); does it belong to the other team?
  has_down <- !is.na(df$down)
  idx <- seq_len(nrow(df))
  next_down_row <- vapply(idx, function(i) {
    j <- which(has_down & idx > i)
    if (length(j)) j[1] else NA_integer_
  }, integer(1))
  next_team <- df$pos_team[next_down_row]
  short_on_4th <- df$down %in% 4L & scrimmage & !is.na(df$yards_gained) &
    df$yards_gained < df$distance & !touchdown & !fumble_lost &
    !stringr::str_detect(txt, ic("penalty")) &
    !is.na(next_team) & next_team != df$pos_team
  downs_turnover <- stringr::str_detect(txt, ic("turnover on downs")) | short_on_4th

  turnover <- int | fumble_lost | downs_turnover

  flags <- list(rush = rush, pass = pass, completion = completion, sack = sack,
                int = int, fumble_vec = fumble, turnover = turnover,
                downs_turnover = downs_turnover, touchdown = touchdown, safety = safety)
  for (nm in names(flags)) df[[nm]] <- flags[[nm]] & !no_play
  df
}
