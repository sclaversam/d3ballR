#' Parse the "Away at Home" matchup off the boxscore header
#'
#' The first table on the plays page starts with "Carnegie Mellon at Chicago
#' - Chicago Logo, Illinois 09/06/2025 - 12:00 PM". The two names are in the
#' header / line-score spelling ("Chicago", "UW-La Crosse"), which is not
#' always the `pos_team` spelling; map them with [build_team_map()].
#'
#' @param tbls A list of data frames (from [tables_on()]).
#' @return Named character vector `c(away = ..., home = ...)`.
#' @keywords internal
parse_matchup <- function(tbls) {
  for (t in tbls) {
    cell <- stringr::str_squish(as.character(t[[1]][1]))
    m <- stringr::str_match(cell, "^(.+?) at (.+?) - ")
    if (!is.na(m[1, 1])) return(c(away = m[1, 2], home = m[1, 3]))
  }
  stop("No 'Away at Home' header found. Open the page and check the layout.")
}

#' Build a map from every team spelling on the page to one canonical name
#'
#' d3 names a team several ways on one page: the header, line score, score
#' lines and drive headers use one spelling ("Chicago", "Franklin and
#' Marshall"); drive-start rows use another ("UChicago", "Franklin &
#' Marshall"). The canonical name is the drive-start spelling, which is what
#' `pos_team` has always used. A drive header is mapped to the drive-start
#' name in the row right after it. Any other name (e.g. a line-score name
#' that never appears on a drive row) is mapped by elimination: once one of
#' the two line-score names is matched, the other gets the remaining team.
#'
#' @param classified Classified rows (full set).
#' @param other_names Further spellings to map (the line-score / header
#'   names).
#' @return Named character vector: names are spellings, values canonical.
#' @keywords internal
build_team_map <- function(classified, other_names) {
  rt <- classified$row_type
  header <- stringr::str_match(classified$play, "^(.*?) at \\d{1,2}:\\d{2}$")[, 2]
  start <- stringr::str_match(classified$play, stringr::regex("^(.*?) drive start at", ignore_case = TRUE))[, 2]
  canonical <- unique(stats::na.omit(start[rt == "drive_start"]))

  map <- stats::setNames(canonical, canonical)
  h <- which(rt == "drive_header")
  pairs <- h[h < nrow(classified) & rt[h + 1] == "drive_start"]
  if (length(pairs)) {
    ph <- header[pairs]
    ps <- start[pairs + 1]
    for (nm in unique(ph)) {
      if (!nm %in% names(map)) map[nm] <- names(sort(table(ps[ph == nm]), decreasing = TRUE))[1]
    }
  }
  # headers never followed by a start row keep their own spelling only if
  # it is one of the canonical names; otherwise resolved by elimination below
  unresolved <- setdiff(c(unique(stats::na.omit(header[rt == "drive_header"])), other_names), names(map))
  if (length(canonical) != 2) {
    stop("Expected 2 drive-start team names, got: ", paste(canonical, collapse = " / "))
  }
  for (nm in unresolved) {
    matched <- intersect(unname(map[intersect(other_names, names(map))]), canonical)
    if (nm %in% other_names && length(matched) == 1) {
      map[nm] <- setdiff(canonical, matched)
    } else {
      stop("Cannot map team name '", nm, "' to one of: ", paste(canonical, collapse = " / "))
    }
  }
  map
}

#' Resolve a team reference (name, situation token, or play-text token)
#'
#' Coin-toss rows mix full names ("Carnegie Mellon wins toss") with
#' situation tokens ("UC will receive"); recovery and penalty clauses use
#' play-text tokens ("recovered by UCHI"). This looks a reference up in each
#' map in turn.
#'
#' @param x Character vector of references.
#' @param team_map Output of [build_team_map()].
#' @param own_side Output of [infer_own_side()] (team -> situation token).
#' @param text_team Output of [infer_text_team()] (play-text token -> team).
#' @return Character vector of canonical team names (NA if unresolved).
#' @keywords internal
resolve_team <- function(x, team_map, own_side, text_team) {
  token_team <- stats::setNames(names(own_side), own_side)
  out <- unname(team_map[x])
  out <- ifelse(is.na(out), unname(token_team[x]), out)
  out <- ifelse(is.na(out), unname(text_team[x]), out)
  out
}

#' The other team
#' @param x Character vector of canonical team names.
#' @param teams The game's two canonical team names.
#' @keywords internal
other_team <- function(x, teams) {
  ifelse(is.na(x), NA_character_, ifelse(x == teams[1], teams[2], teams[1]))
}
