#' Points scored on each play, from `pos_team`'s view
#'
#' TD +6 for the offense, -6 when the defense scores (interception or
#' fumble return, punt / blocked-kick return, or a kickoff the kicking team
#' recovers and scores on); a punt or kick the kicking team recovers (a muff)
#' and scores on is +6; FG +3; extra point +1; two-point try +2; safety
#' conceded -2; a try the defense returns ("defensive PAT Successful") -2. Zero otherwise, and zero on every `penalty_no_play` row.
#' On a kickoff `pos_team` is the receiving team, so a kickoff-return TD is
#' +6.
#'
#' @param kept Kept rows with `play_type`, `play_text`, `touchdown`,
#'   `turnover`, `safety`, `kicker_recovered`, `penalty_no_play`,
#'   `recovering_team` (from [parse_outcome_flags()]).
#' @return Integer vector.
#' @keywords internal
score_points <- function(kept) {
  pt <- kept$play_type
  txt <- kept$play_text
  ic <- function(pattern) stringr::regex(pattern, ignore_case = TRUE)
  kick_types <- c("punt_no_return", "punt_with_return", "punt_blocked",
                  "field_goal_blocked", "field_goal_missed")
  # the kicking team recovered a muff / fumble and scored
  kicker_regained <- pt %in% kick_types & !is.na(kept$recovering_team) &
    kept$recovering_team == kept$pos_team
  defense_scores <- kept$touchdown & !kicker_regained & (
    kept$turnover | pt %in% kick_types |
      (pt == "kickoff" & kept$kicker_recovered)
  )
  # a blocked / failed try returned by the defense: "... defensive PAT
  # Successful."
  defensive_try <- pt %in% c("extra_point", "two_point") &
    stringr::str_detect(txt, ic("\\bdefensive (PAT|two[- ]point|2[- ]?pt|conversion)\\b.*\\bsuccessful\\b"))
  pat_good <- pt == "extra_point" & stringr::str_detect(txt, ic("\\bgood\\b")) &
    !stringr::str_detect(txt, ic("no good|failed|blocked"))
  two_good <- pt == "two_point" & stringr::str_detect(txt, ic("\\b(good|successful)\\b")) &
    !stringr::str_detect(txt, ic("failed|no good"))
  pts <- dplyr::case_when(
    kept$touchdown & defense_scores ~ -6L,
    kept$touchdown ~ 6L,
    pt == "field_goal_good" ~ 3L,
    kept$safety ~ -2L,
    defensive_try ~ -2L,
    pat_good ~ 1L,
    two_good ~ 2L,
    TRUE ~ 0L
  )
  ifelse(kept$penalty_no_play, 0L, pts)
}

#' Running score before each play
#'
#' The score before row i is the running total of the points parsed on the
#' rows before it (`score_pts`, credited to `pos_team` when positive and
#' `def_pos_team` when negative). A PAT's "before" score therefore includes
#' its touchdown. d3's printed score lines are not used as the source,
#' because a stat crew sometimes skips one and the following lines lag a
#' score behind. Each line is compared with the parsed total at that point
#' instead (`checks`); the game's final score is reconciled separately
#' against the boxscore.
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

  # score before each row = running total of the parsed points before it
  s1 <- cumsum(c(0L, p1))[seq_len(nrow(kept))]
  s2 <- cumsum(c(0L, p2))[seq_len(nrow(kept))]

  # d3's printed score lines are a check, not the source: compare each with
  # the parsed total at that point
  checks <- do.call(rbind, lapply(seq_len(nrow(scores)), function(j) {
    before <- kept$row < scores$row[j]
    data.frame(row = scores$row[j], stated_1 = scores$score_1[j], stated_2 = scores$score_2[j],
               parsed_1 = sum(p1[before]), parsed_2 = sum(p2[before]))
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
#'   first down, matching StatCrew). Never on a turnover or a no-play. If the
#'   offense also committed an accepted penalty on the play (e.g. holding),
#'   the first down only stands if the same offense snaps a 1st down next.
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
  # an accepted penalty on the offense during the play (holding, etc.) can
  # take the first down away even when the yardage reached the line, and
  # even when d3 printed "1ST DOWN" before the penalty clause: then the first
  # down only stands if the same offense really snaps a 1st down next
  off_penalty <- accepted & !is.na(kept$penalized_team) & kept$penalized_team == kept$pos_team
  # "really" = a new series, not the same 1st down moved back by the
  # enforcement (1st & 15, 10-yd holding -> 1st & 5 is not a first down)
  net_nxt <- kept$yards_to_goal - kept$yards_to_goal[nxt]
  next_new_series <- !is.na(nxt) & kept$pos_team[nxt] %in% kept$pos_team &
    kept$pos_team[nxt] == kept$pos_team & kept$down[nxt] %in% 1L &
    (!(kept$down %in% 1L) | !(kept$distance[nxt] %in% (kept$distance - net_nxt)))
  stands <- !off_penalty | next_new_series
  kept$fd_yards_text <- fd_yards_text & kept$scrimmage_play & !kept$penalty_no_play & !kept$turnover
  kept$firstD_by_yards <- (fd_yards_text | fd_yards_rule) & kept$scrimmage_play &
    !kept$penalty_no_play & !kept$turnover & stands

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

#' Next snap that can start a new series for this row
#'
#' The next scrimmage snap in the same half ([next_snap_index()]), except
#' that overtime periods don't connect to anything else: the last
#' regulation play doesn't lead into overtime, and one OT period doesn't
#' lead into the next. Each OT period is its own unit.
#'
#' @param kept Kept rows with `period`.
#' @param nxt Output of [next_snap_index()].
#' @return Integer vector (NA when no connected snap follows).
#' @keywords internal
series_next_snap <- function(kept, nxt) {
  ok <- !is.na(nxt)
  ok[ok] <- (kept$period[ok] <= 4L & kept$period[nxt[ok]] <= 4L) | kept$period[ok] == kept$period[nxt[ok]]
  ifelse(ok, nxt, NA_integer_)
}

#' First-down / new-series flags, on the snap that starts the new series
#'
#' cfbfastR column names. Each flag sits on the FIRST SNAP of a new series
#' (the 1st-and-10 or 1st-and-goal snap), never on the play that caused it.
#' At most one is TRUE, chosen by the cause of the new series:
#' - `firstD_by_kickoff`: the first snap after a kickoff (including an onside
#'   kick, whichever team recovered).
#' - `firstD_by_poss`: the first snap after a change of possession (punt,
#'   interception, lost fumble, turnover on downs, missed or blocked field
#'   goal, or a punt / field goal the kicking team regains after a muff or
#'   return fumble), and the first snap of each overtime possession.
#' - `firstD_by_yards`: same offense, and the previous play reached the line
#'   to gain ([derive_first_downs()], including the offensive-penalty
#'   correction).
#' - `firstD_by_penalty`: same offense, the previous play didn't reach the
#'   line, and an accepted penalty awarded the first down (a declined penalty
#'   never counts).
#'
#' `new_series` is any of the four. Every other row (mid-series snaps,
#' replays after a no-play penalty, kickoffs, tries) is FALSE in all five.
#'
#' How it works: the cause is read on each causing row (a kickoff; a play
#' after which the next snap belongs to the other team, or a regained kick;
#' the yards / penalty first-down flags), excluding scoring plays, tries and
#' rows with no connected next snap. It is then moved to the next snap row
#' (a snap, or a penalty_no_play row: a dead-ball penalty or a nullified snap)
#' in the same half and, in overtime, the same period: that row is the first
#' snap of the new series. A snap that replays the same down after a no-play
#' penalty is never a series start. If two causes point at
#' one snap, precedence kickoff > poss > yards > penalty decides. Finally,
#' the first snap of each overtime possession is `firstD_by_poss`.
#'
#' @param kept Kept rows after [derive_first_downs()], with `play_type`,
#'   `pos_team`, `penalty_no_play`, `scoring_play`, `try_phase`,
#'   `fumble_vec`, `down`, `half`, `period`.
#' @param nxt Output of [next_snap_index()].
#' @return `kept` with the five flags (replacing the raw yards / penalty
#'   flags) and `series_cause_row` / `series_causes` for the report.
#' @keywords internal
derive_series_flags <- function(kept, nxt) {
  n <- nrow(kept)
  sn <- series_next_snap(kept, nxt)
  has_next <- !is.na(sn)
  live <- !kept$penalty_no_play
  next_team <- kept$pos_team[sn]
  same_team <- has_next & !is.na(next_team) & !is.na(kept$pos_team) & next_team == kept$pos_team
  other_team <- has_next & !same_team
  excluded <- kept$scoring_play | kept$try_phase | kept$play_type %in% c("extra_point", "two_point") | !has_next

  kicked <- kept$play_type %in% c("punt_no_return", "punt_with_return", "punt_blocked",
                                  "field_goal_missed", "field_goal_blocked")
  regained_kick <- kicked & live & kept$fumble_vec & same_team & kept$down[sn] %in% 1L

  # causes, on the causing row
  cause <- rep(NA_character_, n)
  cause[!excluded & kept$firstD_by_penalty & same_team] <- "penalty"
  cause[!excluded & kept$firstD_by_yards & live & same_team] <- "yards"
  cause[!excluded & live & kept$play_type != "kickoff" & (other_team | regained_kick)] <- "poss"
  cause[!excluded & live & kept$play_type == "kickoff"] <- "kickoff"

  # target: the next snap row -- a snap or a penalty_no_play row (dead-ball
  # or nullified snap), not a try -- in the same half; in overtime, the same
  # period. The series starts on that row; a replay of the same down after a
  # no-play penalty comes later and is never a series start.
  is_snap <- (kept$play_type %in% play_type_categories | kept$play_type == "penalty_no_play") &
    !kept$try_phase & !is.na(kept$down)
  snaps <- which(is_snap)
  target <- vapply(seq_len(n), function(i) {
    if (is.na(cause[i])) return(NA_integer_)
    j <- snaps[snaps > i & kept$half[snaps] == kept$half[i]]
    j <- j[(kept$period[i] <= 4L & kept$period[j] <= 4L) | kept$period[j] == kept$period[i]]
    if (length(j)) j[1] else NA_integer_
  }, integer(1))

  rank <- c(kickoff = 1L, poss = 2L, yards = 3L, penalty = 4L)
  best <- rep(NA_character_, n)
  causes_at <- rep(NA_character_, n)
  cause_row <- rep(NA_integer_, n)
  for (i in which(!is.na(target))) {
    t <- target[i]
    causes_at[t] <- if (is.na(causes_at[t])) cause[i] else paste(causes_at[t], cause[i], sep = " + ")
    if (is.na(best[t]) || rank[cause[i]] < rank[best[t]]) {
      best[t] <- cause[i]
      cause_row[t] <- i
    }
  }

  # first snap of each overtime possession
  for (t in snaps[kept$period[snaps] > 4L]) {
    prev <- snaps[snaps < t & kept$period[snaps] == kept$period[t]]
    first_of_possession <- !length(prev) || !identical(kept$pos_team[prev[length(prev)]], kept$pos_team[t])
    if (first_of_possession && (is.na(best[t]) || rank[best[t]] > rank["poss"])) {
      best[t] <- "poss"
      if (is.na(causes_at[t])) causes_at[t] <- "overtime possession"
    }
  }

  kept$firstD_by_kickoff <- best %in% "kickoff"
  kept$firstD_by_poss <- best %in% "poss"
  kept$firstD_by_yards <- best %in% "yards"
  kept$firstD_by_penalty <- best %in% "penalty"
  kept$new_series <- !is.na(best)
  kept$series_cause_row <- cause_row
  kept$series_causes <- causes_at
  kept
}
