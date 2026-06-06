#!/bin/bash
# Report, per recup folder, how many PHOTOS are already in Immich (duplicates) vs NEW (your lost photos).
# Read-only (uses immich --dry-run). Run as your normal user. Usage: bash ~/check-recovery.sh [recup.N]
R=/Users/nila/SEENI-recovery
IMMICH=/opt/homebrew/bin/immich
imgexpr=( -iname '*.heic' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.tif' -o -iname '*.tiff' -o -iname '*.gif' -o -iname '*.bmp' -o -iname '*.orf' -o -iname '*.rw2' -o -iname '*.raf' )
targets=()
if [[ -n "${1:-}" ]]; then targets=("$R/$1"); else targets=($(ls -d "$R"/recup.* 2>/dev/null | sort -t. -k2 -n)); fi
printf "%-12s %8s %8s %8s   %s\n" FOLDER PHOTOS NEW DUP VERDICT
for d in "${targets[@]}"; do
  [[ -d "$d" ]] || continue
  ph=$(find "$d" -type f \( "${imgexpr[@]}" \) 2>/dev/null | wc -l | tr -d ' ')
  [[ "$ph" -eq 0 ]] && { printf "%-12s %8s %8s %8s   %s\n" "$(basename "$d")" 0 0 0 "no photos (videos/junk only -> safe to delete)"; continue; }
  out=$("$IMMICH" upload --dry-run --recursive "$d" 2>/dev/null | grep -iE 'new files and')
  new=$(echo "$out" | grep -oiE 'Found [0-9]+ new' | grep -oE '[0-9]+'); new=${new:-0}
  dup=$(echo "$out" | grep -oiE 'and [0-9]+ duplicate' | grep -oE '[0-9]+'); dup=${dup:-0}
  if [[ "$new" -eq 0 ]]; then v="ALL in Immich -> safe to delete"; else v=">>> $new LOST photos -> KEEP (upload these)"; fi
  printf "%-12s %8s %8s %8s   %s\n" "$(basename "$d")" "$ph" "$new" "$dup" "$v"
done
