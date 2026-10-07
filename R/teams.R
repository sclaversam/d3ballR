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
  team <- drive_row_team(classified$play)
  header <- ifelse(rt == "drive_header", team, NA_character_)
  start <- ifelse(rt == "drive_start", team, NA_character_)
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

#' The player a play description starts with (its "actor")
#'
#' The rusher, passer, sacked QB, punter, or kicker: the name right before the
#' play's verb, after an optional printed clock ("(04:23) ") and formation
#' ("No Huddle-Shotgun", "Shotgun", ...). Works for both "Booker,Jayden" and
#' "Andrew Deutsch" styles. "Kneel down by NAME" gives NAME. "TEAM" (a team
#' play) gives NA.
#'
#' @param text Play descriptions.
#' @return Character vector (NA when no name is found).
#' @keywords internal
play_actor <- function(text) {
  t <- stringr::str_remove(text, "^\\(\\d{1,2}:\\d{2}\\)\\s*")
  t <- stringr::str_remove(t, stringr::regex("^((No Huddle-)?(Shotgun|Pistol|Under Center|Wildcat)|No Huddle)\\s+", ignore_case = TRUE))
  kneel <- stringr::str_match(t, stringr::regex("^Kneel down by (.+?) (?:at|for)\\b", ignore_case = TRUE))[, 2]
  verb <- "(?:onside kickoff|kickoff|kick attempt|field goal attempt|pass attempt|rush attempt|pass complete|pass incomplete|pass intercepted|sacked|punt|rush|pass)\\b"
  a <- stringr::str_match(t, paste0("^(.{2,40}?) ", verb))[, 2]
  a <- dplyr::coalesce(kneel, a)
  a <- stringr::str_squish(a)
  ifelse(is.na(a) | toupper(a) == "TEAM", NA_character_, a)
}

#' Which team each player name belongs to, learned from plays with a known team
#'
#' Training rows: snaps (their offense is known from the drive headers), and
#' ordinary kickoffs decided by the drive header (the kicker is on the
#' kicking team). Onside kicks are left out, since those are what the map is
#' used to check. A name is mapped when at least 80% of its plays agree.
#'
#' @param kept Kept rows with `play_type`, `play_text`, `pos_team`, `row`.
#' @param kickoffs Output of [assign_kickoffs()].
#' @return Named character vector: player name -> team.
#' @keywords internal
build_actor_map <- function(kept, kickoffs) {
  snap <- kept$play_type %in% play_type_categories
  ko <- kickoffs[kickoffs$rule == "header" & !kickoffs$kicker_recovered, ]
  ko_text <- kept$play_text[match(ko$row, kept$row)]
  ko <- ko[!stringr::str_detect(ko_text, stringr::regex("on-?side", ignore_case = TRUE)), ]
  d <- data.frame(
    actor = c(play_actor(kept$play_text[snap]), play_actor(kept$play_text[match(ko$row, kept$row)])),
    team = c(kept$pos_team[snap], ko$kicking_team)
  )
  d <- d[!is.na(d$actor) & !is.na(d$team), ]
  if (!nrow(d)) return(character())
  tab <- table(d$actor, d$team)
  share <- apply(tab, 1, max) / rowSums(tab)
  best <- colnames(tab)[apply(tab, 1, which.max)]
  stats::setNames(best[share >= 0.8], rownames(tab)[share >= 0.8])
}

#' Correct kickoffs using the kicker's team
#'
#' The kicker named on a kickoff is on the kicking team. When the kicker's
#' team is known ([build_actor_map()]) it decides the kicking team, and if
#' the next drive belongs to that same team, the kicking team recovered (an
#' onside kick, or a return fumble), even when the text never says
#' "recovered by". Example: "Jesch,Mateo onside kickoff 12 yards to the
#' WHE47." followed by a Wheaton drive.
#'
#' @param kickoffs Output of [assign_kickoffs()].
#' @param kept Kept rows with `row`, `play_text`.
#' @param actor_map Output of [build_actor_map()].
#' @param teams The two canonical team names.
#' @return `kickoffs`, with `kicking_team`, `receiving_team`,
#'   `kicker_recovered`, `rule`, `disagreement` updated where the kicker
#'   decides.
#' @keywords internal
refine_kickoffs_by_kicker <- function(kickoffs, kept, actor_map, teams) {
  kicker <- play_actor(kept$play_text[match(kickoffs$row, kept$row)])
  kt <- unname(actor_map[kicker])
  for (i in which(!is.na(kt))) {
    recovered <- isTRUE(kickoffs$header_team[i] == kt[i]) || kickoffs$kicker_recovered[i]
    if (!identical(kickoffs$kicking_team[i], kt[i]) || recovered != kickoffs$kicker_recovered[i]) {
      kickoffs$disagreement[i] <- paste0("kicker ", kicker[i], " is ", kt[i], "; was ", kickoffs$rule[i],
                                         " (kicking ", kickoffs$kicking_team[i], ")")
      kickoffs$rule[i] <- "kicker"
    }
    kickoffs$kicking_team[i] <- kt[i]
    kickoffs$receiving_team[i] <- other_team(kt[i], teams)
    kickoffs$kicker_recovered[i] <- recovered
  }
  kickoffs
}

#' The team named on a drive header or drive-start row
#'
#' Drive headers read "TEAM at MM:SS" (some stat crews drop the clock:
#' "Virginia-Lynchburg at"); drive-start rows read "TEAM drive start at
#' MM:SS.", sometimes after a clock ("clock 09:08, LaGrange College drive
#' start at 09:08."). Callers apply this to drive_header / drive_start rows.
#'
#' @param play Play text.
#' @return Character vector of team spellings (NA when neither shape matches).
#' @keywords internal
drive_row_team <- function(play) {
  p <- stringr::str_remove(play, stringr::regex("^clock \\d{1,2}:\\d{2},\\s*", ignore_case = TRUE))
  dplyr::coalesce(
    stringr::str_match(p, stringr::regex("^(.*?) drive start at", ignore_case = TRUE))[, 2],
    stringr::str_match(p, "^(.*?) at(?: \\d{1,2}:\\d{2})?$")[, 2]
  )
}
