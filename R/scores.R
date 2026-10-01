#' Parse the score-update rows into a running score table
#'
#' d3 prints a score line after every scoring sequence ("Carnegie Mellon 7,
#' Chicago 0"), using the header spelling of each name. For a touchdown the
#' line comes after the try, so one line covers TD + PAT.
#'
#' @param classified Classified rows (full set) with `row_type`.
#' @param team_map Output of [build_team_map()].
#' @param teams The game's two canonical team names.
#' @return A data frame, one row per score line, in game order: `row`
#'   (position in `classified`), `score_1`, `score_2` (totals for `teams[1]`,
#'   `teams[2]`), `scorer` (canonical team whose total went up), `delta`
#'   (points added since the previous line).
#' @keywords internal
parse_score_rows <- function(classified, team_map, teams) {
  r <- which(classified$row_type == "score")
  m <- stringr::str_match(classified$play[r], "^(.*) (\\d+), (.*) (\\d+)$")
  a <- unname(team_map[m[, 2]])
  b <- unname(team_map[m[, 4]])
  if (anyNA(a) || anyNA(b)) stop("Unmapped team name in a score line.")
  sa <- as.integer(m[, 3])
  sb <- as.integer(m[, 5])
  score_1 <- ifelse(a == teams[1], sa, sb)
  score_2 <- ifelse(a == teams[1], sb, sa)
  d1 <- diff(c(0L, score_1))
  d2 <- diff(c(0L, score_2))
  data.frame(
    row = r, score_1 = score_1, score_2 = score_2,
    scorer = ifelse(d1 > 0 & d2 == 0, teams[1], ifelse(d2 > 0 & d1 == 0, teams[2], NA_character_)),
    delta = pmax(d1, d2)
  )
}
