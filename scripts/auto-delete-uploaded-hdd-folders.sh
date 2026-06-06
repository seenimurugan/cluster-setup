#!/bin/bash
# Watch the HDD upload stream logs and rm -rf each folder
# the moment its "<<< END: <path> (exit 0)" marker fires.
# Only deletes on exit code 0. Stays running until both stream logs
# emit the final "<<< END:" line for their last folder.

set -u

LOGDIR="$HOME/homelab/uploads"
WLOG="$LOGDIR/auto-delete.log"
exec >> "$WLOG" 2>&1

ts() { date '+%Y-%m-%d %H:%M:%S'; }

echo "[$(ts)] auto-delete watcher started"

# Tail both stream logs; -F follows rotations; -n 0 means only NEW lines.
tail -n 0 -F "$LOGDIR/stream-a.log" "$LOGDIR/stream-b.log" 2>/dev/null | \
  while IFS= read -r line; do
    # Match: anything ending with "<<< END:   <path> (exit 0)"
    case "$line" in
      *"<<< END:"*"(exit 0)"*)
        # Extract the path between "<<< END:" and " (exit "
        path=${line#*<<< END:}
        # Trim ALL leading whitespace (the log uses ":   " — 3 spaces)
        path="${path#"${path%%[![:space:]]*}"}"
        path=${path% (exit *}               # strip " (exit N)"
        # Trim trailing whitespace too
        path="${path%"${path##*[![:space:]]}"}"
        # Be defensive: must start with /Volumes/Seeni's HDD/
        case "$path" in
          "/Volumes/Seeni's HDD/"*)
            if [ -d "$path" ]; then
              size=$(du -sh "$path" 2>/dev/null | cut -f1)
              echo "[$(ts)] Deleting completed folder ($size): $path"
              rm -rf "$path"
              echo "[$(ts)]   done"
            else
              echo "[$(ts)] (already gone): $path"
            fi
            ;;
          *)
            echo "[$(ts)] (path doesn't look like HDD source, skipping): $path"
            ;;
        esac
        ;;
    esac
  done
