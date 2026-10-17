#!/bin/bash
# =============================================================================
# tests/test_suite_release_check.sh — QA for the suite-release update-check
#
# Pure host: downloads the three upstream webui files at the pinned
# WEBUI_VERSION tag, applies patches/webui-suite-release-check.py in a dry
# run, asserts the patch anchors landed exactly, syntax-checks the JS, and
# exercises the inserted suite-check logic in-process. build.sh/Dockerfile
# propagation is verified against stubbed podman and static greps.
# Run:  bash tests/test_suite_release_check.sh
# =============================================================================
set -u

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$TEST_DIR")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/hs-suite-check-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
BIN="${WORK}/bin"; mkdir -p "$BIN"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1 (want '$2' got '$3')"; }

AGENT_PIN="$(grep -E '^AGENT_VERSION=' "${REPO_DIR}/versions.env" | cut -d= -f2)"
WEBUI_PIN="$(grep -E '^WEBUI_VERSION=' "${REPO_DIR}/versions.env" | cut -d= -f2)"
PATCH="${REPO_DIR}/patches/webui-suite-release-check.py"
REL_TAG="v${AGENT_PIN#v}-${WEBUI_PIN#v}"
IMG_TAG="ascensionoid/hermes-suite:${AGENT_PIN#v}-${WEBUI_PIN#v}"

# --------------------------------------------------------------------------
# A. Fixture download (upstream files at the pinned tag). Network needed;
#    offline hosts skip the whole suite rather than failing.
# --------------------------------------------------------------------------
UP="${WORK}/upstream"; mkdir -p "${UP}/api" "${UP}/static"
DL_FAIL=0
for spec in "api/updates.py" "static/ui.js" "static/panels.js"; do
    curl -fsSL "https://raw.githubusercontent.com/nesquena/hermes-webui/${WEBUI_PIN}/${spec}" \
        -o "${UP}/${spec}" || DL_FAIL=1
done
if [ "$DL_FAIL" -ne 0 ]; then
    echo "SKIP (network unavailable for upstream fixture download)"
    exit 0
fi
cp -r "${UP}" "${WORK}/control"

# --------------------------------------------------------------------------
# B. Apply the patch script (RED: patch file absent here).
# --------------------------------------------------------------------------
PATCH_OK=0
if [ ! -f "$PATCH" ]; then
    bad "patch script present (${PATCH})"
else
    if python3 "$PATCH" "${UP}" >"${WORK}/patch.out" 2>&1; then
        ok "patch script applies cleanly"; PATCH_OK=1
    else
        bad "patch script applies (exit $?, see below)"
        sed 's/^/    /' "${WORK}/patch.out"
    fi
fi

if [ "$PATCH_OK" -eq 1 ]; then
    PUP="${UP}/api/updates.py"; PUI="${UP}/static/ui.js"; PPA="${UP}/static/panels.js"
    CUP="${WORK}/control/api/updates.py"; CUI="${WORK}/control/static/ui.js"; CPA="${WORK}/control/static/panels.js"

    # ----------------------------------------------------------------------
    # C. Anchor assertions on the patched files.
    # ----------------------------------------------------------------------
    eq "_check_suite_release_update def count" "1" "$(grep -c 'def _check_suite_release_update(' "${PUP}")"
    grep -q 'sunnysktsang/hermes-suite/releases' "${PUP}" && ok "_SUITE_RELEASES_URL targets suite releases" || bad "_SUITE_RELEASES_URL targets suite releases"
    grep -q 'suite_info = _check_suite_release_update()' "${PUP}" && ok "hook calls suite check first" || bad "hook calls suite check first"

    eq "manual_command branch count" "1" "$(grep -c 'info.suite&&info.manual_command' "${PUI}")"
    eq "'Hermes Suite' label count" "2" "$(grep -o "'Hermes Suite'" "${PUI}" | wc -l | tr -d ' ')"
    grep -q 'Generate Hermes Suite update summary' "${PUI}" && ok "summary label set relabeled" || bad "summary label set relabeled"

    eq "_webuiLabel count" "4" "$(grep -o '_webuiLabel' "${PPA}" | wc -l | tr -d ' ')"

    grep -q 'def _check_suite_release_update(' "${CUP}" && bad "control updates.py unpatched" || ok "control updates.py unpatched"
    grep -q 'info.suite&&info.manual_command' "${CUI}" && bad "control ui.js unpatched" || ok "control ui.js unpatched"
    grep -q '_webuiLabel' "${CPA}" && bad "control panels.js unpatched" || ok "control panels.js unpatched"

    # ----------------------------------------------------------------------
    # D. JS syntax check (node present on CI and dev hosts).
    # ----------------------------------------------------------------------
    if command -v node >/dev/null 2>&1; then
        node --check "${PUI}" >/dev/null 2>&1 && ok "node --check ui.js" || bad "node --check ui.js"
        node --check "${PPA}" >/dev/null 2>&1 && ok "node --check panels.js" || bad "node --check panels.js"
    else
        echo "  skip - node absent"
    fi

    # ----------------------------------------------------------------------
    # E. Logic tests: exec the inserted suite block in-process.
    # ----------------------------------------------------------------------
    if UP_DIR="${UP}" python3 - <<'PY'
import json, os, re, sys, types

updir = os.environ['UP_DIR']
src = open(os.path.join(updir, 'api', 'updates.py'), encoding='utf-8').read()

START = '_SUITE_RELEASES_URL = ('
END = 'def _check_webui_published_release_update(channel=DEFAULT_UPDATE_CHANNEL):'
si = src.index(START)
ei = src.index(END, si)
block = src[si:ei]

class FakeError(OSError):
    pass

class FakeResp:
    def __init__(self, payload):
        self._payload = payload
    def __enter__(self):
        return self
    def __exit__(self, *a):
        return False
    def read(self):
        return json.dumps(self._payload).encode('utf-8')

STATE = {'releases': [], 'error': False}

def fake_urlopen(request, timeout=None):
    if STATE['error']:
        raise FakeError('fake network error')
    return FakeResp(STATE['releases'])

urllib_mod = types.SimpleNamespace(
    request=types.SimpleNamespace(Request=lambda url, headers=None: None,
                                  urlopen=fake_urlopen),
    error=types.SimpleNamespace(URLError=FakeError),
)

ns = {
    '__name__': 'suite_block_test',
    're': re, 'json': json, 'os': os, 'urllib': urllib_mod,
    '_build_compare_url': lambda repo, cur, lat: f'{repo}/compare/{cur}...{lat}',
}
exec(compile(block, 'suite_block', 'exec'), ns)
check = ns['_check_suite_release_update']

FAILS = []
def chk(name, want, got):
    if want != got:
        FAILS.append(f'  {name}: want {want!r} got {got!r}')

HTML = lambda t: f'https://github.com/sunnysktsang/hermes-suite/releases/tag/{t}'
CANONICAL = [
    {'tag_name': 'v0.22.2-0.52.510', 'draft': False, 'prerelease': False, 'html_url': HTML('v0.22.2-0.52.510')},
    {'tag_name': 'v0.22.1-0.52.500', 'draft': False, 'prerelease': False, 'html_url': HTML('v0.22.1-0.52.500')},
    {'tag_name': 'v2026.9.24-0.52.458', 'draft': False, 'prerelease': False, 'html_url': HTML('v2026.9.24-0.52.458')},
    {'tag_name': 'v2026.7.20-0.52.113', 'draft': False, 'prerelease': False, 'html_url': HTML('v2026.7.20-0.52.113')},
]
STATE['releases'] = CANONICAL

os.environ.pop('HERMES_SUITE_RELEASE_TAG', None)
os.environ.pop('HERMES_SUITE_IMAGE_REF', None)

# 1. env empty -> suite mode off -> None
chk('1 env empty -> None', None, check())

# 2. baked == newest -> behind 0, suite True, no no_git key
os.environ['HERMES_SUITE_RELEASE_TAG'] = 'v0.22.2-0.52.510'
r = check()
chk('2 behind=0', 0, r.get('behind'))
chk('2 suite True', True, r.get('suite'))
chk('2 no no_git key', False, 'no_git' in r)

# 3. baked at index 2 -> behind 2, manual_update, no_git, derived command
os.environ['HERMES_SUITE_RELEASE_TAG'] = 'v2026.9.24-0.52.458'
os.environ.pop('HERMES_SUITE_IMAGE_REF', None)
r = check()
chk('3 behind=2', 2, r.get('behind'))
chk('3 manual_update True', True, r.get('manual_update'))
chk('3 no_git True', True, r.get('no_git'))
chk('3 manual_command derived', 'docker pull ascensionoid/hermes-suite:0.22.2-0.52.510', r.get('manual_command'))

# 4. urlopen error -> cannot-check (behind None), never a banner
STATE['error'] = True
r = check()
chk('4 behind is None', True, r.get('behind') is None)
chk('4 no_git True', True, r.get('no_git'))
chk('4 suite True', True, r.get('suite'))
chk('4 no manual_update', False, 'manual_update' in r)
STATE['error'] = False

# 5. baked tag absent -> same cannot-check shape
os.environ['HERMES_SUITE_RELEASE_TAG'] = 'v2099.1.1-9.9.9'
r = check()
chk('5 behind is None', True, r.get('behind') is None)
chk('5 no_git True', True, r.get('no_git'))

# 6. draft/prerelease filtered before indexing -> newest "real" release is index 0
STATE['releases'] = [
    {'tag_name': 'v2.0.0', 'draft': True, 'prerelease': False, 'html_url': HTML('v2.0.0')},
    {'tag_name': 'v1.5.0-rc1', 'draft': False, 'prerelease': True, 'html_url': HTML('v1.5.0-rc1')},
    {'tag_name': 'v1.0.0', 'draft': False, 'prerelease': False, 'html_url': HTML('v1.0.0')},
]
os.environ['HERMES_SUITE_RELEASE_TAG'] = 'v1.0.0'
r = check()
chk('6 behind=0 after filtering', 0, r.get('behind'))
chk('6 latest is v1.0.0', 'v1.0.0', r.get('latest_version'))

# 7. -slim image ref carried verbatim
STATE['releases'] = CANONICAL
os.environ['HERMES_SUITE_RELEASE_TAG'] = 'v2026.9.24-0.52.458'
os.environ['HERMES_SUITE_IMAGE_REF'] = 'ascensionoid/hermes-suite:0.22.2-0.52.510-slim'
r = check()
chk('7 -slim ref verbatim', 'docker pull ascensionoid/hermes-suite:0.22.2-0.52.510-slim', r.get('manual_command'))

# 8. invalid image ref -> derived fallback
os.environ['HERMES_SUITE_IMAGE_REF'] = 'ascensionoid/hermes-suite:'
r = check()
chk('8 invalid ref fallback', 'docker pull ascensionoid/hermes-suite:0.22.2-0.52.510', r.get('manual_command'))

# 9. leading-v normalization absent on the release list side
os.environ.pop('HERMES_SUITE_IMAGE_REF', None)
STATE['releases'] = [
    {'tag_name': '2026.9.24-0.52.458', 'draft': False, 'prerelease': False, 'html_url': HTML('2026.9.24-0.52.458')},
    {'tag_name': '2026.7.20-0.52.113', 'draft': False, 'prerelease': False, 'html_url': HTML('2026.7.20-0.52.113')},
]
os.environ['HERMES_SUITE_RELEASE_TAG'] = 'v2026.7.20-0.52.113'
r = check()
chk('9 behind=1 (v-normalized)', 1, r.get('behind'))

# 10. compare_url: release html_url wins; else _build_compare_url fallback
STATE['releases'] = [
    {'tag_name': 'v2.0.0', 'draft': False, 'prerelease': False, 'html_url': HTML('v2.0.0')},
    {'tag_name': 'v1.0.0', 'draft': False, 'prerelease': False, 'html_url': HTML('v1.0.0')},
]
os.environ['HERMES_SUITE_RELEASE_TAG'] = 'v1.0.0'
r = check()
chk('10 compare_url = html_url', HTML('v2.0.0'), r.get('compare_url'))

STATE['releases'] = [
    {'tag_name': 'v2.0.0', 'draft': False, 'prerelease': False, 'html_url': 'https://evil.example/x'},
    {'tag_name': 'v1.0.0', 'draft': False, 'prerelease': False},
]
r = check()
chk('10 compare_url fallback', 'https://github.com/sunnysktsang/hermes-suite/compare/v1.0.0...v2.0.0', r.get('compare_url'))

print('PY_SUMMARY:', len(FAILS), 'failure(s)')
if FAILS:
    print('\n'.join(FAILS))
    sys.exit(1)
sys.exit(0)
PY
    then
        ok "updates.py logic tests (10 behaviors)"
    else
        bad "updates.py logic tests (10 behaviors)"
    fi
else
    echo "  skip - sections C/D/E require a working patch script"
fi

# --------------------------------------------------------------------------
# F. build.sh propagation (stub podman; no daemon).
# --------------------------------------------------------------------------
cat > "${BIN}/podman" <<'EOF'
#!/bin/bash
echo "PODMAN-ARGS: $*" >> "${CAPTURE_FILE:?}"
exit 0
EOF
chmod +x "${BIN}/podman"

fresh_repo() {
    rm -rf "${WORK}/repo"
    cp -r "${REPO_DIR}" "${WORK}/repo"
    rm -rf "${WORK}/repo/.git"
}
run_build() {
    ( cd "${WORK}/repo" && env PATH="${BIN}:$PATH" CAPTURE_FILE="${WORK}/$1.args" \
        ./build.sh "${@:2}" ) >"${WORK}/$1.out" 2>&1
}

echo "== build.sh passes suite release tag (default/full) =="
fresh_repo
run_build full
eq "build.sh exit" "0" "$?"
grep -q -- "--build-arg HERMES_SUITE_RELEASE_TAG=${REL_TAG}" "${WORK}/full.args" \
    && ok "RELEASE_TAG build-arg = ${REL_TAG}" || bad "RELEASE_TAG build-arg = ${REL_TAG}"
grep -q -- "--build-arg HERMES_SUITE_IMAGE_REF=${IMG_TAG}" "${WORK}/full.args" \
    && ok "IMAGE_REF build-arg = ${IMG_TAG}" || bad "IMAGE_REF build-arg = ${IMG_TAG}"

echo "== build.sh -slim: IMAGE_REF carries -slim, RELEASE_TAG does not =="
fresh_repo
sed -i 's/^#ENABLE_BROWSER=false/ENABLE_BROWSER=false/' "${WORK}/repo/versions.env"
run_build slim
eq "build.sh -slim exit" "0" "$?"
grep -q -- "--build-arg HERMES_SUITE_IMAGE_REF=${IMG_TAG}-slim" "${WORK}/slim.args" \
    && ok "slim IMAGE_REF has -slim suffix" || bad "slim IMAGE_REF has -slim suffix"
grep -q -- "--build-arg HERMES_SUITE_RELEASE_TAG=${REL_TAG}" "${WORK}/slim.args" \
    && ! grep -q -- "--build-arg HERMES_SUITE_RELEASE_TAG=${REL_TAG}-slim" "${WORK}/slim.args" \
    && ok "slim RELEASE_TAG has no -slim suffix" || bad "slim RELEASE_TAG has no -slim suffix"

# --------------------------------------------------------------------------
# G. Dockerfile static asserts.
# --------------------------------------------------------------------------
DF="${REPO_DIR}/Dockerfile"
echo "== Dockerfile bakes suite env + patch =="
eq "ARG HERMES_SUITE_RELEASE_TAG" "1" "$(grep -c '^ARG HERMES_SUITE_RELEASE_TAG=' "${DF}")"
eq "ARG HERMES_SUITE_IMAGE_REF" "1" "$(grep -c '^ARG HERMES_SUITE_IMAGE_REF=' "${DF}")"
eq "ENV HERMES_SUITE_RELEASE_TAG" "1" "$(grep -c '^ENV HERMES_SUITE_RELEASE_TAG=' "${DF}")"
eq "ENV HERMES_SUITE_IMAGE_REF" "1" "$(grep -c '^ENV HERMES_SUITE_IMAGE_REF=' "${DF}")"
eq "COPY patch line" "1" "$(grep -c '^COPY patches/webui-suite-release-check.py' "${DF}")"
eq "RUN patch line" "1" "$(grep -c '^RUN python3 /tmp/webui-suite-release-check.py' "${DF}")"

# --------------------------------------------------------------------------
# H. Producer side: up.sh exports the release tag for compose.
# --------------------------------------------------------------------------
cat > "${BIN}/podman-compose" <<'EOF'
#!/bin/bash
echo "TAG-IN-ENV: ${HERMES_SUITE_IMAGE_TAG:-unset}" >> "${CAPTURE_FILE:?}"
echo "RELEASE-IN-ENV: ${HERMES_SUITE_RELEASE_TAG:-unset}" >> "${CAPTURE_FILE:?}"
exit 0
EOF
chmod +x "${BIN}/podman-compose"
mkdir -p "${WORK}/home"
fresh_repo
( cd "${WORK}/repo" && env HOME="${WORK}/home" PATH="${BIN}:$PATH" CAPTURE_FILE="${WORK}/up.args" \
  bash up.sh ) >"${WORK}/up.out" 2>&1
eq "up.sh exit" "0" "$?"
grep -q "RELEASE-IN-ENV: ${REL_TAG}" "${WORK}/up.args" \
    && ok "up.sh exports RELEASE_TAG = ${REL_TAG}" || bad "up.sh exports RELEASE_TAG = ${REL_TAG}"

echo ""
echo "=========================================="
echo " Passed: $PASS   Failed: $FAIL"
echo "=========================================="
[ "$FAIL" -eq 0 ]