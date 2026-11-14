# Changelog

All notable changes to this project are documented here. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Earlier
history is in `git log`.

## [Unreleased]

### Added

- Karaoke mode (K, the mic in the player bar, the Karaoke button on the
  lyrics page, or the mic in the mini card's lyrics tab): the song fills the
  window, the line being sung fills with the cover colour across its timing,
  the next line is already shown, and a count-in runs before the first line
  and through long breaks. Lyric match, language, timing and "try another"
  stay on screen.
- Timed lyrics in the bar run as one continuous strip (title, every line,
  breaks as a note). The speed follows each line's timing and eases between
  lines, so it never snaps back to the start of a line.
- Full player matches the design boards: Search in the sidebar and a "+" for
  a new playlist, ranks and play counts in Most played, numbered playlist
  tracks with column heads and the saved date, 16:9 search results with the
  queue button always there, time of day and play counts in Recent, a
  hideable now-playing pane with "Add to playlist", the whole queue beside
  the lyrics, "playing from <list>" (backend now reports `queue_source`), the
  player bar's tools in a "⋯" menu on narrow windows, and a karaoke settings
  sheet with a count-in you can skip with Space.

- New full player layout: a sidebar with the library, a now-playing pane
  with Up next, and a player bar along the bottom. It is a normal window that
  tiles, floats and maximises, and it adapts to its width: the pane goes
  below 1100 px, the sidebar becomes an icon rail below 760 px, and below
  560 px the views move to tabs along the bottom.
- Colours follow the cover art: the accent, the player bar and the panes
  take their tint from the playing track's thumbnail (falls back to the
  theme accent for greyscale art). The mini card follows it too.
- "Play on…" in the player bar: pick the output device for this app's own
  stream.
- Remove a track from a saved playlist from its row menu.
- Bar spectrum colour setting (`ambientColor`): on an island bar showing its
  islands it uses the islands' colour; on a plain or transparent bar it keeps
  the light/dark text colour.

### Changed

- On a left or right bar the mini card opens beside the bar, level with the
  note icon and kept on screen, and sizes to its pane: it grows for search
  results and shrinks for a short queue.
- On a left or right bar the widget is always icon-only and the wide-chip
  toggle is hidden; title and full rows don't fit a side bar.
- Mini card: no "Now playing" label, bigger cover art. The tool row keeps
  per-song actions as tiles (video, karaoke when the song has timed lyrics,
  EQ) and puts the bar options (spectrum, lyrics in the bar, wide chip)
  behind one "Bar" tile with switches. Open on YouTube and a new "Copy link"
  (the plain song link, no timestamp) sit under the full-player button.

### Fixed

- After the backend restarts, pressing play picks the song up where it was
  instead of from the start (the resume point now travels with the load, so
  mpv can't drop it).

- The ambient strip's measuring timer no longer runs while the strip is
  hidden on a side bar.
