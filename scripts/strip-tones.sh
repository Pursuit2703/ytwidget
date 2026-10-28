#!/bin/bash
# Prints one 0/1 per bar for the bar strip of the current wallpaper:
# 1 = wallpaper under that bar is light (draw dark), 0 = dark (draw light).
# The cut-off is where light and dark bar text have equal WCAG contrast.
# usage: strip-tones.sh <monitor-name> <bar-size-logical> <bars> [top|bottom]
mon=$1 size=$2 bars=$3 pos=${4:-top}
bg=$(readlink -f "$HOME/.local/state/omarchy/current/background")
read -r w h scale < <(hyprctl monitors -j | jq -r --arg m "$mon" '(map(select(.name==$m))[0] // .[0]) | "\(.width) \(.height) \(.scale)"')
[[ -f $bg && -n $w ]] || exit 1
px=$(awk -v s="$size" -v k="$scale" 'BEGIN{printf "%d", s*k+0.5}')
y=0; [[ $pos == bottom ]] && y=$((h - px))
magick "$bg" -auto-orient -resize "${w}x${h}^" -gravity center -extent "${w}x${h}" \
  -gravity NorthWest -crop "${w}x${px}+0+${y}" +repage -colorspace Gray \
  -resize "${bars}x1!" txt:- | awk -F'[(,)]' 'NR>1{printf "%d ", ($3>117)?1:0}'
echo
