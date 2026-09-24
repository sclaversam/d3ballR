#' Derive the game-clock bracket for every row
#'
#' Must run on the FULL classified row set, before the kept-row filter,
#' because most rows that state a clock are the ones that get dropped:
#' quarter starts ("Start of 1st quarter, clock 15:00."), drive headers
#' ("Chicago at 15:00"), drive starts ("UChicago drive start at 15:00."),
#' timeouts ("Timeout ..., clock 04:12."). Some kept rows state one too
#' (scores and field goals: "... TOUCHDOWN, clock 10:10.").
#'
#' - `clock_known`: the clock this row states, as "MM:SS", else NA.
#' - `clock_prev_known`: the latest stated clock at or before this row.
#' - `clock_next_known`: the next stated clock at or after this row.
#'
#' Both fills stay within a quarter (the clock resets each quarter), so the
#' last plays of a quarter don't pick up the next quarter's 15:00. The
#' clock is never interpolated between anchors. It doesn't tick uniformly,
#' so the prev/next bracket is the honest representation. Drive-footer
#' "MM:SS elapsed" durations are not clock readings and are ignored. A
#' stated clock that contradicts its neighbors is dropped (see
#' [drop_out_of_order_clocks()]).
#'
#' @param classified A classified tibble, full row set, with `quarter`
#'   already added by [derive_quarter()].
#' @return `classified` with `clock_known`, `clock_prev_known`,
#'   `clock_next_known` (character) added.
#' @keywords internal
derive_clock <- function(classified) {
  txt <- classified$play
  stated <- dplyr::coalesce(
    stringr::str_match(txt, stringr::regex("\\bclock (\\d{1,2}:\\d{2})", ignore_case = TRUE))[, 2],
    stringr::str_match(txt, stringr::regex("drive start at (\\d{1,2}:\\d{2})", ignore_case = TRUE))[, 2],
    ifelse(classified$row_type == "drive_header",
           stringr::str_match(txt, " at (\\d{1,2}:\\d{2})$")[, 2], NA_character_)
  )
  # zero-pad "8:12" -> "08:12"
  stated <- ifelse(is.na(stated), NA_character_, stringr::str_pad(stated, 5, pad = "0"))
  stated <- drop_out_of_order_clocks(stated, classified$quarter)

  classified$clock_known <- stated
  classified$clock_prev_known <- stated
  classified$clock_next_known <- stated
  classified <- dplyr::group_by(classified, .data$quarter)
  classified <- tidyr::fill(classified, "clock_prev_known", .direction = "down")
  classified <- tidyr::fill(classified, "clock_next_known", .direction = "up")
  dplyr::ungroup(classified)
}

#' Drop a stated clock that contradicts the anchors on either side of it
#'
#' Within a quarter the clock only runs down, so each stated clock should
#' sit between the previous anchor (more time left) and the next one (less
#' time left). If the neighbors are in order with each other but this
#' anchor falls outside them, it's a bad reading and is set to NA. The case
#' that motivated this: game 1 play 135, a TD nullified by penalty, prints
#' "clock 00:00" mid-4th-quarter (prev anchor 12:43, next 08:00). One pass,
#' neighbors only. It doesn't try to untangle runs of several bad readings.
#'
#' @param stated Character vector of "MM:SS" or NA.
#' @param quarter Quarter of each row.
#' @return `stated` with contradicting readings set to NA.
#' @keywords internal
drop_out_of_order_clocks <- function(stated, quarter) {
  secs <- function(x) {
    m <- stringr::str_match(x, "^(\\d{2}):(\\d{2})$")
    as.integer(m[, 2]) * 60L + as.integer(m[, 3])
  }
  k <- which(!is.na(stated))
  if (length(k) < 3) return(stated)
  s <- secs(stated[k])
  q <- quarter[k]
  bad <- logical(length(k))
  for (j in 2:(length(k) - 1)) {
    if (q[j - 1] != q[j] || q[j + 1] != q[j]) next
    prev <- s[j - 1]
    nxt <- s[j + 1]
    bad[j] <- prev >= nxt && (s[j] > prev || s[j] < nxt)
  }
  stated[k[bad]] <- NA_character_
  stated
}
