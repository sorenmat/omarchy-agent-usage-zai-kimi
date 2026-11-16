# AGENTS.md

Small repo (5 files): an Omarchy (Quattro) **service plugin**
(`smo.agent-usage-zcode`) that feeds the zcode and kimi-code desktop logins to
Omarchy's built-in **Agents** panel Z.ai and Kimi collectors. `Service.qml`
(Quickshell/QML) runs one bridge per provider from `collectors/` (single-file
Python 3 scripts, stdlib only except the Z.ai bridge's optional
`cryptography`).

Omarchy now ships first-party `omarchy-agent-usage-zai` and
`omarchy-agent-usage-kimi` collectors, and the panel runs them itself on its
own cadence (`omarchy-agent-usage-update`, every `refreshIntervalSec`, plus
`--limits-only` on every panel open). **This plugin no longer publishes usage
records.** It only bridges credentials the first-party collectors cannot
reach, so those collectors' `zai.json` / `kimi.json` records authenticate:

- **Z.ai**: the zcode app's token, decrypted and bridged into
  `~/.config/omarchy/agents/zai.json` (the first-party collector's documented
  config; an explicit config wins over `ZAI_API_KEY` and the pi/omp stores).
- **Kimi**: the kimi-code app's OAuth pair, kept readable at
  `~/.kimi-code/credentials/kimi-code.json` (the file the first-party
  collector scans). Current kimi-code releases keep the active pair in a
  regional `kimi-code-env-<hash>.json` named by
  `[providers."managed:kimi-code".oauth].key` in `config.toml`; the bridge
  keeps `kimi-code.json` a symlink to it, and converges the stores when they
  diverge.

## Commands

```sh
omarchy plugin validate .                          # validate plugin structure/manifest
qmllint -I /usr/share/omarchy/shell Service.qml    # QML lint; the -I path is required for the Quickshell imports
collectors/zai-zcode-bridge                        # run a bridge by hand (prints nothing on success)
collectors/kimi-store-bridge

# Watch what the first-party collectors now see:
OMARCHY_PATH=/usr/share/omarchy /usr/share/omarchy/bin/omarchy-agent-usage-zai --limits-only | jq .
OMARCHY_PATH=/usr/share/omarchy /usr/share/omarchy/bin/omarchy-agent-usage-kimi --limits-only | jq .

omarchy plugin add ~/code/omarchy-agent-usage-zai-kimi --enable   # install local copy
omarchy plugin remove smo.agent-usage-zcode                     # uninstall
omarchy plugin list                                             # confirm omarchy.agents panel is enabled
```

There are no tests, no build step, and no CI. Changes are verified by running
the bridges directly, then the first-party collectors, and watching
`~/.local/state/omarchy/agents/usage/{zai,kimi}.json` (written only by
`omarchy-agent-usage-update` now).

To test the Kimi bridge's refresh path without a live login, point it at a
mock endpoint: `KIMI_CODE_OAUTH_HOST` (or `KIMI_OAUTH_HOST`) overrides the
login host; plain HTTP is allowed for loopback hosts only. `KIMI_CODE_HOME`
moves the whole store, so sandbox the tests:
`KIMI_CODE_HOME=/tmp/... collectors/kimi-store-bridge`.

## Architecture / data flow

1. The panel's backend (`/usr/share/omarchy/shell/plugins/agents/Main.qml`)
   runs `omarchy-agent-usage-update` on a timer and on panel open; that
   script runs every executable `OMARCHY_PATH/bin/omarchy-agent-usage-*`
   collector and writes one `<agent>.json` per collector into
   `~/.local/state/omarchy/agents/usage/`, where the panel's file watcher
   renders the tabs. This plugin never writes into that directory.
2. On shell start and every 5 min, `Service.qml` runs each bridge listed in
   its `bridges` array (`{name, script}`) via a `Repeater` of `Process`
   delegates. **Adding a bridge = new script in `collectors/` plus one entry
   in that array.**
3. Each delegate warns on stderr output or a non-zero exit; the bridges
   always exit 0 (problems are diagnostic, not fatal) and print nothing on
   success.
4. The service `mkdir -p`s the usage dir itself because it can start before
   the panel's first `omarchy-agent-usage-update` creates it.

Reference sources worth reading before touching the bridges: the packaged
collectors in `/usr/share/omarchy/bin/omarchy-agent-usage-{zai,kimi}` (what
credential sources they read, in what order, and which lock they take) and
the shared plumbing `/usr/share/omarchy/shell/plugins/agents/collectors.py`.
When omarchy updates those collectors, re-check the bridges against their new
behavior before assuming they still fit.

## First-party contract (what the bridges must keep true)

The built-in collectors, in order of precedence:

- **Z.ai** (`omarchy-agent-usage-zai`): `~/.config/omarchy/agents/zai.json`
  (`apiKey`, optional `platform`: `zai` | `zhipu`), then `ZAI_API_KEY` /
  `ZHIPU_API_KEY` env, then pi/omp stores. The bridge writes
  `{"apiKey": ..., "__bridgedBy": "smo.agent-usage-zcode:zcode"}` (mode 0600,
  atomic replace). The `__bridgedBy` marker is what makes the bridge allowed
  to delete the file when zcode signs out; a hand-written config (no marker)
  is never touched, and it wins over the bridge because the collector reads
  it first.
- **Kimi** (`omarchy-agent-usage-kimi`): `KIMI_API_KEY` env, then the OAuth
  pair at `$KIMI_CODE_HOME/credentials/kimi-code.json` (default
  `~/.kimi-code/credentials/kimi-code.json`), then the legacy kimi-cli store
  `~/.kimi/credentials/kimi-code.json`. It refreshes expired pairs itself,
  under the store's lock, and persists the rotation **only into
  `kimi-code.json`** (`os.replace` swaps a symlink for a real file). That is
  exactly why the bridge exists and why every rotated pair must be carried
  back into the regional file: the CLI refreshes the regional file only, this
  bridge keeps both in step, and the collector never sees the regional store.
  All three are serialized on the same lock: the directory lease at
  `<home>/oauth/kimi-code.lock` (proper-lockfile style, the bridge renews it
  around its refresh POST) for the kimi-code stores, or a `flock` on the
  sibling `kimi-code.lock` for the legacy store.

## Gotchas

- **Z.ai auth**: the zcode desktop app's token is decrypted from
  `~/.zcode/v2/credentials.json` (`oauth:zai:access_token`,
  `enc:v1:<iv>.<tag>.<ciphertext>` urlsafe-base64, AES-256-GCM keyed by
  sha256 of `ZCODE_CREDENTIAL_SECRET` or the fallback string
  `zcode-credential-fallback:<platform>:<home>:<user>`). If you touch the
  decryption, re-read zcode's derivation — this repo reproduces it exactly.
  A decryption failure keeps the last bridged key in place (it may still be
  live) and logs a warning; only a missing zcode entry removes the bridge
  file.
- **Kimi single-use refresh tokens**: the server issues single-use refresh
  tokens, so a rotated pair must always be persisted back (atomic replace,
  mode 0600) into **every** file that still holds the old one, or the user's
  kimi login is destroyed. After acquiring the lock, re-read the stores — the
  lock holder may have just refreshed. `invalid_grant` can also mean another
  refresher (the CLI or the collector) already spent the token: re-read, and
  if some store now holds a fresh pair, adopt it and converge instead of
  erroring. Only when no store is fresh is it "sign in again with
  `kimi login`"; nothing code can fix.
- **Kimi regional layout**: current releases record the active credential
  file (`kimi-code-env-<hash>.json`) and the regional login host
  (`auth.kimi.com` / `auth.kimi.ai`) in `config.toml` under
  `[providers."managed:kimi-code".oauth]`. The named slot wins over mtime;
  when the named file is missing, the newest `kimi-code-env-*.json` on disk
  stands in. The regional hosts are mirrors of each other (same accounts and
  tokens), which is why bridging into the filename the collector hard-codes
  is enough; the bridge refreshes against the configured regional host.
- **Token security invariants** (do not regress in either bridge): tokens are
  sent only to the provider's own domain (`z.ai` / `kimi.com` / `kimi.ai`
  subdomains) over HTTPS, HTTP redirects are refused (`NoRedirectHandler` —
  urllib would otherwise forward the Authorization header cross-host), and
  tokens never reach logs, stderr, or the usage records (the one place a Z.ai
  token is written to disk is the 0600 first-party config file, which is that
  collector's documented credential store). The one deliberate exception: the
  Kimi bridge allows plain-HTTP refresh URLs for loopback hosts so the
  refresh path is testable via `KIMI_CODE_OAUTH_HOST`.
- **Symlink swap**: the first-party collector's atomic replace turns
  `kimi-code.json` from a symlink into a real file holding a pair newer than
  the regional store's. `converge()` carries that pair into the regional file
  and re-links, so the CLI's own next refresh finds a live token. Do not
  "simplify" this away.
- **Bridge freshness check** mirrors the first-party `token_fresh` (60 s
  skew; a missing `expires_at` means indefinite). If you change one, change
  the other side's expectation too.
- **Header markers**: the `# omarchy:summary=` and `# omarchy:hidden=` lines
  under the shebang are omarchy metadata conventions (copied from the
  packaged collectors); keep them when editing the bridges.
- `cryptography` is imported lazily inside the Z.ai bridge's
  `decrypt_zcode_value`, so the bridge still runs on systems without it
  (warning on stderr, last bridge kept).
- 401/403 at refresh time maps to a "re-sign in" diagnostic; expired logins
  are a user-action problem, not a code fix.
- `fcntl.flock`, the directory-lease lock, and `os.utime` make the Kimi
  bridge Linux-only; fine for omarchy.

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
