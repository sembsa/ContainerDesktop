#!/usr/bin/env bash
#
# Capture the README / website screenshots in every UI language.
#
# Output: docs/screenshots/<lang>/<view>.png — referenced by README.md,
# README.pl.md, README.zh-Hans.md and docs/index*.html. Re-run after UI changes
# worth showing; commit the PNGs together with the docs that reference them.
#
# Requirements
#   * Container Desktop in /Applications — the shipped Release build is what the
#     README should show, not a local Debug build.
#   * Screen Recording permission for this terminal (used by `screencapture`).
#   * Accessibility permission for ~/Applications/ContainerDesktopShots.app, the
#     helper compiled from scripts/ax-bridge.applescript. macOS prompts on first
#     run — approve it once. (Granting Accessibility to the terminal itself would
#     require restarting the terminal, which the helper avoids.)
#   * An unlocked screen: both window capture and UI scripting need one.
#   * Demo containers: `./scripts/screenshots.sh --demo` creates a neutral set,
#     `--clean-demo` removes it. Never shoot with real work containers on the
#     list — the container and image lists end up published on GitHub.
#
# Usage
#   scripts/screenshots.sh --demo                 # create demo containers
#   scripts/screenshots.sh                        # all languages, all views
#   scripts/screenshots.sh --lang en              # one language
#   scripts/screenshots.sh --lang pl --views logs,stats
#   scripts/screenshots.sh --clean-demo

set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"
APP="/Applications/ContainerGUI.app"
BUNDLE_ID="com.containerdesktop.ContainerGUI"
PROC_NAME="Container Desktop"          # AX/CGWindow owner name, not the bundle name
CONTAINER="${CONTAINER_BIN:-/usr/local/bin/container}"

HELPER="$HOME/Applications/ContainerDesktopShots.app"
HELPER_ID="com.containerdesktop.screenshots"
BRIDGE_DIR="$HOME/.container-desktop-shots"
STEP="$BRIDGE_DIR/step.applescript"
RESULT="$BRIDGE_DIR/result.txt"

# Window geometry. The screenshots are captured on a 2x display when one is
# available, so the PNGs are retina-sharp; SCREEN is the frame of that display.
SCREEN="0 0 1728 1117"
WIN_X=280
WIN_Y=140
WIN_W=1420
LIST_H=580      # list-only views: tall enough for the demo rows, short enough
                # that whatever else is on the machine stays below the fold
DETAIL_H=820    # views with the detail panel (logs / stats / terminal)
SHEET_H=760     # modal sheets (run / compose)

LANGS=(en pl zh-Hans)
VIEWS=(containers images system logs stats terminal run-sheet compose)

# --- demo data -------------------------------------------------------------
# Five compose projects, labelled the way the app's Compose support labels them,
# so the containers list shows grouping. Names sort before any real project.

# The Images view lists everything on the machine, sorted by repository, and the
# app has no filter — so a handful of well-known docker.io/library images gives
# that screenshot a neutral top-of-list, keeping private registries below the fold.
DEMO_IMAGES=(
  nginx:alpine busybox:latest golang:alpine haproxy:alpine httpd:alpine
  memcached:alpine nats:alpine rabbitmq:4-alpine registry:2 traefik:v3
  valkey:alpine postgres:16 redis:8-alpine node:22-alpine
)

demo_images() {
  log "pulling demo images"
  for image in "${DEMO_IMAGES[@]}"; do
    if $CONTAINER image ls 2>/dev/null | grep -q "^${image%%:*} .*${image##*:}"; then continue; fi
    log "  $image"
    $CONTAINER image pull "$image" >/dev/null 2>&1 || log "  (failed: $image)"
  done
}

demo_up() {
  demo_images
  demo_containers
}

demo_containers() {
  log "creating demo containers"
  c_run acme-shop web  "-p 8080:80 -m 512M nginx:alpine"
  c_run acme-shop db   "-e POSTGRES_PASSWORD=demo -m 1024M postgres:18"
  c_run acme-shop cache "-m 512M redis:7-alpine"
  # A chatty service, so the log viewer has something with severities to colour.
  c_exists acme-shop-api || $CONTAINER run -d --name acme-shop-api \
    -l compose.project=acme-shop -l compose.service=api -p 3000:3000 -m 512M \
    alpine sh -c 'i=0; while true; do i=$((i+1)); T=$(date +%H:%M:%S); case $((i%8)) in
0) echo "[$T INF] GET /api/orders 200 in 12ms";;
1) echo "[$T INF] GET /api/products?page=2 200 in 8ms";;
2) echo "[$T DBG] pool size=8 idle=3 waiting=0";;
3) echo "[$T WRN] cache miss for key orders:list, falling back to postgres";;
4) echo "[$T INF] POST /api/cart 201 in 24ms";;
5) echo "[$T ERR] postgres connection reset by peer, retry 1/3 in 500ms";;
6) echo "[$T INF] reconnected to acme-shop-db:5432";;
7) echo "[$T INF] GET /healthz 200 in 1ms";;
esac; sleep 1; done' >/dev/null
  c_run blog web   "-p 8081:80 -m 512M caddy:2-alpine"
  c_run blog cache "-m 512M redis:7-alpine"
  c_run cms web   "-p 8082:80 -m 512M nginx:alpine"
  c_run cms api   "-p 4000:4000 -m 512M alpine sleep infinity"
  c_run cms db    "-e POSTGRES_PASSWORD=demo -m 1024M postgres:18"
  c_run cms cache "-m 512M redis:7-alpine"
  # The window cannot go below minHeight 580pt (see ContainerGUIApp.swift), which
  # leaves room for ~21 rows — so these two projects are *created* but never
  # started: they fill the list to the bottom edge, keeping whatever else lives on
  # the machine below the fold, and cost no memory while stopped.
  c_create analytics api    "-p 5000:5000 -m 512M alpine sleep infinity"
  c_create analytics db     "-e POSTGRES_PASSWORD=demo -m 1024M postgres:18"
  c_create analytics worker "-m 512M alpine sleep infinity"
  c_create dev web   "-p 8083:80 -m 512M nginx:alpine"
  c_create dev api   "-p 4100:4100 -m 512M alpine sleep infinity"
  c_create dev db    "-e POSTGRES_PASSWORD=demo -m 1024M postgres:18"
  c_create dev cache "-m 512M redis:7-alpine"
  $CONTAINER ls -a | head -20
}

# Containers stop when the Mac sleeps, and a list full of "stopped" rows makes a
# poor screenshot. Restarting them is not an option: once the project network has
# been recreated under them, `container start` fails with `configureDns`. So when
# the set is not fully up, throw it away and build it again.
demo_ensure() {
  local up=0
  for name in "${DEMO_RUNNING[@]}"; do
    if $CONTAINER ls 2>/dev/null | grep -q "^$name "; then up=$((up + 1)); fi
  done
  if [ "$up" -eq "${#DEMO_RUNNING[@]}" ]; then
    log "demo containers already up"
    return 0
  fi
  log "demo containers not all running ($up/${#DEMO_RUNNING[@]}) — recreating"
  demo_purge
  demo_containers >/dev/null
  sleep 3
}

demo_purge() {
  for name in "${DEMO_CONTAINERS[@]}"; do
    $CONTAINER stop "$name" >/dev/null 2>&1 || true
    $CONTAINER delete "$name" >/dev/null 2>&1 || true
  done
}

DEMO_RUNNING=(
  acme-shop-web acme-shop-api acme-shop-db acme-shop-cache
  blog-web blog-cache
  cms-web cms-api cms-db cms-cache
)
DEMO_STOPPED=(
  analytics-api analytics-db analytics-worker
  dev-web dev-api dev-db dev-cache
)
DEMO_CONTAINERS=("${DEMO_RUNNING[@]}" "${DEMO_STOPPED[@]}")

demo_down() {
  log "removing demo containers"
  demo_purge
  log "removing demo images (nginx:alpine is kept — the run dialog uses it)"
  for image in "${DEMO_IMAGES[@]}"; do
    [ "$image" = nginx:alpine ] && continue
    $CONTAINER image delete "$image" >/dev/null 2>&1 || true
  done
}

c_run() {
  local project="$1" service="$2" rest="$3"
  if c_exists "$project-$service"; then return 0; fi
  # shellcheck disable=SC2086
  $CONTAINER run -d --name "$project-$service" \
    -l "compose.project=$project" -l "compose.service=$service" $rest >/dev/null
}

c_create() {
  local project="$1" service="$2" rest="$3"
  if c_exists "$project-$service"; then return 0; fi
  # shellcheck disable=SC2086
  $CONTAINER create --name "$project-$service" \
    -l "compose.project=$project" -l "compose.service=$service" $rest >/dev/null
}

c_exists() { $CONTAINER ls -a --format json 2>/dev/null | grep -q "\"$1\""; }

# --- accessibility bridge --------------------------------------------------

# Compiled only when missing or out of date: every rebuild gets a fresh ad-hoc
# signature, and macOS then treats the helper as a different app — which silently
# revokes the Accessibility permission granted to the previous build.
bridge_build() {
  mkdir -p "$BRIDGE_DIR" "$HOME/Applications"
  if [ -d "$HELPER" ] && [ "$HELPER/Contents/Resources/Scripts/main.scpt" -nt scripts/ax-bridge.applescript ]; then
    return 0
  fi
  log "compiling $HELPER (approve Accessibility for it once when macOS asks)"
  rm -rf "$HELPER"
  osacompile -o "$HELPER" scripts/ax-bridge.applescript
  # Without these, the Accessibility list shows the applet's executable name —
  # a bare "applet" asking for control of the computer, which nobody should be
  # expected to approve on trust.
  local plist="$HELPER/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $HELPER_ID" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $HELPER_ID" "$plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string ContainerDesktopShots" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ContainerDesktopShots" "$plist"
  codesign --force --sign - "$HELPER" >/dev/null 2>&1
  tccutil reset Accessibility "$HELPER_ID" >/dev/null 2>&1 || true
}

# Runs the AppleScript on stdin inside the helper app and echoes the raw result
# ("OK\n…" or "ERR …"), without treating a failure as fatal.
ax_soft() {
  { ax_prelude; cat; } > "$STEP"
  rm -f "$RESULT"
  open -a "$HELPER"
  local waited=0
  while [ ! -f "$RESULT" ] && [ "$waited" -lt 60 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if [ -f "$RESULT" ]; then cat "$RESULT"; else
    printf 'ERR timeout\nUI scripting timed out. Approve Accessibility for ContainerDesktopShots\n(System Settings → Privacy & Security → Accessibility) and unlock the screen.\n'
  fi
}

# Same, but a failed step aborts the run and echoes only the step's return value.
ax() {
  local result
  result="$(ax_soft)"
  case "$result" in
    ERR*) die "UI scripting failed: $(printf '%s' "$result" | tail -n +2)" ;;
  esac
  printf '%s\n' "$result" | tail -n +2
}

ax_prelude() {
  cat <<'PRELUDE'
-- Click the element with the given accessibility name, wherever it sits in the
-- window. Clicking at its centre rather than pressing it keeps this working for
-- list rows and segmented-picker segments, which do not all handle AXPress.
on clickNamed(nm)
	tell application "System Events"
		tell process "Container Desktop"
			-- Indexing into the list matters: `repeat with e in (entire contents …)`
			-- yields list references whose `name` does not resolve for AX elements.
			set els to entire contents of window 1
			set found to missing value
			repeat with i from 1 to (count of els)
				set e to item i of els
				try
					if (name of e) is nm then
						set found to e
						exit repeat
					end if
				end try
			end repeat
			if found is missing value then error "no element named " & nm
			set {x, y} to position of found
			set {w, h} to size of found
		end tell
		click at {x + (w div 2), y + (h div 2)}
	end tell
	delay 0.6
	return "clicked " & nm
end clickNamed

-- Element lookup goes through explicit paths, not `entire contents of window 1`:
-- every AX property read is an IPC round trip, and scanning the whole window
-- (hundreds of elements once the container list is populated) blows past the
-- caller's timeout.
on sidebarOutline()
	tell application "System Events" to tell process "Container Desktop"
		return outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1 of window 1
	end tell
end sidebarOutline

on listOutline()
	tell application "System Events" to tell process "Container Desktop"
		return outline 1 of scroll area 1 of group 1 of splitter group 1 of group 2 of splitter group 1 of group 1 of window 1
	end tell
end listOutline

-- Sidebar rows carry no name of their own, and a click at their coordinates does
-- not register — so match the label inside the row and set AXSelected.
on selectSidebar(nm)
	tell application "System Events"
		tell process "Container Desktop"
			set sb to my sidebarOutline()
			repeat with i from 1 to (count of rows of sb)
				try
					if (name of static text 1 of UI element 1 of row i of sb) is nm then
						set selected of row i of sb to true
						delay 1.2
						return "selected " & nm
					end if
				end try
			end repeat
			error "no sidebar row named " & nm
		end tell
	end tell
end selectSidebar

-- Toolbar buttons and segmented-picker segments do respond to AXPress. The scan
-- is limited to a subtree: `toolbar 1` for the toolbar, the right-hand side of
-- the split view for the detail panel's tab picker.
on pressNamed(nm)
	tell application "System Events"
		tell process "Container Desktop"
			try
				set els to entire contents of toolbar 1 of window 1
				repeat with i from 1 to (count of els)
					set e to item i of els
					try
						if (name of e) is nm then
							perform action "AXPress" of e
							delay 1.2
							return "pressed " & nm
						end if
					end try
				end repeat
			end try
			set els to entire contents of splitter group 1 of group 2 of splitter group 1 of group 1 of window 1
			repeat with i from 1 to (count of els)
				set e to item i of els
				try
					if (name of e) is nm then
						perform action "AXPress" of e
						delay 1.2
						return "pressed " & nm
					end if
				end try
			end repeat
			error "no element named " & nm
		end tell
	end tell
end pressNamed

-- Selects a container in the list, so the detail panel below it appears. The name
-- sits in the second cell of the row (the first holds the state dot); it has to be
-- reached as `item 2 of cells` — `cell 2 of row i` is a syntax error.
on selectRow(nm)
	tell application "System Events"
		tell process "Container Desktop"
			set lst to my listOutline()
			repeat with i from 1 to (count of rows of lst)
				try
					if (name of static text 1 of group 1 of item 2 of cells of row i of lst) is nm then
						set selected of row i of lst to true
						delay 1.5
						return "selected row " & nm
					end if
				end try
			end repeat
			error "no row named " & nm
		end tell
	end tell
end selectRow

on resizeWindow(w, h)
	tell application "System Events" to tell process "Container Desktop"
		set size of window 1 to {w, h}
	end tell
	delay 0.8
	return "resized"
end resizeWindow

on focusApp()
	tell application "System Events" to tell process "Container Desktop"
		set frontmost to true
	end tell
	delay 0.4
	return "focused"
end focusApp
PRELUDE
}

# --- app control -----------------------------------------------------------

app_restart() {
  local lang="$1"
  require_unlocked
  pkill -x ContainerGUI 2>/dev/null || true
  sleep 2
  # Killing the app makes AppKit record "no windows open", and because the app has
  # a MenuBarExtra it happily relaunches windowless — so drop the restoration state.
  rm -rf "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
  # The app writes its window frame on quit, so set both *after* it is gone.
  defaults write "$BUNDLE_ID" AppleLanguages -array "$lang"
  defaults write "$BUNDLE_ID" "NSWindow Frame main" "$WIN_X $WIN_Y $WIN_W $LIST_H $SCREEN"
  open -a "$APP"
  local waited=0
  until win_id >/dev/null 2>&1; do
    sleep 1
    waited=$((waited + 1))
    if [ "$waited" -ge 30 ]; then die "$APP did not open a window"; fi
  done
  sleep 4   # let the CLI queries settle so no spinners end up in the shot
  # A window visible to CGWindow is not yet a window visible to the accessibility
  # API, so wait for that separately before scripting anything.
  waited=0
  until ax_soft <<<'tell application "System Events" to tell process "Container Desktop" to return (count of windows)' | tail -n +2 | grep -q '^1'; do
    sleep 2
    waited=$((waited + 1))
    if [ "$waited" -ge 15 ]; then die "the accessibility API never saw the app's window"; fi
  done
  # AppKit state restoration wins over the frame written above, so set the size
  # through the accessibility API once the window is up.
  ax <<<"return my resizeWindow($WIN_W, $LIST_H)" >/dev/null
}

win_id() { swift scripts/windowid.swift "$PROC_NAME" 300; }

shoot() {
  local out="$1"
  require_unlocked
  mkdir -p "$(dirname "$out")"
  # The helper app takes focus while scripting the UI, which leaves the window
  # drawn inactive — dim traffic lights, grey selection. Re-activate before the
  # shutter. (`open` activates through LaunchServices, needing no permission.)
  open -a "$APP"
  sleep 1.5
  screencapture -o -x "-l$(win_id)" "$out"
  [ -s "$out" ] || die "captured nothing into $out"
  log "  → $(basename "$(dirname "$out")")/$(basename "$out") ($(sips -g pixelWidth -g pixelHeight "$out" | awk '/pixel/ {printf "%s ", $2}'))"
}

# --- the views -------------------------------------------------------------

# Localized labels, indexed by language.
label() {
  local key="$1" lang="$2"
  case "$key:$lang" in
    containers:en) echo "Containers" ;;  containers:pl) echo "Kontenery" ;;   containers:zh-Hans) echo "容器" ;;
    images:en)     echo "Images" ;;      images:pl)     echo "Obrazy" ;;      images:zh-Hans)     echo "镜像" ;;
    system:en)     echo "System" ;;      system:pl)     echo "System" ;;      system:zh-Hans)     echo "系统" ;;
    logs:en)       echo "Logs" ;;        logs:pl)       echo "Logi" ;;        logs:zh-Hans)       echo "日志" ;;
    stats:en)      echo "Stats" ;;       stats:pl)      echo "Statystyki" ;;  stats:zh-Hans)      echo "统计" ;;
    terminal:en)   echo "Terminal" ;;    terminal:pl)   echo "Terminal" ;;    terminal:zh-Hans)   echo "终端" ;;
    run:en)        echo "Run container";; run:pl)       echo "Uruchom kontener" ;; run:zh-Hans)   echo "启动容器" ;;
    compose:*)     echo "Compose" ;;
    *) die "no label for $key:$lang" ;;
  esac
}

DEMO_YAML='name: wiki

services:
  db:
    image: postgres:18
    environment:
      POSTGRES_PASSWORD: secret
      POSTGRES_DB: wiki
    mem_limit: 1g

  app:
    image: ghcr.io/requarks/wiki:2
    depends_on: [db]
    ports:
      - "3080:3000"
    environment:
      DB_TYPE: postgres
      DB_HOST: wiki-db
      DB_PASS: secret
'

capture_view() {
  local view="$1" lang="$2" out="$REPO/docs/screenshots/$lang/$view.png"

  case "$view" in
    containers)
      ax <<<"return my focusApp()" >/dev/null
      shoot "$out"
      ;;
    images|system)
      ax <<<"return my selectSidebar(\"$(label "$view" "$lang")\")" >/dev/null
      shoot "$out"
      # back to the containers list for whatever comes next
      ax <<<"return my selectSidebar(\"$(label containers "$lang")\")" >/dev/null
      ;;
    logs|stats|terminal)
      ax <<EOF >/dev/null
my resizeWindow($WIN_W, $DETAIL_H)
my selectRow("acme-shop-api")
return my pressNamed("$(label "$view" "$lang")")
EOF
      # charts need a few samples; the terminal needs its shell to come up
      case "$view" in
        stats) sleep 12 ;;
        terminal)
          sleep 4
          ax <<'EOF' >/dev/null
tell application "System Events"
	keystroke "ls -l /etc/nginx"
	key code 36
end tell
delay 1.5
return "typed"
EOF
          ;;
        *) sleep 3 ;;
      esac
      shoot "$out"
      ax <<<"return my resizeWindow($WIN_W, $LIST_H)" >/dev/null
      ;;
    run-sheet)
      ax <<EOF >/dev/null
my resizeWindow($WIN_W, $SHEET_H)
my pressNamed("$(label run "$lang")")
delay 1
tell application "System Events" to keystroke "nginx:alpine"
delay 1
return "opened"
EOF
      shoot "$out"
      ax <<<'tell application "System Events" to key code 53
return "dismissed"' >/dev/null
      ;;
    compose)
      printf '%s' "$DEMO_YAML" | pbcopy
      ax <<EOF >/dev/null
my resizeWindow($WIN_W, $SHEET_H)
my pressNamed("Compose")
delay 1
tell application "System Events"
	keystroke "v" using command down
end tell
delay 1.5
return "pasted"
EOF
      shoot "$out"
      ax <<<'tell application "System Events" to key code 53
return "dismissed"' >/dev/null
      ax <<<"return my resizeWindow($WIN_W, $LIST_H)" >/dev/null
      ;;
    *) die "unknown view: $view" ;;
  esac
}

# --- plumbing --------------------------------------------------------------

log() { printf '%s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# A locked screen does not fail loudly: the accessibility API reports zero windows
# and screencapture refuses every rect, which looks like a dozen unrelated bugs. So
# check before each step, and hold sleep off for the duration of the run.
require_unlocked() {
  if ioreg -n Root -d1 | grep -q '"CGSSessionScreenIsLocked"=Yes'; then
    die "the screen is locked — unlock it and re-run (both window capture and UI scripting need an unlocked screen)"
  fi
}

prevent_sleep() {
  caffeinate -dimsu -w $$ &
}

main() {
  local only_lang="" only_views=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --demo)       demo_up; exit 0 ;;
      --clean-demo) demo_down; exit 0 ;;
      --lang)       only_lang="$2"; shift 2 ;;
      --views)      only_views="$2"; shift 2 ;;
      -h|--help)    sed -n '2,40p' "$0"; exit 0 ;;
      *)            die "unknown option: $1" ;;
    esac
  done

  [ -d "$APP" ] || die "$APP not installed"
  require_unlocked
  prevent_sleep
  if [ -n "$only_lang" ]; then LANGS=("$only_lang"); fi
  if [ -n "$only_views" ]; then IFS=, read -r -a VIEWS <<<"$only_views"; fi

  bridge_build
  demo_ensure
  local saved_lang
  saved_lang="$(defaults read "$BUNDLE_ID" AppleLanguages 2>/dev/null || echo none)"

  for lang in "${LANGS[@]}"; do
    log "== $lang =="
    app_restart "$lang"
    for view in "${VIEWS[@]}"; do
      capture_view "$view" "$lang"
    done
  done

  # Leave the app as the user had it: following the system language.
  pkill -x ContainerGUI 2>/dev/null || true
  sleep 1
  if [ "$saved_lang" = none ]; then
    defaults delete "$BUNDLE_ID" AppleLanguages 2>/dev/null || true
  fi
  log "done — review the PNGs before committing (no internal names in list views)"
}

main "$@"
