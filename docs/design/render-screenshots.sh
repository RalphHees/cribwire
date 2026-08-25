#!/bin/sh
# Render the mockups in app-screens.html to PNGs in screenshots/.
#
# Every per-screen PNG comes out at a size App Store Connect accepts for an
# iPhone screenshot, so the same files are both the design reference and the
# masters uploaded with the listing:
#
#     --display 6.5   414x896pt at 3x  ->  1242x2688   (default)
#     --display 6.7   428x926pt at 3x  ->  1284x2778
#
# The size is not a flag passed to the browser alone: it is the --shot-w and
# --shot-h custom properties in app-screens.html, which the phone frame is
# drawn from, so the mockup you see in a browser is the pixel grid that ships.
#
# Two things are checked, because there are two ways to get this wrong. Every
# PNG written is measured against the accepted list, so an off-size file App
# Store Connect would reject on upload fails the run instead. And the browser
# is asked up front what viewport it actually took: some headless builds ignore
# --window-size for layout and paint the excess as page background, which
# yields a correctly sized PNG with the bottom of the screen missing — a defect
# no measurement of the file would find.
#
# Usage:
#     ./render-screenshots.sh                 # all screens, 6.5"
#     ./render-screenshots.sh --display 6.7   # all screens, 6.7"
#     ./render-screenshots.sh --only s9       # one screen
#     CHROME=/path/to/chrome ./render-screenshots.sh
#
# No dependency beyond a Chrome or Chromium binary.
set -eu

cd "$(dirname "$0")"

SOURCE=app-screens.html
OUT=screenshots
DISPLAY_SIZE=6.5
ONLY=

# App Store Connect's accepted iPhone screenshot sizes, portrait and landscape.
ACCEPTED='1242x2688 2688x1242 1284x2778 2778x1284'

while [ $# -gt 0 ]; do
  case "$1" in
    --display) DISPLAY_SIZE=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --only) ONLY=$2; shift 2 ;;
    -h|--help) sed -n '2,29p' "$0" | cut -c3-; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$DISPLAY_SIZE" in
  6.5) SHOT_W=414; SHOT_H=896 ;;   # 1242x2688
  6.7) SHOT_W=428; SHOT_H=926 ;;   # 1284x2778
  *) echo "--display must be 6.5 or 6.7, got: $DISPLAY_SIZE" >&2; exit 2 ;;
esac

# The full browser and the headless shell disagree in some Chromium builds: the
# shell honours --window-size for layout, while shipped versions of the
# browser's new headless mode lay out at a default viewport and paint the
# excess as page background. Prefer the shell where both exist; whichever is
# used, check_viewport and check_size below are what decide a render is usable.
find_chrome() {
  [ -n "${CHROME:-}" ] && { echo "$CHROME"; return; }
  for candidate in \
    "${PLAYWRIGHT_BROWSERS_PATH:-/opt/pw-browsers}"/chromium_headless_shell-*/chrome-linux/headless_shell \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    "/Applications/Chromium.app/Contents/MacOS/Chromium" \
    "${PLAYWRIGHT_BROWSERS_PATH:-/opt/pw-browsers}"/chromium-*/chrome-linux/chrome
  do
    [ -x "$candidate" ] && { echo "$candidate"; return; }
  done
  for candidate in google-chrome google-chrome-stable chromium chromium-browser; do
    command -v "$candidate" >/dev/null 2>&1 && { command -v "$candidate"; return; }
  done
  echo "no Chrome or Chromium found — set CHROME to its path" >&2
  exit 1
}
CHROME_BIN=$(find_chrome)

# Chrome refuses to start its sandbox as root, which is the normal case inside
# a container. Left on everywhere else.
SANDBOX_FLAG=
[ "$(id -u)" = 0 ] && SANDBOX_FLAG=--no-sandbox

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

# Width and height out of the PNG's IHDR chunk: 8 bytes at offset 16, each a
# big-endian uint32. od gives the bytes, the shell does the arithmetic.
png_size() {
  # shellcheck disable=SC2046 # the split is deliberate: bytes become $1..$8
  set -- $(od -An -tx1 -j16 -N8 "$1")
  echo "$((0x$1$2$3$4))x$((0x$5$6$7$8))"
}

# Ask the browser what viewport --window-size actually gave it, before thirteen
# renders are made under a wrong one. A build that cannot answer (no --dump-dom)
# is let through with a warning rather than blocked.
check_viewport() {
  probe=$TMP/viewport.html
  cat > "$probe" <<'HTML'
<!doctype html><meta charset="utf-8"><body>
<script>addEventListener("load", function () {
  document.body.appendChild(document.createElement("vp-x")).textContent =
    innerWidth + "x" + innerHeight;
});</script>
HTML
  got=$("$CHROME_BIN" --headless --disable-gpu $SANDBOX_FLAG \
        --window-size="$SHOT_W,$SHOT_H" --virtual-time-budget=2000 \
        --dump-dom "file://$probe" 2>/dev/null |
        sed -n 's/.*<vp-x>\([0-9]*x[0-9]*\).*/\1/p' | head -1)

  case "$got" in
    "") echo "  note: $CHROME_BIN would not report its viewport; sizes are still checked" >&2 ;;
    "${SHOT_W}x${SHOT_H}") ;;
    *)
      echo "FAIL $CHROME_BIN laid out at $got, not ${SHOT_W}x${SHOT_H}." >&2
      echo "     Its screenshots would be the right size with the bottom of the" >&2
      echo "     screen replaced by page background. Set CHROME to a" >&2
      echo "     headless_shell binary, or a Chrome whose headless mode honours" >&2
      echo "     --window-size." >&2
      exit 1 ;;
  esac
}

# shoot <name> <out.png> <width> <height> <scale> <extra css>
shoot() {
  page=$TMP/$1.html
  out=$2 width=$3 height=$4 scale=$5 extra_css=$6

  # The sheet lays every screen out side by side; a shot is that sheet with one
  # board left visible and the page furniture — padding, headings, notes —
  # taken out, so the viewport holds nothing but the screen itself.
  sed "s|</head>|<style>\
:root{--shot-w:${SHOT_W}px;--shot-h:${SHOT_H}px}\
body{padding:0;display:block;background:var(--bg)}\
${extra_css}\
</style></head>|" "$SOURCE" > "$page"

  rm -f "$out"
  "$CHROME_BIN" --headless --disable-gpu --hide-scrollbars $SANDBOX_FLAG \
    --force-device-scale-factor="$scale" --window-size="$width,$height" \
    --screenshot="$out" "file://$page" >/dev/null 2>&1

  [ -f "$out" ] || { echo "FAIL $out — the browser wrote no file" >&2; exit 1; }
}

check_size() {
  actual=$(png_size "$1")
  [ "$actual" = "$2" ] || {
    echo "FAIL $1 is ${actual}, expected ${2}" >&2
    echo "     $CHROME_BIN did not capture at the window size it was given." >&2
    exit 1
  }
  for accepted in $ACCEPTED; do
    [ "$actual" = "$accepted" ] && { echo "  $1  $actual"; return; }
  done
  echo "FAIL $1 is ${actual}, which App Store Connect does not accept" >&2
  echo "     accepted: $ACCEPTED" >&2
  exit 1
}

SCREENS='s1:1-role-selection s2:2-camera-home s3:3-pairing-qr
s4:4-pairing-scan s5:5-pairing-confirm s6:6-camera-monitoring
s7:7-camera-alerts s8:8-viewer-home s9:9-viewer-live s10:10-room-controls
s11:11-playlist-picker s12:12-paired-devices s13:13-lockscreen'

mkdir -p "$OUT"
expected="$((SHOT_W * 3))x$((SHOT_H * 3))"
echo "Rendering ${DISPLAY_SIZE}\" screenshots (${expected}) with $CHROME_BIN"
check_viewport

for screen in $SCREENS; do
  id=${screen%%:*}
  name=${screen#*:}
  if [ -n "$ONLY" ] && [ "$ONLY" != "$id" ]; then continue; fi
  # Square corners and no bezel: a store screenshot is the screen, edge to
  # edge. The rounded frame stays in the sheet, where it reads as a device.
  shoot "$id" "$OUT/$name.png" "$SHOT_W" "$SHOT_H" 3 \
    ".board{display:none}.board:has(#$id){display:block}\
.board h2,.board .note{display:none}\
.phone{border-radius:0;box-shadow:none}"
  check_size "$OUT/$name.png" "$expected"
done

# The overview is a contact sheet for the design doc, not a store upload, so it
# is rendered at 1x with the device frames left on and is not size-checked. Its
# box is the thirteen boards plus the 60px page padding, gaps and headings.
if [ -z "$ONLY" ]; then
  shoot overview "$OUT/0-app-overview.png" \
    "$((120 + 13 * SHOT_W + 12 * 60))" "$((120 + SHOT_H + 34))" 1 \
    "body{padding:60px;display:flex;flex-wrap:nowrap;gap:60px;align-items:flex-start}\
.board .note{display:none}"
  echo "  $OUT/0-app-overview.png  $(png_size "$OUT/0-app-overview.png")"
fi

echo "Done."
