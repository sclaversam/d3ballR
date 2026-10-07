#' Down-and-distance situation pattern
#'
#' Matches a real down-and-distance line like "1st and 10 at CMU35" or
#' "4th and Goal at CMU06". Requires an explicit "at" clause, which is what
#' separates a real situation from a bare echo like "2nd and 25." (no "at").
#' @keywords internal
dd_pattern <- "[1-4](st|nd|rd|th)\\s+and\\s+.*\\bat\\b"

#' Snap verb pattern
#'
#' A play is only a `play` if its description contains one of these verbs.
#' Per CLAUDE.md: rush, pass, sacked, punt, field goal, kneel. `pass` requires
#' one of complete/incomplete/intercepted/attempt right after it -- a bare
#' `\\bpass\\b` also matches the word "Pass" inside a penalty name (e.g.
#' "PENALTY CMU Pass Interference ... NO PLAY."), which wrongly typed three
#' dead-ball penalty rows as `play` instead of `penalty_no_play`.
#' @keywords internal
verb_pattern <- "\\b(rush|pass (complete|incomplete|intercepted|attempt)|sacked|punt|field goal|kneel)\\b"

#' Classify each play-by-play row into a type
#'
#' Positive-identification design (see CLAUDE.md "Classifier design"): a row
#' is a `play` only if its `situation` is a real down-and-distance AND its
#' `play` text contains a snap verb. Everything else is swept into a specific
#' non-play type by its own signature. Six of those types are down-and-distance
#' rows with no snap verb, confirmed against game footage as legitimate
#' non-plays (none should ever count as a play):
#' - `coin_toss` — "TEAM wins toss and defers; ..." / "TEAM will receive; ..."
#' - `spot_correction` — "TEAM ball on X19."
#' - `bare_clock` — "clock 02:00." with no other content
#' - `down_distance_echo` — a bare "2nd and 25." (no "at" clause) that repeats
#'   the down/distance set by the row above after penalty enforcement; kept
#'   distinct from the other five because it may need special handling later
#'   (it's driven off the same enforcement as the row before it, so it must
#'   never be double-counted as its own down)
#' - `replay_review` — "previous play upheld by review"
#' - `substitution` — "TEAM_PLAYER in at QB", "D. Brown Jr at QB for Albright."
#' - `annotation` — a note that isn't a play of its own: "Spiked" (after the
#'   incomplete pass that was the spike; the down doesn't advance again),
#'   "2:00 minute warning", "recovered by NAME" (a fragment repeating the
#'   kickoff's recovery)
#'
#' Two more non-play types, with no down-and-distance requirement:
#' - `penalty_note` — a declined or offsetting penalty on its own row with no
#'   situation (seen between a touchdown and its try). It changes nothing, so
#'   it's dropped. An accepted penalty in that spot still lands in `other`.
#' - `blank` — a row whose text is just "." (after a coin toss, or at the half)
#'
#' `other` is the unknown bucket and should come back empty; anything landing
#' there means a new row shape has appeared and the classifier needs a new
#' rule, not that the row should be silently dropped.
#'
#' Ordering matters, per CLAUDE.md:
#' - `play` is checked first, so a nullified snap (has a verb, also has a
#'   `PENALTY ... NO PLAY` clause) is still counted as `play`.
#' - `kickoff` comes next, before `penalty_no_play`, so a kickoff with a
#'   return penalty (and a stale situation) is still a kickoff.
#' - `penalty_no_play` is checked right after, so only dead-down penalties
#'   with no snap verb land there.
#' - `quarter` (which also matches the combined
#'   "Start of Nth quarter, clock M:SS, TEAM ball on X." rows) is checked
#'   before the six down-and-distance non-play types below, so those combined
#'   rows are typed `quarter`, not `spot_correction`.
#' - `drive_start` is checked before `drive_header`, so
#'   "TEAM drive start at MM:SS." doesn't fall through to the header rule.
#'
#' @param plays A tibble with `situation` and `play` columns, as returned by
#'   [scrape_plays()].
#' @return `plays` with an added `row_type` column (character).
#' @export
classify_plays <- function(plays) {
  is_dd <- stringr::str_detect(plays$situation, dd_pattern)
  has_verb <- stringr::str_detect(plays$play, stringr::regex(verb_pattern, ignore_case = TRUE))
  blank_sit <- plays$situation == ""
  same <- plays$situation == plays$play

  is_kickoff <- stringr::str_detect(plays$play, stringr::regex("\\bkickoff\\b", ignore_case = TRUE))

  row_type <- dplyr::case_when(
    is_dd & has_verb ~ "play",
    # A kickoff is a kickoff even when it carries a return penalty: StatCrew
    # then prints a stale down-and-distance in the situation column, which
    # used to send these rows to `penalty_no_play` (Dickinson 2025 play
    # 191, Ursinus play 73).
    is_kickoff ~ "kickoff",
    # a safety recorded on its own line with no play verb ("N.C. Wesleyan
    # SAFETY, clock 03:20." -- e.g. an intentional safety): still a snap
    is_dd & stringr::str_detect(plays$play, "\\bSAFETY\\b") ~ "play",
    is_dd & !has_verb & stringr::str_detect(plays$play, stringr::regex("penalty", ignore_case = TRUE)) ~ "penalty_no_play",
    stringr::str_detect(plays$play, stringr::regex("drive start", ignore_case = TRUE)) ~ "drive_start",
    same & stringr::str_detect(plays$play, " at \\d{1,2}:\\d{2}$") ~ "drive_header",
    same & stringr::str_detect(plays$play, "^\\d+ plays, -?\\d+ yards, \\d{1,2}:\\d{2} elapsed$") ~ "drive_footer",
    (same & stringr::str_detect(plays$play, "^([1-4](st|nd|rd|th)|\\d?OT)$")) |
      stringr::str_detect(plays$play, stringr::regex("^Start of|^End of (game|half)", ignore_case = TRUE)) ~ "quarter",
    blank_sit & stringr::str_detect(plays$play, stringr::regex("kick attempt", ignore_case = TRUE)) ~ "extra_point",
    # Validated on real data: 9 two-point tries across games 3, 6, 7, 8, 9, 11
    # of the 11-game 2025 sweep (none in game 1, which is what CLAUDE.md's
    # original "unvalidated" note referred to). Always blank situation, like
    # extra points, but phrased "pass attempt"/"rush attempt" rather than
    # "kick attempt", which is what keeps this rule from colliding with
    # extra_point above.
    blank_sit & stringr::str_detect(plays$play, stringr::regex("pass attempt|rush attempt", ignore_case = TRUE)) ~ "two_point",
    blank_sit & stringr::str_detect(plays$play, "^[A-Za-z].*\\d+, .*\\d+$") ~ "score",
    stringr::str_detect(plays$play, stringr::regex("^Timeout", ignore_case = TRUE)) ~ "timeout",
    is_dd & stringr::str_detect(plays$play, stringr::regex("^clock \\d{1,2}:\\d{2}\\.?$", ignore_case = TRUE)) ~ "bare_clock",
    is_dd & stringr::str_detect(plays$play, "^[1-4](st|nd|rd|th) and \\d+\\.?$") ~ "down_distance_echo",
    is_dd & stringr::str_detect(plays$play, stringr::regex("wins (the )?toss|will receive|will defend|to receive and defen[ds]e?|won the toss", ignore_case = TRUE)) ~ "coin_toss",
    is_dd & stringr::str_detect(plays$play, stringr::regex("ball on", ignore_case = TRUE)) ~ "spot_correction",
    is_dd & stringr::str_detect(plays$play, " in at | at QB for ") ~ "substitution",
    is_dd & stringr::str_detect(plays$play, stringr::regex("review", ignore_case = TRUE)) ~ "replay_review",
    same & stringr::str_detect(plays$play, stringr::regex("^back to top$|^Quarters:", ignore_case = TRUE)) ~ "nav",
    blank_sit & stringr::str_detect(plays$play, stringr::regex("^PENALTY\\b.*\\b(declined|offsetting)\\b", ignore_case = TRUE)) ~ "penalty_note",
    is_dd & stringr::str_detect(plays$play, stringr::regex("^(Spiked\\.?|\\d:00 minute warning\\.?|two minute warning\\.?|recovered by .+)$", ignore_case = TRUE)) ~ "annotation",
    stringr::str_detect(plays$play, "^\\.?$") ~ "blank",
    TRUE ~ "other"
  )

  dplyr::mutate(plays, row_type = row_type)
}
