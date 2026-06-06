#!/bin/bash
# Native host-side move of Jellyfin films >1GiB: SSD -> homelab-hdd, leaving a
# symlink that points to the Jellyfin POD path (/media-hdd/<rel>) so Jellyfin serves them.
# Safe: verifies size match before deleting the source.
SSD=/Users/nila/movies
HDD=/Volumes/homelab-hdd/jellyfin-media
POD_HDD=/media-hdd
LOG=/Users/nila/move-films.log
ts(){ date '+%H:%M:%S'; }
echo "[$(ts)] === host-side film move start ===" >> "$LOG"
moved=0; bytes=0; fail=0; skip=0
find "$SSD" -type f -size +1073741824c ! -name '._*' -print0 2>/dev/null | while IFS= read -r -d '' f; do
  rel="${f#$SSD/}"; dst="$HDD/$rel"; link="$POD_HDD/$rel"
  ssize=$(stat -f%z "$f" 2>/dev/null)
  mkdir -p "$(dirname "$dst")"
  if [ -f "$dst" ] && [ "$(stat -f%z "$dst" 2>/dev/null)" = "$ssize" ]; then
    echo "[$(ts)] HDD-COPY-OK (reuse) $rel" >> "$LOG"
  else
    echo "[$(ts)] COPY $rel ($((ssize/1024/1024)) MiB)" >> "$LOG"
    cp -p "$f" "$dst" || { echo "[$(ts)] FAIL-COPY $rel" >> "$LOG"; continue; }
  fi
  if [ "$(stat -f%z "$dst" 2>/dev/null)" = "$ssize" ]; then
    rm -f "$f" && ln -s "$link" "$f" && echo "[$(ts)] MOVED+LINK $rel" >> "$LOG"
  else
    echo "[$(ts)] VERIFY-FAIL kept-source $rel" >> "$LOG"
  fi
done
echo "[$(ts)] === done. SSD free: $(df -h / | awk 'NR==2{print \$4}') | HDD jellyfin-media: $(du -sh "$HDD" 2>/dev/null | cut -f1) ===" >> "$LOG"
