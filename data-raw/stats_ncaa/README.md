# stats.ncaa.org pages saved by hand

stats.ncaa.org blocks scripts, so for the games ncaa.com can't give (no
play-by-play, or a file that can't be built) the game's "Play By Play"
page is saved from a browser (Cmd+S, "Webpage, HTML only") into this
folder. Any file name works (stats.ncaa.org's own contest id is fine):
`stats_ncaa_files()` matches each page to its game by date and teams.
Which games: `data-raw/ncaa/{season}_stats_ncaa_candidates.csv`, rows with
`pull_from_stats_ncaa` TRUE. Other saved pages are ignored.
