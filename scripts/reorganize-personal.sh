#!/bin/bash
# Reorganize ~/Documents/ID & Personal Docs → ~/Documents/Personal with proper subfolders.
# Consolidates scattered visa-application packs (Ponnammal, Jothi) under visa/.

set -u
cd "$HOME/Documents"

OLD="ID & Personal Docs"
NEW="Personal"

LOG="$HOME/homelab/uploads/reorganize-personal.log"
exec > >(tee -a "$LOG") 2>&1

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*"; }

# 1. Rename ID & Personal Docs → Personal (if not already done)
if [ -d "$OLD" ] && [ ! -d "$NEW" ]; then
  log "Renaming '$OLD' → '$NEW'"
  mv "$OLD" "$NEW"
fi

cd "$NEW"

# 2. Create subfolder skeleton (mkdir -p is idempotent)
for d in "passport" "oci" "driving-license" "utility" "marriage certificate" "birth certificate" "college" "school" "invitation letters" "visa" "visa/Ponnammal" "visa/Jothi"; do
  mkdir -p "$d"
done
log "Subfolder skeleton ready"

# Helper: safe move (skip if source missing, preserves relative subpath under target)
mv_to() {
  local src="$1"
  local target_dir="$2"
  if [ ! -e "$src" ]; then
    log "  (missing): $src"
    return
  fi
  mkdir -p "$target_dir"
  local base=$(basename "$src")
  local target="$target_dir/$base"
  if [ -e "$target" ]; then
    # If destination exists, add suffix
    local stem="${base%.*}"
    local ext="${base##*.}"
    if [ "$stem" = "$base" ]; then ext=""; else ext=".$ext"; fi
    local n=1
    while [ -e "$target_dir/${stem} (${n})${ext}" ]; do n=$((n+1)); done
    target="$target_dir/${stem} (${n})${ext}"
  fi
  mv "$src" "$target"
  log "  moved: $src → $target"
}

cd "$HOME/Documents/$NEW"

# 3. Move passport files (loose at root + nested)
log "Moving passport files"
for f in \
    "Information for Indian Passport 12.07.2025.docx" \
    "Passport_Tatkal_Request_Letter.pdf" \
    "Request Letter for Tatkal Passport Renewal.pdf" \
    "Request Letter for Tatkal Passport Renewal (1).pdf" \
    "Request Letter for Tatkal Passport Renewal.txt" \
    "Sathasivam passport photo.zip" \
    "Jothi - Invitation documents/seeni-passport-uk.pdf"; do
  mv_to "$f" "passport"
done

# 4. Move OCI files from Uncategorized
log "Moving OCI files"
for f in \
    "$HOME/Documents/Uncategorized/Nithya oci.pdf" \
    "$HOME/Documents/Uncategorized/Seeni oci.pdf"; do
  mv_to "$f" "$HOME/Documents/$NEW/oci"
done

# 5. Move utility files (council tax + electricity) from Tax/
log "Moving utility files"
mv_to "$HOME/Documents/Tax/Jothi - Invitation documents/Council tax letter 2025.pdf" "$HOME/Documents/$NEW/utility"
mv_to "$HOME/Documents/Tax/visa - Ponnammal/council-tax.pdf" "$HOME/Documents/$NEW/utility"
mv_to "$HOME/Documents/Tax/visa - Ponnammal/counciltax and utility bill/3 Jun 2022 Bulb Statement.pdf" "$HOME/Documents/$NEW/utility"
mv_to "$HOME/Documents/Tax/visa - Ponnammal/counciltax and utility bill/1 May 2022 Bulb Statement.pdf" "$HOME/Documents/$NEW/utility"

# 6. Move marriage certificate
log "Moving marriage certificate"
mv_to "visa - Ponnammal/marriage certificate.pdf" "marriage certificate"

# 7. Move invitation letters
log "Moving invitation letters"
for f in \
    "Jothi invitation letter.odt" \
    "Jothi invitation letter.pdf" \
    "Jothi invitation letter (1).pdf" \
    "UK_Visit_Invitation_Letter.pdf" \
    "Invitation_Letter_Jothi_Mahendiran.docx" \
    "Jothi - Invitation documents.zip" \
    "Jothi - Invitation documents/Invitation letter.pdf" \
    "visa - Ponnammal/InvitationLetter-Ponnammal-2.pdf"; do
  mv_to "$f" "invitation letters"
done

# 8. Consolidate "visa - Ponnammal" content into visa/Ponnammal/
log "Consolidating visa - Ponnammal scattered content"
# From Personal/visa - Ponnammal/ (sponsorship + passport)
if [ -d "visa - Ponnammal" ]; then
  # Move remaining files (Sponsorship letter, passport/nithi-passport-uk.pdf)
  mv_to "visa - Ponnammal/Sponsorship letter - Ponnammal.pdf" "visa/Ponnammal"
  mv_to "visa - Ponnammal/passport/nithi-passport-uk.pdf" "passport"
  # Clean up empty dirs
  rmdir "visa - Ponnammal/passport" 2>/dev/null
  rmdir "visa - Ponnammal" 2>/dev/null
fi
# From Bank & Finance/visa - Ponnammal/
if [ -d "$HOME/Documents/Bank & Finance/visa - Ponnammal" ]; then
  log "  Moving Bank & Finance/visa - Ponnammal/* → visa/Ponnammal/bank/"
  mkdir -p "visa/Ponnammal/bank"
  for f in "$HOME/Documents/Bank & Finance/visa - Ponnammal/statements"/*; do
    [ -e "$f" ] || continue
    mv_to "$f" "$HOME/Documents/$NEW/visa/Ponnammal/bank"
  done
  rmdir "$HOME/Documents/Bank & Finance/visa - Ponnammal/statements" 2>/dev/null
  rmdir "$HOME/Documents/Bank & Finance/visa - Ponnammal" 2>/dev/null
fi
# From Tax/visa - Ponnammal/payslips and p60 form/
if [ -d "$HOME/Documents/Tax/visa - Ponnammal/payslips and p60 form" ]; then
  log "  Moving Tax/visa - Ponnammal/payslips/ → visa/Ponnammal/payslips/"
  mkdir -p "visa/Ponnammal/payslips"
  for f in "$HOME/Documents/Tax/visa - Ponnammal/payslips and p60 form"/*; do
    [ -f "$f" ] || continue
    mv_to "$f" "$HOME/Documents/$NEW/visa/Ponnammal/payslips"
  done
  # Employment contract subfolder
  if [ -d "$HOME/Documents/Tax/visa - Ponnammal/payslips and p60 form/employment contract" ]; then
    mkdir -p "visa/Ponnammal/employment-contract"
    for f in "$HOME/Documents/Tax/visa - Ponnammal/payslips and p60 form/employment contract"/*; do
      [ -e "$f" ] || continue
      mv_to "$f" "$HOME/Documents/$NEW/visa/Ponnammal/employment-contract"
    done
    rmdir "$HOME/Documents/Tax/visa - Ponnammal/payslips and p60 form/employment contract" 2>/dev/null
  fi
  rmdir "$HOME/Documents/Tax/visa - Ponnammal/payslips and p60 form" 2>/dev/null
fi
# Clean up empty visa - Ponnammal scaffolding
rmdir "$HOME/Documents/Tax/visa - Ponnammal/counciltax and utility bill" 2>/dev/null
rmdir "$HOME/Documents/Tax/visa - Ponnammal" 2>/dev/null

# 9. Consolidate "Jothi - Invitation documents" remaining content into visa/Jothi/
log "Consolidating Jothi - Invitation documents content"
JOTHI_DIR="$HOME/Documents/$NEW/Jothi - Invitation documents"
if [ -d "$JOTHI_DIR" ]; then
  for f in "$JOTHI_DIR"/*; do
    [ -e "$f" ] || continue
    mv_to "$f" "$HOME/Documents/$NEW/visa/Jothi"
  done
  rmdir "$JOTHI_DIR" 2>/dev/null
fi
# Same for Tax/Jothi - Invitation documents/
if [ -d "$HOME/Documents/Tax/Jothi - Invitation documents" ]; then
  for f in "$HOME/Documents/Tax/Jothi - Invitation documents"/*; do
    [ -e "$f" ] || continue
    mv_to "$f" "$HOME/Documents/$NEW/visa/Jothi"
  done
  for d in "$HOME/Documents/Tax/Jothi - Invitation documents"/*/; do
    [ -d "$d" ] || continue
    base=$(basename "$d")
    mkdir -p "$HOME/Documents/$NEW/visa/Jothi/$base"
    for f in "$d"/*; do
      [ -e "$f" ] || continue
      mv_to "$f" "$HOME/Documents/$NEW/visa/Jothi/$base"
    done
    rmdir "$d" 2>/dev/null
  done
  rmdir "$HOME/Documents/Tax/Jothi - Invitation documents" 2>/dev/null
fi

# 10. Clean up any other emptied dirs
log "Pruning empty directories"
find "$HOME/Documents" -depth -type d -empty 2>/dev/null | while read -r d; do
  name=$(basename "$d")
  # Don't prune the new category root dirs
  case "$name" in
    "Documents"|"Personal"|"Bank & Finance"|"Bills & Receipts"|"Books & Learning"|"Code Archives"|"Education & Certs"|"Installers"|"Insurance"|"Legal & Contracts"|"Manuals & Warranties"|"Medical"|"Tax"|"Travel"|"Uncategorized"|"Work & Career"|"Arduino"|"passport"|"oci"|"driving-license"|"utility"|"marriage certificate"|"birth certificate"|"college"|"school"|"invitation letters"|"visa"|"Ponnammal"|"Jothi"|"bank"|"payslips"|"employment-contract")
      continue ;;
  esac
  log "  rmdir: $d"
  rmdir "$d" 2>/dev/null
done

log "=== DONE ==="
echo
echo "=== Personal/ final structure ==="
cd "$HOME/Documents/$NEW"
for d in */; do
  count=$(find "$d" -type f 2>/dev/null | wc -l | tr -d ' ')
  size=$(du -sh "$d" 2>/dev/null | cut -f1)
  echo "  $d ($count files, $size)"
done
