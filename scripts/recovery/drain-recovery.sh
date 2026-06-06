#!/bin/bash
# Run as ROOT (sudo). Continuously drains PhotoRec output -> Immich -> delete, to keep Mac HD from filling.
# Uploads as user 'nila' (their Immich login). PHOTOS ONLY: keep heic/jpg/png/tif/gif/bmp + raw; drop videos+junk.
# Skips the highest-numbered recup.N (photorec may be writing it) until photorec exits, then does a final pass.
set -u
R=/Users/nila/SEENI-recovery
LOG=$R/drain.log
IMMICH=/opt/homebrew/bin/immich
log(){ echo "$(date +%H:%M:%S) $*" >> "$LOG"; }
asnila(){ sudo -u nila -H env HOME=/Users/nila PATH=/opt/homebrew/bin:/usr/bin:/bin "$@"; }

log "=== drain loop started ==="
while true; do
  pr_running=$(pgrep -f 'photorec .*rdisk5' >/dev/null && echo yes || echo no)
  last=$(ls -d "$R"/recup.* 2>/dev/null | sed -E 's/.*recup\.//' | sort -n | tail -1)
  for d in $(ls -d "$R"/recup.* 2>/dev/null | sort -t. -k2 -n); do
    idx=${d##*recup.}
    # don't touch the active (highest) folder while photorec still running
    [[ "$pr_running" == "yes" && "$idx" == "$last" ]] && continue
    [[ -d "$d" ]] || continue
    # strip non-photo files + junk
    find "$d" -type f \( -iname '*.mov' -o -iname '*.mp4' -o -iname '*.m4v' -o -iname '*.mkv' \
         -o -iname '*.mpg' -o -iname '*.avi' -o -iname '*.out' -o -iname '*.txt' \) -delete 2>/dev/null
    imgs=$(find "$d" -type f ! -name 'report.xml' 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$imgs" -eq 0 ]]; then rm -rf "$d"; log "recup.$idx: no photos -> removed"; continue; fi
    ulog="$R/upload-recup.$idx.log"
    log "recup.$idx: uploading $imgs photos..."
    asnila "$IMMICH" upload --recursive --concurrency 4 "$d" > "$ulog" 2>&1
    if grep -qiE 'Failed to verify|Error:|unhandledRejection|ENOENT' "$ulog"; then
      log "recup.$idx: UPLOAD ERRORS -> KEEPING ($ulog)"; continue; fi
    if grep -qiE 'Successfully uploaded|already been uploaded|new files and .* duplicates|All assets' "$ulog"; then
      newc=$(grep -oiE 'uploaded [0-9]+ new' "$ulog" | grep -oE '[0-9]+' | head -1)
      rm -rf "$d"; log "recup.$idx: DRAINED (new=${newc:-0}) deleted. free=$(df -h / | awk 'NR==2{print $4}')"
    else
      log "recup.$idx: unconfirmed -> KEEPING ($ulog)"; fi
  done
  if [[ "$pr_running" == "no" ]]; then
    # final pass already included last folder above; if nothing left, done
    remaining=$(ls -d "$R"/recup.* 2>/dev/null | wc -l | tr -d ' ')
    log "photorec not running; remaining recup dirs: $remaining"
    [[ "$remaining" -eq 0 ]] && { log "=== drain complete ==="; break; }
  fi
  sleep 60
done
