#!/usr/bin/env bash
# Install the YT Widget playback backend: copy the (dependency-free) Python
# daemon out of the plugin directory (which hot-reloads on save) into a
# stable location, then install its systemd user unit. Never enabled at
# login: the unit has no [Install] section, so it only ever runs when
# explicitly started.
set -euo pipefail

source_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
lib_dir="$HOME/.local/lib/ytwidget"
bin_dir="$HOME/.local/bin"
unit_dir="$HOME/.config/systemd/user"

for command_name in mpv yt-dlp python3 systemctl; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "setup.sh: required command is missing: $command_name" >&2
    exit 1
  }
done

mkdir -p "$lib_dir" "$bin_dir" "$unit_dir"

backend_files=(server.py protocol.py player.py search.py store.py
  play_history.py queue_session.py playlists.py spectrum.py audio_output.py
  urls.py video.py)
for name in "${backend_files[@]}"; do
  install -m 644 -- "$source_root/backend/$name" "$lib_dir/$name"
done

python3 -m py_compile "${backend_files[@]/#/$lib_dir/}"

cat > "$bin_dir/ytwidget-server" <<EOF
#!/usr/bin/env bash
exec /usr/bin/python3 "$lib_dir/server.py" "\$@"
EOF
chmod 755 "$bin_dir/ytwidget-server"

install -m 644 -- "$source_root/systemd/ytwidget.service" "$unit_dir/ytwidget.service"
systemctl --user daemon-reload

echo "Installed ytwidget-server to $bin_dir/ytwidget-server"
echo "The user unit is $unit_dir/ytwidget.service and is not enabled at login."
