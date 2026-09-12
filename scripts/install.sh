#!/usr/bin/env bash
# One-shot recovery: take a fresh clone of this repo to a working widget.
#
#   scripts/install.sh              install the backend and register the widget
#   scripts/install.sh --dev        also bind-mount this checkout into the
#                                   plugins directory, for editing in place
#   scripts/install.sh --restore-bar  also restore the saved bar layout
#
# Anything needing root is never run for you. It is collected and printed at
# the end as one block to paste, so you can read it before it touches
# /etc/fstab.
set -euo pipefail

source_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
plugin_dir="$HOME/.config/omarchy/plugins/omar.ytwidget"
shell_json="$HOME/.config/omarchy/shell.json"

want_dev=0
want_bar=0
for arg in "$@"; do
  case "$arg" in
    --dev) want_dev=1 ;;
    --restore-bar) want_bar=1 ;;
    *) echo "install.sh: unknown option: $arg" >&2; exit 2 ;;
  esac
done

root_steps=()

# ---------------------------------------------------------------- dependencies
missing=()
for command_name in mpv yt-dlp python3 systemctl quickshell; do
  command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
done
# parec records the audio the visualiser draws. Without it everything still
# plays, the bars just never move — which is a confusing way to find out.
command -v parec >/dev/null 2>&1 || missing+=("parec (libpulse)")
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "install.sh: missing: ${missing[*]}" >&2
  echo "install.sh: on Arch: sudo pacman -S --needed mpv yt-dlp python libpulse" >&2
  exit 1
fi

# ---------------------------------------------------------------- the backend
"$source_root/scripts/setup.sh"

# ------------------------------------------------------- plugin visible to the shell
# omarchy-shell's PluginRegistry watches the plugins directory with
# `inotifywait -m -r`, which does not follow a symlink into a subdirectory —
# so a symlinked plugin never hot-reloads on save. A bind mount is a real
# directory as far as inotify is concerned, which is why --dev uses one.
if [[ -e $plugin_dir && ! -L $plugin_dir ]] && mountpoint -q "$plugin_dir" 2>/dev/null; then
  echo "install.sh: $plugin_dir is already a mount point, leaving it alone."
elif [[ "$source_root" == "$plugin_dir" ]]; then
  echo "install.sh: running from the plugins directory, nothing to link."
elif [[ $want_dev -eq 1 ]]; then
  mkdir -p "$plugin_dir"
  root_steps+=("mount --bind '$source_root' '$plugin_dir'")
  root_steps+=("printf '%s\\n' '$source_root $plugin_dir none bind 0 0' >> /etc/fstab")
else
  echo "install.sh: this checkout is not at $plugin_dir."
  echo "            Either clone it there, or re-run with --dev to bind-mount it."
fi

# ------------------------------------------------------- register in the bar
if [[ $want_bar -eq 1 && -f "$source_root/config/shell.json" ]]; then
  if [[ -f $shell_json ]]; then
    backup="$shell_json.bak.$(date +%Y%m%d%H%M%S)"
    cp -- "$shell_json" "$backup"
    echo "install.sh: saved your existing bar config to $backup"
  fi
  mkdir -p "$(dirname -- "$shell_json")"
  install -m 644 -- "$source_root/config/shell.json" "$shell_json"
  echo "install.sh: restored the saved bar layout."
elif [[ -f $shell_json ]]; then
  # Add the widget without disturbing the rest of the layout.
  python3 - "$shell_json" <<'PY'
import collections, json, sys

path = sys.argv[1]
with open(path) as handle:
    config = json.load(handle, object_pairs_hook=collections.OrderedDict)

right = config.setdefault("bar", {}).setdefault("layout", {}).setdefault("right", [])
if any(entry.get("id") == "omar.ytwidget" for entry in right):
    print("install.sh: widget already in the bar.")
else:
    right.append(collections.OrderedDict([("id", "omar.ytwidget")]))
    with open(path, "w") as handle:
        json.dump(config, handle, indent=2)
        handle.write("\n")
    print("install.sh: added omar.ytwidget to the bar's right section.")
PY
else
  echo "install.sh: no $shell_json yet — add {\"id\": \"omar.ytwidget\"} once you have one."
fi

echo
if [[ ${#root_steps[@]} -gt 0 ]]; then
  echo "Run these as root, all at once:"
  echo
  printf '  sudo %s\n' "${root_steps[@]}"
  echo
  echo "Then: omarchy-restart-shell"
else
  echo "Done. Run: omarchy-restart-shell"
fi
