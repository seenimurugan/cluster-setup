#!/usr/bin/env python3
"""
Categorize document files in ~/Documents, ~/Downloads, ~/Desktop into
topic-based buckets under ~/Documents/<Topic>/.

Dry-run by default — prints the plan. Pass --execute to actually move files.

Categorization rules use filename + path keyword matching (case-insensitive).
Files matching nothing go to "Uncategorized" for manual triage.

Skips: code source, photo/video extensions (already in Immich), .git, node_modules,
hidden files, AppleDouble (._*), Office temp (~$*), DS_Store.
"""
from __future__ import annotations
import os
import re
import sys
import json
import shutil
from pathlib import Path
from collections import defaultdict

HOME = Path(os.environ.get("USER_HOME", str(Path.home())))
# 2026-05-29 run: process the newly-copied-from-HDD ~/Documents/Documents/
# folder (~2400 files). Keep DEST_ROOT as ~/Documents so categorized files
# land in the existing top-level category folders (Bank & Finance, etc.).
SOURCES = [HOME / "Documents" / "Documents"]
DEST_ROOT = HOME / "Documents"

EXCLUDE_DIRS = {
    ".git", "node_modules", "target", "build", "dist", "vendor",
    "__pycache__", ".svn", ".tox", ".cache", ".idea", ".vscode",
    ".npm", ".yarn", ".gradle", ".m2",
}
EXCLUDE_FILES = {".DS_Store", ".localized", "Thumbs.db", "desktop.ini"}

# Files under these path-fragments are left WHERE THEY ARE (not categorized).
# Use full lower-case path-fragments. Used for "keep this folder intact" cases.
LEAVE_IN_PLACE_FRAGMENTS = [
    "/arduino/",       # Arduino starter kit + tutorials stay at ~/Documents/Arduino/
]

# Zip files that should be extracted into a specific category (instead of being
# moved as-is). Maps absolute source path → (target category, extract into category root).
EXTRACT_INTO = {
    "${USER_HOME}/Downloads/Archive.zip": "Books & Learning",
}

CODE_EXT = {
    ".py", ".go", ".ts", ".tsx", ".js", ".jsx", ".java", ".kt", ".rs",
    ".c", ".h", ".cpp", ".hpp", ".cs", ".rb", ".php", ".sh", ".bash",
    ".zsh", ".swift", ".m", ".mm", ".sql", ".html", ".css", ".scss",
    ".vue", ".lua", ".pl", ".r", ".scala", ".groovy", ".tf", ".hcl",
    ".proto", ".thrift", ".dockerfile", ".lock", ".sum",
    # Arduino / Processing / Make / config — code, not documents
    ".ino", ".pde", ".mk", ".properties", ".bdf", ".yaml", ".yml",
    ".cfg", ".conf", ".toml",
    # Web/Java project artefacts and asciidoc — these are project sources, not docs
    ".gsp", ".jsp", ".adoc", ".war", ".jar", ".class", ".ear", ".aar",
    ".gradle", ".pom", ".bat",
}
MEDIA_EXT = {
    ".jpg", ".jpeg", ".png", ".gif", ".heic", ".heif", ".mov", ".mp4",
    ".m4v", ".avi", ".mkv", ".webm", ".webp", ".dng", ".raw", ".cr2",
    ".nef", ".arw", ".mp3", ".m4a", ".wav", ".aac", ".flac", ".ogg",
    ".wma", ".opus", ".bmp", ".tif", ".tiff", ".svg",
}

# Categorization rules — first match wins, in priority order.
# Patterns: use (?<![a-z]) and (?![a-z]) lookarounds instead of \b because
# underscores count as word chars in regex (\b won't match in "Bank_Transfer").
WB_L = r"(?<![a-z])"   # left boundary (no alpha before)
WB_R = r"(?![a-z])"    # right boundary (no alpha after)
def w(s): return WB_L + s + WB_R

RULES: list[tuple[str, dict]] = [
    ("Installers",          {"exts": [".dmg", ".pkg", ".exe", ".iso", ".msi", ".deb", ".rpm"]}),
    ("Tax",                 {"patterns": [w("tax"), w("hmrc"), w("p45"), w("p60"), w("p11d"), w("sa302"), r"self.?assess", w("vat"), w("nino"), w("p46"), r"council.?tax"]}),
    ("Bank & Finance",      {"patterns": [w("bank"), r"statement", w("iban"), r"mortgage", r"investment", r"sortcode", w("savings?"), r"current.?account", r"credit.?card", r"debit.?card", r"overdraft", w("monzo"), w("natwest"), w("hsbc"), w("barclays"), w("lloyds"), w("revolut"), w("capitalone"), w("coinbase"), w("halifax"), w("aip"), r"transfer.?request", r"bank.?transfer", r"sort.?code", r"swift.?code", r"account.?number", r"\bpay.?in\b", r"direct.?debit", w("standing.?order")]}),
    ("Bills & Receipts",    {"patterns": [w("bill"), r"invoice", r"receipt", r"utility", r"electric.?bill", r"gas.?bill", r"water.?bill", r"broadband", r"order.?confirm", w("quote"), w("quotation"), r"order_", r"\border\b", w("bulb"), w("bulb.?statement")]}),
    ("Insurance",           {"patterns": [r"insuran", w("policy"), w("claim"), r"cover.?note", r"allianz", r"axa", r"aviva", r"churchill"]}),
    ("Medical",             {"patterns": [w("nhs"), w("gp"), r"prescription", r"dental", w("medical"), w("hospital"), w("health"), w("physio"), r"vaccin", w("clinic"), r"surgery", r"referal", r"referral"]}),
    ("Legal & Contracts",   {"patterns": [r"contract", r"rental", r"tenancy", w("lease"), w("nda"), r"agreement", w("legal"), r"lawyer", r"solicitor", w("deed"), r"affidavit", r"notari[sz]"]}),
    # Personal sub-folders — more specific rules MUST come before the generic
    # "Personal" rule (first-match wins). Categories with "/" become nested
    # folders under DEST_ROOT.
    ("Personal/passport",         {"patterns": [r"passport", r"tatkal"]}),
    ("Personal/oci",              {"patterns": [w("oci")]}),
    ("Personal/driving-license",  {"patterns": [r"driving.?licen[cs]e", r"driving"]}),
    ("Personal/utility",          {"patterns": [r"council.?tax", w("bulb"), r"bulb.?statement", r"electric.?bill", r"gas.?bill", r"water.?bill", r"broadband.?bill"]}),
    ("Personal/marriage certificate", {"patterns": [r"marriage", r"wedding.?cert"]}),
    ("Personal/birth certificate",    {"patterns": [r"birth.?cert"]}),
    ("Personal/invitation letters",   {"patterns": [r"invitation.?letter", r"invitation.?doc", r"sponsor.?letter"]}),
    ("Personal/visa",             {"patterns": [w("visa"), w("brp"), r"biometric.?residence"]}),
    ("Personal",                  {"patterns": [r"licen[cs]e", w("identity"), r"national.?insurance"]}),
    ("Education & Certs",   {"patterns": [r"certificat", w("cert"), w("ckad"), w("cka"), w("diploma"), w("degree"), r"transcript", r"university", r"school.?report", r"school.?application", r"nursery", r"aws.?cert", r"kubernetes.?cert", r"\btraining\b", w("course"), w("marksheet"), w("mark.?sheet")]}),
    ("Manuals & Warranties",{"patterns": [w("manual"), r"warrant(y|ie)", r"user.?guide", r"instruction", r"datasheet", r"setup.?guide", r"schematic", r"dining.?table", r"assembly.?instruction"]}),
    ("Travel",              {"patterns": [r"itiner", r"boarding", w("flight"), r"ticket", w("hotel"), r"booking", r"reservation", r"airbnb", r"booking\.com", r"expedia", r"trainline", r"british.?airways", r"easyjet", r"ryanair", r"emirates", w("boardingpass"), r"boarding.?pass"]}),
    ("Work & Career",       {"patterns": [w("cv"), r"resume", r"payslip", r"payroll", r"salary", r"offer.?letter", r"reference.?letter", r"wisetech", r"employment", r"job.?application", r"appraisal", r"performance.?review"]}),
    ("Code Archives",       {"exts_with_patterns": ({".zip", ".tar", ".gz", ".tgz", ".7z", ".bz2", ".xz"}, [r"-master", r"-main(?![a-z])", r"source", w("src"), r"github\.com", r"release", w("v\d"), r"libraries?"])}),
    ("Books & Learning",    {
        "exts": [".epub", ".azw3", ".mobi", ".djvu"],
        "patterns": [
            # Common author-paper-style book naming
            r"\bo[''’]?reilly\b", r"\bpacktpub\b", r"\bmanning\b", r"\bapress\b",
            r"\bworlds.?worst.?pets\b", r"\bdavid.?walliams\b",
            r"\b(generative|llm|machine.?learning|deep.?learning).*\.(pdf|epub|azw3)$",
            # Author surname + initial pattern: "Lanham M.", "Phoenix J.", "Bahree A.", "Alammar J."
            r"/[A-Z][a-z]+\s+[A-Z]\.\s+",
            # Arduino reference/tutorial PDFs
            r"arduino.*tutorial", r"arduino.*reference",
            # Common book/study folder patterns
            r"/books?/", r"/ebooks?/", r"/reading/", r"/study/",
        ],
    }),
]


def is_excluded(path: Path) -> bool:
    name = path.name
    if name in EXCLUDE_FILES:
        return True
    if name.startswith("._") or name.startswith("~$"):
        return True
    suffix = path.suffix.lower()
    if suffix in MEDIA_EXT or suffix in CODE_EXT:
        return True
    # Hidden files (anything starting with . that isn't a doc)
    if name.startswith("."):
        return True
    # Leave-in-place: files under specified path fragments stay where they are
    full = str(path).lower()
    for frag in LEAVE_IN_PLACE_FRAGMENTS:
        if frag in full:
            return True
    return False


def is_inside_excluded_dir(path: Path, source_root: Path) -> bool:
    rel = path.relative_to(source_root)
    for part in rel.parts[:-1]:
        if part in EXCLUDE_DIRS or part.startswith("."):
            return True
    return False


def already_organized(path: Path) -> bool:
    """Skip files already inside a top-level category folder under ~/Documents.
    Uses the top-level component of each category path (e.g. 'Personal' from
    'Personal/passport') plus the static "Uncategorized" + the new-folder
    being processed itself."""
    try:
        rel = path.relative_to(DEST_ROOT)
    except ValueError:
        return False
    if not rel.parts:
        return False
    top = rel.parts[0]
    top_categories = {name.split("/")[0] for name, _ in RULES}
    return top in top_categories | {"Uncategorized"}


def classify(path: Path) -> str:
    name = path.name.lower()
    full = str(path).lower()
    suffix = path.suffix.lower()

    for cat, rule in RULES:
        # Pure extension match (Installers, etc.)
        if "exts" in rule:
            if suffix in {e.lower() for e in rule["exts"]}:
                return cat

        # Extension + pattern match (Code Archives — only archive files matching keywords)
        if "exts_with_patterns" in rule:
            exts, pats = rule["exts_with_patterns"]
            if suffix in {e.lower() for e in exts}:
                for p in pats:
                    if re.search(p, full):
                        return cat

        # Pattern-only match (most topical categories)
        if "patterns" in rule:
            for p in rule["patterns"]:
                if re.search(p, full):
                    return cat

    return "Uncategorized"


def walk(source_root: Path):
    if not source_root.is_dir():
        return
    for parent, dirs, files in os.walk(source_root):
        dirs[:] = [d for d in dirs if d not in EXCLUDE_DIRS and not d.startswith(".")]
        parent_p = Path(parent)
        for f in files:
            p = parent_p / f
            if not p.is_file():
                continue
            if is_excluded(p):
                continue
            if already_organized(p):
                continue
            yield p


def plan_target(src_path: Path, source_root: Path, category: str) -> Path:
    """Compute target path for a moved file, preserving immediate parent folder name."""
    rel = src_path.relative_to(source_root)
    # If file is directly at source root: target = DEST/<category>/<filename>
    if len(rel.parts) == 1:
        return DEST_ROOT / category / rel
    # Else: preserve the relative path under the category
    return DEST_ROOT / category / rel


def main():
    execute = "--execute" in sys.argv

    buckets: dict[str, list[tuple[Path, Path, Path]]] = defaultdict(list)
    skipped_excluded_root = 0

    for src_root in SOURCES:
        for p in walk(src_root):
            if is_inside_excluded_dir(p, src_root):
                skipped_excluded_root += 1
                continue
            cat = classify(p)
            target = plan_target(p, src_root, cat)
            buckets[cat].append((p, target, src_root))

    # Summary
    print("=" * 70)
    print("DOCUMENT CATEGORIZATION " + ("PLAN (DRY-RUN)" if not execute else "EXECUTING MOVES"))
    print("=" * 70)
    total_files = 0
    total_size = 0
    for cat in sorted(buckets.keys(), key=lambda k: -len(buckets[k])):
        items = buckets[cat]
        sz = sum(s.stat().st_size for s, _, _ in items if s.exists())
        total_files += len(items)
        total_size += sz
        print(f"\n## {cat}: {len(items)} files ({sz/1024/1024:.1f} MB)")
        # Sample up to 5 per category
        for src, tgt, _ in items[:5]:
            print(f"    {src}")
            print(f"      → {tgt}")
        if len(items) > 5:
            print(f"    ... and {len(items) - 5} more")

    print("\n" + "=" * 70)
    print(f"TOTAL: {total_files} files, {total_size/1024/1024:.1f} MB")
    print(f"Skipped (inside excluded dirs): {skipped_excluded_root}")
    print("=" * 70)

    # Save plan
    plan_path = Path("/tmp/doc_classification_plan.json")
    plan_data = {
        cat: [{"src": str(s), "target": str(t), "source_root": str(r)} for s, t, r in items]
        for cat, items in buckets.items()
    }
    with open(plan_path, "w") as out:
        json.dump(plan_data, out, indent=2)
    print(f"\nFull plan: {plan_path}")

    if not execute:
        print("\n(DRY-RUN. Re-run with --execute to actually move files.)")
        return

    # Execute moves
    print("\nExecuting moves...")
    moved = 0
    errors = []
    for cat, items in buckets.items():
        for src, tgt, _ in items:
            try:
                tgt.parent.mkdir(parents=True, exist_ok=True)
                if tgt.exists():
                    base = tgt.stem
                    suf = tgt.suffix
                    n = 1
                    while True:
                        new_tgt = tgt.parent / f"{base} ({n}){suf}"
                        if not new_tgt.exists():
                            tgt = new_tgt
                            break
                        n += 1
                shutil.move(str(src), str(tgt))
                moved += 1
            except Exception as e:
                errors.append((src, tgt, str(e)))
    print(f"Moved: {moved} files")
    if errors:
        print(f"Errors: {len(errors)}")
        for s, t, e in errors[:10]:
            print(f"  {s} → {t}: {e}")

    # Handle EXTRACT_INTO zips: extract contents into category folder, delete zip
    import zipfile
    for zip_path, category in EXTRACT_INTO.items():
        zp = Path(zip_path)
        if not zp.exists():
            print(f"\n[extract] missing, skip: {zp}")
            continue
        target_dir = DEST_ROOT / category
        target_dir.mkdir(parents=True, exist_ok=True)
        print(f"\n[extract] {zp} → {target_dir} (excluding __MACOSX and ._*)")
        extracted = 0
        with zipfile.ZipFile(zp) as zf:
            for info in zf.infolist():
                name = info.filename
                # Skip macOS metadata
                if "__MACOSX" in name or "/._" in name or name.startswith("._"):
                    continue
                if name.endswith("/"):
                    continue  # directory entry
                # Extract under target_dir
                dst = target_dir / name
                dst.parent.mkdir(parents=True, exist_ok=True)
                with zf.open(info) as src_f, open(dst, "wb") as out_f:
                    shutil.copyfileobj(src_f, out_f)
                extracted += 1
        print(f"[extract] {extracted} files extracted; deleting {zp}")
        zp.unlink()


if __name__ == "__main__":
    main()
