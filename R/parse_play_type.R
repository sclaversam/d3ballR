#' Play-type categories recognized within `row_type == "play"`
#'
#' From `analysis/play_type_inventory.csv`, built by categorizing every play
#' row across all 11 CMU 2025 games by hand-checked signature. Twelve
#' categories, zero UNPLACED once `verb_pattern` (see `R/classify.R`) was
#' tightened to stop matching "Pass" inside penalty names.
#' @keywords internal
play_type_categories <- c(
  "field_goal_blocked", "field_goal_missed", "field_goal_good",
  "punt_blocked", "punt_with_return", "punt_no_return",
  "sack", "pass_intercepted", "pass_complete", "pass_incomplete",
  "rush", "kneel"
)

#' Categorize each `play` row by its play type
#'
#' Ordered `case_when` on the `play` description text, same signatures used to
#' build `analysis/play_type_inventory.csv`. Ordering matters where one
#' pattern is a superset of another:
#' - `field_goal_blocked` before `field_goal_missed`/`field_goal_good`, since
#'   a blocked attempt is sometimes also worded "NO GOOD blocked by ...".
#' - `field_goal_missed` before `field_goal_good`, since "good" alone doesn't
#'   appear in a missed attempt but the reverse ordering would be fragile if
#'   wording changes.
#' - `punt_blocked` before `punt_with_return`/`punt_no_return`, and
#'   `punt_with_return` before `punt_no_return`, since a blocked or returned
#'   punt still contains the bare word "punt".
#' - `pass_intercepted` before `pass_complete`/`pass_incomplete`, since an
#'   intercepted pass never says "complete" or "incomplete" in this data but
#'   keeping the more specific pattern first is the safer default.
#' - `rush` last among the snap verbs, since it has no sub-categories to
#'   collide with.
#'
#' Only rows with `row_type == "play"` are categorized; every other row_type
#' gets `NA_character_` in `play_type` (this function does not parse down,
#' yards, or yardline -- that's a later step).
#'
#' @param classified A tibble with `play` and `row_type` columns, as returned
#'   by [classify_plays()].
#' @return `classified` with an added `play_type` column (character, `NA` for
#'   non-`play` rows).
#' @export
parse_play_type <- function(classified) {
  p <- classified$play
  is_play <- classified$row_type == "play"
  ic <- function(pattern) stringr::regex(pattern, ignore_case = TRUE)

  play_type <- dplyr::case_when(
    !is_play ~ NA_character_,
    stringr::str_detect(p, ic("kneel down")) ~ "kneel",
    stringr::str_detect(p, ic("field goal attempt")) & stringr::str_detect(p, ic("blocked")) ~ "field_goal_blocked",
    stringr::str_detect(p, ic("field goal attempt")) & stringr::str_detect(p, ic("no good|missed")) ~ "field_goal_missed",
    stringr::str_detect(p, ic("field goal attempt")) & stringr::str_detect(p, ic("\\bgood\\b")) ~ "field_goal_good",
    stringr::str_detect(p, ic("\\bpunt\\b")) & stringr::str_detect(p, ic("blocked")) ~ "punt_blocked",
    stringr::str_detect(p, ic("\\bpunt\\b")) & stringr::str_detect(p, ic("return")) ~ "punt_with_return",
    stringr::str_detect(p, ic("\\bpunt\\b")) ~ "punt_no_return",
    stringr::str_detect(p, ic("\\bsacked\\b")) ~ "sack",
    stringr::str_detect(p, ic("pass intercepted")) ~ "pass_intercepted",
    stringr::str_detect(p, ic("pass complete")) ~ "pass_complete",
    stringr::str_detect(p, ic("pass incomplete")) ~ "pass_incomplete",
    stringr::str_detect(p, ic("\\brush\\b")) ~ "rush",
    TRUE ~ "UNPLACED"
  )

  dplyr::mutate(classified, play_type = play_type)
}
