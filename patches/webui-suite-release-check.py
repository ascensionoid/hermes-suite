# webui-suite-release-check.py — hermes-suite patch: suite-release update check
# Applied at build time (Stage 5b) to /opt/hermes-webui/{api/updates.py,
# static/ui.js, static/panels.js}. Optional argv[1] overrides the webui root
# (used by tests/test_suite_release_check.sh dry-runs).
#
# Why: in the suite image the webui has no .git, so the upstream check compares
# the baked webui version against nesquena/hermes-webui GitHub tags and tells
# the user to `docker pull ghcr.io/nesquena/hermes-webui:latest` — an image a
# suite deployment cannot use. When HERMES_SUITE_RELEASE_TAG is baked (suite
# builds only), the webui update slot instead reports hermes-suite releases
# from github.com/sunnysktsang/hermes-suite and instructs pulling the matching
# ascensionoid/hermes-suite image tag.
#
# Activation: HERMES_SUITE_RELEASE_TAG = the exact GitHub release tag of the
# suite release baked into this image. Empty/absent -> upstream behavior
# unchanged. HERMES_SUITE_IMAGE_REF (optional) = full docker pull reference
# for the manual-update instruction; validated, else derived as
# ascensionoid/hermes-suite:<latest release tag minus leading v>.
#
# Fail-safe: any network error, malformed response, or a baked tag not found
# in the release list -> no update banner. A missing banner is the safe
# failure; a wrong banner is not.
#
# The check NEVER parses version numbers: detection is an identity compare of
# release tag strings (leading-'v'-normalized only), so it survives any future
# suite tag convention change (agent moved CalVer -> SemVer in Oct 2026).
#
# DROP THIS PATCH when upstream webui ships a deployment/distribution-aware
# release check natively.
import re
import sys
from pathlib import Path

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else '/opt/hermes-webui')

# -- 1. api/updates.py: server-side suite check ------------------------------
UPD = ROOT / 'api' / 'updates.py'
src = UPD.read_text(encoding='utf-8')

PY_BLOCK = '''

# -- hermes-suite patch (suite release check): suite-release update slot ------
# Active only when HERMES_SUITE_RELEASE_TAG is baked (suite builds). Replaces
# the webui update slot's upstream nesquena/hermes-webui comparison with the
# hermes-suite GitHub Releases list (identity tag compare, no version math).
# Fail-safe: errors or an unknown baked tag report "cannot check", never a
# wrong "update available". DROP when upstream webui is deployment-aware.
_SUITE_RELEASES_URL = (
    'https://api.github.com/repos/sunnysktsang/hermes-suite/releases?per_page=100'
)
_SUITE_REPO_URL = 'https://github.com/sunnysktsang/hermes-suite'
_SUITE_IMAGE_REF_RE = re.compile(r'^[a-z0-9._/-]+:[A-Za-z0-9][A-Za-z0-9._-]*$')


def _suite_release_tag_env():
    """Return the baked hermes-suite release tag, or '' when not a suite build."""
    return str(os.environ.get('HERMES_SUITE_RELEASE_TAG') or '').strip()


def _norm_suite_tag(tag):
    """Normalize a release tag for identity comparison (strip leading 'v' only)."""
    raw = str(tag or '').strip()
    return raw[1:] if raw.startswith('v') else raw


def _github_suite_releases(*, timeout=3.0):
    """Return full (non-draft, non-prerelease) suite releases, newest-first."""
    request = urllib.request.Request(
        _SUITE_RELEASES_URL,
        headers={'Accept': 'application/vnd.github+json', 'User-Agent': 'hermes-webui'},
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        page = json.loads(response.read().decode('utf-8'))
    if not isinstance(page, list):
        return []
    out = []
    for item in page:
        if not isinstance(item, dict):
            continue
        name = item.get('tag_name')
        if not isinstance(name, str) or not name.strip():
            continue
        if item.get('draft') or item.get('prerelease'):
            continue
        out.append(item)
    return out


def _check_suite_release_update():
    """Return the suite-driven webui update payload, or None when suite mode is off.

    Suite mode is ON when HERMES_SUITE_RELEASE_TAG is baked. The returned
    payload occupies the existing 'webui' slot so the banner, Settings panel,
    and i18n machinery render it unchanged; 'suite': True flags the JS layer
    to relabel 'WebUI' -> 'Hermes Suite' and use 'manual_command' verbatim.
    """
    current = _suite_release_tag_env()
    if not current:
        return None
    try:
        releases = _github_suite_releases()
    except (OSError, TimeoutError, urllib.error.URLError, json.JSONDecodeError,
            UnicodeDecodeError, ValueError):
        releases = []
    names = [str(r.get('tag_name') or '').strip() for r in releases]
    idx = None
    for i, name in enumerate(names):
        if _norm_suite_tag(name) == _norm_suite_tag(current):
            idx = i
            break
    if idx is None:
        # Baked tag not in the published list (local build, convention change,
        # or beyond page 1): fail safe - never claim an update.
        return {'name': 'webui', 'behind': None, 'no_git': True, 'suite': True}
    if idx == 0:
        return {
            'name': 'webui',
            'behind': 0,
            'suite': True,
            'release_based': True,
            'current_version': current,
            'latest_version': names[0],
        }
    latest = releases[0]
    latest_name = names[0]
    image_ref = str(os.environ.get('HERMES_SUITE_IMAGE_REF') or '').strip()
    if not _SUITE_IMAGE_REF_RE.fullmatch(image_ref):
        base = latest_name[1:] if latest_name.startswith('v') else latest_name
        image_ref = f'ascensionoid/hermes-suite:{base}'
    release_url = str(latest.get('html_url') or '').strip()
    if not release_url.startswith('https://github.com/sunnysktsang/hermes-suite/'):
        release_url = _build_compare_url(_SUITE_REPO_URL, current, latest_name)
    return {
        'name': 'webui',
        'behind': idx,
        'current_version': current,
        'latest_version': latest_name,
        'release_based': True,
        'repo_url': _SUITE_REPO_URL,
        'compare_url': release_url,
        'manual_update': True,
        'manual_command': 'docker pull ' + image_ref,
        'no_git': True,
        'channel': 'stable',
        'suite': True,
    }
'''

anchor_def = 'def _check_webui_published_release_update(channel=DEFAULT_UPDATE_CHANNEL):'
assert src.count(anchor_def) == 1, 'updates.py: published-release def anchor not found or ambiguous'
src = src.replace(anchor_def, PY_BLOCK + anchor_def, 1)

anchor_hook = """    if path is None or not (path / '.git').exists():
        if name == 'webui':
            release_info = _check_webui_published_release_update(channel)"""
assert src.count(anchor_hook) == 1, 'updates.py: _check_repo no-git hook anchor not found or ambiguous'
replacement_hook = """    if path is None or not (path / '.git').exists():
        if name == 'webui':
            # -- hermes-suite patch (suite release check): suite mode first ----
            # When suite mode is on, _check_suite_release_update() never
            # returns None, so the upstream nesquena/hermes-webui comparison
            # below is unreachable in suite builds (and its GitHub call is
            # saved). Non-suite builds skip the suite branch entirely.
            suite_info = _check_suite_release_update()
            if suite_info is not None:
                return suite_info
            release_info = _check_webui_published_release_update(channel)"""
src = src.replace(anchor_hook, replacement_hook, 1)

assert src.count('_check_suite_release_update') == 3  # def + comment mention + call
assert src.count('_SUITE_RELEASES_URL') == 2  # def + usage
UPD.write_text(src, encoding='utf-8')
print('updates.py: suite release check applied')

# -- 2. static/ui.js: banner label, manual command, whats-new label ----------
UI = ROOT / 'static' / 'ui.js'
js = UI.read_text(encoding='utf-8')

anchor_manual = """function _formatManualUpdateInstruction(info){
  if(!(info&&info.no_git&&info.manual_update&&info.behind>0)) return null;
  const tag=info.channel==='experimental'?'experimental':'latest';
  return t('settings_update_manual_docker',`docker pull ghcr.io/nesquena/hermes-webui:${tag}`);
}"""
assert js.count(anchor_manual) == 1, 'ui.js: manual-instruction anchor not found or ambiguous'
js = js.replace(anchor_manual, """function _formatManualUpdateInstruction(info){
  if(!(info&&info.no_git&&info.manual_update&&info.behind>0)) return null;
  // -- hermes-suite patch (suite release check): suite builds carry the ------
  // exact pull command from the server payload; {0} keeps its i18n slot.
  if(info.suite&&info.manual_command) return t('settings_update_manual_docker',info.manual_command);
  const tag=info.channel==='experimental'?'experimental':'latest';
  return t('settings_update_manual_docker',`docker pull ghcr.io/nesquena/hermes-webui:${tag}`);
}""", 1)

anchor_banner = "  const webuiPart=_formatUpdateTargetStatus('WebUI',data.webui);"
assert js.count(anchor_banner) == 1, 'ui.js: banner webui-part anchor not found or ambiguous'
js = js.replace(anchor_banner, """  // -- hermes-suite patch (suite release check): relabel the webui slot -----
  const _suiteWebuiLabel=(data&&data.webui&&data.webui.suite)?'Hermes Suite':'WebUI';
  const webuiPart=_formatUpdateTargetStatus(_suiteWebuiLabel,data.webui);""", 1)

anchor_targets = "    {key:'webui',label:'WebUI',info:data&&data.webui},"
assert js.count(anchor_targets) == 1, 'ui.js: whats-new targets anchor not found or ambiguous'
js = js.replace(anchor_targets, """    // -- hermes-suite patch (suite release check): whats-new label ---------
    {key:'webui',label:((data&&data.webui&&data.webui.suite)?'Hermes Suite':'WebUI'),info:data&&data.webui},""", 1)

anchor_sumlabel = "  const labels=target.key==='webui'\n    ? {generate:'Generate WebUI update summary',view:'View generated WebUI update summary',regenerate:'Re-generate WebUI update summary'}"
assert js.count(anchor_sumlabel) == 1, 'ui.js: summary-label anchor not found or ambiguous'
js = js.replace(anchor_sumlabel, """  // -- hermes-suite patch (suite release check): summary label --------------
  const _suiteSummary=target.key==='webui'&&data&&data.webui&&data.webui.suite;
  const labels=target.key==='webui'
    ? _suiteSummary
      ? {generate:'Generate Hermes Suite update summary',view:'View generated Hermes Suite update summary',regenerate:'Re-generate Hermes Suite update summary'}
      : {generate:'Generate WebUI update summary',view:'View generated WebUI update summary',regenerate:'Re-generate WebUI update summary'}""", 1)

assert js.count("'Hermes Suite'") == 2  # banner relabel + whats-new relabel
UI.write_text(js, encoding='utf-8')
print('ui.js: suite release check applied')

# -- 3. static/panels.js: Settings panel labels ------------------------------
PAN = ROOT / 'static' / 'panels.js'
pj = PAN.read_text(encoding='utf-8')

anchor_pe = "      const webuiError=formatUpdateError('WebUI',data.webui);"
assert pj.count(anchor_pe) == 1, 'panels.js: error-part anchor not found or ambiguous'
pj = pj.replace(anchor_pe, """      // -- hermes-suite patch (suite release check): relabel the webui slot --
      const _webuiLabel=(data&&data.webui&&data.webui.suite)?'Hermes Suite':'WebUI';
      const webuiError=formatUpdateError(_webuiLabel,data.webui);""", 1)

anchor_pp = "      const webuiPart=formatUpdatePart('WebUI',data.webui);"
assert pj.count(anchor_pp) == 1, 'panels.js: update-part anchor not found or ambiguous'
pj = pj.replace(anchor_pp, "      const webuiPart=formatUpdatePart(_webuiLabel,data.webui);", 1)

anchor_ng = "      if(data.webui&&data.webui.no_git&&!data.webui.manual_update) noGitParts.push('WebUI');"
assert pj.count(anchor_ng) == 1, 'panels.js: no-git anchor not found or ambiguous'
pj = pj.replace(anchor_ng, "      if(data.webui&&data.webui.no_git&&!data.webui.manual_update) noGitParts.push(_webuiLabel);", 1)

assert pj.count('_webuiLabel') == 4  # 1 def + 3 uses
PAN.write_text(pj, encoding='utf-8')
print('panels.js: suite release check applied')