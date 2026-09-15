#!/usr/bin/env bash
# Exercise the atelier command against a fake Mac: fake defaults, System
# Events, open, pgrep, and codesign on PATH, a private HOME, and a private
# Homebrew prefix. Nothing on the real machine changes.
set -euo pipefail
# shellcheck source=scripts/lib.sh
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/atelier-cli-tests.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
export HOME="$temporary/home"
export ATELIER_PREFIX="$temporary/prefix"
export ATELIER_HS2_APP="$temporary/Hammerspoon 2.app"
export FAKE_STORE="$temporary/defaults.json"
export FAKE_LOGIN_ITEMS="$temporary/login-items"
export FAKE_LOG="$temporary/log"
export FAKE_HS2_BUILD=133.1 FAKE_HS2_RUNNING=false FAKE_NCPREFS_ASKED=false
share="$ATELIER_PREFIX/share/atelier"
mkdir -p "$HOME" "$share" "$temporary/bin" "$ATELIER_HS2_APP/Contents"
cp "$root/hammerspoon2.json" "$root/install/init.js" "$share/"
printf '{"version":"1.2.3-test"}\n' > "$share/version.json"
printf '#!/bin/sh\nexit 0\n' > "$share/atelier-providers"; chmod +x "$share/atelier-providers"
: > "$FAKE_LOGIN_ITEMS"
printf '{}\n' > "$FAKE_STORE"
cat > "$temporary/bin/defaults" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf 'defaults %s\n' "$*" >> "$FAKE_LOG"
case "$1 $2" in
  "read $ATELIER_HS2_APP/Contents/Info") echo "$FAKE_HS2_BUILD" ;;
  "read com.apple.ncprefs") [[ $FAKE_NCPREFS_ASKED == true ]] && printf '( { "bundle-id" = "net.tenshu.Hammerspoon-2"; } )\n' || printf '( )\n' ;;
  "read net.tenshu.Hammerspoon-2") jq -er --arg key "$3" '.[$key] // empty' "$FAKE_STORE" ;;
  "write net.tenshu.Hammerspoon-2")
    case "$4" in -bool) value=$([[ $5 == true ]] && echo 1 || echo 0) ;; *) value=$5 ;; esac
    jq --arg key "$3" --arg value "$value" '.[$key] = $value' "$FAKE_STORE" > "$FAKE_STORE.tmp"; mv "$FAKE_STORE.tmp" "$FAKE_STORE" ;;
  "delete net.tenshu.Hammerspoon-2") jq -e --arg key "$3" 'has($key)' "$FAKE_STORE" > /dev/null; jq --arg key "$3" 'del(.[$key])' "$FAKE_STORE" > "$FAKE_STORE.tmp"; mv "$FAKE_STORE.tmp" "$FAKE_STORE" ;;
  *) echo "unexpected defaults call: $*" >&2; exit 99 ;;
esac
FAKE
cat > "$temporary/bin/osascript" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf 'osascript %s\n' "$*" >> "$FAKE_LOG"
script=$2
case "$script" in
  *"get the name of every login item"*) paste -sd, "$FAKE_LOGIN_ITEMS" | sed 's/,/, /g' ;;
  *"make login item"*) echo 'Hammerspoon 2' >> "$FAKE_LOGIN_ITEMS" ;;
  *"delete every login item whose name is"*) grep -vx 'Hammerspoon 2' "$FAKE_LOGIN_ITEMS" > "$FAKE_LOGIN_ITEMS.tmp" || true; mv "$FAKE_LOGIN_ITEMS.tmp" "$FAKE_LOGIN_ITEMS" ;;
  *) echo "unexpected osascript: $*" >&2; exit 99 ;;
esac
FAKE
cat > "$temporary/bin/open" <<'FAKE'
#!/usr/bin/env bash
printf 'open %s\n' "$*" >> "$FAKE_LOG"
FAKE
cat > "$temporary/bin/pgrep" <<'FAKE'
#!/usr/bin/env bash
[[ $FAKE_HS2_RUNNING == true ]]
FAKE
printf '#!/usr/bin/env bash\necho 27.1\n' > "$temporary/bin/sw_vers"
printf '#!/usr/bin/env bash\necho arm64\n' > "$temporary/bin/uname"
cat > "$temporary/bin/codesign" <<'FAKE'
#!/usr/bin/env bash
if [[ $1 == -dv ]]; then echo "Authority=Fixture Authority" >&2; fi
FAKE
printf '#!/usr/bin/env bash\necho unexpected-brew >&2; exit 99\n' > "$temporary/bin/brew"
chmod +x "$temporary/bin/"*
export PATH="$temporary/bin:$PATH"
atelier() { "$root/cli/atelier" "$@"; }

atelier install > "$temporary/install.log"
[[ $(jq -r .configLocation "$FAKE_STORE") == "$HOME/.config/atelier/init.js" ]] || fail 'configLocation not written'
[[ $(jq -r .hasCompletedOnboarding "$FAKE_STORE") == 1 && $(jq -r .dockMenuBehaviour "$FAKE_STORE") == menuBar && $(jq -r .SUEnableAutomaticChecks "$FAKE_STORE") == 0 ]] || fail 'HS2 settings not written'
grep -Fq "require(\"$share\")" "$HOME/.config/atelier/init.js" || fail 'seeded init does not require the installed share path'
grep -qx 'Hammerspoon 2' "$FAKE_LOGIN_ITEMS" || fail 'login item not added'
grep -q "^open -a $ATELIER_HS2_APP" "$FAKE_LOG" || fail 'HS2 not started'
printf '// mine\nconst atelier = require("%s");\n' "$share" > "$HOME/.config/atelier/init.js"
FAKE_HS2_RUNNING=true atelier install > "$temporary/reinstall.log"
[[ $(head -1 "$HOME/.config/atelier/init.js") == '// mine' ]] || fail 'rerunning install rewrote the init file'
grep -q 'Reload Config' "$temporary/reinstall.log" || fail 'install did not explain reload while HS2 runs'
[[ $(grep -c '^osascript.*make login item' "$FAKE_LOG") == 1 ]] || fail 'login item added twice'

FAKE_HS2_RUNNING=true FAKE_NCPREFS_ASKED=true atelier doctor > "$temporary/doctor.log"
grep -q 'Everything checked out' "$temporary/doctor.log" || { cat "$temporary/doctor.log"; fail 'healthy doctor did not pass'; }
! grep -q '^FAIL' "$temporary/doctor.log" || fail 'healthy doctor reported failures'
grep -q '^ok .*notification permission' "$temporary/doctor.log" || fail 'doctor missed the notification request'
! grep -q 'Accessibility' "$temporary/doctor.log" || fail 'doctor reported an Accessibility status it cannot check'
[[ $(atelier version) == 1.2.3-test ]] || fail 'version'

# Existing compatible configs may use single quotes and whitespace.
printf "const atelier = require( '%s' );\natelier.start({});\n" "$share" > "$HOME/.config/atelier/init.js"
FAKE_HS2_RUNNING=true atelier install > "$temporary/compatible.log" 2>&1
! grep -q 'Warning:' "$temporary/compatible.log" || fail 'compatible init triggered a warning'
FAKE_HS2_RUNNING=true atelier doctor > "$temporary/compatible-doctor.log"

# A legacy config survives install byte-for-byte, with actionable guidance.
printf 'atelier.start({});\n' > "$HOME/.config/atelier/init.js"
cp "$HOME/.config/atelier/init.js" "$temporary/legacy.js"
FAKE_HS2_RUNNING=true atelier install > "$temporary/conflicting.log" 2>&1
cmp -s "$HOME/.config/atelier/init.js" "$temporary/legacy.js" || fail 'install changed a conflicting init'
grep -Fq "Warning: Kept existing $HOME/.config/atelier/init.js" "$temporary/conflicting.log" || fail 'install did not warn about the existing init'
grep -Fq "const atelier = require(\"$share\"); before atelier.start(...)" "$temporary/conflicting.log" || fail 'install did not explain how to load Atelier'
: > "$FAKE_LOGIN_ITEMS"
set +e
FAKE_HS2_BUILD=133 FAKE_HS2_RUNNING=false atelier doctor > "$temporary/broken.log"; status=$?
set -e
[[ $status == 1 ]] || fail 'broken doctor must exit 1'
for pattern in 'build 133 is not the pinned build 133.1' 'is not running' 'could not find a require' 'is not a login item'; do
  grep -q "^FAIL .*$pattern" "$temporary/broken.log" || { cat "$temporary/broken.log"; fail "doctor missed: $pattern"; }
done
grep -q 'Fix the FAIL lines' "$temporary/broken.log" || fail 'broken doctor did not tell the user what to do'

echo 'Hammerspoon 2' > "$FAKE_LOGIN_ITEMS"
atelier uninstall > "$temporary/uninstall.log"
[[ ! -s $FAKE_LOGIN_ITEMS ]] || fail 'login item not removed'
[[ $(jq 'length' "$FAKE_STORE") == 0 ]] || fail 'HS2 settings not removed'
[[ -f $HOME/.config/atelier/init.js ]] || fail 'uninstall removed the init file'
grep -q 'brew uninstall --cask atelier hammerspoon2' "$temporary/uninstall.log" || fail 'uninstall did not point at brew'
atelier uninstall > /dev/null
printf '{"version":"1.2.4-dev.20260915000000","channel":"dev"}\n' > "$share/version.json"
FAKE_HS2_BUILD=133 atelier doctor > "$temporary/dev-doctor.log" && fail 'mismatched dev build passed doctor'
grep -q 'brew reinstall --cask jeremytondo/atelier/hammerspoon2@dev' "$temporary/dev-doctor.log" || fail 'dev doctor recommended stable HS2'
atelier uninstall > "$temporary/dev-uninstall.log"
grep -q 'brew uninstall --cask atelier@dev hammerspoon2@dev' "$temporary/dev-uninstall.log" || fail 'dev uninstall recommended stable packages'
[[ -f $HOME/.config/atelier/init.js ]] || fail 'dev uninstall removed the init file'
expect_failure atelier banana
rm -rf "$ATELIER_HS2_APP"
expect_failure atelier install
echo 'CLI behavior tests passed.'
