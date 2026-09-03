#!/bin/bash
set -euo pipefail

#############################################
# Validate Environment Variables
#############################################
if [ -z "${VIDEO_URL:-}" ]; then
    echo "ERROR: VIDEO_URL is not set"
    echo "One or more Roman video/animation clips, comma-separated (same format"
    echo "as the solar script): url1,url2,url3. A static image (jpg/png) is also"
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

# ---------------------------------------------------------------
# Live "DSN Now" panel (which antenna is talking to Roman right
# now, signal strength/rate, round-trip light time). Pulled from
# JPL's public DSN Now feed at eyes.nasa.gov/dsn/data/dsn.xml,
# which needs no API key and refreshes roughly every 5 seconds.
# On by default; can be disabled if a runner has no network path
# to eyes.nasa.gov.
#
# ROMAN_DSN_ID: the identifier DSN Now uses for Roman in its feed.
# This is matched case-insensitively as a SUBSTRING against each
# dish's target/spacecraft name, so the default of "roman" should
# match regardless of the exact short code JPL assigned. Override
# it if the fuzzy match turns out wrong once the feed is live.
# ---------------------------------------------------------------
SHOW_DSN=true
if [ "${DISABLE_DSN:-false}" = "true" ]; then
    echo "NOTICE: DISABLE_DSN=true — DSN tracking panel will be hidden."
    SHOW_DSN=false
fi
ROMAN_DSN_ID="${ROMAN_DSN_ID:-roman}"
DSN_FEED="https://eyes.nasa.gov/dsn/data/dsn.xml"

# ---------------------------------------------------------------
# Live "distance from Earth" panel, best-effort via JPL Horizons'
# public REST API (no key required). Off by default because
# Horizons only indexes a spacecraft once JPL has published its
# tracked trajectory — this can lag a few days behind launch, and
# the exact Horizons designation for a brand-new spacecraft isn't
# guaranteed to be simply its common name. Try enabling it; if the
# log shows "no matches found" repeatedly, set ROMAN_HORIZONS_ID to
# whatever designation/NAIF ID JPL has published for Roman, or
# leave SHOW_HORIZONS=false and let the field stay blank.
# ---------------------------------------------------------------
SHOW_HORIZONS=false
if [ "${ENABLE_HORIZONS:-false}" = "true" ]; then
    SHOW_HORIZONS=true
fi
ROMAN_HORIZONS_ID="${ROMAN_HORIZONS_ID:-Roman Space Telescope}"
HORIZONS_API="https://ssd.jpl.nasa.gov/api/horizons.api"

# Distance-traveled is NOT something Horizons (or DSN) exposes
# directly — it's a cumulative odometer NASA's own navigation team
# tracks, not a simple function of current position. This script
# approximates it going forward by integrating the live speed
# Horizons reports (if SHOW_HORIZONS=true) over time, starting from
# an operator-supplied seed value — the last officially published
# "distance traveled" figure (e.g. from https://roman.gsfc.nasa.gov/clock
# or a recent NASA blog post) at the moment this stream starts.
# Without a seed it just starts counting up from 0, which will read
# low compared to NASA's own figure. Update the seed periodically to
# stay accurate; this is an approximation, not telemetry.
ROMAN_DISTANCE_TRAVELED_SEED_KM="${ROMAN_DISTANCE_TRAVELED_SEED_KM:-0}"

# Mission clock: computed purely from the wall clock + a fixed launch
# epoch, so this one is exact (no API needed, no drift).
# Nancy Grace Roman Space Telescope launched 2026-08-30 11:26:00 UTC
# (7:26 a.m. EDT) from LC-39A aboard a Falcon Heavy. Override
# ROMAN_LAUNCH_EPOCH_UTC if this needs correcting.
ROMAN_LAUNCH_EPOCH_UTC="${ROMAN_LAUNCH_EPOCH_UTC:-2026-08-30 11:26:00}"
ROMAN_LAUNCH_EPOCH_S=$(date -u -d "$ROMAN_LAUNCH_EPOCH_UTC" +%s)

echo "========================================"
echo "Starting 24/7 YouTube Stream (Nancy Grace Roman Space Telescope)"
echo "Output Resolution : 1280x720 (720p — sized for a 2-core CI runner)"
echo "FPS               : 30"
echo "========================================"

FONT="font.ttf"
GOLD="0xE8A33D"
RED="0xE8453C"
ASSET_DIR="panel_assets"
INFO_FILE="mission_info.txt"
SLOT=6            # seconds each headline is shown
FACT_SLOT=8       # seconds each fun fact is shown
TICKER_SPEED=110  # pixels/second for the bottom ticker scroll
CHANNEL_NAME="Roman Space Telescope Live"
SHADOW="shadowcolor=black@0.6:shadowx=1:shadowy=1"
HEADLINE_FONTSIZE=21
HEADLINE_LINE_SPACING=9
HEADLINE_LINE_H=$((HEADLINE_FONTSIZE + HEADLINE_LINE_SPACING))
FACT_FONTSIZE=16
FACT_LINE_SPACING=7
FACT_LINE_H=$((FACT_FONTSIZE + FACT_LINE_SPACING))

# ---------------------------------------------------------------
# Layout: identical structure to the solar script — video stays
# centered/full-height, one panel on each side.
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
#   Row 1 - live Roman video/animation feed
#   Row 2 - MISSION STATUS card (day count, elapsed time, distance)
#   Row 3 - "JOURNEY TO L2" progress visualization
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

# Roman's three-month cruise to L2 is roughly this many seconds long,
# used only to draw the "JOURNEY TO L2" progress bar in row 3. This is
# a planning estimate, not a live tracked figure — see the DSN/Horizons
# panels above for the parts of the dashboard that are actually live.
JOURNEY_TOTAL_DAYS="${JOURNEY_TOTAL_DAYS:-92}"

#############################################
# Auto-restart on failure
#############################################
MAX_RETRIES=5
RETRY_DELAY=5
IMAGE_SLIDE_SECONDS="${IMAGE_SLIDE_SECONDS:-25}"

mkdir -p "$ASSET_DIR"

#############################################
# Background audio (one or more tracks, looped)
# Same reasoning/behavior as the solar script: downloaded once,
# rotated across videos, looped locally per-video.
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
# Panel decoration images (Roman / Earth / L2 stills)
#
# Same role as the sun/earth stills in the solar script: a small
# static thumbnail placed in the Mission Status card. Only one URL
# below is a verified, currently-live NASA asset — add more of your
# own (mission renders, L2 orbit diagrams, launch photos) to the
# array; broken URLs just get skipped with a warning, same as the
# solar script's panel-image downloader.
#############################################
PANEL_IMAGE_URLS=(
    "https://assets.science.nasa.gov/content/dam/science/missions/rst/spacecraft-illustrations/Roman_BeautyPass2026-med.png/jcr:content/renditions/cq5dam.web.1280.1280.png"
)
PANEL_IMAGE_LOCAL_FILES=()
pimg_i=0
for piu in "${PANEL_IMAGE_URLS[@]}"; do
    pimg_i=$((pimg_i + 1))
    dest="panel_img_${pimg_i}.jpg"
    echo "Downloading panel image ${pimg_i} ($(basename "$piu"))..."
    if curl -sL --fail -o "$dest" "$piu" && [ -s "$dest" ]; then
        PANEL_IMAGE_LOCAL_FILES+=("$dest")
        echo "  OK ($(du -h "$dest" | cut -f1))"
    else
        echo "  WARNING: failed to download panel image ${pimg_i} — panel thumbnails will be skipped."
    fi
done
NUM_PANEL_IMAGES=${#PANEL_IMAGE_LOCAL_FILES[@]}
PANEL_IMAGES_AVAILABLE=false
if [ "$NUM_PANEL_IMAGES" -gt 0 ]; then
    PANEL_IMAGES_AVAILABLE=true
    echo "Loaded $NUM_PANEL_IMAGES panel thumbnail(s)."
else
    echo "WARNING: no panel thumbnails downloaded — Mission Status thumbnail slot will stay empty."
fi
PANEL_IMAGE_COUNTER=0

#############################################
# Coordinate-label marker dot (unchanged from the solar script)
#############################################
DOT_MARKER="dot_marker.png"
GOLD_R=232; GOLD_G=163; GOLD_B=61
DOT_VF="format=rgba,geq=r=(if(lte(hypot(X-10\,Y-10)\,5)\,${GOLD_R}\,if(lte(hypot(X-10\,Y-10)\,8)\,255\,0))):g=(if(lte(hypot(X-10\,Y-10)\,5)\,${GOLD_G}\,if(lte(hypot(X-10\,Y-10)\,8)\,255\,0))):b=(if(lte(hypot(X-10\,Y-10)\,5)\,${GOLD_B}\,if(lte(hypot(X-10\,Y-10)\,8)\,255\,0))):a=(if(lte(hypot(X-10\,Y-10)\,8)\,255\,0))"
ffmpeg -y -f lavfi -i "color=c=black@0.0:s=20x20" -vf "$DOT_VF" -frames:v 1 "$DOT_MARKER" -loglevel error
if [ ! -s "$DOT_MARKER" ]; then
    echo "WARNING: geq-based marker generation failed — using a blank 1x1 fallback."
    echo "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=" | base64 -d > "$DOT_MARKER"
fi

#############################################
# Background clock writer (UTC wall clock, shown as-is; unchanged
# from the solar script)
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
# Background MISSION CLOCK writer (elapsed time since launch).
# Pure arithmetic against ROMAN_LAUNCH_EPOCH_S — exact, no network
# dependency, updates once a second like the wall clock above.
#############################################
printf '0d 00h 00m 00s' > "$ASSET_DIR/mission_clock.txt"
printf 'DAY 0' > "$ASSET_DIR/mission_day.txt"
(
    while true; do
        NOW_S=$(date -u +%s)
        ELAPSED=$((NOW_S - ROMAN_LAUNCH_EPOCH_S))
        [ "$ELAPSED" -lt 0 ] && ELAPSED=0
        D=$((ELAPSED / 86400))
        H=$(((ELAPSED % 86400) / 3600))
        M=$(((ELAPSED % 3600) / 60))
        S=$((ELAPSED % 60))
        printf '%dd %02dh %02dm %02ds' "$D" "$H" "$M" "$S" > "$ASSET_DIR/mission_clock.txt.tmp"
        mv -f "$ASSET_DIR/mission_clock.txt.tmp" "$ASSET_DIR/mission_clock.txt"
        printf 'DAY %d' "$D" > "$ASSET_DIR/mission_day.txt.tmp"
        mv -f "$ASSET_DIR/mission_day.txt.tmp" "$ASSET_DIR/mission_day.txt"
        sleep 1
    done
) &
MISSIONCLOCK_PID=$!

#############################################
# Background subscriber-count writer (unchanged from the solar script)
#############################################
printf ' ' > "$ASSET_DIR/subs.txt"
SUBS_PID=""
if [ "$SHOW_STATS" = true ]; then
    (
        WARNED_ONCE=false
        while true; do
            RESP=$(curl -s "https://www.googleapis.com/youtube/v3/channels?part=statistics&id=${YOUTUBE_CHANNEL_ID}&key=${YOUTUBE_API_KEY}" || true)
            COUNT=$(echo "$RESP" | grep -o '"subscriberCount"[^"]*"[0-9]*"' | grep -oE '[0-9]+')
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
# Background live-viewer-count writer (unchanged from the solar script)
#############################################
printf ' ' > "$ASSET_DIR/viewers.txt"
VIEWERS_PID=""
if [ "$SHOW_STATS" = true ]; then
    (
        LIVE_VIDEO_ID=""
        while true; do
            if [ -z "$LIVE_VIDEO_ID" ]; then
                SEARCH_RESP=$(curl -s "https://www.googleapis.com/youtube/v3/search?part=id&channelId=${YOUTUBE_CHANNEL_ID}&eventType=live&type=video&key=${YOUTUBE_API_KEY}" || true)
                LIVE_VIDEO_ID=$(echo "$SEARCH_RESP" | grep -o '"videoId": *"[^"]*"' | head -1 | sed -E 's/.*"videoId": *"([^"]*)".*/\1/')
            fi
            if [ -n "$LIVE_VIDEO_ID" ]; then
                VRESP=$(curl -s "https://www.googleapis.com/youtube/v3/videos?part=liveStreamingDetails&id=${LIVE_VIDEO_ID}&key=${YOUTUBE_API_KEY}" || true)
                VIEWERS=$(echo "$VRESP" | grep -o '"concurrentViewers": *"[0-9]*"' | grep -o '[0-9]*')
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
# Background DSN Now poller
#
# Polls eyes.nasa.gov/dsn/data/dsn.xml every 15s (the feed itself
# refreshes ~every 5s; 15s keeps this well under any reasonable
# rate limit) and writes:
#   - which DSN complex/dish is linked to Roman right now
#   - downlink data rate
#   - round-trip light time -> converted to a live distance estimate
#     (light-time * c), which is exactly how NASA's own DSN Now
#     displays range
# If no dish is currently tracking Roman (common — it isn't
# continuously tracked), fields blank out rather than showing stale
# data, same "degrade one field, not the whole panel" approach as
# the solar script's space-weather poller.
#############################################
printf ' ' > "$ASSET_DIR/dsn_station.txt"
printf ' ' > "$ASSET_DIR/dsn_rate.txt"
printf ' ' > "$ASSET_DIR/dsn_distance.txt"
DSN_PID=""
if [ "$SHOW_DSN" = true ]; then
    cat > dsn_poll.py << 'PYEOF'
import sys
import urllib.request
import xml.etree.ElementTree as ET

FEED = sys.argv[1]
ASSET_DIR = sys.argv[2]
SPACECRAFT_ID = sys.argv[3].lower()

def write(name, text):
    import os
    tmp = f"{ASSET_DIR}/{name}.tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, f"{ASSET_DIR}/{name}.txt")

def attr_any(elem, keys):
    for k in keys:
        v = elem.get(k)
        if v:
            return v
    return None

try:
    req = urllib.request.Request(FEED, headers={"User-Agent": "roman-stream-overlay/1.0"})
    with urllib.request.urlopen(req, timeout=15) as r:
        data = r.read()
    root = ET.fromstring(data)

    found_station = None
    found_rate = None
    found_rtlt = None

    for station in root.findall(".//station"):
        station_name = attr_any(station, ["friendlyName", "name"]) or "DSN"
        for dish in station.findall(".//dish"):
            dish_name = attr_any(dish, ["name"]) or ""
            candidates = list(dish.findall("target")) + list(dish.findall("downSignal")) + list(dish.findall("upSignal"))
            for c in candidates:
                sc = (attr_any(c, ["name", "spacecraft", "id"]) or "").lower()
                if SPACECRAFT_ID in sc:
                    found_station = f"{station_name} / {dish_name}"
                    rate = attr_any(c, ["dataRate"])
                    if rate:
                        found_rate = rate
                    rtlt = attr_any(c, ["rtlt"])
                    if rtlt:
                        found_rtlt = rtlt
                    break
            if found_station:
                break
        if found_station:
            break

    if found_station:
        write("dsn_station", found_station)
    else:
        write("dsn_station", " ")

    if found_rate:
        try:
            bps = float(found_rate)
            if bps >= 1000:
                write("dsn_rate", f"{bps/1000:.1f} kb/s")
            else:
                write("dsn_rate", f"{bps:.0f} b/s")
        except ValueError:
            write("dsn_rate", " ")
    else:
        write("dsn_rate", " ")

    if found_rtlt:
        try:
            rtlt_s = float(found_rtlt)
            # distance = one-way light time * speed of light
            km = (rtlt_s / 2.0) * 299792.458
            write("dsn_distance", f"{km:,.0f} km")
        except ValueError:
            write("dsn_distance", " ")
    else:
        write("dsn_distance", " ")

except Exception:
    # Leave whatever was already on disk — a single failed poll
    # shouldn't blank out the last good reading.
    pass
PYEOF
    (
        while true; do
            python3 dsn_poll.py "$DSN_FEED" "$ASSET_DIR" "$ROMAN_DSN_ID" 2>/tmp/dsn_err.log || \
                echo "WARNING: DSN poll cycle failed — $(tail -1 /tmp/dsn_err.log 2>/dev/null)"
            sleep 15
        done
    ) &
    DSN_PID=$!
    echo "DSN tracking panel enabled — polling eyes.nasa.gov/dsn every 15s for spacecraft matching '${ROMAN_DSN_ID}'."
fi

#############################################
# Background JPL Horizons poller (optional, off by default — see
# ENABLE_HORIZONS above). Fetches current geocentric range + speed
# and writes a live "distance from Earth" reading, and integrates
# speed*dt into a running "distance traveled" odometer seeded from
# ROMAN_DISTANCE_TRAVELED_SEED_KM.
#############################################
printf ' ' > "$ASSET_DIR/dist_from_earth.txt"
printf ' ' > "$ASSET_DIR/dist_traveled.txt"
HORIZONS_PID=""
if [ "$SHOW_HORIZONS" = true ]; then
    cat > horizons_poll.py << 'PYEOF'
import sys
import time
import json
import urllib.request
import urllib.parse

API = sys.argv[1]
ASSET_DIR = sys.argv[2]
TARGET = sys.argv[3]
SEED_KM = float(sys.argv[4])
STATE_FILE = f"{ASSET_DIR}/.horizons_state"

def write(name, text):
    import os
    tmp = f"{ASSET_DIR}/{name}.tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, f"{ASSET_DIR}/{name}.txt")

def load_state():
    try:
        with open(STATE_FILE) as f:
            t, total_km = f.read().strip().split(",")
            return float(t), float(total_km)
    except Exception:
        return None, SEED_KM

def save_state(t, total_km):
    with open(STATE_FILE, "w") as f:
        f.write(f"{t},{total_km}")

def fetch_vectors(target):
    params = {
        "format": "json",
        "COMMAND": f"'{target}'",
        "OBJ_DATA": "NO",
        "MAKE_EPHEM": "YES",
        "EPHEM_TYPE": "VECTORS",
        "CENTER": "'500@399'",  # geocentric (Earth body center)
        "OUT_UNITS": "KM-S",
        "VEC_TABLE": "3",       # position + velocity + range/range-rate
        "REF_PLANE": "FRAME",
        "TLIST": str(time.time() / 86400.0 + 2440587.5),  # now, as JD
    }
    url = API + "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"User-Agent": "roman-stream-overlay/1.0"})
    with urllib.request.urlopen(req, timeout=20) as r:
        payload = json.loads(r.read())
    text = payload.get("result", "")
    rg = None
    rr = None
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("RG ="):
            parts = line.replace("RG =", "").split("RR =")
            try:
                rg = float(parts[0].strip().split()[0])
                if len(parts) > 1:
                    rr = float(parts[1].strip().split()[0])
            except (ValueError, IndexError):
                pass
    return rg, rr

try:
    rg_km, rr_kms = fetch_vectors(TARGET)
    if rg_km is not None:
        write("dist_from_earth", f"{rg_km:,.0f} km")

        speed_kms = abs(rr_kms) if rr_kms is not None else 0.0
        now = time.time()
        last_t, total_km = load_state()
        if last_t is not None:
            dt = max(0.0, now - last_t)
            total_km += speed_kms * dt
        save_state(now, total_km)
        write("dist_traveled", f"{total_km:,.0f} km (est.)")
    else:
        write("dist_from_earth", " ")
except Exception:
    pass
PYEOF
    (
        while true; do
            python3 horizons_poll.py "$HORIZONS_API" "$ASSET_DIR" "$ROMAN_HORIZONS_ID" "$ROMAN_DISTANCE_TRAVELED_SEED_KM" 2>/tmp/horizons_err.log || \
                echo "WARNING: Horizons poll cycle failed — $(tail -1 /tmp/horizons_err.log 2>/dev/null)"
            sleep 120
        done
    ) &
    HORIZONS_PID=$!
    echo "Horizons distance panel enabled — polling ssd.jpl.nasa.gov every 120s for '${ROMAN_HORIZONS_ID}'."
    echo "  (If this target isn't found yet in Horizons, distance fields will stay blank — check the log for 'no matches found' and set ROMAN_HORIZONS_ID accordingly.)"
else
    echo "NOTICE: Horizons distance panel disabled (set ENABLE_HORIZONS=true to try it). Distance fields will stay blank."
fi

trap 'kill "$CLOCK_PID" 2>/dev/null || true; kill "$MISSIONCLOCK_PID" 2>/dev/null || true; [ -n "$SUBS_PID" ] && kill "$SUBS_PID" 2>/dev/null || true; [ -n "$VIEWERS_PID" ] && kill "$VIEWERS_PID" 2>/dev/null || true; [ -n "$DSN_PID" ] && kill "$DSN_PID" 2>/dev/null || true; [ -n "$HORIZONS_PID" ] && kill "$HORIZONS_PID" 2>/dev/null || true' EXIT

#############################################
# Static panel text (unchanged across videos)
#############################################
printf 'N A N C Y   G R A C E   R O M A N'   > "$ASSET_DIR/title1.txt"
printf 'S P A C E   T E L E S C O P E'       > "$ASSET_DIR/title2.txt"
printf "T O D A Y ' S   M I S S I O N   U P D A T E" > "$ASSET_DIR/header.txt"
printf 'LIVE · JOURNEY TO L2'                > "$ASSET_DIR/eyebrow.txt"
printf 'SUBSCRIBE to follow the mission'     > "$ASSET_DIR/cta.txt"
printf 'DID YOU KNOW'                        > "$ASSET_DIR/fact_label.txt"
printf 'PAYLOAD'                             > "$ASSET_DIR/instr_label.txt"
printf 'WFI · CORONAGRAPH'                   > "$ASSET_DIR/instr_title.txt"

#############################################
# Default headline / fact pools
#############################################
DEFAULT_HEADLINES=(
    "Roman launched August 30, 2026 aboard a Falcon Heavy from Kennedy Space Center."
    "Roman is on a three-month journey to Sun-Earth Lagrange Point 2, about 1.5 million kilometers away."
    "Roman's field of view is at least 100 times larger than Hubble's."
    "During its planned mission, Roman could measure light from a billion galaxies."
    "The Wide Field Instrument gives Roman its huge panoramic view of the sky."
    "Roman's Coronagraph Instrument will block starlight to directly image exoplanets."
    "Roman is named for Nancy Grace Roman, NASA's first chief astronomer."
    "Roman will help settle open questions about dark energy and dark matter."
    "Roman shares a 2.4 meter primary mirror heritage with the Hubble Space Telescope design."
    "Along the way to L2, Roman is being commissioned: instruments powered on, checked, and calibrated."
    "Roman completed its first mid-course correction burn shortly after launch."
    "At L2, Roman will orbit in a halo around a gravitationally stable point beyond the Moon."
    "Roman is expected to boost the number of known exoplanets from thousands toward 100,000."
    "Roman's data will be shared openly, with little to no proprietary period, unlike many past missions."
)

DEFAULT_FACTS=(
    "Sun-Earth L2 sits about 1.5 million kilometers from Earth, in the direction away from the Sun."
    "The James Webb Space Telescope also orbits near L2, alongside Roman."
    "Roman's primary mirror is 2.4 meters across, the same size as Hubble's."
    "Roman observes in near-infrared light, letting it see through dust that blocks visible light."
    "A coronagraph works like an artificial eclipse, blocking a star's glare to reveal faint nearby planets."
    "Roman's wide field of view lets it survey huge patches of sky in a single pointing."
    "Roman is expected to operate for at least five years after reaching L2."
    "Dark energy is the mysterious force thought to be accelerating the universe's expansion."
    "Roman will conduct a Galactic Bulge survey to hunt for planets via microlensing."
    "Microlensing lets Roman detect planets by watching for the gravitational bending of starlight."
    "Roman's spacecraft was built and assembled at NASA's Goddard Space Flight Center."
    "It takes about three months for a spacecraft to cruise from Earth out to L2."
    "Roman will complement Hubble and Webb rather than replace them, each suited to different tasks."
    "Roman's instruments had to be powered on and calibrated gradually during its cruise to L2."
)

#############################################
# build_labels_chain — unchanged from the solar script (generic
# coordinate-callout feature; still works on any center-strip video).
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
# prepare_video_content — same per-video override mechanism as the
# solar script (<basename>.headlines.txt / .facts.txt), rebuilds
# BASE_CHAIN / FACT_END for the video about to stream.
#############################################
prepare_video_content() {
    local url="$1"
    local base
    base="${url##*/}"
    base="${base%.*}"
    local i idx

    if [ "$PANEL_IMAGES_AVAILABLE" = true ]; then
        MID_PANEL_IMG="${PANEL_IMAGE_LOCAL_FILES[$((PANEL_IMAGE_COUNTER % NUM_PANEL_IMAGES))]}"
        PANEL_IMAGE_COUNTER=$((PANEL_IMAGE_COUNTER + 1))
        echo "Mission Status panel thumbnail this video: $MID_PANEL_IMG"
    fi

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
        printf 'Wide Field Instrument + Coronagraph, imaging in near-infrared' > "$ASSET_DIR/instr_sub.txt"
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
    # Rebuild BASE_CHAIN for this video's content
    #########################################
    CHAIN="color=c=black:s=1280x720[canvas];"
    CHAIN+="[0:v]fps=30,scale=${CENTER_W}:${VIDEO_ROW_H}:force_original_aspect_ratio=increase,crop=${CENTER_W}:${VIDEO_ROW_H}[vidfit];"
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
    CHAIN+="[br8]drawbox=x=${VX0}:y=$((VY1 - 34)):w=220:h=34:color=black@0.55:t=fill[brcap1];"
    CHAIN+="[brcap1]drawtext=fontfile=${FONT}:text='ROMAN LIVE FEED':fontcolor=white@0.9:fontsize=13:x=$((VX0 + 14)):y=$((VY1 - 22)):${SHADOW}[brcap2];"
    local prev="brcap2"

    local CARD_PAD=10
    local CARD_X0=$((CENTER_X0 + CARD_PAD))
    local CARD_W=$((CENTER_W - CARD_PAD * 2))

    # ---------------- Row 2: MISSION STATUS card ----------------
    local CM3_Y0=$((ROW2_Y + CARD_PAD))
    local CM3_Y1=$((ROW3_Y - CARD_PAD))
    CHAIN+="[${prev}]drawbox=x=${CARD_X0}:y=${CM3_Y0}:w=${CARD_W}:h=$((CM3_Y1 - CM3_Y0)):color=black@0.22:t=fill[cm3card];"
    CHAIN+="[cm3card]drawbox=x=${CARD_X0}:y=${CM3_Y0}:w=${CARD_W}:h=$((CM3_Y1 - CM3_Y0)):color=${GOLD}@0.3:t=1[cm3border];"

    local CM3_LABEL_Y=$((CM3_Y0 + 20))
    local CM3_LINE1_Y=$((CM3_LABEL_Y + 30))
    local CM3_LINE2_Y=$((CM3_LINE1_Y + 26))
    local CM3_LINE3_Y=$((CM3_LINE2_Y + 26))
    local CM3_LINE4_Y=$((CM3_LINE3_Y + 26))
    local CM3_LINE5_Y=$((CM3_LINE4_Y + 26))

    CHAIN+="[cm3border]drawbox=x=$((MTEXT_INSET - 2)):y=$((CM3_LABEL_Y - 2)):w=6:h=6:color=${GOLD}:t=fill[cm3z];"
    CHAIN+="[cm3z]drawtext=fontfile=${FONT}:text='MISSION STATUS':fontcolor=${GOLD}@0.85:fontsize=13:x=$((MTEXT_INSET + 14)):y=$((CM3_LABEL_Y - 6))[cm3z2];"
    CHAIN+="[cm3z2]drawbox=x=${MTEXT_INSET}:y=$((CM3_LABEL_Y + 14)):w=$((CARD_W - 40)):h=1:color=white@0.15:t=fill[cm3a];"
    CHAIN+="[cm3a]drawtext=fontfile=${FONT}:text='MISSION DAY':fontcolor=white@0.55:fontsize=13:x=${MTEXT_INSET}:y=${CM3_LINE1_Y}[cm3b];"
    CHAIN+="[cm3b]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/mission_day.txt:reload=1:fontcolor=white:fontsize=14:x=${MVALUE_X}:y=${CM3_LINE1_Y}[cm3c];"
    CHAIN+="[cm3c]drawtext=fontfile=${FONT}:text='ELAPSED TIME':fontcolor=white@0.55:fontsize=13:x=${MTEXT_INSET}:y=${CM3_LINE2_Y}[cm3d];"
    CHAIN+="[cm3d]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/mission_clock.txt:reload=1:fontcolor=white:fontsize=14:x=${MVALUE_X}:y=${CM3_LINE2_Y}[cm3e];"
    CHAIN+="[cm3e]drawtext=fontfile=${FONT}:text='DIST. FROM EARTH':fontcolor=white@0.55:fontsize=13:x=${MTEXT_INSET}:y=${CM3_LINE3_Y}[cm3f];"
    CHAIN+="[cm3f]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/dist_from_earth.txt:reload=1:fontcolor=white:fontsize=14:x=${MVALUE_X}:y=${CM3_LINE3_Y}[cm3g];"
    CHAIN+="[cm3g]drawtext=fontfile=${FONT}:text='DIST. TRAVELED':fontcolor=white@0.55:fontsize=13:x=${MTEXT_INSET}:y=${CM3_LINE4_Y}[cm3h];"
    CHAIN+="[cm3h]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/dist_traveled.txt:reload=1:fontcolor=white:fontsize=14:x=${MVALUE_X}:y=${CM3_LINE4_Y}[cm3i];"
    CHAIN+="[cm3i]drawtext=fontfile=${FONT}:text='TARGET':fontcolor=white@0.55:fontsize=13:x=${MTEXT_INSET}:y=${CM3_LINE5_Y}[cm3j];"
    CHAIN+="[cm3j]drawtext=fontfile=${FONT}:text='Sun-Earth L2':fontcolor=${GOLD}:fontsize=14:x=${MVALUE_X}:y=${CM3_LINE5_Y}[cm3final];"
    prev="cm3final"

    # ---------------- Center strip: framed Roman thumbnail ----------------
    if [ "$PANEL_IMAGES_AVAILABLE" = true ]; then
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
            CHAIN+="[${prev}]drawbox=x=$((MTX - 4)):y=$((MTY - 4)):w=$((MTHUMB + 8)):h=$((MTHUMB + 8)):color=black@0.6:t=fill[mthumbbg];"
            CHAIN+="[mthumbbg]drawbox=x=$((MTX - 4)):y=$((MTY - 4)):w=$((MTHUMB + 8)):h=$((MTHUMB + 8)):color=${GOLD}@0.5:t=1[mthumbborder];"
            CHAIN+="[3:v]fps=30,scale=${MTHUMB}:${MTHUMB}:force_original_aspect_ratio=increase,crop=${MTHUMB}:${MTHUMB}[mimg];"
            CHAIN+="[mthumbborder][mimg]overlay=x=${MTX}:y=${MTY}:shortest=1[mthumbfinal];"
            prev="mthumbfinal"
        fi
    fi

    # ---------------- Row 3: "JOURNEY TO L2" progress visualization ----------------
    # Bar fills according to elapsed mission days / JOURNEY_TOTAL_DAYS —
    # a planning estimate, clearly labeled as such, not a tracked figure.
    local CM4_Y0=$((ROW3_Y + CARD_PAD))
    local CM4_Y1=$((680 - CARD_PAD))
    CHAIN+="[${prev}]drawbox=x=${CARD_X0}:y=${CM4_Y0}:w=${CARD_W}:h=$((CM4_Y1 - CM4_Y0)):color=black@0.22:t=fill[cm4card];"
    CHAIN+="[cm4card]drawbox=x=${CARD_X0}:y=${CM4_Y0}:w=${CARD_W}:h=$((CM4_Y1 - CM4_Y0)):color=${RED}@0.3:t=1[cm4border];"

    local CM4_LABEL_Y=$((CM4_Y0 + 20))
    local CM4_BAR_Y=$((CM4_LABEL_Y + 22))
    local CM4_BAR_H=18
    local CM4_BAR_X=$((MTEXT_INSET - 4))
    local CM4_BAR_W=$((CARD_W - 40))
    local JOURNEY_TOTAL_SECONDS=$((JOURNEY_TOTAL_DAYS * 86400))

    # ffmpeg's own `t` variable is relative to when THIS video's ffmpeg
    # process started, not to the real launch date, so the fill amount
    # is computed here in bash (real wall-clock elapsed / planned
    # cruise length) each time prepare_video_content runs — i.e. it
    # refreshes on every video rotation, not frame-by-frame, which is
    # more than fine for a bar that moves over weeks.
    local NOW_S_FOR_BAR
    NOW_S_FOR_BAR=$(date -u +%s)
    local ELAPSED_S_FOR_BAR=$((NOW_S_FOR_BAR - ROMAN_LAUNCH_EPOCH_S))
    [ "$ELAPSED_S_FOR_BAR" -lt 0 ] && ELAPSED_S_FOR_BAR=0
    local CM4_FILL_W=$((CM4_BAR_W * ELAPSED_S_FOR_BAR / JOURNEY_TOTAL_SECONDS))
    [ "$CM4_FILL_W" -gt "$CM4_BAR_W" ] && CM4_FILL_W=$CM4_BAR_W
    [ "$CM4_FILL_W" -lt 0 ] && CM4_FILL_W=0

    CHAIN+="[cm4border]drawbox=x=$((MTEXT_INSET - 2)):y=$((CM4_LABEL_Y - 2)):w=6:h=6:color=${RED}:t=fill:enable='lt(mod(t\,1.2)\,0.75)'[cm4a];"
    CHAIN+="[cm4a]drawtext=fontfile=${FONT}:text='JOURNEY TO L2 (est.)':fontcolor=white@0.75:fontsize=13:x=$((MTEXT_INSET + 14)):y=$((CM4_LABEL_Y - 6))[cm4b];"
    CHAIN+="[cm4b]drawbox=x=${CM4_BAR_X}:y=${CM4_BAR_Y}:w=${CM4_BAR_W}:h=${CM4_BAR_H}:color=black@0.4:t=fill[cm4barbg];"
    CHAIN+="[cm4barbg]drawbox=x=${CM4_BAR_X}:y=${CM4_BAR_Y}:w=${CM4_BAR_W}:h=${CM4_BAR_H}:color=white@0.2:t=1[cm4barborder];"
    CHAIN+="[cm4barborder]drawbox=x=${CM4_BAR_X}:y=${CM4_BAR_Y}:w=${CM4_FILL_W}:h=${CM4_BAR_H}:color=${GOLD}@0.85:t=fill[cm4fillraw];"
    prev="cm4fillraw"
    CHAIN+="[${prev}]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/mission_day.txt:reload=1:fontcolor=white:fontsize=13:x=$((CM4_BAR_X)):y=$((CM4_BAR_Y + CM4_BAR_H + 12)):${SHADOW}[cm4day];"
    CHAIN+="[cm4day]drawtext=fontfile=${FONT}:text='of ~${JOURNEY_TOTAL_DAYS} day cruise':fontcolor=white@0.55:fontsize=13:x=$((CM4_BAR_X + 90)):y=$((CM4_BAR_Y + CM4_BAR_H + 12))[cm4base];"
    prev="cm4base"

    # ---------------- Left panel: story / headlines (unchanged structure) ----------------
    CHAIN+="[${prev}]drawbox=x=0:y=0:w=${PANEL_W}:h=720:color=black@0.92:t=fill[p1];"
    CHAIN+="[p1]drawbox=x=${PANEL_W}:y=0:w=3:h=720:color=${GOLD}@0.75:t=fill[p2];"
    CHAIN+="[p2]drawbox=x=0:y=0:w=${PANEL_W}:h=4:color=${GOLD}@0.9:t=fill[p3];"

    CHAIN+="[p3]drawbox=x=27:y=28:w=11:h=11:color=${RED}:t=fill:enable='lt(mod(t\,1)\,0.6)'[p4];"
    CHAIN+="[p4]drawtext=fontfile=${FONT}:text='LIVE':fontcolor=white:fontsize=30:x=44:y=19[p5];"
    CHAIN+="[p5]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/eyebrow.txt:fontcolor=${GOLD}@0.9:fontsize=13:x=${TEXT_INSET}-text_w+280:y=39[p6];"

    CHAIN+="[p6]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/title1.txt:fontcolor=white:fontsize=22:x=${TEXT_INSET}:y=95:${SHADOW}[p7];"
    CHAIN+="[p7]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/title2.txt:fontcolor=white@0.85:fontsize=16:x=${TEXT_INSET}:y=123:${SHADOW}[p8];"
    CHAIN+="[p8]drawbox=x=${TEXT_INSET}:y=153:w=${PANEL_TEXT_W}:h=2:color=white@0.3:t=fill[p9];"

    CHAIN+="[p9]drawbox=x=${TEXT_INSET}:y=171:w=8:h=8:color=${GOLD}:t=fill[p10];"
    CHAIN+="[p10]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/header.txt:fontcolor=${GOLD}:fontsize=14:x=$((TEXT_INSET + 16)):y=168[p11];"

    local prev="p11"
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

    # ---------------- Left panel: animated "MISSION ACTIVITY" bar graph ----------------
    local GRAPH_LABEL_Y=$((DOTS_Y + 40))
    local GRAPH_BASE_Y=$((GRAPH_LABEL_Y + 160))
    local BAR_COUNT=14
    local BAR_W=13
    local BAR_GAP=6
    local BAR_MINH=8
    local BAR_MAXH=100

    CHAIN+="[${prev}]drawbox=x=$((TEXT_INSET - 2)):y=$((GRAPH_LABEL_Y - 2)):w=6:h=6:color=${GOLD}:t=fill:enable='lt(mod(t\,1.4)\,0.9)'[sa1];"
    CHAIN+="[sa1]drawtext=fontfile=${FONT}:text='MISSION ACTIVITY':fontcolor=white@0.55:fontsize=11:x=$((TEXT_INSET + 14)):y=$((GRAPH_LABEL_Y - 8))[sa2];"
    CHAIN+="[sa2]drawtext=fontfile=${FONT}:text='%{eif\:64+24*sin(2*PI*t/11)\:d} PCT':fontcolor=${GOLD}:fontsize=16:x=${TEXT_INSET}:y=$((GRAPH_LABEL_Y + 10)):${SHADOW}[sa3];"
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

    # ---------------- Right panel: stats + payload + facts ----------------
    CHAIN+="[${prev}]drawbox=x=${RIGHT_X0}:y=0:w=${PANEL_W}:h=720:color=black@0.92:t=fill[r1];"
    CHAIN+="[r1]drawbox=x=$((RIGHT_X0 - 3)):y=0:w=3:h=720:color=${GOLD}@0.75:t=fill[r2];"
    CHAIN+="[r2]drawbox=x=${RIGHT_X0}:y=0:w=${PANEL_W}:h=4:color=${GOLD}@0.9:t=fill[r3];"

    CHAIN+="[r3]drawtext=fontfile=${FONT}:text='Credits\: NASA / GSFC':fontcolor=white@0.85:fontsize=14:x=${RTEXT_INSET}:y=${RSTAT_Y}[r4];"
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

    # ---------------- Right panel: live DSN tracking readings ----------------
    local RREAD_DIV_Y=$((RFACT_TEXT_Y + MAX_FACT_LINES * FACT_LINE_H + 16))
    local RREAD_LABEL_Y=$((RREAD_DIV_Y + 14))
    local RREAD_LINE1_Y=$((RREAD_LABEL_Y + 22))
    local RREAD_LINE2_Y=$((RREAD_LINE1_Y + 20))
    local RREAD_LINE3_Y=$((RREAD_LINE2_Y + 20))
    local RGRAPH_LABEL_Y=$((RREAD_LINE3_Y + 30))

    CHAIN+="[${prev}]drawbox=x=${RTEXT_INSET}:y=${RREAD_DIV_Y}:w=${PANEL_TEXT_W}:h=2:color=white@0.15:t=fill[rr0];"
    CHAIN+="[rr0]drawtext=fontfile=${FONT}:text='DSN TRACKING (LIVE)':fontcolor=${GOLD}@0.85:fontsize=12:x=${RTEXT_INSET}:y=${RREAD_LABEL_Y}[rr0b];"
    CHAIN+="[rr0b]drawtext=fontfile=${FONT}:text='STATION':fontcolor=white@0.55:fontsize=12:x=${RTEXT_INSET}:y=${RREAD_LINE1_Y}[rr0c];"
    CHAIN+="[rr0c]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/dsn_station.txt:reload=1:fontcolor=white:fontsize=13:x=$((RTEXT_INSET + 80)):y=${RREAD_LINE1_Y}[rr1];"
    CHAIN+="[rr1]drawtext=fontfile=${FONT}:text='DATA RATE':fontcolor=white@0.55:fontsize=12:x=${RTEXT_INSET}:y=${RREAD_LINE2_Y}[rr1b];"
    CHAIN+="[rr1b]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/dsn_rate.txt:reload=1:fontcolor=white:fontsize=13:x=$((RTEXT_INSET + 80)):y=${RREAD_LINE2_Y}[rr2];"
    CHAIN+="[rr2]drawtext=fontfile=${FONT}:text='RANGE (DSN)':fontcolor=white@0.55:fontsize=12:x=${RTEXT_INSET}:y=${RREAD_LINE3_Y}[rr2b];"
    CHAIN+="[rr2b]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/dsn_distance.txt:reload=1:fontcolor=white:fontsize=13:x=$((RTEXT_INSET + 80)):y=${RREAD_LINE3_Y}[rr3];"
    prev="rr3"

    # ---------------- Right panel: mission-clock pie/percent gauge ----------------
    # Same procedural geq pie-wedge approach as the solar script, now
    # driven by real elapsed-vs-planned-cruise percentage instead of a
    # sine wave, plus the launch date underneath.
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

    # Same reasoning as the progress bar above: computed here in bash
    # from the real wall clock (refreshes each video rotation), not
    # from ffmpeg's per-video-relative `t`.
    local PIE_PCT_NOW=$((100 * ELAPSED_S_FOR_BAR / JOURNEY_TOTAL_SECONDS))
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
    CHAIN+="[rgp1]drawtext=fontfile=${FONT}:text='CRUISE PROGRESS (est.)':fontcolor=white@0.55:fontsize=11:x=$((RTEXT_INSET + 14)):y=$((PIE_LABEL_Y - 8))[rgp2];"
    CHAIN+="color=c=black@0:s=${PIE_SIZE}x${PIE_SIZE}[pie_src];"
    CHAIN+="[pie_src]format=rgba,geq=r='${PIE_R_EXPR}':g='${PIE_G_EXPR}':b='${PIE_B_EXPR}':a='${PIE_A_EXPR}'[pie_img];"
    CHAIN+="[rgp2][pie_img]overlay=x=${PIE_X}:y=${PIE_Y}:shortest=1[rgp3];"
    CHAIN+="[rgp3]drawtext=fontfile=${FONT}:text='${PIE_PCT_NOW} PCT':fontcolor=white:fontsize=16:x=$((PIE_X + PIE_SIZE / 2 - 28)):y=$((PIE_Y + PIE_SIZE / 2 - 9)):${SHADOW}[rgp4];"
    CHAIN+="[rgp4]drawtext=fontfile=${FONT}:text='Launched Aug 30, 2026':fontcolor=white@0.5:fontsize=11:x=${RTEXT_INSET}:y=$((PIE_Y + PIE_SIZE + 12))[rgbase];"
    prev="rgbase"

    BASE_CHAIN="$CHAIN"
    FACT_END="$prev"
}

#############################################
# build_final_filter — unchanged from the solar script (CTA / next-
# video countdown / ticker / watermark).
#############################################
build_final_filter() {
    local total_duration="$1"
    local tail="$BASE_CHAIN"

    local CTA_CYCLE=240
    local CTA_SHOW=8
    local CTA_ALPHA="if(between(mod(t\,${CTA_CYCLE})\,0\,${CTA_SHOW})\,if(lt(mod(t\,${CTA_CYCLE})\,0.6)\,mod(t\,${CTA_CYCLE})/0.6\,if(gt(mod(t\,${CTA_CYCLE})\,${CTA_SHOW}-0.6)\,(${CTA_SHOW}-mod(t\,${CTA_CYCLE}))/0.6\,1))\,0)"
    local CTA_ENABLE="between(mod(t\,${CTA_CYCLE})\,0\,${CTA_SHOW})"
    local COUNTDOWN_ENABLE="not(${CTA_ENABLE})"

    local CTA_W=460
    local CTA_X=$((CENTER_X0 + (CENTER_W - CTA_W) / 2))
    local CTA_Y=640

    tail+="[${FACT_END}]drawbox=x=${CTA_X}:y=${CTA_Y}:w=${CTA_W}:h=43:color=black@0.75:t=fill[cta_bg];"
    tail+="[cta_bg]drawbox=x=${CTA_X}:y=${CTA_Y}:w=4:h=43:color=${GOLD}:t=fill[cta_bar];"
    tail+="[cta_bar]drawbox=x=$((CTA_X + 22)):y=$((CTA_Y + 16)):w=11:h=11:color=${RED}:t=fill:enable='${CTA_ENABLE}'[cta_dot];"
    tail+="[cta_dot]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/cta.txt:fontcolor=white:fontsize=18:x=$((CTA_X + 40)):y=$((CTA_Y + 13)):alpha='${CTA_ALPHA}'[cta_sub];"

    if [[ "$total_duration" =~ ^[0-9]+$ ]] && [ "$total_duration" -gt 0 ]; then
        tail+="[cta_sub]drawtext=fontfile=${FONT}:text='Next view in %{eif\:max(${total_duration}-t\,0)\:d}s':fontcolor=white:fontsize=18:x=$((CTA_X + 40)):y=$((CTA_Y + 13)):enable='${COUNTDOWN_ENABLE}'[cta_final];"
    else
        tail+="[cta_sub]drawtext=fontfile=${FONT}:text='Coming up next...':fontcolor=white@0.85:fontsize=18:x=$((CTA_X + 40)):y=$((CTA_Y + 13)):enable='${COUNTDOWN_ENABLE}'[cta_final];"
    fi

    tail+="[cta_final]drawbox=x=0:y=680:w=1280:h=40:color=black@0.85:t=fill[tk1];"
    tail+="[tk1]drawbox=x=0:y=680:w=1280:h=2:color=${GOLD}@0.9:t=fill[tk2];"
    tail+="[tk2]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/ticker.txt:fontcolor=white:fontsize=17:borderw=2:bordercolor=black@0.6:y=695:x='w-mod(t*${TICKER_SPEED}\,text_w+w)'[tk3];"
    tail+="[tk3]drawbox=x=0:y=680:w=120:h=40:color=black@0.9:t=fill[tk4];"
    tail+="[tk4]drawbox=x=0:y=682:w=113:h=38:color=${GOLD}:t=fill[tk5];"
    tail+="[tk5]drawtext=fontfile=${FONT}:text='LIVE NOW':fontcolor=black:fontsize=15:x=13:y=695[tk6];"

    tail+="[tk6]drawtext=fontfile=${FONT}:text='${CHANNEL_NAME}':fontcolor=white@0.45:fontsize=14:borderw=1.5:bordercolor=black@0.7:x=(w-text_w)/2:y=657[final]"

    echo "$tail"
}

#############################################
# is_image_url / get_image_local_path — unchanged from the solar script.
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
# run_video — unchanged from the solar script (retry logic, image-
# slide handling, audio/panel-image inputs, ffmpeg invocation).
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
            echo "Could not probe duration — countdown will show generic filler text."
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

    local PANEL_IMG_INPUT_ARGS=()
    if [ "$PANEL_IMAGES_AVAILABLE" = true ]; then
        PANEL_IMG_INPUT_ARGS=(-loop 1 -framerate 30 -i "$MID_PANEL_IMG")
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
        "${PANEL_IMG_INPUT_ARGS[@]}" \
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
        "rtmp://a.rtmp.youtube.com/live2/${YOUTUBE_STREAM_KEY}"
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
# Stream loop — unchanged from the solar script.
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
        run_video "$url"
        echo "Loading next video..."
        echo ""
    done
done
