#' Detect penalties that nullified the snap
#'
#' `penalty_no_play` is TRUE when the play text says "NO PLAY", or the row is
#' a dead-ball penalty with no snap at all (its text starts with "PENALTY";
#' e.g. a false start in the StatCrew format that doesn't print "NO PLAY").
#' It deliberately does NOT trust the upstream `row_type ==
#' "penalty_no_play"` label on its own. That label is wrong on two kickoffs
#' with a return penalty (Dickinson 191, Ursinus 73), where the kickoff still
#' counts, and on "Penalty after touchdown before PAT" marker rows. See
#' "Known bugs" in `analysis/pbp_schema.md`.
#'
#' @param play_text,row_type Character vectors.
#' @return Logical vector.
#' @keywords internal
is_no_play <- function(play_text, row_type) {
  stringr::str_detect(play_text, stringr::regex("\\bno play\\b", ignore_case = TRUE)) |
    (row_type == "penalty_no_play" & stringr::str_detect(play_text, "^PENALTY "))
}

#' Split a play's penalty clause into individual infractions
#'
#' One "PENALTY" clause can hold several infractions
#' ("PENALTY CMU Holding declined CMU Running Into The Kicker (...) 5 yards
#' from UCHI47 to CMU48"). Each infraction is a team token, a name, an
#' optional (player), then one of: "N yard(s) from X to Y", "N yard(s) to
#' the X", "declined", or "off-setting"/"offsetting". Team tokens match
#' case-sensitively so a lower-case word in a name can't pass as one.
#' Enforcement yards come
#' only from "N yard(s) from/to", never from the play's "for N yards"
#' (convention 5).
#'
#' @param clause Character vector: text from the first "PENALTY" onward.
#' @param tokens The game's play-text team tokens (names of
#'   [infer_text_team()]'s output).
#' @return A list, one data frame per element of `clause`, with columns
#'   `token`, `yards` (integer), `status` ("accepted", "declined",
#'   "offsetting").
#' @keywords internal
split_infractions <- function(clause, tokens) {
  tok <- paste(stringr::str_replace_all(tokens, "([&])", "\\\\\\1"), collapse = "|")
  pattern <- paste0(
    "\\b(", tok, ") .*?",
    "(?:(\\d+) yards? (?:from|to)|(?i:(declined)|(off-?setting)))"
  )
  lapply(clause, function(cl) {
    if (is.na(cl)) return(data.frame(token = character(), yards = integer(), status = character()))
    m <- stringr::str_match_all(cl, pattern)[[1]]
    data.frame(
      token = m[, 2],
      yards = suppressWarnings(as.integer(m[, 3])),
      status = ifelse(!is.na(m[, 4]), "declined", ifelse(!is.na(m[, 5]), "offsetting", "accepted"))
    )
  })
}

#' Populate the penalty columns
#'
#' Sets `penalty_flag`, `penalty_yards_signed`, `penalized_team`,
#' `penalty_no_play`, `penalty_declined`, `penalty_text` per conventions 1-5
#' in `analysis/pbp_schema_and_build_plan.md`.
#'
#' - `penalty_flag`: text mentions a penalty (any case).
#' - `penalty_text`: the raw clause from the first upper-case "PENALTY"
#'   onward (so "TOUCHDOWN nullified by penalty" isn't mistaken for the
#'   clause start). NA if none.
#' - `penalized_team`: team name of the accepted infraction(s); for an
#'   offsetting or two-team row, both names joined by "; ". If every
#'   infraction was declined, the declined team.
#' - `penalty_yards_signed`: sum of the accepted infractions' yards, each
#'   positive if the defense (`def_pos_team`) was flagged and negative if the
#'   offense (`pos_team`) was. Offsetting -> 0. All declined -> NA. On a
#'   kickoff, `pos_team` is the kicking team, so the sign is relative to the
#'   kicking team.
#' - `penalty_declined`: TRUE when there are infractions and every one was
#'   declined. A row with one declined and one accepted infraction is FALSE,
#'   and the accepted one supplies the yards.
#' - `penalty_no_play`: see [is_no_play()].
#'
#' @param df Kept rows with `play_text`, `row_type`, `pos_team`,
#'   `def_pos_team`.
#' @param text_team Output of [infer_text_team()].
#' @return `df` with the six penalty columns set.
#' @keywords internal
parse_penalties <- function(df, text_team) {
  txt <- df$play_text
  flag <- stringr::str_detect(txt, stringr::regex("penalty", ignore_case = TRUE))
  clause <- stringr::str_extract(txt, "PENALTY .*$")
  inf <- split_infractions(clause, names(text_team))

  n <- nrow(df)
  yards <- rep(NA_integer_, n)
  team <- rep(NA_character_, n)
  declined <- rep(NA, n)
  for (i in seq_len(n)) {
    x <- inf[[i]]
    if (!nrow(x)) next
    x$team <- unname(text_team[x$token])
    acc <- x[x$status == "accepted", ]
    off <- x[x$status == "offsetting", ]
    declined[i] <- all(x$status == "declined")
    if (nrow(off)) {
      team[i] <- paste(unique(off$team), collapse = "; ")
      yards[i] <- 0L
    } else if (nrow(acc)) {
      team[i] <- paste(unique(acc$team), collapse = "; ")
      sign <- ifelse(acc$team == df$def_pos_team[i], 1L,
                     ifelse(acc$team == df$pos_team[i], -1L, NA_integer_))
      yards[i] <- as.integer(sum(sign * acc$yards))
    } else {
      team[i] <- paste(unique(x$team), collapse = "; ")
    }
  }

  df$penalty_flag <- flag
  df$penalty_yards_signed <- yards
  df$penalized_team <- team
  df$penalty_no_play <- is_no_play(txt, df$row_type)
  df$penalty_declined <- ifelse(flag, declined %in% TRUE, NA)
  df$penalty_text <- clause
  df
}
