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

## Install

```sh
git clone <this repo> ~/.config/omarchy/plugins/omar.ytwidget
~/.config/omarchy/plugins/omar.ytwidget/scripts/setup.sh
```

`setup.sh` copies the backend into `~/.local/lib/ytwidget` (stable, not
hot-reloaded), installs `~/.local/bin/ytwidget-server`, and installs the
`ytwidget.service` systemd user unit. The unit has no `[Install]` section —
it's never enabled at login, only started on demand when you first open the
widget.

Add the widget to your bar in `~/.config/omarchy/shell.json`:

```json
{ "id": "omar.ytwidget" }
```

or bind a toggle in Hyprland:

```lua
o.bind("SUPER + ALT + Y", "YT Widget", "omarchy-shell shell toggle omar.ytwidget {}")
```

## Customizing

Everything under `barWidget.schema` in [`manifest.json`](manifest.json) is
exposed live in Omarchy's widget settings UI — no config file editing needed:

| Setting | Default | Notes |
|---|---|---|
| `idleShutdownMinutes` | 15 | Stop local playback when idle (`0` = never) |
| `maxWidth` | 150 | Bar title width, px |
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
