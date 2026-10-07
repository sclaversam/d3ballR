#' Extract the boxscore game id from a game URL
#'
#' @param game_url Boxscore URL, e.g.
#'   "https://www.d3football.com/seasons/2025/boxscores/20250906_e064.xml".
#' @return Character scalar, e.g. "20250906_e064".
#' @keywords internal
extract_game_id <- function(game_url) {
  stringr::str_match(game_url, "boxscores/([^./]+)\\.xml")[, 2]
}

#' Is this table the line score?
#'
#' A table with at least 2 rows and either a "Final" column or a first
#' column headed "Scoring" (a game stopped early has no "Final" column).
#'
#' @param t A data frame.
#' @return TRUE / FALSE.
#' @keywords internal
is_line_score <- function(t) {
  nrow(t) >= 2 && ("Final" %in% colnames(t) || identical(colnames(t)[1], "Scoring"))
}

#' Read the two team names off a boxscore's line-score table
#'
#' Located by content (see [is_line_score()]),
#' not by position, same philosophy as [find_plays()]. Each of the first two
#' rows is "TEAM NAME (W-L, conf)" or "TEAM NAME (W-L)"; the trailing
#' parenthetical record is stripped.
#'
#' @param tbls A list of data frames (from [tables_on()]).
#' @return A character vector of length 2: the two team names.
#' @keywords internal
find_line_score_teams <- function(tbls) {
  for (t in tbls) {
    if (is_line_score(t)) {
      raw <- stringr::str_squish(as.character(t[[1]][1:2]))
      return(stringr::str_remove(raw, "\\s*\\([^)]*\\)\\s*$"))
    }
  }
  stop("No line-score table found. Open the page and check the layout.")
}

#' Read the two final scores off a boxscore's line-score table
#'
#' Same table as [find_line_score_teams()]; the "Final" column. A game
#' stopped early has no "Final" column: its last column is the score when
#' play stopped ("3rd QTR - 04:19" in Case Western Reserve at Rowan, 2025).
#'
#' @param tbls A list of data frames (from [tables_on()]).
#' @return Integer vector of length 2, named by the line-score team names.
#' @keywords internal
find_line_score_finals <- function(tbls) {
  for (t in tbls) {
    if (is_line_score(t)) {
      raw <- stringr::str_squish(as.character(t[[1]][1:2]))
      nm <- stringr::str_remove(raw, "\\s*\\([^)]*\\)\\s*$")
      final <- if ("Final" %in% colnames(t)) t[["Final"]] else t[[ncol(t)]]
      return(stats::setNames(suppressWarnings(as.integer(final[1:2])), nm))
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
#'   (both line-score names), `finals` (line-score final scores, named by
#'   team), `matchup` (`c(away, home)`, header spelling),
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
    finals      = find_line_score_finals(tbls),
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
#' @return A list: `index_home`, `index_away` (scoreboard spelling, else the
#'   boxscore header's), `season`, `game_date`, `week`, `season_type`,
#'   `week_source` ("index" or "date fallback").
#' @keywords internal
game_calendar <- function(game, index, season_dates) {
  hit <- if (!is.null(index)) index[!is.na(index$game_id) & index$game_id == game$game_id, ] else NULL
  if (!is.null(hit) && nrow(hit) == 1) {
    return(list(index_home = hit$home, index_away = hit$away,
                season = as.integer(hit$season), game_date = as.character(hit$game_date),
                week = as.integer(hit$week), season_type = hit$season_type, week_source = "index"))
  }
  d <- dplyr::coalesce(as.Date(substr(game$game_id, 1, 8), format = "%Y%m%d"), game$header_date)
  st <- classify_season_type(d, game$season, season_dates)
  wk <- date_based_week(d, game$season, st, season_dates)
  message("Game ", game$game_id, " not found in the ", game$season,
          " season index; using a date-based week (", wk, ", ", st, ").")
  list(index_home = unname(game$matchup[["home"]]), index_away = unname(game$matchup[["away"]]),
       season = game$season, game_date = format(d, "%Y-%m-%d"), week = wk,
       season_type = st, week_source = "date fallback")
}

#' Forward-fill quarter from quarter-marker rows
#'
#' Reads the quarter number off two row shapes typed `quarter` by
#' [classify_plays()]: the bare "1st"/"2nd"/"3rd"/"4th" marker, and
#' "Start of Nth quarter, clock M:SS, ...." Overtime markers ("OT",
#' "Start of OT quarter", "2OT") give periods 5, 6, ... "End of half"/"End of game"
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
  # overtime: "OT" / "2OT" marker rows and "Start of OT quarter" / "Start of
  # 2OT ..." -> period 5, 6, ...
  ot <- stringr::str_match(classified$play, stringr::regex("^(?:Start of )?(\\d?)OT\\b", ignore_case = TRUE))
  ot_period <- ifelse(is.na(ot[, 1]), NA_character_,
                      as.character(4L + ifelse(ot[, 2] == "", 1L, suppressWarnings(as.integer(ot[, 2])))))
  quarter_here <- dplyr::coalesce(bare, started, ot_period)
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
  possession_here <- ifelse(classified$row_type %in% c("drive_header", "drive_start"),
                            drive_row_team(classified$play), NA_character_)
  classified$possession <- unname(team_map[possession_here])
  tidyr::fill(classified, "possession", .direction = "down")
}

#' Event types kept in the play-by-play table
#' @keywords internal
kept_row_types <- c("play", "kickoff", "extra_point", "two_point", "penalty_no_play")

#' Down/distance/yardline pattern for a real situation line
#'
#' e.g. "1st and 10 at CMU35" or "1st and Goal at CMU06" or "4th and 3 at UC 25".
#' The team code can contain periods and a space ("MASS. MA27": the code is
#' "MASS. MA"). The yardline's team-letters group is optional so a bare midfield number
#' ("at 50") still parses down/distance/yard_num, with `yard_side` NA. A
#' negative distance (d3 printed "4th and -2" once in 2025) is kept as
#' printed rather than dropping the down.
#' @keywords internal
situation_pattern <- "^([1-4])(?:st|nd|rd|th)\\s+and\\s+(Goal|-?\\d+)\\s+at\\s+([A-Za-z&.' ]*?)\\s*(\\d+)$"

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
#' `docs/schema.md` (Key conventions)). Only the text BEFORE the
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
#' cfbfastR-aligned. See `docs/schema.md` for the data dictionary.
#' @keywords internal
pbp_columns <- c(
  "game_id", "season", "game_date", "week", "season_type", "home", "away",
  "home_team_conference", "away_team_conference", "conference_game", "play_index",
  "drive_number", "drive_play_number", "period", "half", "clock_start", "clock_end",
  "clock_start_max", "clock_start_min", "secs_remaining_start", "secs_remaining_end",
  "secs_remaining_start_max", "secs_remaining_start_min", "pos_team", "def_pos_team",
  "pos_team_score", "def_pos_team_score", "score_diff", "down", "distance",
  "yards_to_goal", "Goal_To_Go", "down_end", "distance_end", "yards_to_goal_end",
  "play_type", "scrimmage_play", "yards_gained", "rush", "pass", "completion", "sack",
  "int", "fumble_vec", "turnover", "downs_turnover", "touchdown", "safety",
  "field_goal_attempt", "field_goal_made", "punt", "scoring_play", "score_pts",
  "drive_result", "firstD_by_kickoff", "firstD_by_poss", "firstD_by_yards",
  "firstD_by_penalty", "new_series", "penalty_flag", "penalty_yards_signed",
  "penalized_team", "penalty_no_play", "penalty_declined", "penalty_text", "situation",
  "play_text"
)

#' Possession on try-phase rows: the team that just scored
#'
#' A PAT / two-point try (and any penalty row between a score and the next
#' kickoff) belongs to the scoring team, which is about to kick. For the
#' extra point / two-point try itself, the player named on it (kicker,
#' passer, rusher) decides when their team is known ([build_actor_map()]).
#' Otherwise the scorer is the team that kicks off next in the same half (its teams come from the
#' next drive header); if no kickoff follows (end of half, overtime), the
#' first score line after the scoring play (after a safety, the team that
#' conceded), else the scoring play's own offense. Score lines are not the
#' first choice because d3 sometimes skips one and the rest lag a score
#' behind (Dean at Fitchburg State, 2025). This fixes the try after a
#' defensive touchdown, which otherwise inherits the team that was scored
#' on.
#'
#' @param kept Kept rows with `row`, `try_phase`, `play_type`, `play_text`,
#'   `penalty_no_play`, `pos_team`.
#' @param scores Output of [parse_score_rows()].
#' @param teams The two canonical team names.
#' @param kickoffs Output of [assign_kickoffs()] (refined by the kicker).
#' @param actor_map Output of [build_actor_map()].
#' @return Character vector: the corrected `pos_team`.
#' @keywords internal
try_phase_team <- function(kept, scores, teams, kickoffs = NULL, actor_map = character()) {
  scoring <- which(is_scoring_snap(kept))
  out <- kept$pos_team
  actor_team <- unname(actor_map[play_actor(kept$play_text)])
  for (i in which(kept$try_phase)) {
    s <- scoring[scoring < i]
    if (!length(s)) next
    s <- s[length(s)]
    # 0. the kicker / passer / rusher named on the try is on the scoring team
    if (kept$play_type[i] %in% c("extra_point", "two_point") && !is.na(actor_team[i])) {
      out[i] <- actor_team[i]
      next
    }
    # 1. the team that kicks off next in the same half scored (or conceded a
    #    safety). Kickoff teams come from the next drive header, which is
    #    reliable; d3's score lines sometimes lag a score behind.
    k <- if (!is.null(kickoffs)) kickoffs[kickoffs$row > kept$row[i] & kickoffs$half == kept$half[i], ] else NULL
    if (!is.null(k) && nrow(k) && !is.na(k$kicking_team[1])) {
      out[i] <- k$kicking_team[1]
      next
    }
    # 2. no kickoff follows (end of half, overtime): the next score line
    sr <- scores[scores$row > kept$row[s], ]
    safety <- stringr::str_detect(kept$play_text[s], stringr::regex("\\bsafety\\b", ignore_case = TRUE))
    if (nrow(sr) && !is.na(sr$scorer[1])) {
      out[i] <- if (safety) other_team(sr$scorer[1], teams) else sr$scorer[1]
    } else {
      # 3. the scoring play's own offense
      out[i] <- kept$pos_team[s]
    }
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
#' @param season_dates Season-dates table; if NULL, [ensure_season_dates()]
#'   for the game's season (adds it from Wikipedia if missing).
#' @param conf Conference data from [build_conference_table()]; if NULL, the
#'   cached `data-raw/conferences/{season}*.csv` files are used when present
#'   (no network), else the conference columns are NA.
#' @return A tibble, one row per kept play, with the columns in
#'   `pbp_columns`. Attributes, for the validation reports and change log:
#'   `week_source` ("index" or "date fallback"), `unclassified` (rows the
#'   classifier put in its unknown `other` bucket; should be NULL),
#'   `shared_conference` (both
#'   teams in one conference; for the cross-check), `finals` (line-score
#'   final scores by canonical team name), `kickoffs` (the
#'   per-kickoff possession decisions from [assign_kickoffs()]),
#'   `score_checks` (each score line vs the parsed points),
#'   `first_down_text` (the text-only first-down flags), and `next_snap`
#'   (row index of the next scrimmage snap in the half), `clock_discards`
#'   (stated clocks dropped as inconsistent), `footer_clock` (drive-footer
#'   elapsed time vs the clock anchors).
#' @export
build_pbp <- function(game_url, index = NULL, season_dates = NULL, conf = NULL) {
  game <- fetch_game(game_url)
  if (is.null(index)) index <- load_cached_index(game$season)
  if (is.null(season_dates)) season_dates <- ensure_season_dates(game$season)
  cal <- game_calendar(game, index, season_dates)
  if (is.null(conf)) conf <- load_cached_conferences(game$season)
  gc <- game_conferences(game$game_id, cal$index_home, cal$index_away, conf)

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
  kept$half <- dplyr::case_when(kept$period %in% 1:2 ~ 1L, kept$period >= 3L ~ 2L,  # OT is in half 2
                                TRUE ~ NA_integer_)
  kept <- parse_situation(kept)
  own_side <- infer_own_side(kept)
  text_team <- infer_text_team(kept, own_side)
  kept$penalty_no_play <- is_no_play(kept$play_text)

  # kickoffs: pos_team is the receiving team
  scores <- parse_score_rows(classified, team_map, teams)
  kickoffs <- assign_kickoffs(classified, teams, team_map, own_side, text_team, scores)
  actor_map <- build_actor_map(kept, kickoffs)
  kickoffs <- refine_kickoffs_by_kicker(kickoffs, kept, actor_map, teams)
  ko <- match(kickoffs$row, kept$row)
  kept$pos_team[ko] <- kickoffs$receiving_team
  kept$kicker_recovered <- FALSE
  kept$kicker_recovered[ko] <- kickoffs$kicker_recovered

  # tries belong to the scoring team
  kept$try_phase <- flag_try_phase(kept)
  kept$pos_team <- try_phase_team(kept, scores, teams, kickoffs, actor_map)
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
  kept <- derive_series_flags(kept, nxt)
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
  kept$home_team_conference <- gc$home_team_conference
  kept$away_team_conference <- gc$away_team_conference
  kept$conference_game <- gc$conference_game
  kept$play_index <- seq_len(nrow(kept))

  # Team names: within a game every spelling was mapped to one name (the
  # drive-start spelling), but stat crews spell teams differently from game
  # to game ("Ursinus", "URSINUS", "URSINUS COLLEGE"). The season index
  # (scoreboard) spells each team one way all season, so output uses that.
  to_index <- stats::setNames(c(cal$index_home, cal$index_away), c(kept$home[1], kept$away[1]))
  rename <- function(x) {
    ifelse(is.na(x), NA_character_, vapply(strsplit(x, "; ", fixed = TRUE), function(p) {
      m <- unname(to_index[p])
      paste(ifelse(is.na(m), p, m), collapse = "; ")
    }, character(1)))
  }
  for (col in c("home", "away", "pos_team", "def_pos_team", "penalized_team")) kept[[col]] <- rename(kept[[col]])
  for (col in c("kicking_team", "receiving_team", "header_team", "context_kicker", "recovered_by")) {
    kickoffs[[col]] <- rename(kickoffs[[col]])
  }
  finals <- game$finals
  names(finals) <- rename(unname(team_map[names(finals)]))

  out <- kept[, pbp_columns]
  attr(out, "week_source") <- cal$week_source
  unk <- classified[classified$row_type == "other", c("situation", "play")]
  attr(out, "unclassified") <- if (nrow(unk)) data.frame(game_id = game$game_id, situation = unk$situation, play = unk$play) else NULL
  attr(out, "shared_conference") <- gc$shared_conference
  attr(out, "finals") <- finals
  kickoffs$play_index <- kept$play_index[ko]
  kickoffs$period <- kept$period[ko]
  kickoffs$game_id <- game$game_id
  attr(out, "kickoffs") <- kickoffs
  rs$checks$game_id <- game$game_id
  attr(out, "score_checks") <- rs$checks
  attr(out, "first_down_text") <- kept[, c("fd_yards_text", "fd_penalty_text")]
  attr(out, "next_snap") <- nxt
  attr(out, "series_detail") <- data.frame(
    series_causes = kept$series_causes,
    cause_play_index = kept$play_index[kept$series_cause_row],
    try_phase = kept$try_phase
  )
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

#' Read cached conference data without touching the network
#'
#' @param season Season year.
#' @param cache_dir Directory used by [build_conference_table()].
#' @return A list (`table`, `markers`) or NULL.
#' @keywords internal
load_cached_conferences <- function(season, cache_dir = "data-raw/conferences") {
  tf <- file.path(cache_dir, paste0(season, ".csv"))
  mf <- file.path(cache_dir, paste0(season, "_schedule_markers.csv"))
  if (is.na(season) || !file.exists(tf)) return(NULL)
  list(table = utils::read.csv(tf, na.strings = ""),
       markers = if (file.exists(mf)) utils::read.csv(mf, na.strings = "", colClasses = c(game_id = "character")) else NULL)
}

#' Points each team scored in a built game, from `score_pts`
#'
#' `score_pts` is from `pos_team`'s view: positive points went to
#' `pos_team`, negative points (a defensive TD, a safety) to
#' `def_pos_team`.
#'
#' @param g One game's tibble from [build_pbp()].
#' @param team Canonical team name.
#' @return Integer.
#' @export
team_points <- function(g, team) {
  as.integer(sum(g$score_pts[g$score_pts > 0 & g$pos_team == team]) +
               sum(-g$score_pts[g$score_pts < 0 & g$def_pos_team == team]))
}

#' Build and write every game's play-by-play table
#'
#' Usually called by [build_season()]. Writes one CSV per game to
#' `{out_dir}/{game_id}.csv`, a per-game summary to
#' `{check_dir}/pbp_row_counts.csv` (row count, boxscore final score,
#' parsed points per team, `score_reconciled`), and the validation reports
#' to `check_dir` (see [write_pbp_checks()]), plus `score_reconciliation.csv`
#' and `build_failures.csv`. A game that fails to build is logged in
#' `build_failures.csv` and skipped, so one bad page doesn't stop the batch. Each game's season
#' index is loaded once per season, via [build_season_index()] (cached;
#' scraped only if no cache exists). Prints the per-game counts.
#'
#' @param game_urls Character vector of boxscore URLs (any teams, any
#'   seasons).
#' @param out_dir Directory to write per-game CSVs into.
#' @param check_dir Directory for the validation reports.
#' @param conf Conference data from [build_conference_table()] (else the
#'   cached files are used).
#' @return Invisibly, a named list of the per-game tibbles (by `game_id`).
#' @export
build_all_pbp <- function(game_urls, out_dir, check_dir, conf = NULL) {
  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

  seasons <- unique(stats::na.omit(extract_season(game_urls)))
  indexes <- lapply(seasons, build_season_index)
  names(indexes) <- seasons
  season_dates <- ensure_season_dates(seasons)

  failures <- list()
  games <- lapply(game_urls, function(u) {
    tryCatch(
      build_pbp(u, index = indexes[[as.character(extract_season(u))]], season_dates = season_dates, conf = conf),
      error = function(e) {
        failures[[length(failures) + 1]] <<- data.frame(game_url = u, error = conditionMessage(e))
        message("FAILED ", u, ": ", conditionMessage(e))
        NULL
      }
    )
  })
  games <- Filter(Negate(is.null), games)

  counts <- dplyr::bind_rows(lapply(games, function(g) {
    f <- attr(g, "finals")
    home <- g$home[1]
    away <- g$away[1]
    tibble::tibble(game_id = g$game_id[1], season = g$season[1], game_date = g$game_date[1],
                   week = g$week[1], season_type = g$season_type[1],
                   away = away, home = home, n_rows = nrow(g),
                   away_final = unname(f[away]), home_final = unname(f[home]),
                   away_pts_parsed = team_points(g, away), home_pts_parsed = team_points(g, home),
                   week_source = attr(g, "week_source"))
  }))
  counts$score_reconciled <- counts$away_final == counts$away_pts_parsed &
    counts$home_final == counts$home_pts_parsed

  for (g in games) {
    utils::write.csv(g, file.path(out_dir, paste0(g$game_id[1], ".csv")), row.names = FALSE, na = "")
  }
  dir.create(check_dir, showWarnings = FALSE, recursive = TRUE)
  utils::write.csv(counts, file.path(check_dir, "pbp_row_counts.csv"), row.names = FALSE, na = "")
  write_pbp_checks(games, check_dir)
  dir.create(check_dir, showWarnings = FALSE, recursive = TRUE)
  utils::write.csv(do.call(rbind, c(list(data.frame(game_url = character(), error = character())), failures)),
                   file.path(check_dir, "build_failures.csv"), row.names = FALSE, na = "")
  utils::write.csv(counts[, c("game_id", "game_date", "away", "home", "away_final", "home_final",
                              "away_pts_parsed", "home_pts_parsed", "score_reconciled")],
                   file.path(check_dir, "score_reconciliation.csv"), row.names = FALSE, na = "")

  message(nrow(counts), " games built (", sum(counts$score_reconciled), " reconcile with the boxscore final); ",
          length(failures), " not built")

  names(games) <- counts$game_id
  invisible(games)
}
