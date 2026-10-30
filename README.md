# YT Widget

A native, plain-YouTube music player for [Omarchy](https://omarchy.org). Search,
playlists, queue, EQ, spectrum visualizer, and a mini player — all backed by a
local `mpv` + `yt-dlp` daemon. No browser tab, no Google/YouTube login, no
cookies or tokens ever touched.

Ships as an `omarchy-shell` plugin: a bar widget + popup panel (QML) talking
over a Unix socket to a small Python playback backend.

## Why

Browser-based YouTube Music costs a full Chromium/Electron process just to
play audio, drags in an account/cookie login flow, and can't live in the bar.
This is a few hundred KB of QML plus a dependency-free Python backend that
shells out to `mpv` and `yt-dlp` directly.

## Requirements

- [Omarchy](https://omarchy.org) with `omarchy-shell` (Quickshell-based)
- `mpv`
- `yt-dlp`
- `python3` (no third-party pip packages — stdlib only)
- `systemd --user`
- `parec` (from `libpulse`) — records the plugin's own audio for the
  visualiser. Without it playback works and the bars simply never move.

On Arch (Omarchy's base), install all of these up front with:

```sh
sudo pacman -S --needed mpv yt-dlp python libpulse
```

## Install

```sh
omarchy plugin add https://github.com/Pursuit2703/ytwidget.git --enable
```

That's it. The widget appears in your bar immediately. The first time you
use it, it installs its own Python backend and systemd user unit
automatically — there is no second command to run, as long as the
requirements above are already installed.

<details>
<summary>Installing by hand instead</summary>

If you'd rather not use the `omarchy plugin` CLI (or your Omarchy version
predates it), a manual clone works the same way:

```sh
git clone https://github.com/Pursuit2703/ytwidget.git ~/.config/omarchy/plugins/omar.ytwidget
~/.config/omarchy/plugins/omar.ytwidget/scripts/install.sh
omarchy-restart-shell
```

`install.sh` checks the dependencies, installs the backend up front, and
adds the widget to your bar if it is not there already. It never runs
anything as root: if a step needs it, the commands are printed at the end in
one block to read and paste.

Under the hood `setup.sh` (which `install.sh` calls, and which the widget
also calls itself on first use) copies the backend into
`~/.local/lib/ytwidget` — stable, deliberately *not* hot-reloaded — installs
`~/.local/bin/ytwidget-server`, and installs the `ytwidget.service` systemd
user unit. That unit has no `[Install]` section, so it is never enabled at
login, only started on demand.

</details>

**The backend is a copy.** Editing `backend/*.py` in a checkout changes
nothing until you re-run `scripts/setup.sh` and
`systemctl --user restart ytwidget.service`. The QML is the opposite: it is
read from the plugin directory and reloads on save.

## Developing on a live checkout

The above is all a normal install needs. If you want to edit the plugin in
place instead — e.g. you're hacking on `BarWidget.qml` or the backend and
want changes to hot-reload from your own working copy rather than a `git
clone`'d install — clone it anywhere and bind-mount it into the plugins
directory:

```sh
git clone https://github.com/Pursuit2703/ytwidget.git ~/Work/ytwidget
~/Work/ytwidget/scripts/install.sh --dev --restore-bar
# paste the root commands it prints, then:
omarchy-restart-shell
```

- `--dev` bind-mounts the checkout onto
  `~/.config/omarchy/plugins/omar.ytwidget` and adds an `/etc/fstab` entry so
  it survives a reboot. This exists because omarchy-shell's `PluginRegistry`
  watches the plugins directory with `inotifywait -m -r`, and that does not
  follow a symlink into a subdirectory — a symlinked plugin silently never
  hot-reloads. A bind mount is a real directory to inotify.
- `--restore-bar` copies [`config/shell.json`](config/shell.json) over
  `~/.config/omarchy/shell.json`, restoring the whole bar layout: which
  widgets sit where, and this widget's settings. Your existing file is backed
  up next to it first. Leave the flag off to keep your current bar and just
  have the widget appended to it.

`config/shell.json` is a snapshot of a working desktop, so it names other
plugins too (island-bar, pomodoro, salah-time, notification-center,
protonvpn). Those are not installed by this script — the bar simply skips any
it cannot find.

## Customizing

Everything under `barWidget.schema` in [`manifest.json`](manifest.json) is
exposed live in Omarchy's widget settings UI — no config file editing needed:

| Setting | Default | Notes |
|---|---|---|
| `idleShutdownMinutes` | 15 | Stop local playback when idle (`0` = never) |
| `maxWidth` | 128 | Bar title width, px |
| `miniResults` | 12 | Search results the mini player fetches (the list scrolls after five rows) |
| `crossfadeMs` | 500 | Crossfade between tracks (`0` = hard cut) |
| `subtitleLang` | `en` | Preferred subtitle language for the video window |
| `videoQuality` | 1080 | Preferred video window height |
| `videoWindowPercent` | 70 | Max % of screen the video window may fill |
| `videoGpu` | `integrated` | Pin video decode to the integrated GPU, or `default` |

Because the plugin is plain QML + Python with no build step, everything else
is directly editable and hot-reloads on save:

- `BarWidget.qml` / `Panel.qml` — bar pill and popup layout
- `EqBar.qml` / `SpectrumBar.qml` / `BarWave.qml` — visualizer look
- `backend/*.py` — search, queue, playlists, history, playback protocol

The backend files in `backend/` are what `scripts/setup.sh` installs; edit
them and rerun `setup.sh`, or run `scripts/playback-runtime.sh restart` after
manually re-copying, to pick up changes.

## Architecture

```
BarWidget.qml / Panel.qml  (Quickshell UI, hot-reloads)
        |  Unix socket (backend/protocol.py line protocol)
        v
backend/server.py  ->  player.py (mpv IPC) + search.py (yt-dlp) + ...
```

The backend never touches a browser, a YouTube account, or stores
cookies/tokens — see `backend/protocol.py` and `backend/server.py`. Runtime
state lives outside this repo, in `~/.config/ytwidget` and
`~/.cache/ytwidget` (see `backend/store.py`).

## Uninstall

```sh
systemctl --user stop ytwidget.service
rm ~/.config/systemd/user/ytwidget.service
rm ~/.local/bin/ytwidget-server
rm -rf ~/.local/lib/ytwidget
rm -rf ~/.config/omarchy/plugins/omar.ytwidget
```

## License

MIT


## Player UI (mini card and full player)

- Mini card: fixed size on a top or bottom bar; on a left or right bar it opens beside the bar, level with the icon, and sizes to its list (grows for search results, shrinks for a short queue). Blurred cover header, Up next / Recent / Lists pane, pasted playlist links preview in the pane, compact/wide chip switch next to the search field (hidden on a side bar, where the widget is always icon-only).
- Full player: Search / Queue / Playlists / Recent tabs. A pasted playlist link opens a playlist page (Play all, Shuffle, Add to queue, Save) and nothing is saved or played until you press a button. Recent is grouped by day with Play all and Clear history. Most played is ranked from the `plays` counter in `play-history.json`.
- Backend commands added: `preview_playlist` (resolve a link without saving), `clear_history`. History entries now carry `playedAt` and `plays`; playlists list `covers`.
- The daemon runs from `~/.local/lib/ytwidget`, a copy of `backend/`. After changing anything in `backend/`, run `scripts/setup.sh` and restart the daemon, or the UI will talk to the old code.

## Keyboard

Inside the card and the player, while the search box is not focused
(`Esc` leaves the box, `/` goes back into it, `Esc` again closes):

| Key | Does |
|---|---|
| `Space` | play / pause |
| `N` / `P` | next / previous |
| `S` / `R` | shuffle / repeat |
| `←` / `→` | seek -5 s / +5 s |
| `↑` / `↓` | volume +5 / -5 |
| `M` | mute / unmute |
| `1 2 3 4` | card tabs: Up next, Recent, Lists, Lyrics |
| `1 2 3 4 5` | player tabs: Search, Queue, Playlists, Recent, Lyrics |
| `L` | Lyrics tab |
| `E` | equaliser |
| `V` | video window |
| `F` | open the full player (card only) |

From anywhere, add to `~/.config/hypr/bindings.lua`:

    o.bind("SUPER + ALT + A", "Music: play / pause", "playerctl -p mpv.ytwidget play-pause")
    o.bind("SUPER + ALT + Z", "Music: previous",     "playerctl -p mpv.ytwidget previous")
    o.bind("SUPER + ALT + X", "Music: next",         "playerctl -p mpv.ytwidget next")
