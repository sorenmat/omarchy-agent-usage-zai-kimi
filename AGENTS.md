# AGENTS.md

Small repo (5 files): an Omarchy (Quattro) **service plugin** (`smo.agent-usage-zcode`)
that adds Z.ai and Kimi usage tabs to Omarchy's built-in **Agents** panel.
`Service.qml` (Quickshell/QML publisher) runs one collector per provider from
`collectors/` (single-file Python 3 scripts, stdlib only except the Z.ai
collector's optional `cryptography`).

## Commands

```sh
omarchy plugin validate .                          # validate plugin structure/manifest
qmllint -I /usr/share/omarchy/shell Service.qml    # QML lint; the -I path is required for the Quickshell imports
collectors/omarchy-agent-usage-zcode | jq .        # run a collector by hand, inspect the record
collectors/omarchy-agent-usage-kimi | jq .

omarchy plugin add ~/code/omarchy-agent-usage-zcode --enable   # install local copy
omarchy plugin remove smo.agent-usage-zcode                     # uninstall
omarchy plugin list                                             # confirm omarchy.agents panel is enabled
```

There are no tests, no build step, and no CI. Changes are verified by running
the collectors directly and watching the published files in
`~/.local/state/omarchy/agents/usage/`.

To test the Kimi collector's parsing without a live login, point it at a mock
endpoint: `KIMI_USAGE_URL` overrides the usage URL (plain HTTP is allowed for
loopback hosts only) and `KIMI_API_KEY` bypasses the credentials file.

## Architecture / data flow

The built-in `omarchy.agents` panel renders one tab per JSON record in
`~/.local/state/omarchy/agents/usage/`. Omarchy runs its packaged
`omarchy-agent-usage-*` collectors itself but only scans `OMARCHY_PATH/bin`, so
third-party providers need their own publisher — that is the sole reason
`Service.qml` exists. Flow:

1. On shell start and every 5 min, `Service.qml` runs each collector listed in
   its `collectors` array (`{recordId, script}`) via a `Repeater` of `Process`
   delegates. **Adding a provider = new script in `collectors/` plus one entry
   in that array** (and a `rm` line in the README's remove section).
2. Each delegate parses stdout and accepts the record **only if** it is valid
   JSON with `id === recordId`; otherwise it logs a warning and publishes
   nothing (the previous record stays on disk — the panel has no expiry).
3. It writes `<recordId>.json` with `FileView.atomicWrites: true` so the
   panel's file watcher never sees a torn record.
4. The service `mkdir -p`s the usage dir itself because it can start before
   `omarchy-agent-usage-update` creates it.

Reference sources worth reading before touching collectors: the packaged
collectors in `/usr/share/omarchy/bin/omarchy-agent-usage-*` (record
conventions, `omarchy:` header markers) and the panel at
`/usr/share/omarchy/shell/plugins/agents/Panel.qml`.

## Record schema contract (consumed by the panel)

`schemaVersion: 1`, `id`, `name`, `limits: [{label, percent, resetsAt}]`,
`tierLabel`, `ready`, `usageStatusText`, `authHelpText`, plus the stats fields
from `empty_stats()`. Semantics an agent could easily break:

- `percent` is the fraction **used** (0..1), not remaining; the panel flags
  `>= 0.9` as alarming. `resetsAt` must be parseable by QML `new Date(...)`.
- `scope: "account"` — quota numbers are account-global (identical on every
  synced device). The panel's aggregation logic must not sum them; do not
  change this to a machine-local scope.
- Errors are reported **inside** the record (`ready: false` + `authHelpText`),
  and collectors always exit 0 so a failed scan never looks like a crash to
  the service. Keep that behavior.
- `limits` rows with no usable `limit > 0` are skipped entirely.

## Gotchas

- **Z.ai auth order**: `ZAI_API_KEY` env var wins; otherwise the zcode desktop
  app's token is decrypted from `~/.zcode/v2/credentials.json`
  (`oauth:zai:access_token`, `enc:v1:<iv>.<tag>.<ciphertext>` urlsafe-base64,
  AES-256-GCM keyed by sha256 of `ZCODE_CREDENTIAL_SECRET` or the fallback
  string `zcode-credential-fallback:<platform>:<home>:<user>`). If you touch
  the decryption, re-read zcode's derivation — this repo reproduces it exactly.
- **Kimi auth order**: `KIMI_API_KEY` env var wins; otherwise the OAuth pair
  is read from the active kimi-code slot under `$KIMI_CODE_HOME/credentials/`
  (default `~/.kimi-code/...`). Current releases record a regional
  `kimi-code-env-<hash>.json` key and API hosts in `config.toml`; older releases
  use `kimi-code.json`. The collector falls back to the legacy kimi-cli store
  at `~/.kimi/credentials/kimi-code.json` (plain JSON).
  Access tokens expire, so the collector refreshes them itself: form POST of
  the refresh token to `auth.kimi.com/api/oauth/token` with the public
  client id (`17e5f671-…`), using the configured `kimi.com` or `kimi.ai`
  regional host, taken under a `flock` on the sibling
  `kimi-code.lock`. **The server issues single-use refresh tokens: a refreshed
  pair must always be persisted back (atomic replace, mode 0600) or the
  user's kimi login is destroyed.** After acquiring the lock, re-read the
  file — the lock holder may have just refreshed. `invalid_grant` means the
  refresh token expired: surface "sign in again with `kimi login`"; nothing
  code can fix.
- **Token security invariants** (do not regress in either collector): tokens
  are sent only to the provider's own domain (`z.ai` / `kimi.com` / `kimi.ai`
  subdomains)
  over HTTPS, HTTP redirects are refused (`NoRedirectHandler` — urllib would
  otherwise forward the Authorization header cross-host), and tokens are never
  written to disk, logs, or the published record. The one deliberate
  exception: the Kimi collector allows plain-HTTP URLs for loopback hosts so
  the parsing path is testable via `KIMI_USAGE_URL`.
- **Z.ai magic tuples**: api.z.ai identifies limit windows by `(unit, number)`
  pairs — `(5,1)` = monthly search, `(3,5)` = 5-hour session, `(6,1)` = 7-day
  weekly. These are reverse-engineered constants in `window_label()`, not
  documented anywhere upstream.
- **Kimi payload shape** (reverse-engineered from kimi-cli's
  `ui/shell/usage.py`): `{"usage": {...}, "limits": [{window: {duration,
  timeUnit}, detail: {limit, used | remaining, reset_at}}]}`. Labels come from
  `name`/`title`/`scope`, else the window duration (300 minutes -> "Session
  (5-hour)", 7 days -> "Weekly (7-day)"). `used` may be absent and must be
  derived as `limit - remaining`. Timestamps can carry nanosecond fractions
  that Python's `fromisoformat` rejects — trim to microseconds. kimi-cli
  displays "% left"; the panel wants fraction used, so invert.
- **Ignored CLI flags**: `--force` and `--limits-only` are accepted but no-ops;
  they exist only so omarchy can invoke these collectors like the packaged ones.
- **Header markers**: the `# omarchy:summary=`, `# omarchy:args=`, and
  `# omarchy:hidden=` lines under the shebang are omarchy metadata conventions
  (copyed from the packaged collectors); keep them when editing collectors.
- `cryptography` is imported lazily inside the Z.ai `decrypt_zcode_value`, so
  that collector still runs (env-key auth path) on systems without it.
- 401/403 from a provider maps to a "re-sign in" authHelp message; expired
  logins are a user-action problem, not a code fix.
- `fcntl.flock` makes the Kimi collector Linux-only; fine for omarchy.

## Style

- 2-space indentation in both the Python and QML (matches omarchy's shell
  code, not PEP 8's 4). Match it.
- No em dashes in source; use semicolons/commas/parentheses instead (the
  pre-existing Z.ai strings predate this rule; new code follows it).
- The QML `property var shell: null` is injected by the omarchy-shell service
  loader; it is part of the plugin API surface.
- `manifest.json` plugin id follows `<author>.<plugin-name>`
  (`smo.agent-usage-zcode` — kept for install continuity even though the
  plugin now covers two providers; rename only with a migration note).
