#!/usr/bin/env bash
# ============================================================
# report_mp4_mkv_dupes.sh (v1.0) | 22.01.2026
# Copyright Roman Glos
# Intel QSV HEVC Batch-Encoder mit Resume + Watch
# ============================================================
set -euo pipefail

# Report: findet Duplikate, bei denen sowohl
#   <name>.mp4 UND <name>.mkv existieren (gleicher Basename, gleicher Pfad)
# und erstellt:
# - Summary CSV pro Hauptordner
# - Details CSV mit allen Paaren (inkl. Groessen/Delta)
#
# Nutzung:
#   /scripts/report_mp4_mkv_dupes.sh                # default ROOT=/out
#   /scripts/report_mp4_mkv_dupes.sh /out /out/_state
#
# Output:
#   <OUTDIR>/dup_mp4_mkv_summary_<ts>.csv
#   <OUTDIR>/dup_mp4_mkv_details_<ts>.csv
#
# Hinweis:
# - "Hauptordner" = erstes Pfadsegment unter ROOT (z.B. Filme, Filmaufnahme, Serien)
# - Es wird NICHTS geloescht/verschoben.

ROOT="${1:-/out}"
ROOT="${ROOT%/}"            # trailing slash weg
OUTDIR="${2:-$ROOT/_state}"

TS="$(date +%Y%m%d_%H%M%S)"
SUMMARY_CSV="$OUTDIR/dup_mp4_mkv_summary_${TS}.csv"
DETAILS_CSV="$OUTDIR/dup_mp4_mkv_details_${TS}.csv"

mkdir -p "$OUTDIR"

only_digits() { echo -n "${1:-}" | tr -cd '0-9'; }

file_size_bytes() {
  local f="$1"
  local s=""
  if command -v stat >/dev/null 2>&1; then
    s="$(stat -c %s "$f" 2>/dev/null || true)"
    [[ -z "$s" ]] && s="$(stat -f %z "$f" 2>/dev/null || true)"
  fi
  [[ -z "$s" ]] && s="$(wc -c < "$f" 2>/dev/null | tr -d ' ' || true)"
  s="$(only_digits "$s")"
  [[ -z "$s" ]] && s="0"
  echo -n "$s"
}

to_mb() {
  local b="${1:-0}"
  awk -v x="$b" 'BEGIN{ printf "%.3f", (x/1048576.0) }'
}

pct_delta() {
  local a="${1:-0}" # mp4
  local b="${2:-0}" # mkv
  awk -v a="$a" -v b="$b" 'BEGIN{
    if(a<=0){ print ""; exit }
    printf "%.2f", ((b/a)-1.0)*100.0
  }'
}

# relpath ohne fuehrenden Slash (wichtig!)
relpath() {
  local f="$1"
  local r
  if [[ "$f" == "$ROOT"/* ]]; then
    r="${f#"$ROOT"/}"
  else
    r="$f"
  fi
  r="${r#/}"               # fuehrende /
  # doppelte // reduzieren (best effort)
  while [[ "$r" == *"//"* ]]; do r="${r//\/\//\/}"; done
  echo -n "$r"
}

trim_ws() {
  # trims leading/trailing whitespace + CR; also removes newlines/tabs in key
  local s
  s="$(printf '%s' "${1:-}" | tr -d '\r' | tr '\n\t' '  ' )"
  s="$(printf '%s' "$s" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  echo -n "$s"
}

main_folder_of_rel() {
  local r
  r="$(trim_ws "${1:-}")"
  r="${r#/}"
  if [[ -z "$r" ]]; then
    echo -n "(root)"
    return 0
  fi
  if [[ "$r" == *"/"* ]]; then
    local first="${r%%/*}"
    first="$(trim_ws "$first")"
    [[ -z "$first" ]] && first="(root)"
    echo -n "$first"
  else
    echo -n "(root)"
  fi
}

# Case-insensitive extension strip
strip_mp4_ext() { local f="$1"; echo -n "${f%.[mM][pP]4}"; }
strip_mkv_ext() { local f="$1"; echo -n "${f%.[mM][kK][vV]}"; }

declare -A MKV_MAP

# Index aller MKVs (Basename ohne .mkv)
while IFS= read -r -d '' mkv; do
  base="$(strip_mkv_ext "$mkv")"
  MKV_MAP["$base"]="$mkv"
done < <(find "$ROOT" -type f -iname "*.mkv" -print0)

declare -A CNT
declare -A SUM_MP4
declare -A SUM_MKV

echo "main_folder,mp4_rel,mp4_mb,mkv_rel,mkv_mb,delta_pct" > "$DETAILS_CSV"

# Scan MP4s und matchen
while IFS= read -r -d '' mp4; do
  base="$(strip_mp4_ext "$mp4")"
  mkv="${MKV_MAP[$base]:-}"
  [[ -z "$mkv" ]] && continue

  mp4_rel="$(relpath "$mp4")"
  mkv_rel="$(relpath "$mkv")"

  main="$(main_folder_of_rel "$mp4_rel")"
  main="$(trim_ws "$main")"
  [[ -z "$main" ]] && main="(root)"

  mp4_b="$(file_size_bytes "$mp4")"
  mkv_b="$(file_size_bytes "$mkv")"

  mp4_mb="$(to_mb "$mp4_b")"
  mkv_mb="$(to_mb "$mkv_b")"
  d_pct="$(pct_delta "$mp4_b" "$mkv_b")"

  printf '"%s","%s",%s,"%s",%s,%s\n' \
    "$main" "$mp4_rel" "$mp4_mb" "$mkv_rel" "$mkv_mb" "${d_pct:-}" >> "$DETAILS_CSV"

  CNT["$main"]=$(( ${CNT["$main"]:-0} + 1 ))
  SUM_MP4["$main"]=$(( ${SUM_MP4["$main"]:-0} + mp4_b ))
  SUM_MKV["$main"]=$(( ${SUM_MKV["$main"]:-0} + mkv_b ))
done < <(find "$ROOT" -type f -iname "*.mp4" -print0)

echo "main_folder,dupe_count,total_mp4_mb,total_mkv_mb,delta_pct_total" > "$SUMMARY_CSV"

mapfile -t KEYS < <(printf "%s\n" "${!CNT[@]}" | sort)

for k in "${KEYS[@]}"; do
  k="$(trim_ws "$k")"
  [[ -z "$k" ]] && continue
  c="${CNT["$k"]:-0}"
  mp4_sum_b="${SUM_MP4["$k"]:-0}"
  mkv_sum_b="${SUM_MKV["$k"]:-0}"
  mp4_sum_mb="$(to_mb "$mp4_sum_b")"
  mkv_sum_mb="$(to_mb "$mkv_sum_b")"
  total_delta="$(pct_delta "$mp4_sum_b" "$mkv_sum_b")"
  printf '"%s",%s,%s,%s,%s\n' \
    "$k" "$c" "$mp4_sum_mb" "$mkv_sum_mb" "${total_delta:-}" >> "$SUMMARY_CSV"
done

echo "OK:"
echo "  $SUMMARY_CSV"
echo "  $DETAILS_CSV"
