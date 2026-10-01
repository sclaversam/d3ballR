#' Points scored on each play, from `pos_team`'s view
#'
#' TD +6 for the offense, -6 when the defense scores (interception or
#' fumble return, punt / blocked-kick return, or a kickoff the kicking team
#' recovers and scores on); FG +3; extra point +1; two-point try +2; safety
#' conceded -2. Zero otherwise, and zero on every `penalty_no_play` row.
#' On a kickoff `pos_team` is the receiving team, so a kickoff-return TD is
#' +6.
#'
#' @param kept Kept rows with `play_type`, `play_text`, `touchdown`,
#'   `turnover`, `safety`, `kicker_recovered`, `penalty_no_play`.
#' @return Integer vector.
#' @keywords internal
score_points <- function(kept) {
  pt <- kept$play_type
  txt <- kept$play_text
  ic <- function(pattern) stringr::regex(pattern, ignore_case = TRUE)
  defense_scores <- kept$touchdown & (
    kept$turnover |
      pt %in% c("punt_no_return", "punt_with_return", "punt_blocked",
                "field_goal_blocked", "field_goal_missed") |
      (pt == "kickoff" & kept$kicker_recovered)
  )
  pat_good <- pt == "extra_point" & stringr::str_detect(txt, ic("\\bgood\\b")) &
    !stringr::str_detect(txt, ic("no good|failed|blocked"))
  two_good <- pt == "two_point" & stringr::str_detect(txt, ic("\\b(good|successful)\\b")) &
    !stringr::str_detect(txt, ic("failed|no good"))
  pts <- dplyr::case_when(
    kept$touchdown & defense_scores ~ -6L,
    kept$touchdown ~ 6L,
    pt == "field_goal_good" ~ 3L,
    kept$safety ~ -2L,
    pat_good ~ 1L,
    two_good ~ 2L,
    TRUE ~ 0L
  )
  ifelse(kept$penalty_no_play, 0L, pts)
}

#' Running score before each play
#'
#' The score before row i is the last score line printed before it plus any
#' points scored on kept rows between that line and row i. That gets the
#' extra point right: d3 prints the score line AFTER the try, so a PAT's
#' "before" score already includes its touchdown's 6. Every score line is
#' also checked against the play-by-play points since the previous line;
#' mismatches are returned for the change log.
#'
#' @param kept Kept rows with `row`, `pos_team`, `def_pos_team`,
#'   `score_pts`.
#' @param scores Output of [parse_score_rows()].
#' @param teams The two canonical team names.
#' @return A list: `pos_team_score`, `def_pos_team_score` (integer vectors)
#'   and `checks` (data frame, one row per score line, with `ok`).
#' @keywords internal
running_score <- function(kept, scores, teams) {
  # points credited to teams[1] / teams[2] on each kept row
  scorer <- ifelse(kept$score_pts > 0, kept$pos_team, kept$def_pos_team)
  p1 <- ifelse(scorer %in% teams[1], abs(kept$score_pts), 0L)
  p2 <- ifelse(scorer %in% teams[2], abs(kept$score_pts), 0L)

  n <- nrow(kept)
  s1 <- s2 <- integer(n)
  for (i in seq_len(n)) {
    prior <- scores[scores$row < kept$row[i], ]
    base_row <- if (nrow(prior)) prior$row[nrow(prior)] else 0L
    b1 <- if (nrow(prior)) prior$score_1[nrow(prior)] else 0L
    b2 <- if (nrow(prior)) prior$score_2[nrow(prior)] else 0L
    between <- kept$row > base_row & kept$row < kept$row[i]
    s1[i] <- b1 + sum(p1[between])
    s2[i] <- b2 + sum(p2[between])
  }

  checks <- do.call(rbind, lapply(seq_len(nrow(scores)), function(j) {
    prev_row <- if (j > 1) scores$row[j - 1] else 0L
    b1 <- if (j > 1) scores$score_1[j - 1] else 0L
    b2 <- if (j > 1) scores$score_2[j - 1] else 0L
    between <- kept$row > prev_row & kept$row < scores$row[j]
    data.frame(row = scores$row[j], stated_1 = scores$score_1[j], stated_2 = scores$score_2[j],
               parsed_1 = b1 + sum(p1[between]), parsed_2 = b2 + sum(p2[between]))
  }))
  if (!is.null(checks)) checks$ok <- checks$stated_1 == checks$parsed_1 & checks$stated_2 == checks$parsed_2

  list(
    pos_team_score = ifelse(kept$pos_team == teams[1], s1, s2),
    def_pos_team_score = ifelse(kept$pos_team == teams[1], s2, s1),
    checks = checks
  )
}

#' Index of the next scrimmage snap in the same half
#'
#' @param kept Kept rows with `scrimmage_play`, `half`, `try_phase`.
#' @return Integer vector (NA when none follows in the half).
#' @keywords internal
next_snap_index <- function(kept) {
  n <- nrow(kept)
  cand <- which(kept$scrimmage_play & !kept$try_phase)
  vapply(seq_len(n), function(i) {
    j <- cand[cand > i & kept$half[cand] == kept$half[i]]
    if (length(j)) j[1] else NA_integer_
  }, integer(1))
}

#' End-of-play situation: down, distance, yards to goal after the play
#'
#' The situation of the next scrimmage snap in the same half, from THAT
#' snap's offense view (so after a change of possession it's the new
#' offense, as in cfbfastR). NA on scoring plays, tries and try-phase rows,
#' and when no snap follows in the half. On a kickoff it's the receiving
#' team's first snap.
#'
#' @param kept Kept rows with `down`, `distance`, `yards_to_goal`,
#'   `scoring_play`, `try_phase`, `play_type`.
#' @param nxt Output of [next_snap_index()].
#' @return `kept` with `down_end`, `distance_end`, `yards_to_goal_end`.
#' @keywords internal
derive_end_state <- function(kept, nxt) {
  na_end <- kept$scoring_play | kept$try_phase | kept$play_type %in% c("extra_point", "two_point") | is.na(nxt)
  kept$down_end <- ifelse(na_end, NA_integer_, kept$down[nxt])
  kept$distance_end <- ifelse(na_end, NA_integer_, kept$distance[nxt])
  kept$yards_to_goal_end <- ifelse(na_end, NA_integer_, kept$yards_to_goal[nxt])
  kept
}

#' First down by yards / by penalty
#'
#' d3's "Last,First" StatCrew format prints "1ST DOWN"; the other format
#' (7 of the 11 2025 games) never does. So each flag is the printed text OR
#' a data rule, which agree on the games that print it (see the change log).
#'
#' - `firstD_by_yards`: "1ST DOWN" in the play clause (before any PENALTY),
#'   or a rush / completion / sack / kneel whose `yards_gained` reaches
#'   `distance`, outside goal-to-go (a goal-to-go TD is not credited as a
#'   first down, matching StatCrew). Never on a turnover or a no-play.
#' - `firstD_by_penalty`: "1ST DOWN" in the penalty clause with an accepted
#'   penalty, or an accepted penalty on the defense after which the same
#'   offense starts a NEW series (next snap is 1st down, and not just the
#'   same 1st down moved by the enforcement), when the play didn't already
#'   make it by yards.
#'
#' @param kept Kept rows with `play_text`, `play_type`, `yards_gained`,
#'   `distance`, `turnover`, `penalty_no_play`, `penalty_yards_signed`,
#'   `penalty_declined`, `penalized_team`, `def_pos_team`, `pos_team`,
#'   `scrimmage_play`, `scoring_play`.
#' @param nxt Output of [next_snap_index()].
#' @return `kept` with `firstD_by_yards`, `firstD_by_penalty`, and the
#'   text-only versions `fd_yards_text`, `fd_penalty_text` (for checks).
#' @keywords internal
derive_first_downs <- function(kept, nxt) {
  txt <- kept$play_text
  play_clause <- stringr::str_remove(txt, "PENALTY .*$")
  pen_clause <- stringr::str_extract(txt, "PENALTY .*$")
  accepted <- !is.na(kept$penalty_yards_signed) & !(kept$penalty_declined %in% TRUE)
  gain_play <- kept$play_type %in% c("rush", "pass_complete", "sack", "kneel")

  fd_yards_text <- stringr::str_detect(play_clause, "1ST DOWN")
  # goal-to-go plays are excluded: when the line to gain is the goal line,
  # reaching it is a touchdown, and StatCrew does not credit a first down
  fd_yards_rule <- gain_play & !is.na(kept$yards_gained) & !is.na(kept$distance) &
    kept$yards_gained >= kept$distance & !(kept$Goal_To_Go %in% TRUE)
  kept$fd_yards_text <- fd_yards_text & kept$scrimmage_play & !kept$penalty_no_play & !kept$turnover
  kept$firstD_by_yards <- (fd_yards_text | fd_yards_rule) & kept$scrimmage_play &
    !kept$penalty_no_play & !kept$turnover

  fd_pen_text <- !is.na(pen_clause) & stringr::str_detect(pen_clause, "1ST DOWN") & accepted
  # a NEW series: the next snap is 1st down by the same offense, and either
  # this snap wasn't a 1st down or the next distance is longer than plain
  # yardage enforcement would leave (1st & 10, 5-yd offside -> 1st & 5 is
  # not a new series)
  carried <- kept$distance - dplyr::coalesce(kept$penalty_yards_signed, 0L) -
    ifelse(kept$penalty_no_play, 0L, dplyr::coalesce(kept$yards_gained, 0L))
  same_team_first <- !is.na(nxt) & kept$pos_team[nxt] %in% kept$pos_team &
    kept$pos_team[nxt] == kept$pos_team & kept$down[nxt] %in% 1L &
    (!(kept$down %in% 1L) | kept$distance[nxt] > carried)
  fd_pen_rule <- accepted & kept$penalized_team %in% kept$def_pos_team &
    kept$penalized_team == kept$def_pos_team & same_team_first & !kept$firstD_by_yards &
    !kept$scoring_play
  kept$fd_penalty_text <- fd_pen_text & kept$scrimmage_play
  kept$firstD_by_penalty <- (fd_pen_text | fd_pen_rule) & kept$scrimmage_play
  kept
}

#' How each drive ended
#'
#' Read off the drive's last real play (not a try, not a no-play penalty):
#' TD, FG, MISSED FG, BLOCKED FG, PUNT, BLOCKED PUNT, INT, FUMBLE, DOWNS,
#' SAFETY; if that play doesn't end a possession and it's the half's last
#' drive, END OF HALF / END OF GAME. A defensive touchdown is labelled by
#' how the offense lost the ball (INT, FUMBLE, PUNT, BLOCKED PUNT, BLOCKED
#' FG, MISSED FG). A kickoff the kicking team recovers ends the receiving
#' team's (one-play) drive: FUMBLE if the returner fumbled, ONSIDE for an
#' onside kick. Repeated on every row of the drive.
#'
#' @param kept Kept rows with `drive_number`, `half`, `period`, `try_phase`,
#'   `penalty_no_play`, `play_type`, flag columns, `score_pts`,
#'   `kicker_recovered`.
#' @return Character vector.
#' @keywords internal
derive_drive_result <- function(kept) {
  res <- character(nrow(kept))
  last_drive_of_half <- tapply(kept$drive_number, kept$half, max)
  for (d in unique(kept$drive_number)) {
    rows <- which(kept$drive_number == d)
    real <- rows[!kept$try_phase[rows] & !kept$penalty_no_play[rows] &
                   !kept$play_type[rows] %in% c("extra_point", "two_point")]
    r <- if (length(real)) real[length(real)] else rows[length(rows)]
    pt <- kept$play_type[r]
    h <- kept$half[r]
    is_last <- d == last_drive_of_half[as.character(h)]
    label <- dplyr::case_when(
      kept$touchdown[r] & kept$score_pts[r] > 0 ~ "TD",
      kept$touchdown[r] & pt == "pass_intercepted" ~ "INT",
      kept$touchdown[r] & pt == "punt_blocked" ~ "BLOCKED PUNT",
      kept$touchdown[r] & pt %in% c("punt_no_return", "punt_with_return") ~ "PUNT",
      kept$touchdown[r] & pt == "field_goal_blocked" ~ "BLOCKED FG",
      kept$touchdown[r] & pt == "field_goal_missed" ~ "MISSED FG",
      kept$touchdown[r] ~ "FUMBLE",
      kept$safety[r] ~ "SAFETY",
      pt == "field_goal_good" ~ "FG",
      pt == "field_goal_missed" ~ "MISSED FG",
      pt == "field_goal_blocked" ~ "BLOCKED FG",
      pt == "punt_blocked" ~ "BLOCKED PUNT",
      pt %in% c("punt_no_return", "punt_with_return") ~ "PUNT",
      kept$int[r] ~ "INT",
      kept$kicker_recovered[r] & kept$fumble_vec[r] ~ "FUMBLE",
      kept$kicker_recovered[r] ~ "ONSIDE",
      kept$downs_turnover[r] ~ "DOWNS",
      kept$turnover[r] & kept$fumble_vec[r] ~ "FUMBLE",
      is_last & h == 1 ~ "END OF HALF",
      is_last & h == 2 ~ "END OF GAME",
      TRUE ~ "UNKNOWN"
    )
    res[rows] <- label
  }
  res
}
