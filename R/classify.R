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
#' Per CLAUDE.md: rush, pass, sacked, punt, field goal, kneel.
#' @keywords internal
verb_pattern <- "\\b(rush|pass|sacked|punt|field goal|kneel)\\b"

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
#' - `substitution` — "TEAM_PLAYER in at QB"
#'
#' `other` is the unknown bucket and should come back empty; anything landing
#' there means a new row shape has appeared and the classifier needs a new
#' rule, not that the row should be silently dropped.
#'
#' Ordering matters, per CLAUDE.md:
#' - `play` is checked first, so a nullified snap (has a verb, also has a
#'   `PENALTY ... NO PLAY` clause) is still counted as `play`.
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

  row_type <- dplyr::case_when(
    is_dd & has_verb ~ "play",
    is_dd & stringr::str_detect(plays$play, stringr::regex("penalty", ignore_case = TRUE)) ~ "penalty_no_play",
    stringr::str_detect(plays$play, stringr::regex("drive start", ignore_case = TRUE)) ~ "drive_start",
    same & stringr::str_detect(plays$play, " at \\d{1,2}:\\d{2}$") ~ "drive_header",
    same & stringr::str_detect(plays$play, "^\\d+ plays, -?\\d+ yards, \\d{2}:\\d{2} elapsed$") ~ "drive_footer",
    (same & stringr::str_detect(plays$play, "^[1-4](st|nd|rd|th)$")) |
      stringr::str_detect(plays$play, stringr::regex("^Start of|^End of (game|half)", ignore_case = TRUE)) ~ "quarter",
    blank_sit & stringr::str_detect(plays$play, stringr::regex("kickoff", ignore_case = TRUE)) ~ "kickoff",
    blank_sit & stringr::str_detect(plays$play, stringr::regex("kick attempt", ignore_case = TRUE)) ~ "extra_point",
    blank_sit & stringr::str_detect(plays$play, stringr::regex("pass attempt|rush attempt", ignore_case = TRUE)) ~ "two_point",
    blank_sit & stringr::str_detect(plays$play, "^[A-Za-z].*\\d+, .*\\d+$") ~ "score",
    stringr::str_detect(plays$play, stringr::regex("^Timeout", ignore_case = TRUE)) ~ "timeout",
    is_dd & stringr::str_detect(plays$play, "^clock \\d{2}:\\d{2}\\.?$") ~ "bare_clock",
    is_dd & stringr::str_detect(plays$play, "^[1-4](st|nd|rd|th) and \\d+\\.?$") ~ "down_distance_echo",
    is_dd & stringr::str_detect(plays$play, stringr::regex("wins toss|will receive|will defend|to receive and defend|won the toss", ignore_case = TRUE)) ~ "coin_toss",
    is_dd & stringr::str_detect(plays$play, stringr::regex("ball on", ignore_case = TRUE)) ~ "spot_correction",
    is_dd & stringr::str_detect(plays$play, " in at ") ~ "substitution",
    is_dd & stringr::str_detect(plays$play, stringr::regex("review", ignore_case = TRUE)) ~ "replay_review",
    same & stringr::str_detect(plays$play, stringr::regex("^back to top$|^Quarters:", ignore_case = TRUE)) ~ "nav",
    TRUE ~ "other"
  )

  dplyr::mutate(plays, row_type = row_type)
}
