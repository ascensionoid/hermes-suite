# webui-root-env-7048.py — hermes-suite patch for upstream webui issue #7048
# Applied at build time (Stage 5) to /opt/hermes-webui/api/profiles.py.
#
# Why a standalone file instead of a Dockerfile heredoc: podman 3.4.x (the
# runtime on low-resource edge hosts like Jetson Nano / JetPack 4) predates
# BuildKit-style heredoc support and parses heredoc bodies as Dockerfile
# instructions (e.g. 'from pathlib import Path' -> bogus FROM). A COPY+RUN
# works on every builder.
#
# DROP THIS PATCH when a stable webui tag ships _ROOT_ENV_SHARE_ALLOWLIST
# in api/profiles.py natively.
from pathlib import Path

p = Path('/opt/hermes-webui/api/profiles.py')
src = p.read_text(encoding='utf-8')

ALLOWLIST = '''
# ── hermes-suite patch (#7048): root .env fallback for named profiles ──────
# Only explicitly allowlisted, non-secret operator/runtime settings may fall
# back to the root (deployment) .env. Secrets (e.g. FIRECRAWL_API_KEY) and
# HERMES_WEBUI_* server keys are NEVER inherited (profile isolation invariant,
# mirrors upstream PR #7060 maintainer review). A profile-defined key — even
# empty — always wins over the root fallback.
_ROOT_ENV_SHARE_ALLOWLIST = frozenset({
    'SEARXNG_URL',
    'FIRECRAWL_API_URL',
    'FIRECRAWL_GATEWAY_URL',
    'FIRECRAWL_BROWSER_TTL',
})


def _root_env_path_for(home):
    """Return the root/parent .env a named profile may inherit from, else None."""
    try:
        home = Path(home).expanduser()
        if home.parent.name == 'profiles':
            root_candidate = home.parent.parent / '.env'
            if root_candidate.exists():
                return root_candidate
    except Exception:
        pass
    return None
'''

FALLBACK = '''
    # ── hermes-suite patch (#7048): allowlisted root .env fallback ─────────
    root_env_path = _root_env_path_for(home)
    if root_env_path is not None:
        try:
            for line in root_env_path.read_text(encoding='utf-8').splitlines():
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    k, v = line.split('=', 1)
                    k = k.strip()
                    v = v.strip().strip('"').strip("'")
                    if k in _ROOT_ENV_SHARE_ALLOWLIST and k not in env and v:
                        env[k] = v
        except Exception:
            logger.debug("Failed to read root env from %s", root_env_path)
'''

anchor_const = "_PROTECTED_ENV_KEYS = frozenset({\n    'HERMES_WEBUI_ISOLATED_PROFILE',"
assert src.count(anchor_const) == 1, 'protected-keys anchor not found or ambiguous'

# Insert the allowlist block AFTER the closing of _PROTECTED_ENV_KEYS
close_anchor = "    'HERMES_WEBUI_MAX_SESSION_RESOLVE',\n})"
assert src.count(close_anchor) == 1, 'protected-keys close anchor not found or ambiguous'
src = src.replace(close_anchor, close_anchor + '\n' + ALLOWLIST, 1)

anchor_ret = 'logger.debug("Failed to read runtime env from %s", env_path)\n\n    return env'
assert src.count(anchor_ret) == 1, 'return anchor not found or ambiguous'
src = src.replace(anchor_ret,
                  'logger.debug("Failed to read runtime env from %s", env_path)\n'
                  + FALLBACK + '\n    return env', 1)

assert src.count('_ROOT_ENV_SHARE_ALLOWLIST') == 2
assert src.count('_root_env_path_for') == 2
p.write_text(src, encoding='utf-8')
print('webui #7048 root-env patch applied')
