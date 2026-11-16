# Agent Usage: Z.ai + Kimi

An Omarchy (Quattro) **service plugin** that keeps the **Z.ai (GLM Coding
Plan)** and **Kimi for Coding** tabs of Omarchy's built-in **Agents** panel
authenticated with the logins you already have in the **zcode** and
**kimi-code** desktop apps — no hand-entered API key.

Omarchy ships first-party Z.ai and Kimi usage collectors, and the panel runs
them itself. Those collectors cannot see the zcode or kimi-code logins, so
this plugin bridges the credentials where those collectors look for them:

- **Z.ai**: the zcode app's sign-in token is decrypted and bridged into
  `~/.config/omarchy/agents/zai.json`, the collector's documented config
  (which wins over `ZAI_API_KEY`).
- **Kimi**: the kimi-code app's OAuth pair is kept readable at
  `~/.kimi-code/credentials/kimi-code.json`, the file the collector scans.
  Current kimi-code releases keep the active pair in a regional file
  (`kimi-code-env-<hash>.json`, named by `config.toml`), so the bridge
  normally maintains that as a symlink target and converges the stores when
  they diverge.

The built-in collectors publish the usage records themselves; this plugin
writes nothing into the usage state directory.

## How it works

The built-in `omarchy.agents` panel renders one tab per JSON record in
`~/.local/state/omarchy/agents/usage/` and runs omarchy's packaged
`omarchy-agent-usage-*` collectors on its own cadence (every
`refreshIntervalSec`, and a cheap limits-only pass on every panel open).

This plugin is a headless `service` that:

1. Runs each bundled Python bridge every 5 minutes (and on shell start).
2. Z.ai bridge: decrypts the zcode token and atomically writes the 0600
   config file, tagged with a `__bridgedBy` marker so a config you wrote by
   hand is never clobbered.
3. Kimi bridge: keeps `kimi-code.json` in step with the active regional
   credential file (a symlink where possible), and when every copy of the
   OAuth pair is stale, refreshes it the way the CLI does — under the
   store's own lock, so the CLI, the built-in collector and this plugin are
   serialized on one refresh, and the rotated (single-use) refresh token is
   persisted into every file that still holds it.

Adding another bridge means adding a `collectors/*` script and one entry in
`Service.qml`'s `bridges` list.

## Authentication

### Z.ai

The bearer token comes from the zcode app's sign-in at
`~/.zcode/v2/credentials.json` — the `oauth:zai:access_token` entry. zcode
stores it AES-256-GCM encrypted under an `enc:v1:` prefix; the key is `sha256`
of a machine-local secret (`ZCODE_CREDENTIAL_SECRET` when zcode runs with
one, otherwise the built-in `zcode-credential-fallback:<platform>:<home>:<user>`
string). The bridge reproduces that derivation, decrypts the token in memory,
and writes it only to `~/.config/omarchy/agents/zai.json` (mode 0600, atomic
replace). The built-in collector probes Z.ai with it and does the rest (limits
caching, local stats).

Re-sign in inside zcode whenever the token lapses; the panel shows the
collector's own "rejected the saved API key" note until the next bridge cycle.

### Kimi

The OAuth pair comes from the active kimi-code sign-in under
`$KIMI_CODE_HOME/credentials` (default `~/.kimi-code/credentials`). Current
releases record the regional credential filename and API/login hosts in
`config.toml` (`[providers."managed:kimi-code".oauth]`); older releases use
`kimi-code.json` directly, and the legacy kimi-cli store
(`~/.kimi/credentials/kimi-code.json`) is kept fresh in place as a fallback.
Access tokens expire (about fifteen minutes), so the bridge refreshes them
the way the CLI does: under the store's own lock, a form POST of the refresh
token to the configured login host (`kimi.com` or `kimi.ai`) with the public
client id. The server issues single-use refresh tokens, so the rotated pair
is always persisted back (mode 0600, atomic replace) into every file that
still holds it. Tokens go only to official Kimi hosts over HTTPS and never
anywhere else.

When the refresh token itself expires (the CLI shows the same), run
`kimi login`, and the tab recovers on the next cycle.

## What it shows

The tabs are the built-in collectors' records, fed by the bridged logins:

- Z.ai: the plan tier, the 5-hour session window, the 7-day token window, and
  the monthly web-search allowance — from the `api.z.ai` usage monitor, plus
  pi/omp/opencode local stats on Z.ai's providers.
- Kimi: the 5-hour session window and the monthly quotas — from the same
  `api.kimi.com` usage endpoint the CLI's `/usage` command renders, plus
  local stats from the kimi-code session logs.

## Requirements

- Omarchy (Quattro) with the built-in **Agents** widget enabled
  (`omarchy plugin list` shows `omarchy.agents` enabled) and a release whose
  Agents panel ships `omarchy-agent-usage-zai` and `omarchy-agent-usage-kimi`.
- `python3` (the Kimi bridge additionally uses stdlib `fcntl` on Linux).
- For Z.ai: the `cryptography` package (used by every Arch/omarchy install
  that runs zcode; `omarchy pkg add python-cryptography` otherwise).
- For Kimi: a sign-in from [Kimi Code](https://www.kimi.com/code/docs/en/)
  (`kimi login`).

## Install

```sh
omarchy plugin add ~/code/omarchy-agent-usage-zcode --enable
```

## Remove

```sh
omarchy plugin remove smo.agent-usage-zcode
rm -f ~/.config/omarchy/agents/zai.json   # only when it carries the __bridgedBy marker
rm ~/.kimi-code/credentials/kimi-code.json  # only when it is the bridge's symlink
```

The built-in collectors keep running after removal; without the bridges their
tabs simply read "Waiting for auth" again (or your `ZAI_API_KEY` /
`KIMI_API_KEY` if you have one).

## Development

```sh
omarchy plugin validate .
qmllint -I /usr/share/omarchy/shell Service.qml
collectors/zai-zcode-bridge          # prints nothing on success
collectors/kimi-store-bridge

# Then confirm the built-in collectors see the bridged credentials:
OMARCHY_PATH=/usr/share/omarchy /usr/share/omarchy/bin/omarchy-agent-usage-zai --limits-only | jq .
OMARCHY_PATH=/usr/share/omarchy /usr/share/omarchy/bin/omarchy-agent-usage-kimi --limits-only | jq .
```

The Kimi bridge's refresh path can be tested against a mock login endpoint
without a live login: `KIMI_CODE_OAUTH_HOST` overrides the login host (plain
HTTP is allowed for loopback hosts only) and `KIMI_CODE_HOME` moves the whole
store, so run it against a sandbox, e.g.
`KIMI_CODE_HOME=/tmp/kimi-test KIMI_CODE_OAUTH_HOST=http://127.0.0.1:8765 collectors/kimi-store-bridge`.

## License

MIT
