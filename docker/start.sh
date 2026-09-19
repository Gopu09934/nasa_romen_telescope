#!/bin/bash
set -euo pipefail

#############################################
# LIVE: International Observe the Moon Night 2026 |
#
# Same 24/7 ffmpeg -> YouTube pipeline as the Roman / solar scripts,
# re-themed for International Observe the Moon Night (Sept 19, 2026).
#
# NOTE: the YouTube *title* is not set by this script. Put
#   "LIVE: International Observe the Moon Night 2026 |"
# in YouTube Studio (Go Live > Edit). This script only controls what is
# drawn on the video.
#
# Everything on the Moon panels (phase, illumination, age, distance,
# light-time, angular size, next full/new moon, lunar-cycle bar and the
# phase disc) is computed locally from the wall clock, so there are no
# NASA/JPL network dependencies to break. Values are labelled "(est.)"
# where they are modelled rather than tracked.
#############################################

#############################################
# Validate Environment Variables
#############################################
if [ -z "${VIDEO_URL:-}" ]; then
    echo "ERROR: VIDEO_URL is not set"
    echo "One or more Moon video/animation clips, comma-separated (same format"
    echo "as before): url1,url2,url3. A static image (jpg/png) is also"
    echo "accepted as a 'slide' and will be shown for IMAGE_SLIDE_SECONDS."
    exit 1
fi
if [ -z "${YOUTUBE_STREAM_KEY:-}" ]; then
    echo "ERROR: YOUTUBE_STREAM_KEY is not set"
    exit 1
fi
if [ -z "${AUDIO_URL:-}" ]; then
    echo "ERROR: AUDIO_URL is not set"
    echo "Background music/ambience track(s), comma-separated for multiple:"
    echo "url1,url2,url3"
    exit 1
fi

# Subscriber count + live viewer count are optional.
SHOW_STATS=true
if [ -z "${YOUTUBE_API_KEY:-}" ] || [ -z "${YOUTUBE_CHANNEL_ID:-}" ]; then
    echo "NOTICE: YOUTUBE_API_KEY / YOUTUBE_CHANNEL_ID not set — subscriber/viewer stats will be hidden."
    SHOW_STATS=false
fi

# Output target (overridable so the pipeline can be tested without YouTube).
RTMP_BASE="${RTMP_BASE:-rtmp://a.rtmp.youtube.com/live2}"

# ---------------------------------------------------------------
# Feed label honesty: most 24/7 rotations like this are looping
# animations/renders, not a live telescope camera. Default to a label
# that doesn't overclaim; set VIDEO_FEED_LABEL="LIVE MOON CAM" only if
# VIDEO_URL genuinely is a live camera source.
# ---------------------------------------------------------------
VIDEO_FEED_LABEL="${VIDEO_FEED_LABEL:-MOON ANIMATION}"

# Credit line shown top-right. Set this to match the clips in VIDEO_URL.
CREDIT_TEXT="${CREDIT_TEXT:-Credits: NASA}"

# Small chip in the bottom-right corner (mirrors the LIVE NOW chip).
RIGHT_CHIP_TEXT="${RIGHT_CHIP_TEXT:-S E P   1 9}"

# Set MOON_FLIP=true to draw the phase disc as seen from the Southern
# Hemisphere (lit side mirrored). Default is the Northern view.
MOON_FLIP="${MOON_FLIP:-false}"

# ---------------------------------------------------------------
# Network-failure fallback: if a video URL can't even be reached,
# retrying it 5 times burns MAX_RETRIES * RETRY_DELAY seconds of dead
# air. If FALLBACK_IMAGE_URL is set, an unreachable video is skipped in
# favor of streaming that image as a slide for this rotation instead.
# ---------------------------------------------------------------
FALLBACK_IMAGE_URL="${FALLBACK_IMAGE_URL:-}"

# ---------------------------------------------------------------
# Video crop zoom/pan. VIDEO_ZOOM (>1 crops in tighter) plus
# VIDEO_PAN_X / VIDEO_PAN_Y (each -1..1, 0 = centered) shift the crop
# window onto the useful part of the source (e.g. to crop out UI chrome
# baked into a screen capture).
# ---------------------------------------------------------------
VIDEO_ZOOM="${VIDEO_ZOOM:-1.0}"
VIDEO_PAN_X="${VIDEO_PAN_X:-0}"
VIDEO_PAN_Y="${VIDEO_PAN_Y:-0}"

echo "========================================"
echo "Starting 24/7 YouTube Stream (International Observe the Moon Night 2026)"
echo "Output Resolution : 1280x720 (720p — sized for a 2-core CI runner)"
echo "FPS               : 30"
echo "========================================"

FONT="font.ttf"
# Palette: warm moonlight accent + NASA-style "insignia red" for the live
# indicator, on a deep navy panel background.
GOLD="0xF2C96B"
RED="0xFC3D21"
PANEL_BG="0x060B14"
ASSET_DIR="panel_assets"
INFO_FILE="mission_info.txt"
SLOT=6            # seconds each headline is shown
FACT_SLOT=8       # seconds each fun fact is shown
TICKER_SPEED=110  # pixels/second for the bottom ticker scroll
CHANNEL_NAME="${CHANNEL_NAME:-International Observe the Moon Night 2026}"
SHADOW="shadowcolor=black@0.6:shadowx=1:shadowy=1"
HEADLINE_FONTSIZE=21
HEADLINE_LINE_SPACING=9
HEADLINE_LINE_H=$((HEADLINE_FONTSIZE + HEADLINE_LINE_SPACING))
FACT_FONTSIZE=16
FACT_LINE_SPACING=7
FACT_LINE_H=$((FACT_FONTSIZE + FACT_LINE_SPACING))

# ---------------------------------------------------------------
# Layout: video stays centered/full-height, one panel on each side.
# ---------------------------------------------------------------
PANEL_W=333
CENTER_X0=$PANEL_W
CENTER_W=$((1280 - PANEL_W * 2))
RIGHT_X0=$((1280 - PANEL_W))
TEXT_INSET=33
RTEXT_INSET=$((RIGHT_X0 + 33))
PANEL_TEXT_W=$((PANEL_W - 66))

# ---------------------------------------------------------------
# Center strip: 3 stacked bands —
#   Row 1 - Moon video/animation feed
#   Row 2 - MOON TONIGHT card (phase, illumination, age, distance)
#   Row 3 - LUNAR CYCLE progress bar
# ---------------------------------------------------------------
VIDEO_ROW_H=340
INFO_ROW_H=190
GRAPH_ROW_H=$((720 - VIDEO_ROW_H - INFO_ROW_H))
ROW1_Y=0
ROW2_Y=$((VIDEO_ROW_H))
ROW3_Y=$((VIDEO_ROW_H + INFO_ROW_H))
MTEXT_INSET=$((CENTER_X0 + 30))
MVALUE_X=$((MTEXT_INSET + 150))

VIEWER_MIN_TO_SHOW=10

#############################################
# Auto-restart on failure
#############################################
MAX_RETRIES=5
RETRY_DELAY=5
IMAGE_SLIDE_SECONDS="${IMAGE_SLIDE_SECONDS:-25}"

mkdir -p "$ASSET_DIR"

CLOCK_PID=""
MOONCALC_PID=""
SUBS_PID=""
VIEWERS_PID=""
TRIVIA_PID=""
trap 'for p in "$CLOCK_PID" "$MOONCALC_PID" "$SUBS_PID" "$VIEWERS_PID" "$TRIVIA_PID"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done' EXIT

#############################################
# Background audio (one or more tracks, looped)
# Downloaded once, rotated across videos, looped locally per-video.
#############################################
IFS=',' read -ra RAW_AUDIO_URLS <<< "$AUDIO_URL"
AUDIO_LOCAL_FILES=()
audio_i=0
for au in "${RAW_AUDIO_URLS[@]}"; do
    au="${au#"${au%%[![:space:]]*}"}"
    au="${au%"${au##*[![:space:]]}"}"
    [ -z "$au" ] && continue
    audio_i=$((audio_i + 1))
    dest="bg_audio_track_${audio_i}"
    echo "Downloading background audio track ${audio_i}..."
    if curl -sL --fail -o "$dest" "$au" && [ -s "$dest" ]; then
        AUDIO_LOCAL_FILES+=("$dest")
        echo "  OK ($(du -h "$dest" | cut -f1))"
    else
        echo "  WARNING: failed to download track ${audio_i} — skipping it."
    fi
done

NUM_AUDIO=${#AUDIO_LOCAL_FILES[@]}
AUDIO_AVAILABLE=false
if [ "$NUM_AUDIO" -gt 0 ]; then
    AUDIO_AVAILABLE=true
    echo "Loaded $NUM_AUDIO background audio track(s); rotating across videos."
else
    echo "WARNING: no background audio tracks downloaded — stream will run with silent audio instead."
fi
AUDIO_COUNTER=0

#############################################
# Coordinate-label marker dot (generic callout feature, see
# build_labels_chain below)
#############################################
DOT_MARKER="dot_marker.png"
GOLD_R=242; GOLD_G=201; GOLD_B=107
DOT_VF="format=rgba,geq=r=(if(lte(hypot(X-10\,Y-10)\,5)\,${GOLD_R}\,if(lte(hypot(X-10\,Y-10)\,8)\,255\,0))):g=(if(lte(hypot(X-10\,Y-10)\,5)\,${GOLD_G}\,if(lte(hypot(X-10\,Y-10)\,8)\,255\,0))):b=(if(lte(hypot(X-10\,Y-10)\,5)\,${GOLD_B}\,if(lte(hypot(X-10\,Y-10)\,8)\,255\,0))):a=(if(lte(hypot(X-10\,Y-10)\,8)\,255\,0))"
ffmpeg -y -f lavfi -i "color=c=black@0.0:s=20x20" -vf "$DOT_VF" -frames:v 1 "$DOT_MARKER" -loglevel error
if [ ! -s "$DOT_MARKER" ]; then
    echo "WARNING: geq-based marker generation failed — using a blank 1x1 fallback."
    echo "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=" | base64 -d > "$DOT_MARKER"
fi

#############################################
# Background clock writer (UTC wall clock)
#############################################
date -u +'%d %b %Y  •  %H:%M:%S UTC' > "$ASSET_DIR/clock.txt"
(
    while true; do
        date -u +'%d %b %Y  •  %H:%M:%S UTC' > "$ASSET_DIR/clock.txt.tmp"
        mv -f "$ASSET_DIR/clock.txt.tmp" "$ASSET_DIR/clock.txt"
        sleep 1
    done
) &
CLOCK_PID=$!

#############################################
# Moon calculator (pure Python, no network, no API key).
#
# Uses the leading terms of the standard lunar theory (Meeus, "Astronomical
# Algorithms", ch. 47/48) to get the Moon-Sun elongation (phase), the
# Earth-Moon distance and the times of the next full/new moon. Checked
# against the Aug 12 and Aug 28, 2026 eclipses (new/full moon) to within
# minutes. Accuracy: phase/illumination well under 1 PCT, distance within
# a few hundred km — hence the "(est.)" on distance.
#
#   moon_calc.py once          -> prints "psi illum_pct age_frac cos_psi waxing"
#   moon_calc.py write <dir>   -> writes the panel text files once
#   moon_calc.py loop  <dir>   -> writes them every 10 seconds
#############################################
cat > moon_calc.py << 'PYEOF'
import sys
import os
import math
import time
from datetime import datetime, timezone

SYNODIC_DAYS = 29.530588853
MOON_RADIUS_KM = 1737.4
C_KMS = 299792.458
DEG_PER_DAY = 12.1907  # mean elongation rate


def _sin(d):
    return math.sin(math.radians(d))


def _cos(d):
    return math.cos(math.radians(d))


def jd_from_unix(t):
    return t / 86400.0 + 2440587.5


def unix_from_jd(jd):
    return (jd - 2440587.5) * 86400.0


def elements(jd):
    T = (jd - 2451545.0) / 36525.0
    D = (297.8501921 + 445267.1114034 * T) % 360
    M = (357.5291092 + 35999.0502909 * T) % 360
    Mp = (134.9633964 + 477198.8675055 * T) % 360
    return D, M, Mp


def phase_angle(jd):
    """Moon-Sun elongation in degrees: 0 = new, 90 = first quarter,
    180 = full, 270 = last quarter."""
    D, M, Mp = elements(jd)
    psi = (D + 6.289 * _sin(Mp) - 2.100 * _sin(M) + 1.274 * _sin(2 * D - Mp)
           + 0.658 * _sin(2 * D) + 0.214 * _sin(2 * Mp) + 0.110 * _sin(D))
    return psi % 360


def distance_km(jd):
    D, M, Mp = elements(jd)
    return (385000.56
            - 20905.355 * _cos(Mp)
            - 3699.111 * _cos(2 * D - Mp)
            - 2955.968 * _cos(2 * D)
            - 569.925 * _cos(2 * Mp)
            + 48.888 * _cos(M)
            + 246.158 * _cos(2 * D - 2 * Mp)
            - 152.138 * _cos(2 * D - M - Mp)
            - 170.733 * _cos(2 * D + Mp)
            - 204.586 * _cos(2 * D - M)
            - 129.620 * _cos(Mp - M)
            + 108.743 * _cos(D)
            + 104.755 * _cos(Mp + M))


def next_event_jd(jd, target_deg):
    psi = phase_angle(jd)
    j = jd + ((target_deg - psi) % 360) / DEG_PER_DAY
    for _ in range(6):
        d = ((target_deg - phase_angle(j) + 180) % 360) - 180
        j += d / DEG_PER_DAY
    return j


def phase_name(psi):
    if psi < 6 or psi >= 354:
        return "New Moon"
    if psi < 84:
        return "Waxing Crescent"
    if psi < 96:
        return "First Quarter"
    if psi < 174:
        return "Waxing Gibbous"
    if psi < 186:
        return "Full Moon"
    if psi < 264:
        return "Waning Gibbous"
    if psi < 276:
        return "Last Quarter"
    return "Waning Crescent"


def fmt_event(jd_now, jd_evt):
    dt = datetime.fromtimestamp(unix_from_jd(jd_evt), timezone.utc)
    days = jd_evt - jd_now
    return f"{dt.strftime('%b %d')} · in {days:.1f} d"


def compute():
    jd = jd_from_unix(time.time())
    psi = phase_angle(jd)
    illum = (1 - _cos(psi)) / 2
    dist = distance_km(jd)
    return {
        "jd": jd, "psi": psi, "illum": illum, "dist": dist,
        "ang": math.degrees(2 * math.atan(MOON_RADIUS_KM / dist)) * 60,
        "age_days": psi / 360 * SYNODIC_DAYS,
        "full_jd": next_event_jd(jd, 180),
        "new_jd": next_event_jd(jd, 360),
        "name": phase_name(psi),
    }


def write(asset_dir, name, text):
    tmp = f"{asset_dir}/{name}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, f"{asset_dir}/{name}.txt")


def write_all(asset_dir):
    c = compute()
    pct = int(round(c["illum"] * 100))
    write(asset_dir, "moon_phase", c["name"])
    write(asset_dir, "moon_illum", f"{pct} PCT")
    write(asset_dir, "moon_age", f"{c['age_days']:.1f} days")
    write(asset_dir, "moon_dist", f"{c['dist']:,.0f} km (est.)")
    write(asset_dir, "moon_light", f"{c['dist'] / C_KMS:.2f} s (one-way)")
    write(asset_dir, "moon_ang", f"{c['ang']:.1f} arcmin")
    write(asset_dir, "moon_next_full", fmt_event(c["jd"], c["full_jd"]))
    write(asset_dir, "moon_next_new", fmt_event(c["jd"], c["new_jd"]))
    write(asset_dir, "moon_summary", f"{c['name']} · {pct} PCT lit")


if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "once":
        c = compute()
        # psi  illum_pct  age_fraction  cos(psi)  waxing(1/0)
        print(f"{c['psi']:.3f} {int(round(c['illum'] * 100))} {c['psi'] / 360:.5f} "
              f"{_cos(c['psi']):.5f} {1 if c['psi'] < 180 else 0}")
    else:
        asset_dir = sys.argv[2]
        write_all(asset_dir)
        if mode == "loop":
            while True:
                time.sleep(10)
                try:
                    write_all(asset_dir)
                except Exception:
                    pass
PYEOF

# Placeholders so ffmpeg never opens a missing file, then a synchronous first
# write so real values are on disk before the first video starts.
for f in moon_phase moon_illum moon_age moon_dist moon_light moon_ang moon_next_full moon_next_new moon_summary; do
    printf ' ' > "$ASSET_DIR/${f}.txt"
done
if ! python3 moon_calc.py write "$ASSET_DIR" 2>/tmp/moon_calc_err.log; then
    echo "WARNING: initial moon calculation failed — $(tail -1 /tmp/moon_calc_err.log 2>/dev/null)"
fi
(
    python3 moon_calc.py loop "$ASSET_DIR" 2>/tmp/moon_calc_err.log || \
        echo "WARNING: moon calculator stopped — $(tail -1 /tmp/moon_calc_err.log 2>/dev/null)"
) &
MOONCALC_PID=$!

#############################################
# Background subscriber-count writer
#############################################
printf ' ' > "$ASSET_DIR/subs.txt"
if [ "$SHOW_STATS" = true ]; then
    (
        WARNED_ONCE=false
        while true; do
            RESP=$(curl -s "https://www.googleapis.com/youtube/v3/channels?part=statistics&id=${YOUTUBE_CHANNEL_ID}&key=${YOUTUBE_API_KEY}" || true)
            COUNT=$(echo "$RESP" | grep -o '"subscriberCount"[^"]*"[0-9]*"' | grep -oE '[0-9]+' || true)
            if [ -n "$COUNT" ]; then
                FORMATTED=$(echo "$COUNT" | rev | sed 's/\(...\)/\1,/g' | rev | sed 's/^,//')
                printf '%s subscribers' "$FORMATTED" > "$ASSET_DIR/subs.txt.tmp"
                mv -f "$ASSET_DIR/subs.txt.tmp" "$ASSET_DIR/subs.txt"
                WARNED_ONCE=false
            elif [ "$WARNED_ONCE" = false ]; then
                echo "WARNING: could not parse subscriberCount from API response. Raw response:"
                echo "$RESP"
                WARNED_ONCE=true
            fi
            sleep 60
        done
    ) &
    SUBS_PID=$!
fi

#############################################
# Background live-viewer-count writer
#############################################
printf ' ' > "$ASSET_DIR/viewers.txt"
if [ "$SHOW_STATS" = true ]; then
    (
        LIVE_VIDEO_ID=""
        while true; do
            if [ -z "$LIVE_VIDEO_ID" ]; then
                SEARCH_RESP=$(curl -s "https://www.googleapis.com/youtube/v3/search?part=id&channelId=${YOUTUBE_CHANNEL_ID}&eventType=live&type=video&key=${YOUTUBE_API_KEY}" || true)
                LIVE_VIDEO_ID=$(echo "$SEARCH_RESP" | grep -o '"videoId": *"[^"]*"' | head -1 | sed -E 's/.*"videoId": *"([^"]*)".*/\1/' || true)
            fi
            if [ -n "$LIVE_VIDEO_ID" ]; then
                VRESP=$(curl -s "https://www.googleapis.com/youtube/v3/videos?part=liveStreamingDetails&id=${LIVE_VIDEO_ID}&key=${YOUTUBE_API_KEY}" || true)
                VIEWERS=$(echo "$VRESP" | grep -o '"concurrentViewers": *"[0-9]*"' | grep -o '[0-9]*' || true)
                if [ -n "$VIEWERS" ] && [ "$VIEWERS" -ge "$VIEWER_MIN_TO_SHOW" ]; then
                    printf '%s watching now' "$VIEWERS" > "$ASSET_DIR/viewers.txt.tmp"
                    mv -f "$ASSET_DIR/viewers.txt.tmp" "$ASSET_DIR/viewers.txt"
                elif [ -n "$VIEWERS" ]; then
                    printf ' ' > "$ASSET_DIR/viewers.txt.tmp"
                    mv -f "$ASSET_DIR/viewers.txt.tmp" "$ASSET_DIR/viewers.txt"
                else
                    LIVE_VIDEO_ID=""
                    printf ' ' > "$ASSET_DIR/viewers.txt"
                fi
            fi
            sleep 30
        done
    ) &
    VIEWERS_PID=$!
fi

#############################################
# Static panel text (unchanged across videos)
#############################################
printf 'O B S E R V E   T H E'               > "$ASSET_DIR/title1.txt"
printf 'M O O N   N I G H T   2 0 2 6'       > "$ASSET_DIR/title2.txt"
printf 'M O O N   W A T C H'                 > "$ASSET_DIR/header.txt"
printf 'LIVE · SEPTEMBER 19'                 > "$ASSET_DIR/eyebrow.txt"
printf 'SUBSCRIBE for more space livestreams' > "$ASSET_DIR/cta.txt"
printf '%s' "$CREDIT_TEXT"                   > "$ASSET_DIR/credit.txt"
printf 'DID YOU KNOW'                        > "$ASSET_DIR/fact_label.txt"
printf 'OBSERVING TIP'                       > "$ASSET_DIR/instr_label.txt"
printf 'THE TERMINATOR'                      > "$ASSET_DIR/instr_title.txt"

#############################################
# "MOON QUIZ" trivia CTA — alternates with the subscribe prompt in the
# same on-screen slot (see build_final_filter). Override the pool with a
# trivia.txt file (one line per prompt).
#############################################
DEFAULT_TRIVIA=(
    "MOON QUIZ: distance? About 384,400 km away."
    "MOON QUIZ: gravity? Just 1/6 of Earth's."
    "MOON QUIZ: one lunar cycle? About 29.5 days."
    "MOON QUIZ: dark patches? Lunar maria."
    "MOON QUIZ: far side? Never faces Earth."
    "MOON QUIZ: drifting away? 3.8 cm a year."
    "MOON QUIZ: LRO has mapped it since? 2009."
    "MOON QUIZ: best place to look? The terminator."
)
TRIVIA_FILE="${TRIVIA_FILE:-trivia.txt}"
if [ -f "$TRIVIA_FILE" ]; then
    echo "Using curated trivia pool: $TRIVIA_FILE"
    TRIVIA_POOL=()
    while IFS= read -r line; do
        [ -n "$(echo "$line" | tr -d '[:space:]')" ] && TRIVIA_POOL+=("$line")
    done < "$TRIVIA_FILE"
else
    TRIVIA_POOL=("${DEFAULT_TRIVIA[@]}")
fi
printf '%s' "${TRIVIA_POOL[0]}" > "$ASSET_DIR/cta_trivia.txt"
(
    ti=0
    n=${#TRIVIA_POOL[@]}
    while true; do
        sleep 240
        ti=$(((ti + 1) % n))
        printf '%s' "${TRIVIA_POOL[$ti]}" > "$ASSET_DIR/cta_trivia.txt.tmp"
        mv -f "$ASSET_DIR/cta_trivia.txt.tmp" "$ASSET_DIR/cta_trivia.txt"
    done
) &
TRIVIA_PID=$!

#############################################
# Default headline / fact pools
# (avoid '%' and backslashes in these — drawtext treats them specially)
#############################################
DEFAULT_HEADLINES=(
    "International Observe the Moon Night 2026 takes place on September 19."
    "It is a worldwide celebration of lunar science and exploration, held every year since 2010."
    "The date is chosen near the first quarter Moon, when surface features stand out."
    "This year the first quarter Moon fell on September 18, so the Moon is a waxing gibbous."
    "The event is sponsored by NASA's Lunar Reconnaissance Orbiter and Goddard's Solar System Exploration Division."
    "Astronomy clubs, museums and observatories host star parties and virtual events around the world."
    "You don't need a telescope: the Moon is easy to see with the naked eye, even from a bright city."
    "Along the terminator, the line between lunar day and night, long shadows make craters pop."
    "On September 19 the waxing gibbous Moon sits in the constellation Sagittarius."
    "Artemis II sent four astronauts around the Moon in April 2026."
    "The Moon is about 384,400 kilometers from Earth on average."
    "Join an event, host your own, or simply step outside and look up."
    "Find an event near you on NASA's Observe the Moon Night website."
    "Share your Moon photos and stories with moon-watchers around the world."
)

DEFAULT_FACTS=(
    "The Moon is about 384,400 kilometers from Earth on average."
    "The Moon is tidally locked, so we always see the same side from Earth."
    "One full lunar cycle, from new Moon to new Moon, takes about 29.5 days."
    "The dark patches on the Moon are maria, ancient plains of solidified lava."
    "The terminator is the line between lunar day and night, and the best place to spot craters."
    "NASA's Lunar Reconnaissance Orbiter has been mapping the Moon from orbit since 2009."
    "Gravity on the Moon is about one-sixth of Earth's."
    "The Moon drifts away from Earth by about 3.8 centimeters every year."
    "Earthshine, the faint glow on a crescent Moon's dark side, is sunlight reflected off Earth."
    "Apollo astronauts brought back about 382 kilograms of lunar rock and soil."
    "The Moon's gravity is the main driver of ocean tides on Earth."
    "Moon phases happen because we see different amounts of its sunlit half as it orbits."
    "The Moon has almost no atmosphere, so its sky is black even in daytime."
    "Binoculars will show you many more craters than the naked eye can see."
)

#############################################
# build_labels_chain — generic coordinate-callout feature (unchanged;
# still works on any center-strip video via <basename>.labels.txt).
#############################################
build_labels_chain() {
    local url="$1"
    local base
    base="${url##*/}"
    base="${base%.*}"
    local i idx

    LABELS_CHAIN=""
    LABELS_OUT="[base]"

    local labels_file="${base}.labels.txt"
    if [ ! -f "$labels_file" ]; then
        return 0
    fi

    local xs=() ys=() texts=()
    while IFS=',' read -r x y text; do
        x="$(echo "$x" | tr -d '[:space:]')"
        y="$(echo "$y" | tr -d '[:space:]')"
        text="$(echo "$text" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ "$x" =~ ^[0-9]+$ ]] || continue
        [[ "$y" =~ ^[0-9]+$ ]] || continue
        [ -z "$text" ] && continue
        xs+=("$x"); ys+=("$y"); texts+=("$text")
    done < "$labels_file"

    local n=${#xs[@]}
    if [ "$n" -eq 0 ]; then
        echo "NOTICE: $labels_file had no valid lines — skipping labels for this video."
        return 0
    fi
    echo "Using coordinate labels: $labels_file ($n label(s))"

    local BOX_H=42
    local V_OFFSET=70
    local H_OFFSET=40
    local ACCENT_W=4
    local BOX_GAP=10
    local LABEL_FONTSIZE=18
    local LABEL_PAD_L=14
    local LABEL_PAD_R=16
    local AVG_CHAR_W=10
    local BOX_W_MIN=110
    local BOX_W_MAX=260
    local placed_x=() placed_y=() placed_w=()
    local k collision tries

    local split_outs=""
    for ((i = 1; i <= n; i++)); do split_outs+="[dm${i}]"; done
    LABELS_CHAIN+="[1:v]fps=30,split=${n}${split_outs};"

    local prev="base"
    for ((i = 0; i < n; i++)); do
        idx=$((i + 1))
        local x="${xs[$i]}" y="${ys[$i]}" text="${texts[$i]}"
        printf '%s' "$text" > "$ASSET_DIR/label${idx}.txt"

        local box_w=$(( ${#text} * AVG_CHAR_W + ACCENT_W + LABEL_PAD_L + LABEL_PAD_R ))
        [ "$box_w" -lt "$BOX_W_MIN" ] && box_w=$BOX_W_MIN
        [ "$box_w" -gt "$BOX_W_MAX" ] && box_w=$BOX_W_MAX

        local box_y=$((y - V_OFFSET))
        if [ "$box_y" -lt 20 ]; then
            box_y=$((y + V_OFFSET - BOX_H))
        fi
        local box_x=$((x + H_OFFSET))
        if [ $((box_x + box_w)) -gt $((RIGHT_X0 - 10)) ]; then
            box_x=$((x - H_OFFSET - box_w))
        fi
        [ "$box_x" -lt $((CENTER_X0 + 10)) ] && box_x=$((CENTER_X0 + 10))

        tries=0
        while :; do
            collision=false
            for ((k = 0; k < ${#placed_x[@]}; k++)); do
                local px="${placed_x[$k]}" py="${placed_y[$k]}" pw="${placed_w[$k]}"
                if [ $((box_x)) -lt $((px + pw + BOX_GAP)) ] && \
                   [ $((box_x + box_w + BOX_GAP)) -gt $((px)) ] && \
                   [ $((box_y)) -lt $((py + BOX_H + BOX_GAP)) ] && \
                   [ $((box_y + BOX_H + BOX_GAP)) -gt $((py)) ]; then
                    collision=true
                    break
                fi
            done
            [ "$collision" = false ] && break
            box_y=$((box_y + BOX_H + BOX_GAP))
            if [ $((box_y + BOX_H)) -gt 700 ]; then
                box_y=20
            fi
            tries=$((tries + 1))
            [ "$tries" -gt 12 ] && break
        done
        placed_x+=("$box_x")
        placed_y+=("$box_y")
        placed_w+=("$box_w")

        local seg_y_top seg_y_bot
        if [ "$box_y" -gt "$y" ]; then
            seg_y_top=$y; seg_y_bot=$box_y
        else
            seg_y_top=$box_y; seg_y_bot=$y
        fi
        local seg_h=$((seg_y_bot - seg_y_top))
        [ "$seg_h" -lt 2 ] && seg_h=2

        local h_left h_w
        if [ "$box_x" -gt "$x" ]; then
            h_left=$x; h_w=$((box_x - x))
        else
            h_left=$box_x; h_w=$((x - box_x))
        fi
        [ "$h_w" -lt 2 ] && h_w=2

        local n1="lbl${idx}_dot" n2="lbl${idx}_v" n3="lbl${idx}_h" n4="lbl${idx}_bg" n5="lbl${idx}_bar" n6="lbl${idx}_outline" n7="lbl${idx}_txt"

        LABELS_CHAIN+="[${prev}]drawbox=x=${x}:y=${seg_y_top}:w=2:h=${seg_h}:color=${GOLD}@0.85:t=fill[${n2}];"
        LABELS_CHAIN+="[${n2}]drawbox=x=${h_left}:y=${box_y}:w=${h_w}:h=2:color=${GOLD}@0.85:t=fill[${n3}];"
        LABELS_CHAIN+="[${n3}]drawbox=x=${box_x}:y=${box_y}:w=${box_w}:h=${BOX_H}:color=black@0.78:t=fill[${n4}];"
        LABELS_CHAIN+="[${n4}]drawbox=x=${box_x}:y=${box_y}:w=${ACCENT_W}:h=${BOX_H}:color=${GOLD}:t=fill[${n5}];"
        LABELS_CHAIN+="[${n5}]drawbox=x=${box_x}:y=${box_y}:w=${box_w}:h=${BOX_H}:color=${GOLD}@0.5:t=1[${n6}];"
        LABELS_CHAIN+="[${n6}]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/label${idx}.txt:fontcolor=white:fontsize=${LABEL_FONTSIZE}:x=$((box_x + ACCENT_W + LABEL_PAD_L)):y=$((box_y + (BOX_H - LABEL_FONTSIZE) / 2)):${SHADOW}[${n7}];"
        LABELS_CHAIN+="[${n7}][dm${idx}]overlay=x=$((x - 8)):y=$((y - 8)):shortest=1[${n1}];"

        prev="$n1"
    done

    LABELS_OUT="[${prev}]"
    echo "Drew $n label(s) from $labels_file"
}

#############################################
# prepare_video_content — per-video override mechanism
# (<basename>.headlines.txt / .facts.txt / .instrument.txt), rebuilds
# BASE_CHAIN / FACT_END for the video about to stream.
#############################################
prepare_video_content() {
    local url="$1"
    local base
    base="${url##*/}"
    base="${base%.*}"
    local i idx

    RAW_LINES=()
    if [ -f "${base}.headlines.txt" ]; then
        echo "Using curated headlines: ${base}.headlines.txt"
        while IFS= read -r line; do
            [ -n "$(echo "$line" | tr -d '[:space:]')" ] && RAW_LINES+=("$line")
        done < "${base}.headlines.txt"
    fi
    if [ "${#RAW_LINES[@]}" -eq 0 ]; then
        local pool=()
        if [ -f "$INFO_FILE" ]; then
            while IFS= read -r line; do
                [ -n "$(echo "$line" | tr -d '[:space:]')" ] && pool+=("$line")
            done < "$INFO_FILE"
        fi
        [ "${#pool[@]}" -eq 0 ] && pool=("${DEFAULT_HEADLINES[@]}")
        while IFS= read -r line; do
            RAW_LINES+=("$line")
        done < <(printf '%s\n' "${pool[@]}" | shuf)
    fi

    FACTS=()
    if [ -f "${base}.facts.txt" ]; then
        echo "Using curated facts: ${base}.facts.txt"
        while IFS= read -r line; do
            [ -n "$(echo "$line" | tr -d '[:space:]')" ] && FACTS+=("$line")
        done < "${base}.facts.txt"
    fi
    if [ "${#FACTS[@]}" -eq 0 ]; then
        local fpool=()
        if [ -f "facts.txt" ]; then
            while IFS= read -r line; do
                [ -n "$(echo "$line" | tr -d '[:space:]')" ] && fpool+=("$line")
            done < "facts.txt"
        fi
        [ "${#fpool[@]}" -eq 0 ] && fpool=("${DEFAULT_FACTS[@]}")
        while IFS= read -r line; do
            FACTS+=("$line")
        done < <(printf '%s\n' "${fpool[@]}" | shuf)
    fi

    if [ -f "${base}.instrument.txt" ]; then
        head -n 1 "${base}.instrument.txt" > "$ASSET_DIR/instr_sub.txt"
    else
        printf 'Look along the day/night line, where long shadows make craters and mountains stand out.' > "$ASSET_DIR/instr_sub.txt"
    fi
    fold -s -w 26 "$ASSET_DIR/instr_sub.txt" > "$ASSET_DIR/instr_sub.wrapped.txt"

    N=${#RAW_LINES[@]}
    CYCLE=$((N * SLOT))
    echo "This video: $N headline(s), rotation cycle ${CYCLE}s"

    for i in "${!RAW_LINES[@]}"; do
        idx=$((i + 1))
        echo "${RAW_LINES[$i]}" | fold -s -w 25 > "$ASSET_DIR/headline${idx}.txt"
    done

    MAX_HEADLINE_LINES=1
    for i in "${!RAW_LINES[@]}"; do
        idx=$((i + 1))
        lines=$(grep -c '' "$ASSET_DIR/headline${idx}.txt")
        [ "$lines" -gt "$MAX_HEADLINE_LINES" ] && MAX_HEADLINE_LINES=$lines
    done
    echo "Longest headline wraps to $MAX_HEADLINE_LINES line(s)."

    HEADLINE_Y=230
    PROGRESS_Y=$((HEADLINE_Y + MAX_HEADLINE_LINES * HEADLINE_LINE_H + 40))
    DOTS_Y=$((PROGRESS_Y + 20))

    TICKER_STRING=""
    for i in "${!RAW_LINES[@]}"; do
        TICKER_STRING+="${RAW_LINES[$i]}     •     "
    done
    printf '%s' "$TICKER_STRING" > "$ASSET_DIR/ticker.txt"

    FACT_N=${#FACTS[@]}
    FACT_CYCLE=$((FACT_N * FACT_SLOT))
    local max_fact_lines=1
    for i in "${!FACTS[@]}"; do
        idx=$((i + 1))
        echo "${FACTS[$i]}" | fold -s -w 24 > "$ASSET_DIR/fact${idx}.txt"
        lines=$(grep -c '' "$ASSET_DIR/fact${idx}.txt")
        [ "$lines" -gt "$max_fact_lines" ] && max_fact_lines=$lines
    done
    MAX_FACT_LINES=$max_fact_lines

    RSTAT_Y=19
    RDIV1_Y=$((RSTAT_Y + 4 * 20 + 6))
    RINSTR_LABEL_Y=$((RDIV1_Y + 20))
    RINSTR_TITLE_Y=$((RINSTR_LABEL_Y + 22))
    RINSTR_SUB_Y=$((RINSTR_TITLE_Y + 30))
    RDIV2_Y=$((RINSTR_SUB_Y + 44 + 16))
    RFACT_LABEL_Y=$((RDIV2_Y + 14))
    RFACT_TEXT_Y=$((RFACT_LABEL_Y + 24))

    #########################################
    # Moon state for this video. Refreshed on every video rotation, which
    # is plenty for things that change over hours/days (phase disc, cycle
    # bar, illumination gauge). The text readouts refresh live via reload=1.
    #########################################
    local MOON_PSI=90 MOON_ILLUM_PCT=50 MOON_AGE_FRAC=0.25 MOON_COSA=0 MOON_WAXING=1
    read -r MOON_PSI MOON_ILLUM_PCT MOON_AGE_FRAC MOON_COSA MOON_WAXING < <(python3 moon_calc.py once 2>/dev/null) || true
    local MOON_SGN=1
    [ "$MOON_WAXING" = "0" ] && MOON_SGN=-1
    [ "$MOON_FLIP" = "true" ] && MOON_SGN=$((MOON_SGN * -1))
    echo "Moon this video: phase angle ${MOON_PSI} deg, ${MOON_ILLUM_PCT} PCT illuminated, cycle fraction ${MOON_AGE_FRAC}"

    #########################################
    # Rebuild BASE_CHAIN for this video's content
    #########################################
    CHAIN="color=c=black:s=1280x720[canvas];"
    # Scale by VIDEO_ZOOM extra so there's margin to pan within, then crop
    # the fixed output size from a position offset by VIDEO_PAN_X/Y — at
    # zoom=1.0/pan=0 this is a plain center-crop.
    local ZOOM_W ZOOM_H
    ZOOM_W=$(awk -v w="$CENTER_W" -v z="$VIDEO_ZOOM" 'BEGIN{printf "%d", w*z}')
    ZOOM_H=$(awk -v h="$VIDEO_ROW_H" -v z="$VIDEO_ZOOM" 'BEGIN{printf "%d", h*z}')
    CHAIN+="[0:v]fps=30,scale=${ZOOM_W}:${ZOOM_H}:force_original_aspect_ratio=increase,crop=${CENTER_W}:${VIDEO_ROW_H}:x='(in_w-out_w)/2+(in_w-out_w)/2*${VIDEO_PAN_X}':y='(in_h-out_h)/2+(in_h-out_h)/2*${VIDEO_PAN_Y}'[vidfit];"
    CHAIN+="[canvas][vidfit]overlay=${CENTER_X0}:${ROW1_Y}:shortest=1[base];"

    build_labels_chain "$url"
    CHAIN+="$LABELS_CHAIN"

    # ---------------- Broadcast-style corner brackets on the video ----------------
    local BR_L=26 BR_T=3 BR_M=10
    local VX0=$CENTER_X0
    local VX1=$((CENTER_X0 + CENTER_W))
    local VY0=0
    local VY1=$VIDEO_ROW_H
    CHAIN+="${LABELS_OUT}drawbox=x=$((VX0 + BR_M)):y=$((VY0 + BR_M)):w=${BR_L}:h=${BR_T}:color=${GOLD}@0.9:t=fill[br1];"
    CHAIN+="[br1]drawbox=x=$((VX0 + BR_M)):y=$((VY0 + BR_M)):w=${BR_T}:h=${BR_L}:color=${GOLD}@0.9:t=fill[br2];"
    CHAIN+="[br2]drawbox=x=$((VX1 - BR_M - BR_L)):y=$((VY0 + BR_M)):w=${BR_L}:h=${BR_T}:color=${GOLD}@0.9:t=fill[br3];"
    CHAIN+="[br3]drawbox=x=$((VX1 - BR_M - BR_T)):y=$((VY0 + BR_M)):w=${BR_T}:h=${BR_L}:color=${GOLD}@0.9:t=fill[br4];"
    CHAIN+="[br4]drawbox=x=$((VX0 + BR_M)):y=$((VY1 - BR_M - BR_T)):w=${BR_L}:h=${BR_T}:color=${GOLD}@0.9:t=fill[br5];"
    CHAIN+="[br5]drawbox=x=$((VX0 + BR_M)):y=$((VY1 - BR_M - BR_L)):w=${BR_T}:h=${BR_L}:color=${GOLD}@0.9:t=fill[br6];"
    CHAIN+="[br6]drawbox=x=$((VX1 - BR_M - BR_L)):y=$((VY1 - BR_M - BR_T)):w=${BR_L}:h=${BR_T}:color=${GOLD}@0.9:t=fill[br7];"
    CHAIN+="[br7]drawbox=x=$((VX1 - BR_M - BR_T)):y=$((VY1 - BR_M - BR_L)):w=${BR_T}:h=${BR_L}:color=${GOLD}@0.9:t=fill[br8];"

    # Small reticle nodes at each bracket vertex + center tick marks.
    local BR_DOT=3
    CHAIN+="[br8]drawbox=x=$((VX0 + BR_M - 1)):y=$((VY0 + BR_M - 1)):w=${BR_DOT}:h=${BR_DOT}:color=${GOLD}:t=fill[brdot1];"
    CHAIN+="[brdot1]drawbox=x=$((VX1 - BR_M - 2)):y=$((VY0 + BR_M - 1)):w=${BR_DOT}:h=${BR_DOT}:color=${GOLD}:t=fill[brdot2];"
    CHAIN+="[brdot2]drawbox=x=$((VX0 + BR_M - 1)):y=$((VY1 - BR_M - 2)):w=${BR_DOT}:h=${BR_DOT}:color=${GOLD}:t=fill[brdot3];"
    CHAIN+="[brdot3]drawbox=x=$((VX1 - BR_M - 2)):y=$((VY1 - BR_M - 2)):w=${BR_DOT}:h=${BR_DOT}:color=${GOLD}:t=fill[brdot4];"
    local VMID_X=$((VX0 + CENTER_W / 2))
    CHAIN+="[brdot4]drawbox=x=$((VMID_X - 1)):y=${VY0}:w=2:h=8:color=${GOLD}@0.7:t=fill[brtick1];"
    CHAIN+="[brtick1]drawbox=x=$((VMID_X - 1)):y=$((VY1 - 8)):w=2:h=8:color=${GOLD}@0.7:t=fill[br8b];"
    local CAPTION_W=$(( ${#VIDEO_FEED_LABEL} * 8 + 30 ))
    [ "$CAPTION_W" -lt 150 ] && CAPTION_W=150
    CHAIN+="[br8b]drawbox=x=${VX0}:y=$((VY1 - 34)):w=${CAPTION_W}:h=34:color=black@0.55:t=fill[brcap1];"
    CHAIN+="[brcap1]drawtext=fontfile=${FONT}:text='${VIDEO_FEED_LABEL}':fontcolor=white@0.9:fontsize=13:x=$((VX0 + 14)):y=$((VY1 - 22)):${SHADOW}[brcap2];"
    local prev="brcap2"

    local CARD_PAD=10
    local CARD_X0=$((CENTER_X0 + CARD_PAD))
    local CARD_W=$((CENTER_W - CARD_PAD * 2))

    # ---------------- Row 2: MOON TONIGHT card ----------------
    local CM3_Y0=$((ROW2_Y + CARD_PAD))
    local CM3_Y1=$((ROW3_Y - CARD_PAD))
    CHAIN+="[${prev}]drawbox=x=${CARD_X0}:y=${CM3_Y0}:w=${CARD_W}:h=$((CM3_Y1 - CM3_Y0)):color=${PANEL_BG}@0.55:t=fill[cm3card];"
    CHAIN+="[cm3card]drawbox=x=${CARD_X0}:y=${CM3_Y0}:w=${CARD_W}:h=$((CM3_Y1 - CM3_Y0)):color=${GOLD}@0.3:t=1[cm3border];"

    local CM3_LABEL_Y=$((CM3_Y0 + 20))
    local CM3_LINE1_Y=$((CM3_LABEL_Y + 30))
    local CM3_LINE2_Y=$((CM3_LINE1_Y + 26))
    local CM3_LINE3_Y=$((CM3_LINE2_Y + 26))
    local CM3_LINE4_Y=$((CM3_LINE3_Y + 26))
    local CM3_LINE5_Y=$((CM3_LINE4_Y + 26))

    CHAIN+="[cm3border]drawbox=x=$((MTEXT_INSET - 2)):y=$((CM3_LABEL_Y - 2)):w=6:h=6:color=${GOLD}:t=fill[cm3z];"
    CHAIN+="[cm3z]drawtext=fontfile=${FONT}:text='MOON TONIGHT':fontcolor=${GOLD}@0.85:fontsize=13:x=$((MTEXT_INSET + 14)):y=$((CM3_LABEL_Y - 6))[cm3z2];"
    CHAIN+="[cm3z2]drawbox=x=${MTEXT_INSET}:y=$((CM3_LABEL_Y + 14)):w=$((CARD_W - 40)):h=1:color=white@0.15:t=fill[cm3a];"
    CHAIN+="[cm3a]drawtext=fontfile=${FONT}:text='PHASE':fontcolor=white@0.55:fontsize=13:x=${MTEXT_INSET}:y=${CM3_LINE1_Y}[cm3b];"
    CHAIN+="[cm3b]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/moon_phase.txt:reload=1:fontcolor=white:fontsize=14:x=${MVALUE_X}:y=${CM3_LINE1_Y}[cm3c];"
    CHAIN+="[cm3c]drawtext=fontfile=${FONT}:text='ILLUMINATED':fontcolor=white@0.55:fontsize=13:x=${MTEXT_INSET}:y=${CM3_LINE2_Y}[cm3d];"
    CHAIN+="[cm3d]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/moon_illum.txt:reload=1:fontcolor=white:fontsize=14:x=${MVALUE_X}:y=${CM3_LINE2_Y}[cm3e];"
    CHAIN+="[cm3e]drawtext=fontfile=${FONT}:text='MOON AGE':fontcolor=white@0.55:fontsize=13:x=${MTEXT_INSET}:y=${CM3_LINE3_Y}[cm3f];"
    CHAIN+="[cm3f]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/moon_age.txt:reload=1:fontcolor=white:fontsize=14:x=${MVALUE_X}:y=${CM3_LINE3_Y}[cm3g];"
    CHAIN+="[cm3g]drawtext=fontfile=${FONT}:text='DIST. FROM EARTH':fontcolor=white@0.55:fontsize=13:x=${MTEXT_INSET}:y=${CM3_LINE4_Y}[cm3h];"
    CHAIN+="[cm3h]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/moon_dist.txt:reload=1:fontcolor=white:fontsize=14:x=${MVALUE_X}:y=${CM3_LINE4_Y}[cm3i];"
    CHAIN+="[cm3i]drawtext=fontfile=${FONT}:text='EVENT':fontcolor=white@0.55:fontsize=13:x=${MTEXT_INSET}:y=${CM3_LINE5_Y}[cm3j];"
    CHAIN+="[cm3j]drawtext=fontfile=${FONT}:text='InOMN · Sep 19, 2026':fontcolor=${GOLD}:fontsize=14:x=${MVALUE_X}:y=${CM3_LINE5_Y}[cm3final];"
    prev="cm3final"

    # ---------------- Row 2, right: live-rendered Moon phase disc ----------------
    # Drawn procedurally with geq from tonight's phase angle: the lit side
    # is right-hand for a waxing Moon and left-hand for a waning one (Northern
    # Hemisphere view; MOON_FLIP=true mirrors it), with a little limb
    # shading so it reads as a sphere.
    local MID_X0=$((MTEXT_INSET + 400))
    local MID_AVAIL_W=$(((CARD_X0 + CARD_W - 14) - MID_X0))
    local MID_TOP=$((CM3_LABEL_Y + 14 + 14))
    local MID_BOTTOM=$((CM3_Y1 - 16))
    local MID_AVAIL_H=$((MID_BOTTOM - MID_TOP))
    if [ "$MID_AVAIL_W" -ge 90 ] && [ "$MID_AVAIL_H" -ge 90 ]; then
        local MTHUMB=$MID_AVAIL_W
        [ "$MID_AVAIL_H" -lt "$MTHUMB" ] && MTHUMB=$MID_AVAIL_H
        [ "$MTHUMB" -gt 130 ] && MTHUMB=130
        local MTX=$((MID_X0 + (MID_AVAIL_W - MTHUMB) / 2))
        local MTY=$((MID_TOP + (MID_AVAIL_H - MTHUMB) / 2))
        local MC=$((MTHUMB / 2))
        local MR=$((MTHUMB / 2 - 3))
        local M_RR="(hypot(X-${MC}\,Y-${MC})/${MR})"
        local M_SQ="sqrt(max(0\,1-pow((Y-${MC})/${MR}\,2)))"
        local M_LIT="gte(${MOON_SGN}*(X-${MC})/${MR}\,${MOON_COSA}*${M_SQ})"
        local M_LIMB="(0.72+0.28*sqrt(max(0\,1-pow(${M_RR}\,2))))"
        local M_R_EXPR="if(lte(${M_RR}\,1)\,if(${M_LIT}\,236*${M_LIMB}\,28)\,0)"
        local M_G_EXPR="if(lte(${M_RR}\,1)\,if(${M_LIT}\,232*${M_LIMB}\,32)\,0)"
        local M_B_EXPR="if(lte(${M_RR}\,1)\,if(${M_LIT}\,214*${M_LIMB}\,44)\,0)"
        local M_A_EXPR="if(lte(${M_RR}\,1)\,255\,0)"
        CHAIN+="[${prev}]drawbox=x=$((MTX - 4)):y=$((MTY - 4)):w=$((MTHUMB + 8)):h=$((MTHUMB + 8)):color=black@0.6:t=fill[mthumbbg];"
        CHAIN+="[mthumbbg]drawbox=x=$((MTX - 4)):y=$((MTY - 4)):w=$((MTHUMB + 8)):h=$((MTHUMB + 8)):color=${GOLD}@0.5:t=1[mthumbborder];"
        # 1 fps source: the phase doesn't animate, so don't burn CPU on 30 geq frames/s.
        CHAIN+="color=c=black@0:s=${MTHUMB}x${MTHUMB}:r=1[moon_src];"
        CHAIN+="[moon_src]format=rgba,geq=r='${M_R_EXPR}':g='${M_G_EXPR}':b='${M_B_EXPR}':a='${M_A_EXPR}'[mimg];"
        CHAIN+="[mthumbborder][mimg]overlay=x=${MTX}:y=${MTY}:shortest=1[mthumbfinal];"
        prev="mthumbfinal"
    fi

    # ---------------- Row 3: LUNAR CYCLE progress bar ----------------
    # Fill = how far through the ~29.5-day new-to-new cycle the Moon is,
    # with ticks at new / first quarter / full / last quarter.
    local CM4_Y0=$((ROW3_Y + CARD_PAD))
    local CM4_Y1=$((680 - CARD_PAD))
    CHAIN+="[${prev}]drawbox=x=${CARD_X0}:y=${CM4_Y0}:w=${CARD_W}:h=$((CM4_Y1 - CM4_Y0)):color=${PANEL_BG}@0.55:t=fill[cm4card];"
    CHAIN+="[cm4card]drawbox=x=${CARD_X0}:y=${CM4_Y0}:w=${CARD_W}:h=$((CM4_Y1 - CM4_Y0)):color=${RED}@0.3:t=1[cm4border];"

    local CM4_LABEL_Y=$((CM4_Y0 + 20))
    local CM4_BAR_Y=$((CM4_LABEL_Y + 22))
    local CM4_BAR_H=18
    local CM4_BAR_X=$((MTEXT_INSET - 4))
    local CM4_BAR_W=$((CARD_W - 40))
    local CM4_FILL_W
    CM4_FILL_W=$(awk -v w="$CM4_BAR_W" -v f="$MOON_AGE_FRAC" 'BEGIN{printf "%d", w*f}')
    [ "$CM4_FILL_W" -gt "$CM4_BAR_W" ] && CM4_FILL_W=$CM4_BAR_W
    [ "$CM4_FILL_W" -lt 0 ] && CM4_FILL_W=0
    local CM4_TICK_LABEL_Y=$((CM4_BAR_Y + CM4_BAR_H + 12))

    CHAIN+="[cm4border]drawbox=x=$((MTEXT_INSET - 2)):y=$((CM4_LABEL_Y - 2)):w=6:h=6:color=${RED}:t=fill:enable='lt(mod(t\,1.2)\,0.75)'[cm4a];"
    CHAIN+="[cm4a]drawtext=fontfile=${FONT}:text='LUNAR CYCLE (est.)':fontcolor=white@0.75:fontsize=13:x=$((MTEXT_INSET + 14)):y=$((CM4_LABEL_Y - 6))[cm4b];"
    CHAIN+="[cm4b]drawbox=x=${CM4_BAR_X}:y=${CM4_BAR_Y}:w=${CM4_BAR_W}:h=${CM4_BAR_H}:color=black@0.4:t=fill[cm4barbg];"
    CHAIN+="[cm4barbg]drawbox=x=${CM4_BAR_X}:y=${CM4_BAR_Y}:w=${CM4_FILL_W}:h=${CM4_BAR_H}:color=${GOLD}@0.85:t=fill[cm4fill];"
    CHAIN+="[cm4fill]drawbox=x=${CM4_BAR_X}:y=${CM4_BAR_Y}:w=${CM4_BAR_W}:h=${CM4_BAR_H}:color=white@0.2:t=1[cm4barborder];"
    prev="cm4barborder"
    local tk tkx
    for tk in 1 2 3; do
        tkx=$((CM4_BAR_X + CM4_BAR_W * tk / 4))
        CHAIN+="[${prev}]drawbox=x=${tkx}:y=${CM4_BAR_Y}:w=1:h=${CM4_BAR_H}:color=white@0.45:t=fill[cm4t${tk}];"
        prev="cm4t${tk}"
    done
    # "You are here" marker at the current point in the cycle.
    CHAIN+="[${prev}]drawbox=x=$((CM4_BAR_X + CM4_FILL_W - 1)):y=$((CM4_BAR_Y - 4)):w=3:h=$((CM4_BAR_H + 8)):color=white:t=fill[cm4mark];"
    CHAIN+="[cm4mark]drawtext=fontfile=${FONT}:text='NEW':fontcolor=white@0.55:fontsize=12:x=${CM4_BAR_X}:y=${CM4_TICK_LABEL_Y}[cm4l1];"
    CHAIN+="[cm4l1]drawtext=fontfile=${FONT}:text='1ST QTR':fontcolor=white@0.55:fontsize=12:x=$((CM4_BAR_X + CM4_BAR_W / 4))-text_w/2:y=${CM4_TICK_LABEL_Y}[cm4l2];"
    CHAIN+="[cm4l2]drawtext=fontfile=${FONT}:text='FULL':fontcolor=white@0.55:fontsize=12:x=$((CM4_BAR_X + CM4_BAR_W / 2))-text_w/2:y=${CM4_TICK_LABEL_Y}[cm4l3];"
    CHAIN+="[cm4l3]drawtext=fontfile=${FONT}:text='LAST QTR':fontcolor=white@0.55:fontsize=12:x=$((CM4_BAR_X + CM4_BAR_W * 3 / 4))-text_w/2:y=${CM4_TICK_LABEL_Y}[cm4l4];"
    CHAIN+="[cm4l4]drawtext=fontfile=${FONT}:text='NEW':fontcolor=white@0.55:fontsize=12:x=$((CM4_BAR_X + CM4_BAR_W))-text_w:y=${CM4_TICK_LABEL_Y}[cm4base];"
    prev="cm4base"

    # ---------------- Left panel: story / headlines ----------------
    CHAIN+="[${prev}]drawbox=x=0:y=0:w=${PANEL_W}:h=720:color=${PANEL_BG}@0.94:t=fill[p1];"
    CHAIN+="[p1]drawbox=x=${PANEL_W}:y=0:w=3:h=720:color=${GOLD}@0.75:t=fill[p2];"
    # Top-edge "glow" (a soft wide bar under a thin bright one).
    CHAIN+="[p2]drawbox=x=0:y=0:w=${PANEL_W}:h=10:color=${GOLD}@0.18:t=fill[p2g];"
    CHAIN+="[p2g]drawbox=x=0:y=0:w=${PANEL_W}:h=3:color=${GOLD}@0.95:t=fill[p3];"

    CHAIN+="[p3]drawbox=x=27:y=28:w=11:h=11:color=${RED}:t=fill:enable='lt(mod(t\,1)\,0.6)'[p4];"
    CHAIN+="[p4]drawtext=fontfile=${FONT}:text='LIVE':fontcolor=white:fontsize=30:x=44:y=19[p5];"
    CHAIN+="[p5]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/eyebrow.txt:fontcolor=${GOLD}@0.9:fontsize=13:x=${TEXT_INSET}-text_w+280:y=39[p6];"

    CHAIN+="[p6]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/title1.txt:fontcolor=white:fontsize=22:x=${TEXT_INSET}:y=95:${SHADOW}[p7];"
    CHAIN+="[p7]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/title2.txt:fontcolor=white@0.85:fontsize=16:x=${TEXT_INSET}:y=123:${SHADOW}[p8];"
    CHAIN+="[p8]drawbox=x=${TEXT_INSET}:y=153:w=${PANEL_TEXT_W}:h=2:color=white@0.3:t=fill[p9];"

    CHAIN+="[p9]drawbox=x=${TEXT_INSET}:y=171:w=8:h=8:color=${GOLD}:t=fill[p10];"
    CHAIN+="[p10]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/header.txt:fontcolor=${GOLD}:fontsize=14:x=$((TEXT_INSET + 16)):y=168[p11];"
    CHAIN+="[p11]drawtext=fontfile=${FONT}:text='NOW\: ':fontcolor=white@0.45:fontsize=12:x=${TEXT_INSET}:y=191[p11b];"
    CHAIN+="[p11b]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/moon_summary.txt:reload=1:fontcolor=${GOLD}@0.85:fontsize=12:x=$((TEXT_INSET + 42)):y=191[p11c];"

    local prev="p11c"
    for i in "${!RAW_LINES[@]}"; do
        idx=$((i + 1))
        local start=$((i * SLOT))
        local end=$((start + SLOT))
        local nxt="h${idx}"
        local ALPHA="if(between(mod(t\,${CYCLE})\,${start}\,${end})\,if(lt(mod(t\,${CYCLE})-${start}\,0.6)\,(mod(t\,${CYCLE})-${start})/0.6\,if(gt(mod(t\,${CYCLE})-${start}\,${SLOT}-0.6)\,(${end}-mod(t\,${CYCLE}))/0.6\,1))\,0)"
        CHAIN+="[${prev}]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/headline${idx}.txt:fontcolor=white:fontsize=${HEADLINE_FONTSIZE}:line_spacing=${HEADLINE_LINE_SPACING}:x=${TEXT_INSET}:y=${HEADLINE_Y}:alpha='${ALPHA}':${SHADOW}[${nxt}];"
        prev="$nxt"
    done

    CHAIN+="[${prev}]drawtext=fontfile=${FONT}:text='STORY PROGRESS':fontcolor=white@0.35:fontsize=9:x=${TEXT_INSET}:y=$((PROGRESS_Y - 15))[pgcap];"
    CHAIN+="[pgcap]drawbox=x=${TEXT_INSET}:y=${PROGRESS_Y}:w=${PANEL_TEXT_W}:h=2:color=white@0.15:t=fill[pg1];"
    CHAIN+="[pg1]drawbox=x=${TEXT_INSET}:y=${PROGRESS_Y}:w='${PANEL_TEXT_W}*(mod(t\,${SLOT}))/${SLOT}':h=2:color=${GOLD}:t=fill[pg2];"
    prev="pg2"

    for i in "${!RAW_LINES[@]}"; do
        idx=$((i + 1))
        local x=$((TEXT_INSET + i * 17))
        local nxt="db${idx}"
        CHAIN+="[${prev}]drawbox=x=${x}:y=${DOTS_Y}:w=7:h=7:color=white@0.3:t=fill[${nxt}];"
        prev="$nxt"
    done

    local last=$((N - 1))
    for i in "${!RAW_LINES[@]}"; do
        idx=$((i + 1))
        local x=$((TEXT_INSET + i * 17))
        local start=$((i * SLOT))
        local end=$((start + SLOT))
        local ENABLE="between(mod(t\,${CYCLE})\,${start}\,${end})"
        if [ "$i" -eq "$last" ]; then
            CHAIN+="[${prev}]drawbox=x=${x}:y=${DOTS_Y}:w=7:h=7:color=${GOLD}:t=fill:enable='${ENABLE}'[pdotend];"
            prev="pdotend"
        else
            local nxt="da${idx}"
            CHAIN+="[${prev}]drawbox=x=${x}:y=${DOTS_Y}:w=7:h=7:color=${GOLD}:t=fill:enable='${ENABLE}'[${nxt}];"
            prev="$nxt"
        fi
    done

    # ---------------- Left panel: animated "LIVE SIGNAL" bar graph ----------------
    # Purely decorative (not data-driven), like the activity graph in the
    # earlier scripts — so it carries no number, just motion.
    local GRAPH_LABEL_Y=$((DOTS_Y + 40))
    local GRAPH_BASE_Y=$((GRAPH_LABEL_Y + 160))
    local BAR_COUNT=14
    local BAR_W=13
    local BAR_GAP=6
    local BAR_MINH=8
    local BAR_MAXH=100

    CHAIN+="[${prev}]drawbox=x=$((TEXT_INSET - 2)):y=$((GRAPH_LABEL_Y - 2)):w=6:h=6:color=${GOLD}:t=fill:enable='lt(mod(t\,1.4)\,0.9)'[sa1];"
    CHAIN+="[sa1]drawtext=fontfile=${FONT}:text='LIVE SIGNAL':fontcolor=white@0.55:fontsize=11:x=$((TEXT_INSET + 14)):y=$((GRAPH_LABEL_Y - 8))[sa3];"
    prev="sa3"

    local bi bx h_expr y_expr bnxt
    for ((bi = 0; bi < BAR_COUNT; bi++)); do
        bx=$((TEXT_INSET + bi * (BAR_W + BAR_GAP)))
        h_expr="clip(60+38*sin(2*PI*t/3.1+${bi}*0.55)+18*sin(2*PI*t/1.6+${bi}*0.9)\,${BAR_MINH}\,${BAR_MAXH})"
        y_expr="${GRAPH_BASE_Y}-(${h_expr})"
        bnxt="sabar${bi}"
        CHAIN+="[${prev}]drawbox=x=${bx}:y='${y_expr}':w=${BAR_W}:h='${h_expr}':color=${GOLD}@0.8:t=fill[${bnxt}];"
        prev="$bnxt"
    done
    CHAIN+="[${prev}]drawbox=x=${TEXT_INSET}:y=${GRAPH_BASE_Y}:w=${PANEL_TEXT_W}:h=1:color=white@0.2:t=fill[sabase];"
    prev="sabase"

    # ---------------- Right panel: stats + observing tip + facts ----------------
    CHAIN+="[${prev}]drawbox=x=${RIGHT_X0}:y=0:w=${PANEL_W}:h=720:color=${PANEL_BG}@0.94:t=fill[r1];"
    CHAIN+="[r1]drawbox=x=$((RIGHT_X0 - 3)):y=0:w=3:h=720:color=${GOLD}@0.75:t=fill[r2];"
    CHAIN+="[r2]drawbox=x=${RIGHT_X0}:y=0:w=${PANEL_W}:h=10:color=${GOLD}@0.18:t=fill[r2g];"
    CHAIN+="[r2g]drawbox=x=${RIGHT_X0}:y=0:w=${PANEL_W}:h=3:color=${GOLD}@0.95:t=fill[r3];"

    CHAIN+="[r3]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/credit.txt:fontcolor=white@0.85:fontsize=14:x=${RTEXT_INSET}:y=${RSTAT_Y}[r4];"
    CHAIN+="[r4]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/clock.txt:reload=1:fontcolor=${GOLD}:fontsize=14:x=${RTEXT_INSET}:y=$((RSTAT_Y + 20))[r5];"
    CHAIN+="[r5]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/subs.txt:reload=1:fontcolor=white@0.75:fontsize=13:x=${RTEXT_INSET}:y=$((RSTAT_Y + 40))[r6];"
    CHAIN+="[r6]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/viewers.txt:reload=1:fontcolor=white@0.75:fontsize=13:x=${RTEXT_INSET}:y=$((RSTAT_Y + 60))[r7];"

    CHAIN+="[r7]drawbox=x=${RTEXT_INSET}:y=${RDIV1_Y}:w=${PANEL_TEXT_W}:h=2:color=white@0.15:t=fill[r8];"

    CHAIN+="[r8]drawbox=x=${RTEXT_INSET}:y=${RINSTR_LABEL_Y}:w=8:h=8:color=${GOLD}:t=fill[r9];"
    CHAIN+="[r9]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/instr_label.txt:fontcolor=${GOLD}:fontsize=14:x=$((RTEXT_INSET + 16)):y=$((RINSTR_LABEL_Y - 3))[r10];"
    CHAIN+="[r10]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/instr_title.txt:fontcolor=white:fontsize=20:x=${RTEXT_INSET}:y=${RINSTR_TITLE_Y}:${SHADOW}[r11];"
    CHAIN+="[r11]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/instr_sub.wrapped.txt:fontcolor=white@0.75:fontsize=14:line_spacing=6:x=${RTEXT_INSET}:y=${RINSTR_SUB_Y}[r12];"

    CHAIN+="[r12]drawbox=x=${RTEXT_INSET}:y=${RDIV2_Y}:w=${PANEL_TEXT_W}:h=2:color=${GOLD}@0.4:t=fill[r13];"
    CHAIN+="[r13]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/fact_label.txt:fontcolor=${GOLD}@0.85:fontsize=12:x=${RTEXT_INSET}:y=${RFACT_LABEL_Y}[r14];"
    prev="r14"
    for i in "${!FACTS[@]}"; do
        idx=$((i + 1))
        local start=$((i * FACT_SLOT))
        local end=$((start + FACT_SLOT))
        local nxt="f${idx}"
        local FALPHA="if(between(mod(t\,${FACT_CYCLE})\,${start}\,${end})\,if(lt(mod(t\,${FACT_CYCLE})-${start}\,0.6)\,(mod(t\,${FACT_CYCLE})-${start})/0.6\,if(gt(mod(t\,${FACT_CYCLE})-${start}\,${FACT_SLOT}-0.6)\,(${end}-mod(t\,${FACT_CYCLE}))/0.6\,1))\,0)"
        CHAIN+="[${prev}]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/fact${idx}.txt:fontcolor=white@0.9:fontsize=${FACT_FONTSIZE}:line_spacing=${FACT_LINE_SPACING}:x=${RTEXT_INSET}:y=${RFACT_TEXT_Y}:alpha='${FALPHA}'[${nxt}];"
        prev="$nxt"
    done

    # ---------------- Right panel: Moon readings (computed) ----------------
    local RREAD_DIV_Y=$((RFACT_TEXT_Y + MAX_FACT_LINES * FACT_LINE_H + 16))
    local RREAD_LABEL_Y=$((RREAD_DIV_Y + 14))
    local RREAD_LINE1_Y=$((RREAD_LABEL_Y + 22))
    local RREAD_LINE2_Y=$((RREAD_LINE1_Y + 20))
    local RREAD_LINE3_Y=$((RREAD_LINE2_Y + 20))
    local RREAD_LINE4_Y=$((RREAD_LINE3_Y + 20))
    local RGRAPH_LABEL_Y=$((RREAD_LINE4_Y + 30))

    CHAIN+="[${prev}]drawbox=x=${RTEXT_INSET}:y=${RREAD_DIV_Y}:w=${PANEL_TEXT_W}:h=2:color=white@0.15:t=fill[rr0];"
    CHAIN+="[rr0]drawtext=fontfile=${FONT}:text='MOON READINGS (est.)':fontcolor=${GOLD}@0.85:fontsize=12:x=${RTEXT_INSET}:y=${RREAD_LABEL_Y}[rr0b];"
    CHAIN+="[rr0b]drawtext=fontfile=${FONT}:text='LIGHT TIME':fontcolor=white@0.55:fontsize=12:x=${RTEXT_INSET}:y=${RREAD_LINE1_Y}[rr0c];"
    CHAIN+="[rr0c]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/moon_light.txt:reload=1:fontcolor=white:fontsize=13:x=$((RTEXT_INSET + 80)):y=${RREAD_LINE1_Y}[rr1];"
    CHAIN+="[rr1]drawtext=fontfile=${FONT}:text='ANG. SIZE':fontcolor=white@0.55:fontsize=12:x=${RTEXT_INSET}:y=${RREAD_LINE2_Y}[rr1b];"
    CHAIN+="[rr1b]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/moon_ang.txt:reload=1:fontcolor=white:fontsize=13:x=$((RTEXT_INSET + 80)):y=${RREAD_LINE2_Y}[rr2];"
    CHAIN+="[rr2]drawtext=fontfile=${FONT}:text='NEXT FULL':fontcolor=white@0.55:fontsize=12:x=${RTEXT_INSET}:y=${RREAD_LINE3_Y}[rr2b];"
    CHAIN+="[rr2b]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/moon_next_full.txt:reload=1:fontcolor=white:fontsize=13:x=$((RTEXT_INSET + 80)):y=${RREAD_LINE3_Y}[rr2c];"
    CHAIN+="[rr2c]drawtext=fontfile=${FONT}:text='NEXT NEW':fontcolor=white@0.55:fontsize=12:x=${RTEXT_INSET}:y=${RREAD_LINE4_Y}[rr2d];"
    CHAIN+="[rr2d]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/moon_next_new.txt:reload=1:fontcolor=white:fontsize=13:x=$((RTEXT_INSET + 80)):y=${RREAD_LINE4_Y}[rr3];"
    prev="rr3"

    # ---------------- Right panel: illumination pie gauge ----------------
    # Same procedural geq pie-wedge approach as before, now filled to the
    # Moon's current illuminated percentage.
    local PIE_LABEL_Y=$((RGRAPH_LABEL_Y))
    local PIE_TOP=$((PIE_LABEL_Y + 18))
    local PIE_AVAIL_H=$((660 - PIE_TOP))
    local PIE_SIZE=$PIE_AVAIL_H
    [ "$PIE_SIZE" -gt "$PANEL_TEXT_W" ] && PIE_SIZE=$PANEL_TEXT_W
    [ "$PIE_SIZE" -gt 130 ] && PIE_SIZE=130
    local PIE_CX=$((PIE_SIZE / 2))
    local PIE_CY=$((PIE_SIZE / 2))
    local PIE_R=$((PIE_SIZE / 2 - 4))
    local PIE_X=$((RTEXT_INSET + (PANEL_TEXT_W - PIE_SIZE) / 2))
    local PIE_Y=$PIE_TOP

    local PIE_PCT_NOW=$MOON_ILLUM_PCT
    [ "$PIE_PCT_NOW" -gt 100 ] && PIE_PCT_NOW=100
    [ "$PIE_PCT_NOW" -lt 0 ] && PIE_PCT_NOW=0
    local PIE_DIST="hypot(X-${PIE_CX}\,Y-${PIE_CY})"
    local PIE_THETA="mod(atan2(Y-${PIE_CY}\,X-${PIE_CX})+PI/2+2*PI\,2*PI)"
    local PIE_FILL_ANGLE="(2*PI*${PIE_PCT_NOW}/100)"
    local PIE_R_EXPR="if(lte(${PIE_DIST}\,${PIE_R})\,if(lte(${PIE_THETA}\,${PIE_FILL_ANGLE})\,${GOLD_R}\,45)\,0)"
    local PIE_G_EXPR="if(lte(${PIE_DIST}\,${PIE_R})\,if(lte(${PIE_THETA}\,${PIE_FILL_ANGLE})\,${GOLD_G}\,45)\,0)"
    local PIE_B_EXPR="if(lte(${PIE_DIST}\,${PIE_R})\,if(lte(${PIE_THETA}\,${PIE_FILL_ANGLE})\,${GOLD_B}\,45)\,0)"
    local PIE_A_EXPR="if(lte(${PIE_DIST}\,${PIE_R})\,255\,0)"

    CHAIN+="[${prev}]drawbox=x=$((RTEXT_INSET - 2)):y=$((PIE_LABEL_Y - 2)):w=6:h=6:color=${GOLD}:t=fill[rgp1];"
    CHAIN+="[rgp1]drawtext=fontfile=${FONT}:text='MOON ILLUMINATED':fontcolor=white@0.55:fontsize=11:x=$((RTEXT_INSET + 14)):y=$((PIE_LABEL_Y - 8))[rgp2];"
    CHAIN+="color=c=black@0:s=${PIE_SIZE}x${PIE_SIZE}:r=1[pie_src];"
    CHAIN+="[pie_src]format=rgba,geq=r='${PIE_R_EXPR}':g='${PIE_G_EXPR}':b='${PIE_B_EXPR}':a='${PIE_A_EXPR}'[pie_img];"
    CHAIN+="[rgp2][pie_img]overlay=x=${PIE_X}:y=${PIE_Y}:shortest=1[rgp3];"
    CHAIN+="[rgp3]drawtext=fontfile=${FONT}:text='${PIE_PCT_NOW} PCT':fontcolor=white:fontsize=16:x=$((PIE_X + PIE_SIZE / 2 - 28)):y=$((PIE_Y + PIE_SIZE / 2 - 9)):${SHADOW}[rgp4];"
    CHAIN+="[rgp4]drawtext=fontfile=${FONT}:text='InOMN · September 19, 2026':fontcolor=white@0.5:fontsize=11:x=${RTEXT_INSET}:y=$((PIE_Y + PIE_SIZE + 12))[rgbase];"
    prev="rgbase"

    BASE_CHAIN="$CHAIN"
    FACT_END="$prev"
}

#############################################
# build_final_filter — CTA / ticker / watermark.
#############################################
build_final_filter() {
    local total_duration="$1"
    local tail="$BASE_CHAIN"

    local CTA_CYCLE=240
    local CTA_SHOW=8
    local CTA_ALPHA="if(between(mod(t\,${CTA_CYCLE})\,0\,${CTA_SHOW})\,if(lt(mod(t\,${CTA_CYCLE})\,0.6)\,mod(t\,${CTA_CYCLE})/0.6\,if(gt(mod(t\,${CTA_CYCLE})\,${CTA_SHOW}-0.6)\,(${CTA_SHOW}-mod(t\,${CTA_CYCLE}))/0.6\,1))\,0)"
    local CTA_ENABLE="between(mod(t\,${CTA_CYCLE})\,0\,${CTA_SHOW})"
    # Alternate the subscribe CTA with the "MOON QUIZ" trivia CTA every
    # other cycle. Parity is relative to this video's own start time
    # (ffmpeg's `t`), so a single long-running video will cycle between
    # the two; short/looping clips mostly land on the first.
    local CTA_EVEN="eq(mod(trunc(t/${CTA_CYCLE})\,2)\,0)"
    local CTA_ODD="eq(mod(trunc(t/${CTA_CYCLE})\,2)\,1)"

    local CTA_W=460
    local CTA_X=$((CENTER_X0 + (CENTER_W - CTA_W) / 2))
    local CTA_Y=640

    tail+="[${FACT_END}]drawbox=x=${CTA_X}:y=${CTA_Y}:w=${CTA_W}:h=43:color=black@0.75:t=fill:enable='${CTA_ENABLE}'[cta_bg];"
    tail+="[cta_bg]drawbox=x=${CTA_X}:y=${CTA_Y}:w=4:h=43:color=${GOLD}:t=fill:enable='${CTA_ENABLE}'[cta_bar];"
    tail+="[cta_bar]drawbox=x=$((CTA_X + 22)):y=$((CTA_Y + 16)):w=11:h=11:color=${RED}:t=fill:enable='${CTA_ENABLE}'[cta_dot];"
    tail+="[cta_dot]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/cta.txt:fontcolor=white:fontsize=18:x=$((CTA_X + 40)):y=$((CTA_Y + 13)):alpha='${CTA_ALPHA}':enable='${CTA_EVEN}'[cta_sub0];"
    tail+="[cta_sub0]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/cta_trivia.txt:reload=1:fontcolor=${GOLD}:fontsize=18:x=$((CTA_X + 40)):y=$((CTA_Y + 13)):alpha='${CTA_ALPHA}':enable='${CTA_ODD}'[cta_final];"

    tail+="[cta_final]drawbox=x=0:y=680:w=1280:h=40:color=black@0.85:t=fill[tk1];"
    tail+="[tk1]drawbox=x=0:y=680:w=1280:h=2:color=${GOLD}@0.9:t=fill[tk2];"
    tail+="[tk2]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/ticker.txt:fontcolor=white:fontsize=17:borderw=2:bordercolor=black@0.6:y=695:x='w-mod(t*${TICKER_SPEED}\,text_w+w)'[tk3];"
    tail+="[tk3]drawbox=x=0:y=680:w=120:h=40:color=black@0.9:t=fill[tk4];"
    tail+="[tk4]drawbox=x=0:y=682:w=113:h=38:color=${GOLD}:t=fill[tk5];"
    tail+="[tk5]drawtext=fontfile=${FONT}:text='LIVE NOW':fontcolor=black:fontsize=15:x=13:y=695[tk6];"

    # Date chip on the opposite corner. (Deliberately not a NASA wordmark:
    # this is your channel's stream, not an official NASA broadcast.)
    tail+="[tk6]drawbox=x=1160:y=680:w=120:h=40:color=black@0.9:t=fill[tk7];"
    tail+="[tk7]drawbox=x=1163:y=682:w=113:h=38:color=${RED}:t=fill[tk8];"
    tail+="[tk8]drawtext=fontfile=${FONT}:text='${RIGHT_CHIP_TEXT}':fontcolor=white:fontsize=15:x=1163+(113-text_w)/2:y=695[tk9];"

    tail+="[tk9]drawtext=fontfile=${FONT}:text='${CHANNEL_NAME}':fontcolor=white@0.45:fontsize=14:borderw=1.5:bordercolor=black@0.7:x=(w-text_w)/2:y=657[final]"

    echo "$tail"
}

#############################################
# is_image_url / get_image_local_path
#############################################
is_image_url() {
    local u="${1%%\?*}"
    local ext="${u##*.}"
    ext="$(echo "$ext" | tr '[:upper:]' '[:lower:]')"
    case "$ext" in
        jpg|jpeg|png|gif|bmp|webp) return 0 ;;
        *) return 1 ;;
    esac
}

get_image_local_path() {
    local url="$1"
    local base="${url##*/}"
    base="${base%%\?*}"
    local dest="img_cache_${base}"
    if [ ! -s "$dest" ]; then
        echo "Downloading image slide: $base" >&2
        if ! curl -sL --fail -o "$dest" "$url"; then
            rm -f "$dest"
            return 1
        fi
    fi
    echo "$dest"
    return 0
}

#############################################
# run_video — retry logic, image-slide handling, audio input, ffmpeg
# invocation.
#############################################
run_video() {
    local url="$1"
    local attempt=1

    local is_image=false
    local stream_source="$url"
    if is_image_url "$url"; then
        is_image=true
        local local_img
        if ! local_img=$(get_image_local_path "$url"); then
            echo "WARNING: failed to download image slide '$url' — skipping it."
            return 1
        fi
        stream_source="$local_img"
        echo "Image slide: $url -> $stream_source"
    else
        # Reachability pre-check for real video URLs (short HEAD request).
        # If the URL is genuinely unreachable and a fallback image is
        # configured, use it for this rotation instead of burning
        # MAX_RETRIES * RETRY_DELAY seconds retrying a dead video.
        if ! curl -sI --fail --max-time 10 "$url" >/dev/null 2>&1; then
            echo "WARNING: '$url' did not respond to a reachability check."
            if [ -n "$FALLBACK_IMAGE_URL" ]; then
                echo "Falling back to FALLBACK_IMAGE_URL for this rotation: $FALLBACK_IMAGE_URL"
                local fallback_local
                if fallback_local=$(get_image_local_path "$FALLBACK_IMAGE_URL"); then
                    url="$FALLBACK_IMAGE_URL"
                    is_image=true
                    stream_source="$fallback_local"
                else
                    echo "WARNING: fallback image also failed to download — proceeding with normal retries against the original URL."
                fi
            else
                echo "  (set FALLBACK_IMAGE_URL to skip straight to a fallback slide instead of retrying.)"
            fi
        fi
    fi

    prepare_video_content "$url"

    local duration
    if [ "$is_image" = true ]; then
        duration="$IMAGE_SLIDE_SECONDS"
        echo "Static image slide — showing for ${duration}s, locked to 30fps."
    else
        duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$url" 2>/dev/null || echo "")
        duration=${duration%.*}
        [[ "$duration" =~ ^[0-9]+$ ]] || duration=""
        if [ -n "$duration" ]; then
            echo "Probed duration: ${duration}s"
        else
            echo "Could not probe duration."
        fi
    fi

    local filter
    filter=$(build_final_filter "$duration")

    local AUDIO_INPUT_ARGS=()
    local AUDIO_MAP="2:a"
    if [ "$AUDIO_AVAILABLE" = true ]; then
        local this_audio="${AUDIO_LOCAL_FILES[$((AUDIO_COUNTER % NUM_AUDIO))]}"
        AUDIO_COUNTER=$((AUDIO_COUNTER + 1))
        echo "Background audio for this video: $this_audio"
        AUDIO_INPUT_ARGS=(-stream_loop -1 -i "$this_audio")
    else
        AUDIO_INPUT_ARGS=(-f lavfi -i "anullsrc=r=48000:cl=stereo")
    fi

    while [ "$attempt" -le "$MAX_RETRIES" ]; do
        echo "----------------------------------------"
        echo "Streaming (attempt ${attempt}/${MAX_RETRIES}):"
        echo "$url"
        echo "----------------------------------------"

        local MAIN_INPUT_ARGS=()
        local EXTRA_OUTPUT_ARGS=()
        if [ "$is_image" = true ]; then
            MAIN_INPUT_ARGS=(-loop 1 -framerate 30 -i "$stream_source")
            EXTRA_OUTPUT_ARGS=(-t "$duration")
        else
            MAIN_INPUT_ARGS=(-reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 -re -i "$stream_source")
        fi

        set +e
        ffmpeg \
        -hide_banner \
        -loglevel info \
        "${MAIN_INPUT_ARGS[@]}" \
        -loop 1 -framerate 30 -i "$DOT_MARKER" \
        "${AUDIO_INPUT_ARGS[@]}" \
        -filter_complex "$filter" \
        -map "[final]" \
        -map "$AUDIO_MAP" \
        -r 30 \
        -s 1280x720 \
        -c:v libx264 \
        -preset ultrafast \
        -tune zerolatency \
        -threads 2 \
        -profile:v high \
        -level 4.1 \
        -pix_fmt yuv420p \
        -b:v 3000k \
        -maxrate 3000k \
        -bufsize 6000k \
        -g 60 \
        -keyint_min 60 \
        -sc_threshold 0 \
        -c:a aac \
        -b:a 128k \
        -ar 48000 \
        -ac 2 \
        -shortest \
        "${EXTRA_OUTPUT_ARGS[@]}" \
        -f flv \
        "${RTMP_BASE}/${YOUTUBE_STREAM_KEY}"
        local exit_code=$?
        set -e

        if [ "$exit_code" -eq 0 ]; then
            echo "Video finished normally."
            return 0
        fi

        echo "WARNING: ffmpeg exited with code ${exit_code} (attempt ${attempt}/${MAX_RETRIES})."
        attempt=$((attempt + 1))
        if [ "$attempt" -le "$MAX_RETRIES" ]; then
            echo "Retrying in ${RETRY_DELAY}s..."
            sleep "$RETRY_DELAY"
        else
            echo "ERROR: Max retries reached for this video. Moving on."
        fi
    done
    return 1
}

#############################################
# Stream loop
#############################################
IFS=',' read -ra RAW_URLS <<< "$VIDEO_URL"
URLS=()
for u in "${RAW_URLS[@]}"; do
    u="${u#"${u%%[![:space:]]*}"}"
    u="${u%"${u##*[![:space:]]}"}"
    [ -n "$u" ] && URLS+=("$u")
done
NUM_URLS=${#URLS[@]}
if [ "$NUM_URLS" -eq 0 ]; then
    echo "ERROR: VIDEO_URL contained no valid entries after parsing"
    exit 1
fi

if [ "$NUM_URLS" -gt 1 ]; then
    mapfile -t URLS < <(printf '%s\n' "${URLS[@]}" | shuf)
    echo "Shuffled playback order for this run:"
    for u in "${URLS[@]}"; do
        echo "  - $u"
    done
fi

while true; do
    for ((i = 0; i < NUM_URLS; i++)); do
        url="${URLS[$i]}"
        run_video "$url" || true
        echo "Loading next video..."
        echo ""
    done
done
