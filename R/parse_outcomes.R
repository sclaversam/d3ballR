#' Yardline pattern in play text
#'
#' "to the UCHI45", "at RMCFB32", "to the McD28", "to the Wolves05": a token
#' that starts with a capital letter, then the yard number. Tokens can be
#' upper-case codes, mixed case ("McD"), nicknames ("Wolves"), or two words
#' ("MASS. MA27": the token is "MASS. MA").
#' @keywords internal
text_yard_pattern <- "(?:to the|at the|at|from|to) ([A-Z][A-Za-z&.]{1,9}(?: [A-Z][A-Za-z&.]{0,9})?) ?(\\d{1,2})\\b"

#' Map play-text team tokens to team names
#'
#' The play description names field sides with its own tokens ("to the
#' UCHI45", "recovered by DCFB", "to the Wolves05"), which often differ from
#' the situation column's tokens ("UC 25", "DCC32", "ALV05"). The two play-text
#' tokens are the two most frequent yardline tokens in the text.
#'
#' The mapping is decided by a vote: when a play ends "to the WU34" and the
#' next row's situation reads "at WAY34", the same yard number pairs WU with
#' WAY. Tokens name field sides, not offenses, so this holds across changes
#' of possession too. Of the two possible pairings, the one with more votes
#' wins (it must have at least twice as many). With no votes at all, a token
#' spelled the same as a situation token maps straight across and the other
#' takes the leftover (UCHI -> UC). The situation token is then mapped to a
#' team name with [infer_own_side()]'s output.
#'
#' @param df Kept rows with `play_text`, `situation`.
#' @param own_side Output of [infer_own_side()] (team name -> own token).
#' @return Named character vector: names are play-text tokens, values are
#'   `pos_team` names. Stops if the mapping isn't clear-cut.
#' @keywords internal
infer_text_team <- function(df, own_side) {
  pre_penalty <- stringr::str_remove(df$play_text, "PENALTY .*$")
  m <- stringr::str_match_all(pre_penalty, text_yard_pattern)
  all_tok <- unlist(lapply(m, function(x) x[, 2]))
  freq <- sort(table(all_tok), decreasing = TRUE)
  if (length(freq) < 2) {
    stop("Expected 2 play-text team tokens, got: ", paste(names(freq), collapse = " / "))
  }
  text_tokens <- names(freq)[1:2]
  sit_tokens <- unname(own_side)

  # votes: last yardline in the play text vs the next row's situation yardline
  end_tok <- vapply(m, function(x) if (nrow(x)) x[nrow(x), 2] else NA_character_, character(1))
  end_num <- vapply(m, function(x) if (nrow(x)) as.integer(x[nrow(x), 3]) else NA_integer_, integer(1))
  sm <- stringr::str_match(df$situation, " at ([A-Za-z&.' ]+?) ?(\\d{1,2})$")
  n <- nrow(df)
  nxt_tok <- c(sm[-1, 2], NA)
  nxt_num <- c(suppressWarnings(as.integer(sm[-1, 3])), NA)
  ok <- !is.na(end_tok) & !is.na(nxt_tok) & end_num %in% nxt_num & end_num == nxt_num &
    end_tok %in% text_tokens & nxt_tok %in% sit_tokens & end_num != 50L
  pair_a <- sum(ok & ((end_tok == text_tokens[1] & nxt_tok == sit_tokens[1]) |
                        (end_tok == text_tokens[2] & nxt_tok == sit_tokens[2])))
  pair_b <- sum(ok & ((end_tok == text_tokens[1] & nxt_tok == sit_tokens[2]) |
                        (end_tok == text_tokens[2] & nxt_tok == sit_tokens[1])))

  if (pair_a + pair_b > 0) {
    if (max(pair_a, pair_b) < 2 * min(pair_a, pair_b)) {
      stop("Play-text token vote too close to call (", pair_a, " vs ", pair_b, ").")
    }
    mapped <- if (pair_a >= pair_b) sit_tokens else rev(sit_tokens)
  } else {
    exact <- text_tokens %in% sit_tokens
    if (!any(exact)) {
      stop("No play-text token matches a situation token: ",
           paste(text_tokens, collapse = " / "), " vs ", paste(sit_tokens, collapse = " / "))
    }
    mapped <- ifelse(exact, text_tokens, setdiff(sit_tokens, text_tokens[exact])[1])
  }
  token_to_team <- stats::setNames(names(own_side), own_side)
  stats::setNames(unname(token_to_team[mapped]), text_tokens)
}

#' Regex alternation matching a game's play-text team tokens
#' @param tokens Token strings (names of [infer_text_team()]'s output).
#' @keywords internal
token_regex <- function(tokens) {
  paste0("(", paste(stringr::str_replace_all(tokens, "([.&])", "\\\\\\1"), collapse = "|"), ")")
}

#' Populate the outcome-flag columns
#'
#' Sets `rush`, `pass`, `completion`, `sack`, `int`, `fumble_vec`,
#' `turnover`, `downs_turnover`, `touchdown`, `safety`. All are FALSE on
#' rows with `penalty_no_play` TRUE (see [is_no_play()]), regardless of
#' what the text says.
#'
#' - `rush`: play_type `rush` or `kneel`. A sack is NOT a rush here (it has
#'   its own flag), even though NCAA stats charge sacks to rushing.
#' - `pass`: `pass_complete`, `pass_incomplete`, `pass_intercepted`.
#' - `completion`, `int`, `sack`: the matching play_type.
#' - Two-point tries (`two_point`) get no rush/pass flag; they aren't
#'   scrimmage plays in cfbfastR's counting.
#' - `fumble_vec`: text mentions "fumble"/"fumbled"/"muff", on any row.
#' - `turnover`: an interception, a lost fumble, or a turnover on downs. A
#'   fumble is lost when the LAST "recovered by TEAM" after the fumble is not
#'   the fumbling team. The fumbling team is the offense (`pos_team`) on a
#'   rush/pass/sack/kneel and on kickoffs (where `pos_team` is the receiving
#'   team), and the returning side (`def_pos_team`) on punts, blocked kicks,
#'   and interception returns. A kickoff the kicking team recovers (onside
#'   or a return fumble; `kicker_recovered`) is always a turnover. Exception:
#'   on a blocked kick (`field_goal_blocked`/`punt_blocked`) where the
#'   kicking team gets the ball back on the fumble, possession ends where
#'   it started, so it is NOT a turnover (McDaniel 2025 play 147).
#' - `downs_turnover`: the text says "TURNOVER ON DOWNS", OR it's a 4th-down
#'   rush/pass/sack/kneel that fell short of the line to gain (by the loose
#'   `yards_gained`), wasn't a touchdown, interception, or lost fumble, had no
#'   penalty, and the next row with a down belongs to the other team. Some
#'   StatCrew formats never print the phrase, so the rule is needed.
#' - `touchdown`: text says "TOUCHDOWN" (upper case) and wasn't nullified.
#' - `safety`: text says "safety". None in the 2025 CMU games.
#'
#' @param df Kept rows with `play_text`, `play_type`, `pos_team`,
#'   `def_pos_team`, `down`, `distance`, `yards_gained`, `penalty_no_play`,
#'   `kicker_recovered`.
#' @param text_team Output of [infer_text_team()].
#' @return `df` with the ten flag columns set (logical, never NA).
#' @keywords internal
parse_outcome_flags <- function(df, text_team) {
  ic <- function(pattern) stringr::regex(pattern, ignore_case = TRUE)
  txt <- df$play_text
  pt <- df$play_type
  no_play <- df$penalty_no_play
  scrimmage <- pt %in% c("rush", "kneel", "pass_complete", "pass_incomplete", "sack")

  rush <- pt %in% c("rush", "kneel")
  pass <- pt %in% c("pass_complete", "pass_incomplete", "pass_intercepted")
  completion <- pt == "pass_complete"
  sack <- pt == "sack"
  int <- pt == "pass_intercepted"
  fumble <- stringr::str_detect(txt, ic("\\b(fumbled?|muffed|muff)\\b"))
  # upper-case only: scores are always "TOUCHDOWN"; the lower-case word
  # appears in "Penalty after touchdown before PAT" marker rows
  touchdown <- stringr::str_detect(txt, "\\bTOUCHDOWN\\b") &
    !stringr::str_detect(txt, ic("touchdown nullified"))
  safety <- stringr::str_detect(txt, ic("\\bsafety\\b"))

  # last recovery after the last mention of a fumble
  after_fumble <- stringr::str_replace(txt, ic("^.*\\b(fumbled?|muffed|muff)\\b"), "")
  recov_token <- vapply(
    stringr::str_match_all(after_fumble, paste0("recovered by ", token_regex(names(text_team)), "\\b")),
    function(m) if (nrow(m)) m[nrow(m), 2] else NA_character_, character(1)
  )
  recov_team <- unname(text_team[recov_token])
  # on a kickoff pos_team is the receiving (returning) team
  fumbling_team <- ifelse(scrimmage | pt == "kickoff", df$pos_team, df$def_pos_team)
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

  blocked_kick_regained <- pt %in% c("field_goal_blocked", "punt_blocked") &
    fumble_lost & recov_team == df$pos_team
  turnover <- int | (fumble_lost & !blocked_kick_regained) | downs_turnover |
    df$kicker_recovered

  flags <- list(rush = rush, pass = pass, completion = completion, sack = sack,
                int = int, fumble_vec = fumble, turnover = turnover,
                downs_turnover = downs_turnover, touchdown = touchdown, safety = safety)
  for (nm in names(flags)) df[[nm]] <- flags[[nm]] & !no_play
  df
}
