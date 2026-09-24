#' Extract the boxscore game id from a game URL
#'
#' @param game_url Boxscore URL, e.g.
#'   "https://www.d3football.com/seasons/2025/boxscores/20250906_e064.xml".
#' @return Character scalar, e.g. "20250906_e064".
#' @keywords internal
extract_game_id <- function(game_url) {
  stringr::str_match(game_url, "boxscores/([^./]+)\\.xml")[, 2]
}

#' Read the two team names off a boxscore's line-score table
#'
#' Located by content (a table with a "Final" column and at least 2 rows),
#' not by position, same philosophy as [find_plays()]. Each of the first two
#' rows is "TEAM NAME (W-L, conf)" or "TEAM NAME (W-L)"; the trailing
#' parenthetical record is stripped.
#'
#' @param tbls A list of data frames (from [tables_on()]).
#' @return A character vector of length 2: the two team names.
#' @keywords internal
find_line_score_teams <- function(tbls) {
  for (t in tbls) {
    if ("Final" %in% colnames(t) && nrow(t) >= 2) {
      raw <- stringr::str_squish(as.character(t[[1]][1:2]))
      return(stringr::str_remove(raw, "\\s*\\([^)]*\\)\\s*$"))
    }
  }
  stop("No line-score table found. Open the page and check the layout.")
}

#' Fetch one game's play table plus its opponent
#'
#' Fetches the plays view page once and pulls both the play-by-play table
#' (via [find_plays()]) and the two team names off the line-score table on
#' the same page, so each game only costs one HTTP request.
#'
#' @param game_url Boxscore URL without the `?view=` suffix.
#' @return A list with `game_id` (character), `opponent` (character, CMU's
#'   opponent), and `plays` (tibble with `situation`/`play`, from
#'   [find_plays()]).
#' @keywords internal
fetch_game <- function(game_url) {
  html <- fetch_html(paste0(game_url, "?view=plays"))
  tbls <- tables_on(html)
  teams <- find_line_score_teams(tbls)
  is_cmu <- stringr::str_detect(teams, stringr::regex("carnegie mellon", ignore_case = TRUE))
  if (sum(is_cmu) != 1) {
    stop("Could not uniquely identify Carnegie Mellon in team names: ",
         paste(teams, collapse = " / "))
  }
  list(
    game_id  = extract_game_id(game_url),
    opponent = teams[!is_cmu],
    plays    = find_plays(tbls)
  )
}

#' Forward-fill quarter from quarter-marker rows
#'
#' Reads the quarter number off two row shapes typed `quarter` by
#' [classify_plays()]: the bare "1st"/"2nd"/"3rd"/"4th" marker, and
#' "Start of Nth quarter, clock M:SS[, ...]." "End of half"/"End of game"
#' rows carry no digit and are left NA here, which is correct -- forward-fill
#' carries the still-current quarter through them.
#'
#' @param classified A classified tibble (from [classify_plays()]), full row
#'   set (not yet filtered to kept row types).
#' @return `classified` with an added `quarter` column (character, forward
#'   filled).
#' @keywords internal
derive_quarter <- function(classified) {
  is_quarter <- classified$row_type == "quarter"
  bare <- stringr::str_match(classified$play, "^([1-4])(?:st|nd|rd|th)$")[, 2]
  started <- stringr::str_match(
    classified$play,
    stringr::regex("^Start of ([1-4])(?:st|nd|rd|th) quarter", ignore_case = TRUE)
  )[, 2]
  quarter_here <- dplyr::coalesce(bare, started)
  quarter_here <- ifelse(is_quarter, quarter_here, NA_character_)
  classified$quarter <- quarter_here
  tidyr::fill(classified, "quarter", .direction = "down")
}

#' Forward-fill possession from drive_header / drive_start rows
#'
#' Both row shapes name the possessing team: `drive_header` is
#' "TEAM at MM:SS" (situation == play), `drive_start` is
#' "TEAM drive start at MM:SS." The two rows come back to back for the same
#' drive; when both are present, `drive_start`'s spelling of the team name
#' wins for the rows that follow, since it's checked second and overwrites.
#' The very first kickoff of the game (before any drive_header/drive_start
#' has appeared) is a known gap -- there's nothing earlier to forward-fill
#' from, so `possession` is NA there.
#'
#' @param classified A classified tibble (from [classify_plays()]), full row
#'   set (not yet filtered to kept row types), with `quarter` already added.
#' @return `classified` with an added `possession` column (character,
#'   forward filled).
#' @keywords internal
derive_possession <- function(classified) {
  header_team <- stringr::str_match(classified$play, "^(.*?) at \\d{1,2}:\\d{2}$")[, 2]
  start_team <- stringr::str_match(classified$play, stringr::regex("^(.*?) drive start at", ignore_case = TRUE))[, 2]
  possession_here <- dplyr::case_when(
    classified$row_type == "drive_header" ~ header_team,
    classified$row_type == "drive_start" ~ start_team,
    TRUE ~ NA_character_
  )
  classified$possession <- possession_here
  tidyr::fill(classified, "possession", .direction = "down")
}

#' Row types CMU logs as plays -- the set this table keeps
#' @keywords internal
kept_row_types <- c("play", "kickoff", "extra_point", "two_point", "penalty_no_play")

#' Down/distance/yardline pattern for a real situation line
#'
#' e.g. "1st and 10 at CMU35" or "1st and Goal at CMU06" or "4th and 3 at UC 25".
#' The yardline's team-letters group is optional so a bare midfield number
#' ("at 50") still parses down/distance/yard_num, with `yard_side` NA.
#' @keywords internal
situation_pattern <- "^([1-4])(?:st|nd|rd|th)\\s+and\\s+(Goal|\\d+)\\s+at\\s+([A-Za-z&]*)\\s*(\\d+)$"

#' Parse down, distance, yard_side, yard_num from `situation`
#'
#' Blank `situation` (kickoffs, PATs, two-point tries) yields NA in all four
#' fields, matching how CMU logs those event types with no down/distance/
#' field position. `distance` for an "and Goal" situation is filled in later
#' by [derive_goal_to_go()], once we know which side of the field the
#' offense is on.
#'
#' @param df A tibble with a `situation` column.
#' @return `df` with `down` (integer), `distance` (integer, NA on "and
#'   Goal" for now), `distance_is_goal` (logical, the literal "and Goal"
#'   text), `yard_side` (character), `yard_num` (integer) added.
#' @keywords internal
parse_situation <- function(df) {
  m <- stringr::str_match(df$situation, stringr::regex(situation_pattern, ignore_case = TRUE))
  down <- suppressWarnings(as.integer(m[, 2]))
  distance_raw <- m[, 3]
  yard_side <- m[, 4]
  yard_side <- ifelse(is.na(yard_side) | nchar(trimws(yard_side)) == 0, NA_character_, yard_side)

  df$down <- down
  df$distance <- suppressWarnings(as.integer(distance_raw))
  df$distance_is_goal <- ifelse(is.na(down), NA, tolower(distance_raw) == "goal")
  df$yard_side <- yard_side
  df$yard_num <- suppressWarnings(as.integer(m[, 5]))
  df
}

#' Infer which yardline token is each team's own side of the field
#'
#' The situation column writes yardlines with a short team token ("UC 25",
#' "CMU35"), but possession is a team *name* ("UChicago"), and the page
#' never states which token belongs to which name. So infer it from the
#' data: on consecutive snaps by the same offense on the same token, the
#' yard number goes UP when that token is the offense's own side (moving
#' away from its own goal) and DOWN when it's the opponent's side. Gains
#' far outnumber losses, so a vote over the whole game is decisive.
#'
#' Scores the two possible pairings (team 1 owns token 1, or team 1 owns
#' token 2) and keeps the one with more agreeing votes. Stops if the game
#' doesn't have exactly two teams and two tokens, or if the vote is too
#' close to trust.
#'
#' @param df Kept rows with `pos_team`, `yard_side`, `yard_num`.
#' @return Named character vector: names are the two `pos_team` values,
#'   values are that team's own-side token.
#' @keywords internal
infer_own_side <- function(df) {
  teams <- sort(unique(stats::na.omit(df$pos_team)))
  tokens <- sort(unique(stats::na.omit(df$yard_side)))
  if (length(teams) != 2 || length(tokens) != 2) {
    stop("Expected 2 teams and 2 yardline tokens, got teams: ",
         paste(teams, collapse = " / "), "; tokens: ", paste(tokens, collapse = " / "))
  }

  n <- nrow(df)
  same <- df$pos_team[-1] == df$pos_team[-n] & df$yard_side[-1] == df$yard_side[-n]
  step <- df$yard_num[-1] - df$yard_num[-n]
  ok <- same %in% TRUE & !is.na(step) & step != 0
  team <- df$pos_team[-n][ok]
  token <- df$yard_side[-n][ok]
  up <- step[ok] > 0

  # votes for pairing A: teams[1] owns tokens[1], teams[2] owns tokens[2]
  own_a <- ifelse(team == teams[1], tokens[1], tokens[2])
  agree_a <- sum((token == own_a) == up)
  agree_b <- sum((token != own_a) == up)
  if (max(agree_a, agree_b) < 2 * min(agree_a, agree_b)) {
    stop("Yardline side vote too close to call (", agree_a, " vs ", agree_b, ").")
  }
  if (agree_a >= agree_b) stats::setNames(tokens, teams) else stats::setNames(rev(tokens), teams)
}

#' Compute yards_to_goal from the yardline and the possessing team's side
#'
#' Own 25 -> 75, opponent 25 -> 25, bare midfield "at 50" -> 50. NA when
#' there's no situation or no `pos_team`.
#'
#' @param df Kept rows with `pos_team`, `yard_side`, `yard_num`.
#' @param own_side Output of [infer_own_side()].
#' @return Integer vector.
#' @keywords internal
compute_yards_to_goal <- function(df, own_side) {
  own_token <- unname(own_side[df$pos_team])
  ytg <- dplyr::case_when(
    is.na(df$pos_team) | is.na(df$yard_num) ~ NA_integer_,
    is.na(df$yard_side) & df$yard_num == 50L ~ 50L,
    df$yard_side == own_token ~ 100L - df$yard_num,
    df$yard_side != own_token ~ df$yard_num,
    TRUE ~ NA_integer_
  )
  as.integer(ytg)
}

#' Flag goal-to-go situations and fill their distance
#'
#' Goal-to-go means the line to gain is the goal line. d3's StatCrew text
#' writes that two ways: literally ("1st and Goal at CMU06"), and as a
#' number that happens to equal the distance to the goal ("1st and 4 at
#' UC 4", "1st and 1 at UC 1"). Both are goal-to-go, so `Goal_To_Go` is
#' TRUE when the text says "Goal" OR `distance == yards_to_goal`. For the
#' literal "and Goal" rows, `distance` is set to `yards_to_goal`.
#'
#' @param df Kept rows after [parse_situation()], with `yards_to_goal`.
#' @return `df` with `Goal_To_Go` (logical; NA where there's no down) and
#'   `distance` filled on "and Goal" rows. Drops `distance_is_goal`.
#' @keywords internal
derive_goal_to_go <- function(df) {
  literal <- df$distance_is_goal %in% TRUE
  df$distance <- ifelse(literal, df$yards_to_goal, df$distance)
  numeric_goal <- !is.na(df$distance) & !is.na(df$yards_to_goal) & df$distance == df$yards_to_goal
  df$Goal_To_Go <- ifelse(is.na(df$down), NA, literal | numeric_goal)
  df$distance_is_goal <- NULL
  df
}

#' Loosely parse yards gained from a play description
#'
#' Play yards only, penalty enforcement excluded (enforcement text reads
#' "N yard(s) from X to Y", never "for N yards", so it doesn't collide with
#' these patterns). Handles the wording variants seen across the 11-game
#' 2025 sweep: "for N yards gain", "for N yards loss", "for loss of N yard(s)"
#' (sacks, kneels, and an alternate rush phrasing), "for no gain", and a bare
#' "for N yards" (assumed positive when no gain/loss qualifier is present).
#' Only computed for `row_type == "play"`, and only for the play types where
#' "yards gained" is unambiguous (rush, pass_complete, sack, kneel; incomplete
#' passes are always 0). Left NA for kickoff/extra_point/two_point/
#' penalty_no_play (no snap, or not a rush/pass yardage stat), and for
#' pass_intercepted/punt*/field_goal* play types, where what "yards_gained"
#' should even mean isn't settled yet -- proper yardage validation is a later
#' step, this is deliberately loose.
#'
#' @param play_text Character vector, the raw `play` description.
#' @param play_type Character vector, from [parse_play_type()] (already
#'   backfilled to `row_type` for non-scrimmage kept rows).
#' @param row_type Character vector, from [classify_plays()].
#' @return Integer vector, `NA` where not confidently parsed.
#' @keywords internal
parse_yards_gained <- function(play_text, play_type, row_type) {
  ic <- function(pattern) stringr::regex(pattern, ignore_case = TRUE)

  no_gain <- stringr::str_detect(play_text, ic("no gain"))
  loss_of <- suppressWarnings(as.integer(stringr::str_match(play_text, ic("(?:for )?loss of (\\d+) yard"))[, 2]))
  yards_loss_suffix <- suppressWarnings(as.integer(stringr::str_match(play_text, ic("for (\\d+) yards? loss"))[, 2]))
  yards_gain_suffix <- suppressWarnings(as.integer(stringr::str_match(play_text, ic("for (\\d+) yards? gain"))[, 2]))
  yards_plain <- suppressWarnings(as.integer(stringr::str_match(play_text, ic("for (\\d+) yards?\\b"))[, 2]))

  generic <- dplyr::case_when(
    no_gain ~ 0L,
    !is.na(loss_of) ~ -loss_of,
    !is.na(yards_loss_suffix) ~ -yards_loss_suffix,
    !is.na(yards_gain_suffix) ~ yards_gain_suffix,
    !is.na(yards_plain) ~ yards_plain,
    TRUE ~ NA_integer_
  )

  dplyr::case_when(
    row_type != "play" ~ NA_integer_,
    play_type %in% c("rush", "pass_complete", "sack", "kneel") ~ generic,
    play_type == "pass_incomplete" ~ 0L,
    TRUE ~ NA_integer_
  )
}

#' Build one game's play-by-play table
#'
#' Own schema (not CMU's exact columns yet): keeps only the row types CMU
#' logs (`play`, `kickoff`, `extra_point`, `two_point`, `penalty_no_play`),
#' after using the dropped administrative rows to derive `quarter` and
#' `possession`. See `R/classify.R` and `R/parse_play_type.R` for the
#' upstream row_type/play_type classification this builds on.
#'
#' Not built yet (deliberately, per CLAUDE.md's ordering): signed
#' `field_pos`, penalty columns (`has_penalty`/`penalty_yards`/
#' `penalty_text`), or CMU's exact column names/values. This pass is about
#' completeness and row-count correctness.
#'
#' @param game_url Boxscore URL without the `?view=` suffix.
#' @return A tibble, one row per kept play, columns: `game_id`, `opponent`,
#'   `play_index`, `quarter`, `possession`, `row_type`, `down`, `distance`,
#'   `Goal_To_Go`, `yard_side`, `yard_num`, `play_type`, `yards_gained`,
#'   `situation`, `play`.
#' @export
build_pbp <- function(game_url) {
  game <- fetch_game(game_url)

  classified <- classify_plays(game$plays)
  classified <- derive_quarter(classified)
  classified <- derive_possession(classified)
  classified <- parse_play_type(classified)

  kept <- classified[classified$row_type %in% kept_row_types, ]
  kept$play_type <- ifelse(kept$row_type == "play", kept$play_type, kept$row_type)
  kept <- parse_situation(kept)
  kept$pos_team <- kept$possession
  kept$yards_to_goal <- compute_yards_to_goal(kept, infer_own_side(kept))
  kept <- derive_goal_to_go(kept)
  kept$yards_gained <- parse_yards_gained(kept$play, kept$play_type, kept$row_type)

  kept$game_id <- game$game_id
  kept$opponent <- game$opponent
  kept$play_index <- seq_len(nrow(kept))

  kept[, c(
    "game_id", "opponent", "play_index", "quarter", "possession", "row_type",
    "down", "distance", "Goal_To_Go", "yard_side", "yard_num", "play_type",
    "yards_gained", "situation", "play"
  )]
}

#' Build and write every game's play-by-play table
#'
#' Writes one CSV per game to `{out_dir}/{game_id}.csv`, plus a summary of
#' kept-row counts to `{out_dir}/../pbp_row_counts.csv`. Prints the per-game
#' counts to the console.
#'
#' @param game_urls Character vector of boxscore URLs.
#' @param out_dir Directory to write per-game CSVs into.
#' @return Invisibly, a named list of the per-game tibbles (by `game_id`).
#' @export
build_all_pbp <- function(game_urls, out_dir = "analysis/pbp") {
  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

  games <- lapply(game_urls, build_pbp)

  counts <- dplyr::bind_rows(lapply(games, function(g) {
    tibble::tibble(game_id = g$game_id[1], opponent = g$opponent[1], n_rows = nrow(g))
  }))

  for (g in games) {
    utils::write.csv(g, file.path(out_dir, paste0(g$game_id[1], ".csv")), row.names = FALSE, na = "")
  }
  utils::write.csv(counts, file.path(out_dir, "..", "pbp_row_counts.csv"), row.names = FALSE, na = "")

  print(as.data.frame(counts))

  names(games) <- counts$game_id
  invisible(games)
}
