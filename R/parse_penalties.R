#' Detect penalties that nullified the snap
#'
#' `penalty_no_play` is TRUE when the play text says "NO PLAY", or the row is
#' a dead-ball penalty with no snap at all (its text starts with "PENALTY";
#' e.g. a false start in the StatCrew format that doesn't print "NO PLAY").
#' Decided from the text alone, never from the classifier's `row_type`
#' label.
#'
#' @param play_text Character vector.
#' @return Logical vector.
#' @keywords internal
is_no_play <- function(play_text) {
  stringr::str_detect(play_text, stringr::regex("\\bno play\\b", ignore_case = TRUE)) |
    stringr::str_detect(play_text, "^PENALTY ")
}

#' Split a play's penalty clause into individual infractions
#'
#' One "PENALTY" clause can hold several infractions
#' ("PENALTY CMU Holding declined CMU Running Into The Kicker (...) 5 yards
#' from UCHI47 to CMU48"). Each infraction is a team token, a name, an
#' optional (player), then one of: "N yard(s) from X to Y", "N yard(s) to
#' the X", "declined", "off-setting"/"offsetting", or nothing but ", 1ST
#' DOWN" (a foul with no yardage printed, e.g. "PENALTY FMC Pass
#' Interference, 1ST DOWN. NO PLAY."; accepted, 0 yards). Team tokens match
#' case-sensitively so a lower-case word in a name can't pass as one.
#' Enforcement yards come
#' only from "N yard(s) from/to", never from the play's "for N yards"
#' (convention 5).
#'
#' The team code is followed by a space, or (in some host files) by the
#' infraction name with no space ("PENALTY CCHolding 10 yards ...",
#' "MCUNR: Unnecessary Roughness"). The clause is cut at each team code;
#' when an infraction is followed by a declined one that carries the
#' enforcement yards ("BEL Roughing The Passer BEL Offside declined 15
#' yards from ..."), the yards belong to the first.
#'
#' @param clause Character vector: text from the first "PENALTY" onward.
#' @param tokens The game's play-text team tokens (names of
#'   [infer_text_team()]'s output).
#' @return A list, one data frame per element of `clause`, with columns
#'   `token`, `yards` (integer), `status` ("accepted", "declined",
#'   "offsetting").
#' @keywords internal
split_infractions <- function(clause, tokens) {
  # where an infraction starts: a team code, then a space (not a yard
  # number: "from EC 28") or, in some files, the infraction name glued on
  # ("PENALTY MCHolding", "GUIllegal", "MCUNR: Unnecessary Roughness")
  # ("12 men on the field" is a foul name, "EC 28" a yard line)
  start_pat <- paste0("\\b", token_regex(tokens), "(?:(?= (?!\\d{1,2}\\b(?! men)))|(?=[A-Z][a-z])|(?=[A-Z]{2,4}:))")
  yard_pat <- "(\\d+) yards? (?:from|to)"
  empty <- data.frame(token = character(), yards = integer(), status = character())
  lapply(clause, function(cl) {
    if (is.na(cl)) return(empty)
    loc <- stringr::str_locate_all(cl, start_pat)[[1]]
    if (!nrow(loc)) return(empty)
    tok <- stringr::str_sub(cl, loc[, 1], loc[, 2])
    ends <- c(loc[-1, 1] - 1L, nchar(cl))
    chunk <- stringr::str_sub(cl, loc[, 1], ends)
    yards <- suppressWarnings(as.integer(stringr::str_match(chunk, yard_pat)[, 2]))
    declined <- stringr::str_detect(chunk, stringr::regex("declined", ignore_case = TRUE))
    offsetting <- stringr::str_detect(chunk, stringr::regex("off-?setting", ignore_case = TRUE))
    first_down <- stringr::str_detect(chunk, ", 1ST DOWN")
    status <- ifelse(declined, "declined", ifelse(offsetting, "offsetting", "accepted"))
    # "A Roughing The Passer B Offside declined 15 yards from ...": the
    # yards printed after a declined infraction are the accepted one's
    # before it, which has no ending of its own (6461520)
    # Any other infraction with no ending of its own runs on to the next
    # ending, which it takes ("A Holding B UNS 25 yards ...": A, 25 yards;
    # "A Holding B UNR offsetting C UNS offsetting": A and C offsetting).
    pending <- status == "accepted" & is.na(yards) & !first_down
    drop <- rep(FALSE, length(chunk))
    for (k in seq_along(chunk)[-1]) {
      j <- k - 1L
      while (j >= 1L && drop[j]) j <- j - 1L
      if (j < 1L || !pending[j]) next
      if (status[k] == "declined" && !is.na(yards[k])) {
        yards[j] <- yards[k]
        yards[k] <- NA_integer_
      } else {
        yards[j] <- yards[k]
        status[j] <- status[k]
        first_down[j] <- first_down[k]
        pending[j] <- pending[k]
        drop[k] <- TRUE
      }
      if (!pending[j]) pending[j] <- FALSE
    }
    # an infraction needs an ending: yards, declined, offsetting, or a bare
    # ", 1ST DOWN" (accepted, 0 yards); anything else isn't one
    keep <- !drop & (!is.na(yards) | status != "accepted" | first_down)
    yards[status == "accepted" & is.na(yards)] <- 0L
    data.frame(token = tok, yards = yards, status = status)[keep, , drop = FALSE]
  })
}

#' Populate the penalty columns
#'
#' Sets `penalty_flag`, `penalty_yards_signed`, `penalized_team`,
#' `penalty_no_play`, `penalty_declined`, `penalty_play_text` per conventions 1-5
#' in `docs/schema.md` (Key conventions).
#'
#' - `penalty_flag`: text mentions a penalty (any case).
#' - `penalty_play_text`: the raw clause from the first upper-case "PENALTY"
#'   onward (so "TOUCHDOWN nullified by penalty" isn't mistaken for the
#'   clause start). NA if none.
#' - `penalized_team`: team name of the accepted infraction(s); for an
#'   offsetting or two-team row, both names joined by "; ". If every
#'   infraction was declined, the declined team.
#' - `penalty_yards_signed`: sum of the accepted infractions' yards, each
#'   positive if the defense (`def_pos_team`) was flagged and negative if the
#'   offense (`pos_team`) was. Offsetting -> 0. All declined -> NA. On a
#'   kickoff `pos_team` is the receiving team, so a positive value means the
#'   kicking team was flagged.
#' - `penalty_declined`: TRUE when there are infractions and every one was
#'   declined. A row with one declined and one accepted infraction is FALSE,
#'   and the accepted one supplies the yards.
#' - `penalty_no_play`: see [is_no_play()].
#'
#' @param df Kept rows with `play_text`, `pos_team`, `def_pos_team`.
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
  df$penalty_no_play <- is_no_play(txt)
  df$penalty_declined <- ifelse(flag, declined %in% TRUE, NA)
  # d3ballR's own labels ("[d3ballR: ...]") aren't part of the penalty
  df$penalty_play_text <- stringr::str_trim(stringr::str_remove(clause, "\\s*\\[d3ballR:[^]]*\\]\\s*$"))
  df
}
