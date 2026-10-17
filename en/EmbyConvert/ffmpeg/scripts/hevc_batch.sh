#!/usr/bin/env bash
# ============================================================
# hevc_batch.sh (v7.6.8) | 2026-01-22
# Copyright Roman Glos
# Intel QSV HEVC Batch-Encoder mit Resume + Watch
# ============================================================

# Wenn das Script (fälschlich) mit /bin/sh gestartet wird, re-exec in bash.
if [[ -z "${BASH_VERSION:-}" ]]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  fi
  echo "ERROR: bash is not available, but this script requires bash." >&2
  exit 1
fi

set -euo pipefail

# ---------------------------
# Defaults / Settings
# ---------------------------
IN_ROOT="${IN_ROOT:-/in}"
OUT_ROOT="${OUT_ROOT:-/out}"

# QSV Qualität (ICQ): kleiner = besser, aber potentiell größer.
GQ="${GQ:-18}"
PRESET="${PRESET:-slow}"

# Bitratenmodus (für H264/H265->HEVC Standard-Encode):
# - auto: Zielbitrate aus Quelle schätzen und mit BITRATE_FACTOR multiplizieren
# - same: stream.bit_rate benutzen (wenn fehlt -> quality fallback)
# - quality: nur global_quality nutzen
RATE_MODE="${RATE_MODE:-auto}"            # auto|same|quality
BITRATE_FACTOR="${BITRATE_FACTOR:-0.95}"
MIN_VBPS="${MIN_VBPS:-250000}"
MAX_VBPS="${MAX_VBPS:-0}"                 # 0 = kein Limit

# Optional: "Hybrid" = erst ICQ, dann Bitrate-Fallback (Option A)
HYBRID_ENCODE="${HYBRID_ENCODE:-1}"        # 0|1
HYBRID_ICQ_TRIES="${HYBRID_ICQ_TRIES:-3}"  # wie oft ICQ probieren, bevor auf Bitrate-Fallback gewechselt wird
HYBRID_ICQ_STEP="${HYBRID_ICQ_STEP:-1}"    # pro Versuch ICQ erhöhen (mehr Kompression)
HYBRID_ICQ_MAX="${HYBRID_ICQ_MAX:-26}"     # harte Grenze

# Timestamp Handling (YouTube/VFR etc.)
FPS_MODE="${FPS_MODE:-vfr}"
GENPTS="${GENPTS:-1}"
IGNDTS="${IGNDTS:-1}"
AVOID_NEG_TS="${AVOID_NEG_TS:-make_zero}"

PROBESIZE="${PROBESIZE:-20M}"
ANALYZEDURATION="${ANALYZEDURATION:-20M}"

HW_DECODE="${HW_DECODE:-0}"
QSV_DEVICE="${QSV_DEVICE:-/dev/dri/renderD128}"

# Skip-Regeln
SKIP_4K="${SKIP_4K:-1}"                    # >1080p skip
SKIP_DOLBY_VISION="${SKIP_DOLBY_VISION:-1}"
SKIP_HDR="${SKIP_HDR:-1}"

# HEVC Handling:
# REMUX_HEVC=0: HEVC standardmäßig überspringen
# REMUX_HEVC=1: HEVC remux/copy nach MKV (nur wenn Output noch nicht existiert)
REMUX_HEVC="${REMUX_HEVC:-0}"

KEEP_ALL_VIDEO_STREAMS="${KEEP_ALL_VIDEO_STREAMS:-0}"  # 0=nur v:0, 1=alle Video-Streams mappen (v:0 wird encodiert)

# Audio Policy
AUDIO_GERMAN_ONLY="${AUDIO_GERMAN_ONLY:-0}"            # 0=alle Audiospuren behalten, 1=nur Deutsch (wenn eindeutig, sonst SKIP)

# Exclude dirs (kommagetrennt)
EXCLUDE_DIRS="${EXCLUDE_DIRS:-#recycle,@eaDir}"

# Size-Guard
SIZE_GUARD="${SIZE_GUARD:-1}"
ALLOW_SIZE_GROW_PCT="${ALLOW_SIZE_GROW_PCT:-0}"          # 0% = Output darf NICHT größer sein (empfohlen)
SIZE_GUARD_ACTION="${SIZE_GUARD_ACTION:-retry}"          # keep|skip|retry
SIZE_GUARD_MAX_TRIES="${SIZE_GUARD_MAX_TRIES:-6}"
SIZE_GUARD_FACTOR_STEP="${SIZE_GUARD_FACTOR_STEP:-0.95}" # pro Retry Faktor * STEP

# Integritäts-Checks
STRICT_INPUT="${STRICT_INPUT:-1}"                         # 0|1
VERIFY_OUTPUT="${VERIFY_OUTPUT:-1}"                       # 0|1
CORRUPT_PATTERNS="${CORRUPT_PATTERNS:-Truncating packet|File ended prematurely|invalid as first byte of an EBML number|EBML header parsing failed|Invalid data found when processing input|moov atom not found|error reading|Error reading|Could not find codec parameters|Invalid NAL unit|I/O error}"

# HEVC Re-Encode (optional)
REENCODE_HEVC="${REENCODE_HEVC:-0}"                       # 0|1  (0 = nur Kandidatenliste schreiben)
HEVC_MIN_SIZE_GB="${HEVC_MIN_SIZE_GB:-10}"                # ab dieser Größe immer Kandidat
HEVC_MIN_VBPS_1080P="${HEVC_MIN_VBPS_1080P:-9000000}"     # 1080p Kandidat wenn vbps darüber
HEVC_MIN_VBPS_720P="${HEVC_MIN_VBPS_720P:-5000000}"       # <=720p Kandidat wenn vbps darüber
HEVC_MIN_SAVINGS_PCT="${HEVC_MIN_SAVINGS_PCT:-10}"        # Output muss mind. X% kleiner sein
HEVC_REENCODE_GQ_START="${HEVC_REENCODE_GQ_START:-20}"
HEVC_REENCODE_GQ_MAX="${HEVC_REENCODE_GQ_MAX:-24}"
HEVC_REENCODE_GQ_STEP="${HEVC_REENCODE_GQ_STEP:-1}"

# Optional VMAF Sample Check (nur wenn libvmaf verfügbar)
VMAF_CHECK="${VMAF_CHECK:-0}"                             # 0|1
VMAF_MIN="${VMAF_MIN:-97}"                                # konservativ
VMAF_SAMPLE_SEC="${VMAF_SAMPLE_SEC:-30}"
VMAF_SAMPLES="${VMAF_SAMPLES:-0.1,0.5,0.9}"              # relative Positionen (0..1)

# Logging/Runtime
FFMPEG_LOGLEVEL="${FFMPEG_LOGLEVEL:-error}"
FFMPEG_NOSTATS="${FFMPEG_NOSTATS:-1}"
DRY_RUN="${DRY_RUN:-0}"

RESUME="${RESUME:-1}"
REBUILD_MANIFEST="${REBUILD_MANIFEST:-0}"
WATCH="${WATCH:-0}"
WAIT_SEC="${WAIT_SEC:-300}"
OVERWRITE="${OVERWRITE:-0}"
SUBDIR="${SUBDIR:-}"

# Logging dirs
LOG_DIR="$OUT_ROOT/_ffmpeg_logs"
STATE_DIR="$OUT_ROOT/_state"
mkdir -p "$LOG_DIR" "$STATE_DIR"

LOG_FILE_DEFAULT="$LOG_DIR/hevc_batch_$(date +%Y%m%d_%H%M%S).log"
LOG_FILE="$LOG_FILE_DEFAULT"

MANIFEST_FILE="$STATE_DIR/manifest_ROOT.txt"
PROGRESS_FILE="$STATE_DIR/progress_ROOT.txt"
LOCK_FILE="$STATE_DIR/lock_ROOT"

SKIPLIST_LARGER_FILE="$STATE_DIR/skip_larger.txt"
SKIPLIST_CORRUPT_INPUT_FILE="$STATE_DIR/skip_corrupt_input.txt"
SKIPLIST_BAD_OUTPUT_FILE="$STATE_DIR/skip_bad_output.txt"
SKIPLIST_FAILED_FILE="$STATE_DIR/skip_failed.txt"
SKIPLIST_AUDIO_AMBIG_FILE="$STATE_DIR/skip_audio_ambiguous.txt"

HEVC_CAND_FILE="$STATE_DIR/hevc_reencode_candidates.csv"

touch "$SKIPLIST_LARGER_FILE" "$SKIPLIST_CORRUPT_INPUT_FILE" "$SKIPLIST_BAD_OUTPUT_FILE" "$SKIPLIST_FAILED_FILE" "$SKIPLIST_AUDIO_AMBIG_FILE" 2>/dev/null || true

ts() { date '+%F %T'; }
log() { echo "[$(ts)] $*" | tee -a "$LOG_FILE"; }

run_cmd() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log "DRY-RUN: $*"
    return 0
  fi
  set +e
  if [[ "${FFMPEG_NOSTATS:-1}" == "1" ]]; then
    "$@" 2>&1 | sed -u '/^frame=.*fps=.*q=.*size=.*time=.*bitrate=.*speed=.*/d' | tee -a "$LOG_FILE"
  else
    "$@" 2>&1 | tee -a "$LOG_FILE"
  fi
  local rc=${PIPESTATUS[0]}
  set -e
  return "$rc"
}

first_line() { awk 'NR==1{print; exit}'; }
only_digits() { echo -n "${1:-}" | tr -cd '0-9'; }

normalize_codec() {
  local s
  s="$(echo -n "${1:-}" | tr -d '\r' | tr '[:upper:]' '[:lower:]' | sed -e 's/[[:space:]]*$//' -e 's/[[:space:],]*$//')"
  echo -n "$s"
}

normalize_lang() {
  # Normalisiert ISO-639 / freie Sprachtags auf kurze, vergleichbare Form (z.B. deu/ger/german -> de).
  local s
  s="$(echo -n "${1:-}" | tr -d '\r' | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

  # nur "token" bis zum ersten Sonderzeichen/Leerzeichen behalten
  s="$(echo -n "$s" | sed -E 's/[^a-z0-9_-].*$//')"

  case "$s" in
    de|deu|ger|german|de-de|de_de|deutsch) echo -n "de" ;;
    und|unk|unknown|'?')                  echo -n "und" ;;
    en|eng|english)                       echo -n "en" ;;
    fr|fra|fre|french)                    echo -n "fr" ;;
    es|spa|spanish)                       echo -n "es" ;;
    it|ita|italian)                       echo -n "it" ;;
    *)
      # z.B. de-at / deu-de -> de
      if [[ "$s" == de* ]]; then
        echo -n "de"
      else
        echo -n "$s"
      fi
      ;;
  esac
}


# Subtitle-Kompatibilität:
# MP4/QuickTime Text-Subs ("mov_text") können NICHT direkt in MKV kopiert werden.
# Lösung: Bei Erkennung -> Subtitles nach SRT transcodieren.
set_subtitle_args() {
  # Für MP4/M4V/MOV: mov_text/tx3g/webvtt sind in MKV nicht direkt unterstützt -> zu SRT konvertieren.
  # SUB_ARGS wird pro Datei gesetzt und später nach '-c copy' angehängt.
  local f="$1"
  local ext_lc="${2:-}"
  local rel="${3:-}"
  SUB_ARGS=()

  case "$ext_lc" in
    mp4|m4v|mov) ;;
    *) return 0 ;;
  esac

  local idx=0 codec need=0
  while IFS= read -r codec; do
    codec="$(normalize_codec "$codec")"
    [[ -z "$codec" ]] && continue
    case "$codec" in
      mov_text|tx3g|webvtt)
        SUB_ARGS+=("-c:s:${idx}" "srt")
        need=1
        ;;
      *) : ;;
    esac
    idx=$((idx+1))
  done < <(ffprobe -v error -select_streams s -show_entries stream=codec_name -of default=nw=1:nk=1 "$f" 2>/dev/null || true)

  if [[ "$need" == "1" ]]; then
    log "  SUBS: Konvertiere MP4-Text-Untertitel zu SRT (mov_text/tx3g/webvtt): ${rel:-$f}"
  fi
  return 0
}


array_contains() {
  local needle="$1"; shift
  local x
  for x in "$@"; do
    [[ "$x" == "$needle" ]] && return 0
  done
  return 1
}


is_hevc_codec() {
  local c
  c="$(normalize_codec "$1")"
  [[ "$c" == "hevc" || "$c" == "h265" || "$c" == "h.265" || "$c" == *"hevc"* || "$c" == *"h265"* ]]
}

# ---------------------------
# Excludes
# ---------------------------
EXCL_ARR=()
read_excludes() {
  local raw="${EXCLUDE_DIRS:-}"
  # remove optional surrounding quotes
  raw="${raw%\"}"; raw="${raw#\"}"
  raw="${raw%\'}"; raw="${raw#\'}"
  local IFS=',' part
  EXCL_ARR=()
  for part in $raw; do
    part="$(echo -n "$part" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    part="${part%\"}"; part="${part#\"}"
    part="${part%\'}"; part="${part#\'}"
    [[ -z "$part" ]] && continue
    EXCL_ARR+=("$part")
  done
}
read_excludes

path_is_excluded() {
  local p="$1" d
  for d in "${EXCL_ARR[@]}"; do
    [[ -z "$d" ]] && continue
    if [[ "$p" == *"/$d/"* || "$p" == "$d/"* || "$p" == *"/$d" || "$p" == "$d" ]]; then
      return 0
    fi
  done
  return 1
}

# ---------------------------
# ffprobe helpers
# ---------------------------
get_vcodec() {
  local v
  v="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$1" 2>/dev/null | first_line || true)"
  echo -n "$(normalize_codec "$v")"
}
get_width() {
  local w
  w="$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=nw=1:nk=1 "$1" 2>/dev/null | first_line || true)"
  echo -n "$(only_digits "$w")"
}
get_height() {
  local h
  h="$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=nw=1:nk=1 "$1" 2>/dev/null | first_line || true)"
  echo -n "$(only_digits "$h")"
}
get_stream_bitrate() {
  local b
  b="$(ffprobe -v error -select_streams "$2" -show_entries stream=bit_rate -of default=nw=1:nk=1 "$1" 2>/dev/null | first_line || true)"
  echo -n "$(only_digits "$b")"
}
get_duration_sec() {
  local d
  d="$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$1" 2>/dev/null | first_line || true)"
  echo -n "$(echo -n "$d" | tr -cd '0-9.')"
}
get_primary_video_duration_sec() {
  # Container duration may include longer audio that the audio policy removes.
  # Read v:0 packet timestamps: this also works when MKV stream.duration is N/A.
  # Presentation order can differ from packet order, and remuxing can shift PTS.
  ffprobe -v error -select_streams v:0 \
    -show_entries packet=pts_time,duration_time -of compact=p=0:nk=0 "$1" 2>/dev/null \
    | LC_ALL=C awk -F '|' '
      BEGIN { number="^-?[0-9]+([.][0-9]+)?$" }
      NF {
        pts=""; duration="";
        for (i=1; i<=NF; i++) {
          split($i, field, "=");
          if (field[1]=="pts_time") pts=field[2];
          if (field[1]=="duration_time") duration=field[2];
        }
        if (pts !~ number) { invalid=1; next }
        pts+=0;
        duration=(duration ~ number && duration+0 > 0) ? duration+0 : 0;
        if (!count || pts < first) first=pts;
        if (!count || pts > latest) latest=pts;
        if (!count || pts+duration > end) end=pts+duration;
        count++;
      }
      END {
        # Without a known final packet duration, do not guess the video end.
        if (invalid || !count || end <= latest || end <= first) exit 1;
        printf "%.6f", end-first;
      }'
}
get_filesize_bytes() {
  local s=""
  if command -v stat >/dev/null 2>&1; then
    s="$(stat -c %s "$1" 2>/dev/null || true)"
    [[ -z "$s" ]] && s="$(stat -f %z "$1" 2>/dev/null || true)"
  fi
  [[ -z "$s" ]] && s="$(wc -c < "$1" 2>/dev/null | tr -d ' ' || true)"
  echo -n "$(only_digits "$s")"
}

sum_audio_bitrate() {
  local f="$1"
  local sum=0 any=0 b
  while IFS= read -r b; do
    b="$(only_digits "$b")"
    if [[ -n "$b" && "$b" -gt 0 ]]; then
      sum=$((sum + b))
      any=1
    fi
  done < <(ffprobe -v error -select_streams a -show_entries stream=bit_rate -of default=nw=1:nk=1 "$f" 2>/dev/null || true)
  [[ "$any" == "1" ]] && echo -n "$sum" || echo -n ""
}

estimate_video_bitrate() {
  local f="$1"
  local vb
  vb="$(get_stream_bitrate "$f" "v:0")"
  if [[ -n "$vb" && "$vb" -gt 0 ]]; then
    echo -n "$vb"
    return 0
  fi
  local dur size ab total_bps out
  dur="$(get_duration_sec "$f")"
  size="$(get_filesize_bytes "$f")"
  ab="$(sum_audio_bitrate "$f")"
  [[ -z "$ab" ]] && ab="384000"

  if [[ -n "$dur" && -n "$size" && "$size" -gt 0 ]]; then
    total_bps="$(awk -v s="$size" -v d="$dur" 'BEGIN{ if(d>0) printf "%.0f", (s*8)/d; else print "" }')"
    total_bps="$(only_digits "$total_bps")"
    if [[ -n "$total_bps" && "$total_bps" -gt 0 ]]; then
      out=$((total_bps - ab))
      [[ "$out" -lt "$MIN_VBPS" ]] && out="$MIN_VBPS"
      echo -n "$out"
      return 0
    fi
  fi
  echo -n ""
}

calc_target_vbps() {
  local src_vbps="$1" factor="$2" out
  out="$(awk -v b="$src_vbps" -v f="$factor" 'BEGIN{printf "%.0f", b*f}')"
  out="$(only_digits "$out")"
  [[ -z "$out" || "$out" -le 0 ]] && out="$MIN_VBPS"
  [[ "$out" -lt "$MIN_VBPS" ]] && out="$MIN_VBPS"
  if [[ "$MAX_VBPS" -gt 0 && "$out" -gt "$MAX_VBPS" ]]; then out="$MAX_VBPS"; fi
  echo -n "$out"
}

# Dolby Vision / HDR detection (best effort)
is_dolby_vision() {
  local f="$1" sd
  sd="$(ffprobe -v error -select_streams v:0 -show_entries stream=side_data_list -of json "$f" 2>/dev/null || true)"
  echo "$sd" | grep -qiE 'DOVI|dovi|dolby' && return 0
  return 1
}
is_hdr() {
  local f="$1" p
  p="$(ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer,color_primaries,color_space,side_data_list -of default=nw=1 "$f" 2>/dev/null || true)"
  echo "$p" | grep -qiE 'smpte2084|arib-std-b67|bt2020' && return 0
  return 1
}

# ---------------------------
# Integrity scan (ffmpeg)
# ---------------------------
ffmpeg_scan_corruption() {
  local f="$1"
  local scope="${2:-input}"   # input|output
  local out rc ll="warning"
  local -a decode_args=() map_args=(-map 0 -c copy)
  if [[ "$scope" == "output" ]]; then
    ll="error"
    # Decode every video/audio stream. Stream copy only checks the container.
    decode_args=(-xerror -err_detect explode)
    map_args=(-map 0:v -map '0:a?')
  fi

  if out="$(
    ffmpeg -hide_banner -nostdin -nostats -loglevel "$ll" \
      -probesize "$PROBESIZE" -analyzeduration "$ANALYZEDURATION" \
      -fflags +genpts -fflags +igndts "${decode_args[@]}" \
      -i "$f" "${map_args[@]}" -f null - 2>&1 >/dev/null
  )"; then
    rc=0
  else
    rc=$?
  fi

  [[ "$rc" -ne 0 ]] && return 1
  # Some FFmpeg builds log decoder errors but still exit successfully.
  [[ "$scope" == "output" && -n "$out" ]] && return 1
  echo "$out" | grep -Eiq "$CORRUPT_PATTERNS" && return 1
  return 0
}

verify_output() {
  local src="$1" out="$2" src_duration out_duration
  ffmpeg_scan_corruption "$out" "output" || return 1
  src_duration="$(get_primary_video_duration_sec "$src")" || return 1
  out_duration="$(get_primary_video_duration_sec "$out")" || return 1
  [[ "$src_duration" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
  [[ "$out_duration" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1

  # Permit timestamp/packet rounding: 1%, limited to 0.25 through 2 seconds.
  awk -v src="$src_duration" -v out="$out_duration" 'BEGIN {
    if (src <= 0 || out <= 0) exit 1;
    tolerance=src*0.01;
    if (tolerance < 0.25) tolerance=0.25;
    if (tolerance > 2) tolerance=2;
    difference=src-out;
    if (difference < 0) difference=-difference;
    exit (difference <= tolerance) ? 0 : 1;
  }'
}

# ---------------------------
# Audio selection
# ---------------------------
# returns lines "aidx,lang" (aidx = 0..n-1 in audio-stream order; lang may be empty)
list_audio_aidx_lang() {
  # Output: one line per Audio-Stream: "<audio_index>:<lang>"
  # WICHTIG: audio_index ist die *Audio-Ordinal* (0..), passend zu ffmpeg -map 0:a:<N>
  local f="$1"
  local i=0
  while IFS=',' read -r _idx lang; do
    lang="$(normalize_lang "$lang")"
    echo "${i}:${lang}"
    i=$((i+1))
  done < <(ffprobe -v error -select_streams a -show_entries stream=index:stream_tags=language -of csv=p=0 "$f" 2>/dev/null || true)
}


is_lang_german() {
  [[ "$(normalize_lang "${1:-}")" == "de" ]]
}

# Build ffmpeg map args for audio policy.
# Output: sets global array MAP_ARGS.
MAP_ARGS=()
# Extra Codec-Args (z.B. Subtitle-Transcode mov_text->srt bei MP4->MKV)
SUB_ARGS=()
build_map_args() {
  local f="$1"
  local ext_lc="$2"
  local keep_all_video="$3"

  # Für Log-Ausgaben: relpath (sicher, auch unter set -u)
  local rel=""
  rel="$(relpath_from_in "$f" 2>/dev/null || true)"
  [[ -z "$rel" ]] && rel="$f"

  MAP_ARGS=()
# Extra Codec-Args (z.B. Subtitle-Transcode mov_text->srt bei MP4->MKV)
SUB_ARGS=()

  # MKV: alles mappen (inkl. Attachments), Unknowns kopieren
  if [[ "$ext_lc" == "mkv" ]]; then
    MAP_ARGS+=(-map 0 -map_metadata 0 -map_chapters 0 -copy_unknown)
  else
    # Nicht-MKV (mp4/m4v/ts/m2ts/avi/mov/webm/...):
    # Nur Video/Audio/Subs mappen und Data-Streams droppen (-dn),
    # sonst schlagen TS/M2TS/MP4 mit Teletext/Data/Unknowns gern beim MKV-Mux fehl.
    if [[ "$keep_all_video" == "1" ]]; then
      MAP_ARGS+=(-map 0:v -map 0:a? -map 0:s? -map_metadata 0 -map_chapters 0 -dn)
    else
      MAP_ARGS+=(-map 0:v:0 -map 0:a? -map 0:s? -map_metadata 0 -map_chapters 0 -dn)
    fi
  fi

  # --- Audio-Policy: Nur Deutsch behalten, wenn >1 Audio-Stream vorhanden
  # Wenn Audio-Tags nicht eindeutig sind -> SKIP (damit wir nichts falsch wegwerfen)
  if [[ "${AUDIO_GERMAN_ONLY:-0}" == "1" ]]; then
    local -a aud_lines=()
    mapfile -t aud_lines < <(list_audio_aidx_lang "$f")
    local acnt="${#aud_lines[@]}"

    # Wenn nur 0/1 Audio-Streams: immer behalten (wie gewünscht)
    if [[ "$acnt" -gt 1 ]]; then
      local any_amb=0
      local -a all_aidx=()
      local -a german_aidx=()

      local line aidx lang
      for line in "${aud_lines[@]}"; do
        aidx="${line%%:*}"
        lang="${line#*:}"
        [[ -z "$aidx" ]] && continue

        all_aidx+=("$aidx")

        lang="$(normalize_lang "$lang")"
        if [[ -z "$lang" || "$lang" == "und" ]]; then
          any_amb=1
        fi

        if is_lang_german "$lang"; then
          german_aidx+=("$aidx")
        fi
      done

      if [[ "$any_amb" == "1" ]]; then
        log "SKIP (audio ambiguous/unknown tags -> cannot safely enforce German-only): $rel"
        return 2
      fi

      if [[ "${#german_aidx[@]}" -lt 1 ]]; then
        log "SKIP (no German audio track found, but German-only is enabled): $rel"
        return 2
      fi

      # Entferne alle nicht-deutschen Audiospuren, aber behalte sonst alles (Subs/Metadata/Attachments).
      local idx
      for idx in "${all_aidx[@]}"; do
        if ! array_contains "$idx" "${german_aidx[@]}"; then
          MAP_ARGS+=(-map "-0:a:${idx}")
        fi
      done
    fi
  fi


  # Subtitle-Fix für MP4/M4V/MOV (mov_text/tx3g/webvtt -> SRT in MKV)
  set_subtitle_args "$f" "$ext_lc" "$rel" || true

  return 0
}


# ---------------------------
# VMAF sample check (optional)
# ---------------------------
have_vmaf_filter() {
  ffmpeg -hide_banner -filters 2>/dev/null | grep -qiE '^\s*libvmaf\s' && return 0
  return 1
}

vmaf_sample_check() {
  # Returns 0 if ok, 1 if below threshold or failed.
  local src="$1" out="$2"
  [[ "$VMAF_CHECK" != "1" ]] && return 0
  have_vmaf_filter || { log "  VMAF: libvmaf not available -> skipping VMAF check"; return 0; }

  local tmpvmaf="$STATE_DIR/vmaf_$$.log"
  rm -f "$tmpvmaf" 2>/dev/null || true

  # Sample positions are relative; we run for each sample a short comparison.
  local dur
  dur="$(get_duration_sec "$src")"
  dur="${dur:-}"
  if [[ -z "$dur" ]]; then
    log "  VMAF: duration unknown -> skipping VMAF check"
    return 0
  fi

  local IFS=',' p
  local worst=999.0
  for p in $VMAF_SAMPLES; do
    p="$(echo -n "$p" | tr -cd '0-9.')"
    [[ -z "$p" ]] && continue
    local start
    start="$(awk -v d="$dur" -v r="$p" 'BEGIN{ s=d*r; if(s<0) s=0; printf "%.3f", s }')"
    log "  VMAF: sample at ${start}s for ${VMAF_SAMPLE_SEC}s"
    set +e
    ffmpeg -hide_banner -nostdin -loglevel error \
      -ss "$start" -t "$VMAF_SAMPLE_SEC" -i "$src" \
      -ss "$start" -t "$VMAF_SAMPLE_SEC" -i "$out" \
      -lavfi "libvmaf=log_path=${tmpvmaf}:log_fmt=json" -f null - >/dev/null 2>&1
    local rc=$?
    set -e
    if [[ "$rc" -ne 0 || ! -s "$tmpvmaf" ]]; then
      log "  VMAF: measurement failed -> skipping VMAF check"
      rm -f "$tmpvmaf" 2>/dev/null || true
      return 0
    fi

    # Extract last "vmaf" value from json (simple grep/sed; robust enough for our use)
    local v
    v="$(grep -oE '"vmaf"[[:space:]]*:[[:space:]]*[0-9]+\.[0-9]+' "$tmpvmaf" | tail -n 1 | grep -oE '[0-9]+\.[0-9]+' || true)"
    rm -f "$tmpvmaf" 2>/dev/null || true
    if [[ -z "$v" ]]; then
      log "  VMAF: value not found -> skipping VMAF check"
      return 0
    fi
    worst="$(awk -v a="$worst" -v b="$v" 'BEGIN{ if(b<a) printf "%.3f", b; else printf "%.3f", a }')"
  done

  log "  VMAF: worst=${worst} (min=${VMAF_MIN})"
  awk -v w="$worst" -v m="$VMAF_MIN" 'BEGIN{ exit (w+0 < m+0) ? 1 : 0 }'
}

# ---------------------------
# lock
# ---------------------------
acquire_lock() {
  if [[ -f "$LOCK_FILE" ]]; then
    local pid
    pid="$(cat "$LOCK_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      log "Lock present (pid=$pid) -> exiting (prevents double runner)"
      exit 0
    fi
  fi
  echo $$ > "$LOCK_FILE"
  trap 'rm -f "$LOCK_FILE" 2>/dev/null || true' EXIT
}

# ---------------------------
# Manifest
# ---------------------------
build_manifest() {
  local search_root="$IN_ROOT"
  [[ -n "$SUBDIR" ]] && search_root="$IN_ROOT/$SUBDIR"

  if [[ "$RESUME" == "1" && -f "$MANIFEST_FILE" && "$REBUILD_MANIFEST" != "1" ]]; then
    log "Resume enabled: using existing manifest: $MANIFEST_FILE"
    return 0
  fi

  log "Erzeuge Manifest: $MANIFEST_FILE (SEARCH_ROOT=$search_root)"
  : > "$MANIFEST_FILE"

  local find_cmd=(find "$search_root")
  if [[ "${#EXCL_ARR[@]}" -gt 0 ]]; then
    find_cmd+=( \( -type d \( )
    local idx
    for idx in "${!EXCL_ARR[@]}"; do
      find_cmd+=( -iname "${EXCL_ARR[$idx]}" )
      if [[ "$idx" -lt "$(( ${#EXCL_ARR[@]} - 1 ))" ]]; then
        find_cmd+=( -o )
      fi
    done
    find_cmd+=( \) -prune \) -o )
  fi
  find_cmd+=( -type f \( \
    -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.m4v' -o -iname '*.webm' -o -iname '*.avi' -o -iname '*.mov' -o -iname '*.ts' -o -iname '*.m2ts' \
  \) -print0 )

  while IFS= read -r -d '' f; do
    [[ -z "$f" ]] && continue
    path_is_excluded "$f" && continue
    echo "$f" >> "$MANIFEST_FILE"
  done < <("${find_cmd[@]}" 2>/dev/null | sort -z)

  local cnt
  cnt="$(wc -l < "$MANIFEST_FILE" | tr -d ' ')"
  log "Manifest created: $cnt files"
}

relpath_from_in() { echo -n "${1#"$IN_ROOT"/}"; }

# ---------------------------
# Size guard helper
# ---------------------------
size_guard_ok() {
  local in_f="$1" out_f="$2"
  local in_sz out_sz limit pct
  in_sz="$(get_filesize_bytes "$in_f")"
  out_sz="$(get_filesize_bytes "$out_f")"
  [[ -z "$in_sz" || -z "$out_sz" || "$in_sz" -le 0 || "$out_sz" -le 0 ]] && return 0
  limit="$(awk -v s="$in_sz" -v p="$ALLOW_SIZE_GROW_PCT" 'BEGIN{printf "%.0f", s*(1+(p/100.0))}')"
  limit="$(only_digits "$limit")"
  [[ -z "$limit" || "$limit" -le 0 ]] && return 0
  if [[ "$out_sz" -le "$limit" ]]; then
    return 0
  fi
  pct="$(awk -v o="$out_sz" -v i="$in_sz" 'BEGIN{printf "%.1f", (o/i-1)*100.0}')"
  log "  SIZE-GUARD: output too large (+${pct}%). in=$in_sz out=$out_sz limit=$limit"
  return 1
}

min_savings_ok() {
  # output must be at least X% smaller than input
  local in_f="$1" out_f="$2" pct_req="$3"
  local in_sz out_sz
  in_sz="$(get_filesize_bytes "$in_f")"
  out_sz="$(get_filesize_bytes "$out_f")"
  [[ -z "$in_sz" || -z "$out_sz" || "$in_sz" -le 0 || "$out_sz" -le 0 ]] && return 1
  awk -v i="$in_sz" -v o="$out_sz" -v p="$pct_req" 'BEGIN{
    need=i*(1-(p/100.0));
    exit (o <= need) ? 0 : 1
  }'
}

# ---------------------------
# HEVC candidate detection
# ---------------------------
bytes_to_gb() {
  awk -v b="$1" 'BEGIN{printf "%.2f", (b/1024/1024/1024)}'
}

is_hevc_candidate() {
  local f="$1" w="$2" h="$3"
  local sz vbps reason=""
  sz="$(get_filesize_bytes "$f")"
  vbps="$(estimate_video_bitrate "$f")"
  local gb
  gb="$(bytes_to_gb "${sz:-0}")"

  if awk -v g="$gb" -v t="$HEVC_MIN_SIZE_GB" 'BEGIN{exit (g+0 >= t+0)?0:1}'; then
    reason="size>=${HEVC_MIN_SIZE_GB}GB"
  else
    if [[ -n "$vbps" ]]; then
      if [[ "$h" -ge 900 ]]; then
        [[ "$vbps" -ge "$HEVC_MIN_VBPS_1080P" ]] && reason="vbps>=${HEVC_MIN_VBPS_1080P}(1080p)"
      else
        [[ "$vbps" -ge "$HEVC_MIN_VBPS_720P" ]] && reason="vbps>=${HEVC_MIN_VBPS_720P}(<=720p)"
      fi
    fi
  fi

  [[ -n "$reason" ]] && echo -n "$reason" && return 0
  return 1
}

write_hevc_candidate() {
  local rel="$1" f="$2" w="$3" h="$4" reason="$5"
  local sz vbps gb
  sz="$(get_filesize_bytes "$f")"
  vbps="$(estimate_video_bitrate "$f")"
  gb="$(bytes_to_gb "${sz:-0}")"
  if [[ ! -f "$HEVC_CAND_FILE" ]]; then
    echo "relpath,width,height,video_bps,size_gb,reason" > "$HEVC_CAND_FILE"
  fi
  echo "\"$rel\",$w,$h,${vbps:-},$gb,\"$reason\"" >> "$HEVC_CAND_FILE"
}

# ---------------------------
# Encoding helpers
# ---------------------------
qsv_common_args() {
  # Writes common args into global array QSV_ARGS
  QSV_ARGS=()
  QSV_ARGS+=( -hide_banner -y -nostdin -loglevel "$FFMPEG_LOGLEVEL" )
  QSV_ARGS+=( -probesize "$PROBESIZE" -analyzeduration "$ANALYZEDURATION" )
  [[ "$GENPTS" == "1" ]] && QSV_ARGS+=( -fflags +genpts )
  [[ "$IGNDTS" == "1" ]] && QSV_ARGS+=( -fflags +igndts )
  if [[ "$HW_DECODE" == "1" ]]; then
    QSV_ARGS+=( -hwaccel qsv -qsv_device "$QSV_DEVICE" )
  fi
}

encode_hevc_qsv_to_tmp() {
  # Params: src, tmp, mode, gq, target_vbps, ext_lc
  local src="$1" tmp="$2" mode="$3" gq="$4" tvbps="${5:-}" ext_lc="$6"
  local -a args
  qsv_common_args
  args=(ffmpeg "${QSV_ARGS[@]}" -i "$src")

  # mapping
  if ! build_map_args "$src" "$ext_lc" "$KEEP_ALL_VIDEO_STREAMS"; then
    return 2  # audio ambiguous
  fi
  args+=("${MAP_ARGS[@]}")

  # codecs: default copy, but reencode v:0
  args+=(-c copy)
  args+=("${SUB_ARGS[@]}")
  args+=(-c:v:0 hevc_qsv -preset "$PRESET" -fps_mode:v:0 "$FPS_MODE")
  args+=(-max_muxing_queue_size 4096 -avoid_negative_ts "$AVOID_NEG_TS")

  if [[ "$mode" == "quality" ]]; then
    args+=(-global_quality "$gq")
  else
    args+=(-b:v:0 "$tvbps" -maxrate:v:0 "$tvbps" -bufsize:v:0 "$((tvbps*2))")
  fi

  args+=("$tmp")
  run_cmd "${args[@]}"
}

# ---------------------------
# Main per-file
# ---------------------------
process_one() {
  local f="$1"
  local rel out tmp legacy_tmp ext_lc vcodec width height
  rel="$(relpath_from_in "$f")"

  # Excludes
  if path_is_excluded "$rel"; then
    log "SKIP (excluded dir): $rel"
    return 0
  fi

  out="$OUT_ROOT/${rel%.*}.mkv"
  tmp="${out}.tmp.mkv"
  legacy_tmp="${out}tmp.mkv"
  ext_lc="$(echo -n "${rel##*.}" | tr '[:upper:]' '[:lower:]')"

  # Subtitle-Fix (wichtig für Remux von MP4/M4V/MOV nach MKV)
  set_subtitle_args "$f" "$ext_lc" "$rel" || true


  mkdir -p "$(dirname "$out")"

  # stale tmp cleanup (nur wenn out noch nicht existiert)
  if [[ ! -f "$out" ]]; then
    rm -f "$tmp" "$legacy_tmp" 2>/dev/null || true
  fi

  if [[ -f "$out" && "$OVERWRITE" != "1" ]]; then
    log "SKIP (exists): $rel"
    return 0
  fi

  # skip-lists
  grep -Fxq "$rel" "$SKIPLIST_LARGER_FILE" 2>/dev/null && { log "SKIP (size-guard list): $rel"; return 0; }
  grep -Fxq "$rel" "$SKIPLIST_CORRUPT_INPUT_FILE" 2>/dev/null && { log "SKIP (corrupt input list): $rel"; return 0; }
  grep -Fxq "$rel" "$SKIPLIST_BAD_OUTPUT_FILE" 2>/dev/null && { log "SKIP (bad output list): $rel"; return 0; }
  grep -Fxq "$rel" "$SKIPLIST_FAILED_FILE" 2>/dev/null && { log "SKIP (failed list): $rel"; return 0; }
  grep -Fxq "$rel" "$SKIPLIST_AUDIO_AMBIG_FILE" 2>/dev/null && { log "SKIP (audio ambiguous list): $rel"; return 0; }

  vcodec="$(get_vcodec "$f")"
  width="$(get_width "$f")"
  height="$(get_height "$f")"
  if [[ -z "$vcodec" || -z "$width" || -z "$height" ]]; then
    log "SKIP (ffprobe failed): $rel (vcodec='$vcodec' width='$width' height='$height')"
    return 0
  fi

  # skip 4K/HDR/DV
  if [[ "$SKIP_4K" == "1" && ( "$height" -gt 1080 || "$width" -gt 1920 ) ]]; then
    log "SKIP (4K/>1080p): $rel (width=$width height=$height)"
    return 0
  fi
  if [[ "$SKIP_DOLBY_VISION" == "1" ]] && is_dolby_vision "$f"; then
    log "SKIP (Dolby Vision): $rel"
    return 0
  fi
  if [[ "$SKIP_HDR" == "1" ]] && is_hdr "$f"; then
    log "SKIP (HDR): $rel"
    return 0
  fi

  # STRICT_INPUT scan
  if [[ "$STRICT_INPUT" == "1" ]]; then
    if ! ffmpeg_scan_corruption "$f" "input"; then
      log "SKIP (corrupt input): $rel"
      echo "$rel" >> "$SKIPLIST_CORRUPT_INPUT_FILE" || true
      return 0
    fi
  fi

  # --------
  # HEVC Input handling
  # --------
  if is_hevc_codec "$vcodec"; then
    # Candidate detection + report
    local reason=""
    if reason="$(is_hevc_candidate "$f" "$width" "$height" "$vcodec")"; then
      write_hevc_candidate "$rel" "$f" "$width" "$height" "$reason"
    fi

    if [[ "$REENCODE_HEVC" != "1" ]]; then
      if [[ "$REMUX_HEVC" == "1" ]]; then
        log "REMUX (already HEVC): $rel -> ${out#"$OUT_ROOT"/}"
        rm -f "$tmp" 2>/dev/null || true
        if ! run_cmd ffmpeg -hide_banner -y -nostdin -loglevel "$FFMPEG_LOGLEVEL" \
          -probesize "$PROBESIZE" -analyzeduration "$ANALYZEDURATION" \
          -fflags +genpts -fflags +igndts \
          -i "$f" \
          -map 0 -map_metadata 0 -map_chapters 0 -copy_unknown \
          -c copy "${SUB_ARGS[@]}" -max_muxing_queue_size 4096 -avoid_negative_ts "$AVOID_NEG_TS" \
          "$tmp"; then
          rm -f "$tmp" 2>/dev/null || true
          log "ERROR: REMUX fehlgeschlagen: $rel"
          echo "$rel" >> "$SKIPLIST_FAILED_FILE" || true
          return 0
        fi

        if [[ "$DRY_RUN" == "1" ]]; then
          log "DRY-RUN: would write REMUX output -> ${out#"$OUT_ROOT"/}"
          rm -f "$tmp" 2>/dev/null || true
          return 0
        fi

        if [[ "$VERIFY_OUTPUT" == "1" ]]; then
          if ! verify_output "$f" "$tmp"; then
            log "ERROR: VERIFY_OUTPUT failed -> verwerfe Output: $rel"
            echo "$rel" >> "$SKIPLIST_BAD_OUTPUT_FILE" || true
            rm -f "$tmp" 2>/dev/null || true
            return 0
          fi
        fi
        if [[ "$SIZE_GUARD" == "1" ]] && ! size_guard_ok "$f" "$tmp"; then
          log "SKIP (size-guard remux): $rel"
          echo "$rel" >> "$SKIPLIST_LARGER_FILE" || true
          rm -f "$tmp" 2>/dev/null || true
          return 0
        fi
        mv -f "$tmp" "$out"
      else
        log "SKIP (already HEVC): $rel"
      fi
      return 0
    fi

    # Reencode nur wenn Kandidat (reason nicht leer)
    if [[ -z "$reason" ]]; then
      log "SKIP (HEVC reencode: not a candidate): $rel"
      return 0
    fi

    log "HEVC-REENCODE (candidate: $reason): $rel -> ${out#"$OUT_ROOT"/}"

    local gq="${HEVC_REENCODE_GQ_START}"
    local ok=0
    while [[ "$gq" -le "$HEVC_REENCODE_GQ_MAX" ]]; do
      rm -f "$tmp" 2>/dev/null || true
      log "  HEVC-REENCODE: ICQ=$gq (min_savings=${HEVC_MIN_SAVINGS_PCT}%)"

      # Encode with quality mode
      set +e
      encode_hevc_qsv_to_tmp "$f" "$tmp" "quality" "$gq" "" "$ext_lc"
      local rc=$?
      set -e
      if [[ "$rc" -eq 2 ]]; then
        log "SKIP (audio ambiguous): $rel"
        echo "$rel" >> "$SKIPLIST_AUDIO_AMBIG_FILE" || true
        rm -f "$tmp" 2>/dev/null || true
        return 0
      fi
      if [[ "$rc" -ne 0 ]]; then
        rm -f "$tmp" 2>/dev/null || true
        log "ERROR: HEVC-REENCODE fehlgeschlagen: $rel"
        echo "$rel" >> "$SKIPLIST_FAILED_FILE" || true
        return 0
      fi

      if [[ "$DRY_RUN" == "1" ]]; then
        log "DRY-RUN: would write output -> ${out#"$OUT_ROOT"/}"
        rm -f "$tmp" 2>/dev/null || true
        return 0
      fi

      # VERIFY_OUTPUT
      if [[ "$VERIFY_OUTPUT" == "1" ]]; then
        if ! verify_output "$f" "$tmp"; then
          log "ERROR: VERIFY_OUTPUT failed -> verwerfe Output: $rel"
          echo "$rel" >> "$SKIPLIST_BAD_OUTPUT_FILE" || true
          rm -f "$tmp" 2>/dev/null || true
          gq=$((gq + HEVC_REENCODE_GQ_STEP))
          continue
        fi
      fi

      # Must be smaller enough
      if ! min_savings_ok "$f" "$tmp" "$HEVC_MIN_SAVINGS_PCT"; then
        log "  HEVC-REENCODE: not enough savings -> increasing ICQ"
        rm -f "$tmp" 2>/dev/null || true
        gq=$((gq + HEVC_REENCODE_GQ_STEP))
        continue
      fi

      # Size guard (sollte sowieso erfüllt sein, aber als Sicherheitsnetz)
      if [[ "$SIZE_GUARD" == "1" ]] && ! size_guard_ok "$f" "$tmp"; then
        log "  HEVC-REENCODE: size guard -> increasing ICQ"
        rm -f "$tmp" 2>/dev/null || true
        gq=$((gq + HEVC_REENCODE_GQ_STEP))
        continue
      fi

      # Optional VMAF
      if ! vmaf_sample_check "$f" "$tmp"; then
        log "  HEVC-REENCODE: VMAF below threshold -> increasing ICQ"
        rm -f "$tmp" 2>/dev/null || true
        gq=$((gq + HEVC_REENCODE_GQ_STEP))
        continue
      fi

      ok=1
      break
    done

    if [[ "$ok" != "1" ]]; then
      log "SKIP (HEVC reencode: no acceptable result): $rel"
      echo "$rel" >> "$SKIPLIST_FAILED_FILE" || true
      rm -f "$tmp" 2>/dev/null || true
      return 0
    fi

    mv -f "$tmp" "$out"
    return 0
  fi

  # --------
  # Standard Encode (Nicht-HEVC -> HEVC)
  # --------
  log "ENCODE (to HEVC): $rel (vcodec=$vcodec width=$width height=$height) -> ${out#"$OUT_ROOT"/}"

  local try=1
  local factor="$BITRATE_FACTOR"
  local use_quality=0
  local q_try=0
  local gq_try="$GQ"

  while true; do
    rm -f "$tmp" 2>/dev/null || true

    local mode="$RATE_MODE"
    local tvbps=""
    if [[ "$HYBRID_ENCODE" == "1" ]]; then
      # first N tries in quality mode, then fallback to bitrate auto/same
      if [[ "$q_try" -lt "$HYBRID_ICQ_TRIES" && "$gq_try" -le "$HYBRID_ICQ_MAX" ]]; then
        mode="quality"
        q_try=$((q_try+1))
        log "  HYBRID: ICQ attempt $q_try/$HYBRID_ICQ_TRIES (global_quality=$gq_try)"
      else
        mode="$RATE_MODE"
      fi
    fi

    if [[ "$mode" == "quality" ]]; then
      # Capture real return code (do NOT use `if ! cmd; then rc=$?` because rc would be 0 due to `!`)
      set +e
      encode_hevc_qsv_to_tmp "$f" "$tmp" "quality" "$gq_try" "" "$ext_lc"
      local rc=$?
      set -e
      if [[ "$rc" -eq 2 ]]; then
        log "SKIP (audio ambiguous): $rel"
        echo "$rel" >> "$SKIPLIST_AUDIO_AMBIG_FILE" || true
        return 0
      elif [[ "$rc" -ne 0 ]]; then
        rm -f "$tmp" 2>/dev/null || true
        log "ERROR: ENCODE fehlgeschlagen: $rel"
        echo "$rel" >> "$SKIPLIST_FAILED_FILE" || true
        return 0
      fi

      # DRY-RUN: stop here (no output checks/move)
      if [[ "$DRY_RUN" == "1" ]]; then
        log "DRY-RUN: would write output -> ${out#"$OUT_ROOT"/}"
        rm -f "$tmp" 2>/dev/null || true
        return 0
      fi
    else
      local src_vbps
      src_vbps="$(estimate_video_bitrate "$f")"
      if [[ -n "$src_vbps" ]]; then
        tvbps="$(calc_target_vbps "$src_vbps" "$factor")"
        log "  RATE: target video bitrate = ${tvbps} bps (factor=$factor, mode=$mode, try=$try)"
        set +e
        encode_hevc_qsv_to_tmp "$f" "$tmp" "rate" "" "$tvbps" "$ext_lc"
        local rc=$?
        set -e
        if [[ "$rc" -eq 2 ]]; then
          log "SKIP (audio ambiguous): $rel"
          echo "$rel" >> "$SKIPLIST_AUDIO_AMBIG_FILE" || true
          return 0
        elif [[ "$rc" -ne 0 ]]; then
          rm -f "$tmp" 2>/dev/null || true
          log "ERROR: ENCODE fehlgeschlagen: $rel"
          echo "$rel" >> "$SKIPLIST_FAILED_FILE" || true
          return 0
        fi

        if [[ "$DRY_RUN" == "1" ]]; then
          log "DRY-RUN: would write output -> ${out#"$OUT_ROOT"/}"
          rm -f "$tmp" 2>/dev/null || true
          return 0
        fi
      else
        log "  RATE: unable to determine bitrate -> falling back to quality (GQ=$gq_try, try=$try)"
        set +e
        encode_hevc_qsv_to_tmp "$f" "$tmp" "quality" "$gq_try" "" "$ext_lc"
        local rc=$?
        set -e
        if [[ "$rc" -eq 2 ]]; then
          log "SKIP (audio ambiguous): $rel"
          echo "$rel" >> "$SKIPLIST_AUDIO_AMBIG_FILE" || true
          return 0
        elif [[ "$rc" -ne 0 ]]; then
          rm -f "$tmp" 2>/dev/null || true
          log "ERROR: ENCODE fehlgeschlagen: $rel"
          echo "$rel" >> "$SKIPLIST_FAILED_FILE" || true
          return 0
        fi

        if [[ "$DRY_RUN" == "1" ]]; then
          log "DRY-RUN: would write output -> ${out#"$OUT_ROOT"/}"
          rm -f "$tmp" 2>/dev/null || true
          return 0
        fi
      fi
    fi

    # Size guard + retries
    if [[ "$SIZE_GUARD" == "1" ]]; then
      if size_guard_ok "$f" "$tmp"; then
        :
      else
        if [[ "$SIZE_GUARD_ACTION" == "keep" ]]; then
          log "  SIZE-GUARD: keep -> akzeptiere trotzdem: $rel"
        elif [[ "$SIZE_GUARD_ACTION" == "skip" ]]; then
          echo "$rel" >> "$SKIPLIST_LARGER_FILE" || true
          rm -f "$tmp" 2>/dev/null || true
          log "SKIP (size-guard): $rel"
          return 0
        else
          # retry
          if [[ "$try" -lt "$SIZE_GUARD_MAX_TRIES" ]]; then
            try=$((try+1))
            # if we were in quality mode, increase ICQ (more compression)
            if [[ "$HYBRID_ENCODE" == "1" && "$mode" == "quality" ]]; then
              gq_try=$((gq_try + HYBRID_ICQ_STEP))
              [[ "$gq_try" -gt "$HYBRID_ICQ_MAX" ]] && gq_try="$HYBRID_ICQ_MAX"
              log "  SIZE-GUARD: retry -> neuer ICQ=$gq_try (try=$try)"
            else
              factor="$(awk -v f="$factor" -v s="$SIZE_GUARD_FACTOR_STEP" 'BEGIN{printf "%.4f", f*s}')"
              log "  SIZE-GUARD: retry -> neuer BITRATE_FACTOR=$factor (try=$try)"
            fi
            rm -f "$tmp" 2>/dev/null || true
            continue
          fi
          echo "$rel" >> "$SKIPLIST_LARGER_FILE" || true
          rm -f "$tmp" 2>/dev/null || true
          log "SKIP (size-guard, max tries reached): $rel"
          return 0
        fi
      fi
    fi

    # VERIFY_OUTPUT
    if [[ "$VERIFY_OUTPUT" == "1" ]]; then
      if ! verify_output "$f" "$tmp"; then
        log "ERROR: VERIFY_OUTPUT failed -> verwerfe Output: $rel"
        echo "$rel" >> "$SKIPLIST_BAD_OUTPUT_FILE" || true
        rm -f "$tmp" 2>/dev/null || true
        return 0
      fi
    fi

    break
  done

  mv -f "$tmp" "$out"
  return 0
}

# ---------------------------
# main once + watch
# ---------------------------
main_once() {
  build_manifest

  local total cursor
  total="$(wc -l < "$MANIFEST_FILE" | tr -d ' ')"
  cursor="0"
  if [[ "$RESUME" == "1" && -f "$PROGRESS_FILE" ]]; then
    cursor="$(only_digits "$(cat "$PROGRESS_FILE" 2>/dev/null || echo 0)")"
    [[ -z "$cursor" ]] && cursor="0"
  fi

  log "Start: MODE=run SUBDIR='$SUBDIR' Files=$total (resume_cursor=$cursor)"
  log "IN_ROOT=$IN_ROOT OUT_ROOT=$OUT_ROOT GQ=$GQ PRESET=$PRESET RATE_MODE=$RATE_MODE BITRATE_FACTOR=$BITRATE_FACTOR"
  log "FPS_MODE=$FPS_MODE GENPTS=$GENPTS IGNDTS=$IGNDTS AVOID_NEG_TS=$AVOID_NEG_TS HW_DECODE=$HW_DECODE QSV_DEVICE=$QSV_DEVICE"
  log "PROBESIZE=$PROBESIZE ANALYZEDURATION=$ANALYZEDURATION"
  log "SKIP_4K=$SKIP_4K SKIP_DOLBY_VISION=$SKIP_DOLBY_VISION SKIP_HDR=$SKIP_HDR REMUX_HEVC=$REMUX_HEVC"
  log "EXCLUDE_DIRS=$EXCLUDE_DIRS"
  log "AUDIO_GERMAN_ONLY=$AUDIO_GERMAN_ONLY"
  log "HYBRID_ENCODE=$HYBRID_ENCODE HYBRID_ICQ_TRIES=$HYBRID_ICQ_TRIES ICQ_STEP=$HYBRID_ICQ_STEP ICQ_MAX=$HYBRID_ICQ_MAX"
  log "SIZE_GUARD=$SIZE_GUARD ALLOW_SIZE_GROW_PCT=$ALLOW_SIZE_GROW_PCT ACTION=$SIZE_GUARD_ACTION MAX_TRIES=$SIZE_GUARD_MAX_TRIES"
  log "STRICT_INPUT=$STRICT_INPUT VERIFY_OUTPUT=$VERIFY_OUTPUT"
  log "REENCODE_HEVC=$REENCODE_HEVC HEVC_MIN_SIZE_GB=$HEVC_MIN_SIZE_GB HEVC_MIN_SAVINGS_PCT=$HEVC_MIN_SAVINGS_PCT"
  log "VMAF_CHECK=$VMAF_CHECK (min=$VMAF_MIN)"
  log "FFMPEG_LOGLEVEL=$FFMPEG_LOGLEVEL FFMPEG_NOSTATS=$FFMPEG_NOSTATS DRY_RUN=${DRY_RUN:-0}"
  log "Log: $LOG_FILE"
  echo "" >> "$LOG_FILE"

  local idx=0
  while IFS= read -r f; do
    idx=$((idx+1))
    if [[ "$idx" -le "$cursor" ]]; then
      continue
    fi
    if [[ ! -f "$f" ]]; then
      log "SKIP (missing): $f"
      echo "$idx" > "$PROGRESS_FILE"
      continue
    fi

    log "---- [$idx/$total] ----"
    process_one "$f"

    # Progress erst nach Abschluss dieser Datei
    echo "$idx" > "$PROGRESS_FILE"
  done < "$MANIFEST_FILE"

  log "Fertig."
}

# ---------------------------
# Args
# ---------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --runlog) LOG_FILE="${2:-$LOG_FILE_DEFAULT}"; shift 2;;
    --watch) WATCH="1"; shift;;
    --wait) WAIT_SEC="${2:-$WAIT_SEC}"; shift 2;;
    --rebuild-manifest) REBUILD_MANIFEST="1"; shift;;
    --subdir) SUBDIR="${2:-}"; shift 2;;
    *) shift;;
  esac
done

mkdir -p "$(dirname "$LOG_FILE")" || true

acquire_lock

if [[ "$WATCH" == "1" ]]; then
  while true; do
    main_once || true
    log "WATCH=1 -> waiting $WAIT_SEC seconds..."
    sleep "$WAIT_SEC"
  done
else
  main_once
fi
