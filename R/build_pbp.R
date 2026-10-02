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

#' Extract the season from a boxscore URL path
#'
#' Always the `/seasons/{year}/` path segment, never the game date: a
#' January championship and the 2020 season (played in spring 2021) belong
#' to the season in the path.
#'
#' @param game_url Boxscore URL.
#' @return Integer.
#' @keywords internal
extract_season <- function(game_url) {
  as.integer(stringr::str_match(game_url, "/seasons/(\\d{4})/")[, 2])
}

#' Fetch one game's play table plus its team names
#'
#' Fetches the plays view page once and pulls the play-by-play table (via
#' [find_plays()]), the two line-score team names, the "Away at Home"
#' header (via [parse_matchup()]) and the header date, so each game only
#' costs one HTTP request. Works for any game: nothing assumes a team.
#'
#' @param game_url Boxscore URL without the `?view=` suffix.
#' @return A list with `game_id`, `season` (from the URL path), `teams`
#'   (both line-score names), `matchup` (`c(away, home)`, header spelling),
#'   `header_date` (Date from the header, used only if the game isn't in
#'   the season index), and `plays` (tibble with `situation`/`play`).
#' @keywords internal
fetch_game <- function(game_url) {
  html <- fetch_html(paste0(game_url, "?view=plays"))
  tbls <- tables_on(html)
  header <- stringr::str_squish(as.character(tbls[[1]][[1]][1]))
  list(
    game_id     = extract_game_id(game_url),
    season      = extract_season(game_url),
    teams       = find_line_score_teams(tbls),
    matchup     = parse_matchup(tbls),
    header_date = as.Date(stringr::str_match(header, "(\\d{1,2}/\\d{1,2}/\\d{4})")[, 2], format = "%m/%d/%Y"),
    plays       = find_plays(tbls)
  )
}

#' Look a game up in its season index
#'
#' Returns `season`, `game_date` (ISO), `week`, `season_type` for the game.
#' If the game isn't in the index (or no index is available), falls back to
#' the boxscore id's date (else the header date), [classify_season_type()],
#' and a date-based Sunday-to-Saturday week ([date_based_week()]), and logs
#' a message saying so.
#'
#' @param game A list from [fetch_game()].
#' @param index A season index from [build_season_index()], or NULL.
#' @param season_dates Output of [read_season_dates()].
#' @return A list: `season`, `game_date`, `week`, `season_type`,
#'   `week_source` ("index" or "date fallback").
#' @keywords internal
game_calendar <- function(game, index, season_dates) {
  hit <- if (!is.null(index)) index[!is.na(index$game_id) & index$game_id == game$game_id, ] else NULL
  if (!is.null(hit) && nrow(hit) == 1) {
    return(list(season = as.integer(hit$season), game_date = as.character(hit$game_date),
                week = as.integer(hit$week), season_type = hit$season_type, week_source = "index"))
  }
  d <- dplyr::coalesce(as.Date(substr(game$game_id, 1, 8), format = "%Y%m%d"), game$header_date)
  st <- classify_season_type(d, game$season, season_dates)
  wk <- date_based_week(d, game$season, st, season_dates)
  message("Game ", game$game_id, " not found in the ", game$season,
          " season index; using a date-based week (", wk, ", ", st, ").")
  list(season = game$season, game_date = format(d, "%Y-%m-%d"), week = wk,
       season_type = st, week_source = "date fallback")
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
#' "TEAM drive start at MM:SS." The two can spell the team differently
#' ("Chicago" / "UChicago"), so both are mapped to one canonical name with
#' `team_map` (see [build_team_map()]). Kickoff rows get their possession
#' later, from [assign_kickoffs()]; forward-fill only covers the rows in
#' between drive rows.
#'
#' @param classified A classified tibble, full row set.
#' @param team_map Output of [build_team_map()].
#' @return `classified` with an added `possession` column (character,
#'   forward filled, canonical names).
#' @keywords internal
derive_possession <- function(classified, team_map) {
  header_team <- stringr::str_match(classified$play, "^(.*?) at \\d{1,2}:\\d{2}$")[, 2]
  start_team <- stringr::str_match(classified$play, stringr::regex("^(.*?) drive start at", ignore_case = TRUE))[, 2]
  possession_here <- dplyr::case_when(
    classified$row_type == "drive_header" ~ header_team,
    classified$row_type == "drive_start" ~ start_team,
    TRUE ~ NA_character_
  )
  classified$possession <- unname(team_map[possession_here])
  tidyr::fill(classified, "possession", .direction = "down")
}

#' Event types kept in the play-by-play table
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
#' @param df A tibble with `situation` and `play_type` columns.
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
  # kickoffs and tries have no down, even when StatCrew leaves a stale
  # down-and-distance in the situation column (a kickoff with a return
  # penalty does)
  no_down <- df$play_type %in% c("kickoff", "extra_point", "two_point")
  for (col in c("down", "distance", "distance_is_goal", "yard_side", "yard_num")) {
    df[[col]][no_down] <- NA
  }
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
#' Play yards only, penalty enforcement excluded (conventions 1, 4, 5 in
#' `analysis/pbp_schema_and_build_plan.md`). Only the text BEFORE the
#' "PENALTY" clause is read, so enforcement yardage ("N yard(s) from X to
#' Y" / "N yards to the X") can never land here. NA on every no-play row
#' (convention 3): the wiped-out attempt's "for 54 yards" is not credited.
#' Handles the wording variants seen across the 11-game
#' 2025 sweep: "for N yards gain", "for N yards loss", "for loss of N yard(s)"
#' (sacks, kneels, and an alternate rush phrasing), "for no gain", and a bare
#' "for N yards" (assumed positive when no gain/loss qualifier is present).
#' Only computed for snaps (a `play_type` in [play_type_categories]), and
#' only for the play types where
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
#' @param no_play Logical vector, `penalty_no_play` from [parse_penalties()].
#' @return Integer vector, `NA` where not confidently parsed.
#' @keywords internal
parse_yards_gained <- function(play_text, play_type, no_play) {
  ic <- function(pattern) stringr::regex(pattern, ignore_case = TRUE)
  play_text <- stringr::str_remove(play_text, "PENALTY .*$")

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
    !play_type %in% play_type_categories | no_play ~ NA_integer_,
    play_type %in% c("rush", "pass_complete", "sack", "kneel") ~ generic,
    play_type == "pass_incomplete" ~ 0L,
    TRUE ~ NA_integer_
  )
}

#' Output column order
#'
#' cfbfastR-aligned. See `analysis/pbp_schema.md` for the data dictionary.
#' @keywords internal
pbp_columns <- c(
  "game_id", "season", "game_date", "week", "season_type",
  "home", "away", "play_index", "drive_number", "drive_play_number",
  "period", "half", "clock_start", "clock_end", "clock_upper", "clock_lower",
  "pos_team", "def_pos_team", "pos_team_score", "def_pos_team_score", "score_diff",
  "down", "distance", "yards_to_goal", "Goal_To_Go",
  "down_end", "distance_end", "yards_to_goal_end",
  "play_type", "scrimmage_play", "yards_gained",
  "rush", "pass", "completion", "sack", "int", "fumble_vec", "turnover", "downs_turnover",
  "touchdown", "safety",
  "field_goal_attempt", "field_goal_made", "punt",
  "scoring_play", "score_pts", "firstD_by_yards", "firstD_by_penalty",
  "penalty_flag", "penalty_yards_signed", "penalized_team", "penalty_no_play",
  "penalty_declined", "penalty_text",
  "drive_result", "situation", "play_text"
)

#' Possession on try-phase rows: the team that just scored
#'
#' A PAT / two-point try (and any penalty row between a score and the next
#' kickoff) belongs to the scoring team, which is about to kick. The scorer
#' is read off the first score line after the scoring play (after a safety,
#' the team that conceded kicks instead). This fixes the try after a
#' defensive touchdown, which otherwise inherits the team that was scored
#' on.
#'
#' @param kept Kept rows with `row`, `try_phase`, `play_type`, `play_text`,
#'   `penalty_no_play`, `pos_team`.
#' @param scores Output of [parse_score_rows()].
#' @param teams The two canonical team names.
#' @return Character vector: the corrected `pos_team`.
#' @keywords internal
try_phase_team <- function(kept, scores, teams) {
  scoring <- which(is_scoring_snap(kept))
  out <- kept$pos_team
  for (i in which(kept$try_phase)) {
    s <- scoring[scoring < i]
    if (!length(s)) next
    s <- s[length(s)]
    sr <- scores[scores$row > kept$row[s], ]
    if (!nrow(sr) || is.na(sr$scorer[1])) next
    safety <- stringr::str_detect(kept$play_text[s], stringr::regex("\\bsafety\\b", ignore_case = TRUE))
    out[i] <- if (safety) other_team(sr$scorer[1], teams) else sr$scorer[1]
  }
  out
}

#' Build one game's play-by-play table
#'
#' Works for any d3football game. Keeps the five event types (`play`,
#' `kickoff`, `extra_point`, `two_point`, `penalty_no_play`), after using
#' the dropped administrative rows to derive `period`, `pos_team`, the
#' kickoff teams, and the clock. `season`, `game_date`, `week` and
#' `season_type` come from the season index (see [build_season_index()]).
#' See `R/classify.R` and `R/parse_play_type.R` for the upstream row_type /
#' play_type classification this builds on.
#'
#' @param game_url Boxscore URL without the `?view=` suffix.
#' @param index Season index for the game's season. If NULL, the cached
#'   `data-raw/index/{season}.csv` is used when present (no network);
#'   otherwise a date-based week is used and logged (see [game_calendar()]).
#' @param season_dates Output of [read_season_dates()].
#' @return A tibble, one row per kept play, with the columns in
#'   `pbp_columns`. Attributes, for the validation reports and change log:
#'   `week_source` ("index" or "date fallback"), `kickoffs` (the
#'   per-kickoff possession decisions from [assign_kickoffs()]),
#'   `score_checks` (each score line vs the parsed points),
#'   `first_down_text` (the text-only first-down flags), and `next_snap`
#'   (row index of the next scrimmage snap in the half), `clock_discards`
#'   (stated clocks dropped as inconsistent), `footer_clock` (drive-footer
#'   elapsed time vs the clock anchors).
#' @export
build_pbp <- function(game_url, index = NULL, season_dates = read_season_dates()) {
  game <- fetch_game(game_url)
  if (is.null(index)) index <- load_cached_index(game$season)
  cal <- game_calendar(game, index, season_dates)

  classified <- classify_plays(game$plays)
  classified$row <- seq_len(nrow(classified))
  classified <- derive_quarter(classified)
  team_map <- build_team_map(classified, c(game$teams, unname(game$matchup)))
  teams <- sort(unique(unname(team_map)))
  classified <- derive_possession(classified, team_map)
  classified <- parse_play_type(classified)

  kept <- classified[classified$row_type %in% kept_row_types, ]
  kept$play_type <- ifelse(kept$row_type == "play", kept$play_type, kept$row_type)
  kept$play_text <- kept$play
  kept$pos_team <- kept$possession
  kept$period <- as.integer(kept$quarter)
  kept$half <- dplyr::case_when(kept$period %in% 1:2 ~ 1L, kept$period %in% 3:4 ~ 2L,
                                TRUE ~ NA_integer_)
  kept <- parse_situation(kept)
  own_side <- infer_own_side(kept)
  text_team <- infer_text_team(kept, own_side)
  kept$penalty_no_play <- is_no_play(kept$play_text)

  # kickoffs: pos_team is the receiving team
  scores <- parse_score_rows(classified, team_map, teams)
  kickoffs <- assign_kickoffs(classified, teams, team_map, own_side, text_team, scores)
  ko <- match(kickoffs$row, kept$row)
  kept$pos_team[ko] <- kickoffs$receiving_team
  kept$kicker_recovered <- FALSE
  kept$kicker_recovered[ko] <- kickoffs$kicker_recovered

  # tries belong to the scoring team
  kept$try_phase <- flag_try_phase(kept)
  kept$pos_team <- try_phase_team(kept, scores, teams)
  kept$def_pos_team <- other_team(kept$pos_team, teams)

  kept$yards_to_goal <- compute_yards_to_goal(kept, own_side)
  kept <- derive_goal_to_go(kept)
  kept <- parse_penalties(kept, text_team)
  kept$yards_gained <- parse_yards_gained(kept$play_text, kept$play_type, kept$penalty_no_play)
  kept <- parse_outcome_flags(kept, text_team)
  kept <- assign_drives(kept)

  # Tier 1 columns
  kept$scrimmage_play <- !is.na(kept$down)
  live <- !kept$penalty_no_play
  kept$field_goal_attempt <- kept$play_type %in% c("field_goal_good", "field_goal_missed", "field_goal_blocked") & live
  kept$field_goal_made <- kept$play_type == "field_goal_good" & live
  kept$punt <- kept$play_type %in% c("punt_no_return", "punt_with_return", "punt_blocked") & live
  kept$score_pts <- score_points(kept)
  kept$scoring_play <- kept$score_pts != 0L
  rs <- running_score(kept, scores, teams)
  kept$pos_team_score <- rs$pos_team_score
  kept$def_pos_team_score <- rs$def_pos_team_score
  kept$score_diff <- kept$pos_team_score - kept$def_pos_team_score
  nxt <- next_snap_index(kept)
  kept <- derive_end_state(kept, nxt)
  kept <- derive_first_downs(kept, nxt)
  kept$drive_result <- derive_drive_result(kept)
  clk <- derive_clock(classified, kept)
  kept <- clk$kept
  kept$home <- unname(team_map[game$matchup[["home"]]])
  kept$away <- unname(team_map[game$matchup[["away"]]])

  kept$game_id <- game$game_id
  kept$season <- cal$season
  kept$game_date <- cal$game_date
  kept$week <- cal$week
  kept$season_type <- cal$season_type
  kept$play_index <- seq_len(nrow(kept))

  out <- kept[, pbp_columns]
  attr(out, "week_source") <- cal$week_source
  kickoffs$play_index <- kept$play_index[ko]
  kickoffs$period <- kept$period[ko]
  kickoffs$game_id <- game$game_id
  attr(out, "kickoffs") <- kickoffs
  rs$checks$game_id <- game$game_id
  attr(out, "score_checks") <- rs$checks
  attr(out, "first_down_text") <- kept[, c("fd_yards_text", "fd_penalty_text")]
  attr(out, "next_snap") <- nxt
  clk$discarded$game_id <- rep(game$game_id, nrow(clk$discarded))
  clk$discarded$play_index <- kept$play_index[match(clk$discarded$row, kept$row)]
  attr(out, "clock_discards") <- clk$discarded
  attr(out, "footer_clock") <- footer_clock_check(classified, clk, kept, game$game_id)
  out
}

#' Read a cached season index without touching the network
#'
#' @param season Season year.
#' @param cache_dir Cache directory used by [build_season_index()].
#' @return The index, or NULL if no cache exists.
#' @keywords internal
load_cached_index <- function(season, cache_dir = "data-raw/index") {
  f <- file.path(cache_dir, paste0(season, ".csv"))
  if (is.na(season) || !file.exists(f)) return(NULL)
  utils::read.csv(f, na.strings = "", colClasses = c(game_id = "character"))
}

#' Build and write every game's play-by-play table
#'
#' Writes one CSV per game to `{out_dir}/{game_id}.csv`, a summary of
#' kept-row counts to `{out_dir}/../pbp_row_counts.csv`, and the validation
#' reports to `check_dir` (see [write_pbp_checks()]). Each game's season
#' index is loaded once per season, via [build_season_index()] (cached;
#' scraped only if no cache exists). Prints the per-game counts.
#'
#' @param game_urls Character vector of boxscore URLs (any teams, any
#'   seasons).
#' @param out_dir Directory to write per-game CSVs into.
#' @param check_dir Directory for the validation reports.
#' @return Invisibly, a named list of the per-game tibbles (by `game_id`).
#' @export
build_all_pbp <- function(game_urls, out_dir = "analysis/pbp", check_dir = "analysis/checks") {
  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

  seasons <- unique(stats::na.omit(extract_season(game_urls)))
  indexes <- lapply(seasons, build_season_index)
  names(indexes) <- seasons
  season_dates <- read_season_dates()

  games <- lapply(game_urls, function(u) {
    build_pbp(u, index = indexes[[as.character(extract_season(u))]], season_dates = season_dates)
  })

  counts <- dplyr::bind_rows(lapply(games, function(g) {
    tibble::tibble(game_id = g$game_id[1], season = g$season[1], game_date = g$game_date[1],
                   week = g$week[1], season_type = g$season_type[1],
                   away = g$away[1], home = g$home[1], n_rows = nrow(g),
                   week_source = attr(g, "week_source"))
  }))

  for (g in games) {
    utils::write.csv(g, file.path(out_dir, paste0(g$game_id[1], ".csv")), row.names = FALSE, na = "")
  }
  utils::write.csv(counts, file.path(out_dir, "..", "pbp_row_counts.csv"), row.names = FALSE, na = "")
  write_pbp_checks(games, check_dir)

  print(as.data.frame(counts))

  names(games) <- counts$game_id
  invisible(games)
}
