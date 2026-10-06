#' Convert "MM:SS" to seconds remaining
#' @param x Character vector.
#' @keywords internal
clock_secs <- function(x) {
  m <- stringr::str_match(x, "^(\\d{1,2}):(\\d{2})$")
  as.integer(m[, 2]) * 60L + as.integer(m[, 3])
}

#' Format seconds remaining as zero-padded "MM:SS"
#' @param s Integer vector.
#' @keywords internal
fmt_clock <- function(s) {
  ifelse(is.na(s), NA_character_, sprintf("%02d:%02d", s %/% 60L, s %% 60L))
}

#' Every clock reading d3 states, as positioned anchors
#'
#' Readings come from "clock M:SS" anywhere in a row (timeouts, quarter
#' starts, bare clock rows, spot corrections, end-of-half rows, and kept
#' plays: scores, field goals, some kickoffs), "drive start at M:SS", and
#' drive headers "TEAM at M:SS". A reading on a kept play row is the clock
#' when that play ENDED, so it is placed just after the row (`pos = row +
#' 0.5`); every other reading is a moment between plays (`pos = row`).
#'
#' Some stat crews also print a clock at the start of each play's text
#' ("(11:25) Shotgun ..."). Checked against the other readings, it always
#' falls between the play's snap and its end (often equal to the snap,
#' sometimes a few seconds later), so it is placed between them (`pos = row +
#' 0.25`, kind "printed") and used as a bound: a minimum for that snap and a
#' maximum for every later one.
#'
#' @param full Classified rows with `row`, `row_type`, `play`, `quarter`.
#' @return Data frame: `row`, `pos`, `quarter`, `secs`, `kind` ("end" for
#'   a kept play's own reading, "printed" for a per-play printed clock, else
#'   the source row_type).
#' @keywords internal
stated_clock_anchors <- function(full) {
  txt <- full$play
  val <- dplyr::coalesce(
    stringr::str_match(txt, stringr::regex("\\bclock (\\d{1,2}:\\d{2})", ignore_case = TRUE))[, 2],
    stringr::str_match(txt, stringr::regex("drive start at (\\d{1,2}:\\d{2})", ignore_case = TRUE))[, 2],
    ifelse(full$row_type == "drive_header", stringr::str_match(txt, " at (\\d{1,2}:\\d{2})$")[, 2], NA_character_)
  )
  r <- which(!is.na(val))
  kept <- full$row_type[r] %in% kept_row_types
  stated <- data.frame(
    row = full$row[r], pos = full$row[r] + ifelse(kept, 0.5, 0), quarter = full$quarter_num[r],
    secs = clock_secs(val[r]), kind = ifelse(kept, "end", full$row_type[r]),
    text = txt[r]
  )
  # per-play printed clocks "(MM:SS) ..." (some stat crews log one with every
  # play): a time between the play's snap and its end, so placed between
  # them (pos = row + 0.25)
  pre <- stringr::str_match(txt, "^\\((\\d{1,2}:\\d{2})\\)")[, 2]
  rp <- which(!is.na(pre) & full$row_type %in% kept_row_types)
  printed <- data.frame(
    row = full$row[rp], pos = full$row[rp] + 0.25, quarter = full$quarter_num[rp],
    secs = clock_secs(pre[rp]), kind = rep("printed", length(rp)), text = txt[rp]
  )
  rbind(stated, printed)
}

#' Keep the largest set of clock readings consistent with a running clock
#'
#' Within a quarter the clock only runs down, so the readings in game order
#' should never go up. Some printed readings are wrong (game 1 play 135, a
#' nullified TD printed "clock 00:00" mid-4th; the Berry game prints
#' "clock 15:00" twice right before "End of half, clock 00:00"). Per
#' quarter, this keeps the non-increasing subsequence of readings with the
#' most weight (15:00 / 00:00 pinned at the quarter's start / end; an
#' official reading counts 5, a per-play printed clock 1) and discards the
#' rest. It removes as little as possible, which a neighbor-only check can't
#' do when two bad readings sit next to each other, and prefers dropping a
#' printed clock over an official reading.
#'
#' @param anchors Output of [stated_clock_anchors()].
#' @return `anchors` with a logical `keep` column.
#' @keywords internal
clean_clock_anchors <- function(anchors) {
  anchors <- anchors[order(anchors$pos), ]
  anchors$keep <- TRUE
  for (q in unique(anchors$quarter)) {
    i <- which(anchors$quarter == q)
    s <- c(900L, anchors$secs[i], 0L)
    # official readings (drive starts, timeouts, scores, ...) outweigh the
    # per-play printed clocks, which are scorer-entered and sometimes typos
    w <- c(1e6, ifelse(anchors$kind[i] == "printed", 1, 5), 1e6)
    n <- length(s)
    best <- w
    prev <- rep(NA_integer_, n)
    for (j in seq_len(n)[-1]) {
      for (k in seq_len(j - 1)) {
        if (s[k] >= s[j] && best[k] + w[j] > best[j]) {
          best[j] <- best[k] + w[j]
          prev[j] <- k
        }
      }
    }
    # walk back from the pinned 00:00 end
    on <- logical(n)
    j <- n
    while (!is.na(j)) {
      on[j] <- TRUE
      j <- prev[j]
    }
    anchors$keep[i] <- on[2:(n - 1)]
  }
  anchors
}

#' Derive the four clock columns
#'
#' Runs on the FULL classified row set (most clock readings are on rows that
#' get dropped) together with the kept rows.
#'
#' **`clock_start`** (exact clock at the snap, else NA). The clock is
#' stopped at a known reading and restarts on the next snap after: a
#' quarter start (15:00), a timeout, the start of a drive (the drive
#' header / start row that opens a possession), or a score (its stated
#' clock, for the try and the kickoff that follow). The row that snaps next
#' gets that reading, and so does any untimed row before it (a dead-ball
#' penalty with no snap, a PAT, a two-point try). Covers: first snap of a
#' drive = drive start time; snap after a timeout = timeout clock; first
#' play of a quarter = 15:00 (so the opening and second-half kickoffs);
#' PAT / two-point / kickoff after a score = the score's clock.
#'
#' **`clock_end`** (exact clock when the play ended, else NA): the play's
#' own stated clock (scores, field goals, some kickoffs), else, for a play
#' that hands the ball over (punt, turnover, downs, missed / blocked field
#' goal, kickoff), the next drive's start time if that is in the same
#' quarter (a hand-over that ends a quarter is left NA).
#'
#' **`clock_start_max` / `clock_start_min`** (always filled in regulation):
#' the range the snap clock must lie in: the latest known reading at or
#' before the snap (most time it could be) and the earliest at or after it
#' (least time), within the quarter, with 15:00 at the quarter's start and
#' 00:00 at its end. Readings include the per-play printed clocks. A play's
#' own printed clock and `clock_end` are after its snap, so they can be its
#' `clock_start_min` but never its `clock_start_max`. When the two meet,
#' `clock_start` is set to that value; when `clock_start` is known, all three
#' are equal. Never interpolated.
#'
#' **`secs_remaining_start` / `_end` / `_start_max` / `_start_min`**: the
#' same four as integer seconds remaining in the game (regulation):
#' `(4 - period) * 900 + quarter clock seconds`.
#'
#' Overtime (period 5+) is untimed in college football, so all four columns
#' are NA there.
#'
#' @param full Classified rows with `row`, `row_type`, `play`, `quarter`.
#' @param kept Kept rows with `row`, `period`, `play_type`, `try_phase`,
#'   `penalty_no_play`, `touchdown`, `turnover`, `downs_turnover`,
#'   `field_goal_made`, `safety`.
#' @return A list: `kept` with `clock_start`, `clock_end`,
#'   `clock_start_max`, `clock_start_min` ("MM:SS") and the four
#'   `secs_remaining_*` (integer), and `discarded` (readings dropped as
#'   inconsistent).
#' @keywords internal
derive_clock <- function(full, kept) {
  full$quarter_num <- dplyr::coalesce(as.integer(full$quarter), 1L)
  anchors <- clean_clock_anchors(stated_clock_anchors(full))
  discarded <- anchors[!anchors$keep, ]
  good <- anchors[anchors$keep, ]

  # timed rows: snaps (including nullified ones) and kickoffs
  pt <- kept$play_type
  timed <- (pt %in% play_type_categories | pt == "kickoff") & !kept$try_phase
  scoring <- kept$touchdown | kept$field_goal_made | kept$safety

  # drive-opening markers: a header/start row with no snap since the last
  # drive footer or kickoff (restatements mid-drive are bounds only)
  rt <- full$row_type
  marker <- which(rt %in% c("drive_header", "drive_start"))
  opening <- vapply(marker, function(m) {
    back <- which(rt[seq_len(m - 1)] %in% c("drive_footer", "kickoff"))
    from <- if (length(back)) back[length(back)] else 0L
    !any(rt[seq_len(m - 1)][seq_along(rt[seq_len(m - 1)]) > from] == "play")
  }, logical(1))
  opening_rows <- marker[opening]

  # stop anchors: clock stopped at a known reading until the next snap
  qstart <- tapply(full$row, full$quarter_num, min)
  stops <- rbind(
    data.frame(pos = as.numeric(qstart) - 0.5, quarter = as.integer(names(qstart)), secs = 900L),
    good[good$kind == "timeout" | (good$kind %in% c("drive_header", "drive_start") & good$row %in% opening_rows),
         c("pos", "quarter", "secs")],
    good[good$kind == "end" & good$row %in% kept$row[scoring], c("pos", "quarter", "secs")]
  )
  stops <- stops[order(stops$pos), ]

  n <- nrow(kept)
  start <- rep(NA_integer_, n)
  last_timed_pos <- 0
  for (i in seq_len(n)) {
    p <- kept$row[i]
    w <- stops[stops$pos > last_timed_pos & stops$pos < p, ]
    if (nrow(w)) start[i] <- w$secs[nrow(w)]
    if (timed[i]) last_timed_pos <- p + 0.25  # this snap's own end reading (p + 0.5) counts for later rows
  }

  # clock_end: own reading, else next drive start after a change of possession
  end <- rep(NA_integer_, n)
  own <- good[good$kind == "end", ]
  end[match(own$row, kept$row)] <- own$secs
  hand_over <- (pt %in% c("punt_no_return", "punt_with_return", "punt_blocked",
                          "field_goal_missed", "field_goal_blocked", "kickoff") |
                  kept$turnover | kept$downs_turnover) & !kept$penalty_no_play & !scoring
  next_timed <- vapply(seq_len(n), function(i) {
    j <- which(timed & seq_len(n) > i)
    if (length(j)) kept$row[j[1]] else Inf
  }, numeric(1))
  open_good <- good[good$row %in% opening_rows, ]
  for (i in which(hand_over & is.na(end))) {
    # same quarter only: a hand-over on the last play of a quarter is followed
    # by the next quarter's 15:00 drive start, which is not this play's end
    o <- open_good[open_good$pos > kept$row[i] & open_good$pos < next_timed[i] &
                     open_good$quarter == kept$period[i], ]
    if (nrow(o)) end[i] <- o$secs[1]
  }

  # bounds from every known reading in the quarter
  qend <- tapply(full$row, full$quarter_num, max)
  pts <- rbind(
    data.frame(pos = as.numeric(qstart) - 0.5, quarter = as.integer(names(qstart)), secs = 900L),
    data.frame(pos = as.numeric(qend) + 0.9, quarter = as.integer(names(qend)), secs = 0L),
    good[, c("pos", "quarter", "secs")],
    data.frame(pos = kept$row, quarter = kept$period, secs = start)[!is.na(start), ],
    data.frame(pos = kept$row + 0.5, quarter = kept$period, secs = end)[!is.na(end), ]
  )
  pts <- pts[order(pts$pos), ]
  upper <- lower <- integer(n)
  for (i in seq_len(n)) {
    q <- pts[pts$quarter == kept$period[i], ]
    if (!nrow(q)) next
    before <- q[q$pos <= kept$row[i], ]
    after <- q[q$pos >= kept$row[i], ]
    upper[i] <- before$secs[nrow(before)]
    lower[i] <- after$secs[1]
  }
  # when the bounds meet, the snap clock is known exactly
  pinned <- is.na(start) & upper == lower
  start[pinned] <- upper[pinned]

  # college overtime is untimed: no game clock in periods 5+
  ot <- kept$period > 4L
  pinned[ot] <- FALSE
  start[ot] <- NA
  end[ot] <- NA
  upper[ot] <- NA
  lower[ot] <- NA
  kept$clock_start <- fmt_clock(start)
  kept$clock_end <- fmt_clock(end)
  kept$clock_start_max <- fmt_clock(upper)
  kept$clock_start_min <- fmt_clock(lower)
  # the same four as seconds remaining in the game (regulation): later
  # quarters' full 15:00 plus the quarter clock
  game_secs <- function(x) ifelse(is.na(x), NA_integer_, (4L - kept$period) * 900L + x)
  kept$secs_remaining_start <- game_secs(start)
  kept$secs_remaining_end <- game_secs(end)
  kept$secs_remaining_start_max <- game_secs(upper)
  kept$secs_remaining_start_min <- game_secs(lower)
  discarded$value <- fmt_clock(discarded$secs)
  list(kept = kept, discarded = discarded[, c("row", "quarter", "value", "kind", "text")],
       anchors = good, opening_rows = opening_rows)
}
