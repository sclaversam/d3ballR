#' Read the receiving team off a coin-toss row
#'
#' Coin-toss wording varies by StatCrew format: "Carnegie Mellon wins toss
#' and defers; UC will receive; ...", "UWL wins toss will receive and
#' defends west", "Gettysburg wins toss, defers, CMU to receive and defend
#' west", "Carnegie Mellon to receive and defend the East end zone". The
#' receiver is the reference right before "will receive" / "to receive"
#' (or the toss winner, when the winner's own clause says it receives).
#'
#' @param text Coin-toss row text.
#' @return The receiver reference as written (name or token), or NA.
#' @keywords internal
parse_coin_receiver <- function(text) {
  clauses <- stringr::str_trim(unlist(strsplit(text, "[;,]")))
  hit <- clauses[stringr::str_detect(clauses, stringr::regex("\\b(will|to) receive\\b", ignore_case = TRUE))]
  if (!length(hit)) return(NA_character_)
  ref <- stringr::str_match(hit[1], stringr::regex("^(.*?)\\s+(?:wins toss\\s+)?(?:will|to) receive", ignore_case = TRUE))[, 2]
  ref <- stringr::str_remove(ref, stringr::regex("\\s+wins toss.*$", ignore_case = TRUE))
  stringr::str_trim(ref)
}

#' Decide the kicking and receiving team of every kickoff
#'
#' cfbfastR convention: on a kickoff `pos_team` is the RECEIVING team. Per
#' kickoff, in order:
#' 1. **override** -- the text shows the kicking team recovered (onside kick,
#'    or a return fumble/muff recovered by the kicker). The receiving team is
#'    the other team, and the play is a turnover.
#' 2. **header** -- otherwise, the team named on the next drive header/start
#'    row after the kickoff (before the next kickoff, same half).
#' 3. **fallback** -- no drive row follows (e.g. a kickoff-return TD): the
#'    pre-kick context decides who kicked.
#'
#' Pre-kick context (`context_kicker`): a re-kick (previous kept row in the
#' half is a kickoff) uses the same kicker; after a score the scorer kicks
#' (after a safety, the team that conceded); at the start of a half the
#' coin-toss row's "X will receive" names the receiver; in the second half
#' with no coin-toss row, the first half's receiving team kicks. It is also
#' what identifies "the kicking team" for the override, and is compared
#' against the header in the validation report.
#'
#' @param full Classified rows with `quarter`, `possession` (canonical),
#'   `play_type` (kickoff rows), `row_type`.
#' @param teams The two canonical team names.
#' @param team_map,own_side,text_team See [resolve_team()].
#' @param scores Output of [parse_score_rows()].
#' @return A data frame, one row per kickoff: `row`, `half`, `kicking_team`,
#'   `receiving_team`, `rule`, `header_team`, `context_kicker`,
#'   `context_source`, `recovered_by`, `kicker_recovered`, `disagreement`.
#' @keywords internal
assign_kickoffs <- function(full, teams, team_map, own_side, text_team, scores) {
  rt <- full$row_type
  half <- ifelse(as.integer(full$quarter) <= 2, 1L, 2L)
  ko <- which(rt == "kickoff")
  kept <- rt %in% kept_row_types
  marker <- rt %in% c("drive_header", "drive_start")
  marker_team <- dplyr::coalesce(
    stringr::str_match(full$play, "^(.*?) at \\d{1,2}:\\d{2}$")[, 2],
    stringr::str_match(full$play, stringr::regex("^(.*?) drive start at", ignore_case = TRUE))[, 2]
  )
  marker_team <- unname(team_map[marker_team])

  res <- vector("list", length(ko))
  first_half_receiver <- NA_character_
  for (n in seq_along(ko)) {
    k <- ko[n]
    h <- half[k]
    in_half <- half %in% h
    idx <- seq_len(nrow(full))

    # header: next drive row before the next kickoff in this half
    next_ko <- ko[ko > k & half[ko] == h]
    limit <- if (length(next_ko)) next_ko[1] else max(which(in_half)) + 1
    m <- which(marker & idx > k & idx < limit & in_half)
    header_team <- if (length(m)) marker_team[m[1]] else NA_character_

    # pre-kick context
    prev_kept <- which(kept & idx < k & in_half)
    last_kept <- if (length(prev_kept)) prev_kept[length(prev_kept)] else NA_integer_
    snaps <- which(rt == "play" & idx < k & in_half)
    last_snap <- if (length(snaps)) snaps[length(snaps)] else 0L
    sc <- scores[scores$row > last_snap & scores$row < k & half[scores$row] %in% h, ]
    context_kicker <- NA_character_
    context_source <- NA_character_
    if (!is.na(last_kept) && rt[last_kept] == "kickoff") {
      prev <- res[[which(ko == last_kept)]]
      context_kicker <- prev$kicking_team
      context_source <- "re-kick"
    } else if (nrow(sc)) {
      s <- sc[nrow(sc), ]
      scoring_rows <- which(kept & idx > last_snap - 1 & idx < s$row)
      was_safety <- any(stringr::str_detect(full$play[scoring_rows], stringr::regex("\\bsafety\\b", ignore_case = TRUE)))
      context_kicker <- if (was_safety) other_team(s$scorer, teams) else s$scorer
      context_source <- if (was_safety) "after safety" else "after score"
    } else if (last_snap == 0L) {
      coin <- which(rt == "coin_toss" & idx < k & in_half)
      recv <- if (length(coin)) {
        refs <- vapply(full$play[coin], parse_coin_receiver, character(1))
        refs <- refs[!is.na(refs)]
        if (length(refs)) resolve_team(refs[length(refs)], team_map, own_side, text_team) else NA_character_
      } else NA_character_
      if (!is.na(recv)) {
        context_kicker <- other_team(recv, teams)
        context_source <- "coin toss"
      } else if (h == 2 && !is.na(first_half_receiver)) {
        context_kicker <- first_half_receiver
        context_source <- "second half: first-half receiver kicks"
      }
    }

    # recovery by the kicking team?
    rec <- stringr::str_match_all(full$play[k], paste0("recovered by ", token_regex(names(text_team)), "\\b"))[[1]]
    recovered_by <- if (nrow(rec)) unname(text_team[rec[nrow(rec), 2]]) else NA_character_
    kicker_recovered <- !is.na(recovered_by) && !is.na(context_kicker) && recovered_by == context_kicker

    if (kicker_recovered) {
      rule <- "override"
      kicking <- context_kicker
    } else if (!is.na(header_team)) {
      rule <- "header"
      kicking <- other_team(header_team, teams)
    } else {
      rule <- "fallback"
      kicking <- context_kicker
    }
    receiving <- other_team(kicking, teams)

    disagreement <- NA_character_
    if (rule == "header" && !is.na(context_kicker) && context_kicker != kicking) {
      disagreement <- paste0("header says ", header_team, " receives; context (", context_source,
                             ") says ", context_kicker, " kicks")
    }
    if (rule == "override" && !is.na(header_team) && header_team != kicking) {
      disagreement <- paste0("kicker recovered but next drive row names ", header_team)
    }
    if (is.na(kicking)) disagreement <- "could not determine kicking team"

    if (h == 1 && is.na(first_half_receiver)) first_half_receiver <- receiving
    res[[n]] <- data.frame(
      row = k, half = h, kicking_team = kicking, receiving_team = receiving, rule = rule,
      header_team = header_team, context_kicker = context_kicker, context_source = context_source,
      recovered_by = recovered_by, kicker_recovered = kicker_recovered, disagreement = disagreement
    )
  }
  do.call(rbind, res)
}
