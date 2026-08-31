# Agent Usage: Z.ai + Kimi

An Omarchy (Quattro) **service plugin** that adds **Z.ai (GLM Coding Plan)** and
**Kimi for Coding** usage tabs to Omarchy's built-in **Agents** panel — the panel
that already ships Claude, Codex, and Fireworks tabs.

Unlike other Z.ai/Kimi collectors, this one needs no API key and no opencode
sign-in: it authenticates with the login you already have in the **zcode** and
**kimi-code** desktop apps.

## How it works

The built-in `omarchy.agents` panel draws one tab per JSON record in
`~/.local/state/omarchy/agents/usage/`. Omarchy runs its packaged
`omarchy-agent-usage-*` collectors itself, but only scans `OMARCHY_PATH/bin`,
so third-party providers need their own publisher.

This plugin is a headless `service` that:

1. Runs each bundled Python collector every 5 minutes (and on shell start).
2. Validates each collector's JSON output.
3. Publishes the records to the usage state directory with atomic writes.

Adding another provider means adding a `collectors/omarchy-agent-usage-*`
script and one entry in `Service.qml`'s `collectors` list.

## Authentication

### Z.ai

The bearer token is resolved in this order:

1. `ZAI_API_KEY` environment variable, when set.
2. The zcode app's sign-in at `~/.zcode/v2/credentials.json` — the
   `oauth:zai:access_token` entry. zcode stores it AES-256-GCM encrypted under
   an `enc:v1:` prefix; the key is `sha256` of a machine-local secret
   (`ZCODE_CREDENTIAL_SECRET` when zcode runs with one, otherwise the built-in
   `zcode-credential-fallback:<platform>:<home>:<user>` string). The collector
   reproduces that derivation, decrypts the token in memory, and:

   - sends it only to `https://api.z.ai` over HTTPS (redirects are refused so
     the token can never leak to another host),
   - never writes it to disk, logs, or the published JSON record.

Re-sign in inside zcode whenever the token expires; the collector reports
"Z.ai rejected the credentials" until then.

### Kimi

The bearer token is resolved in this order:

1. `KIMI_API_KEY` environment variable, when set.
2. The active kimi-code sign-in under `$KIMI_CODE_HOME/credentials/`
   (default `~/.kimi-code/credentials/`), including the regional
   `kimi-code-env-<hash>.json` slots used by current releases, falling back to
   the legacy kimi-cli store at `~/.kimi/credentials/kimi-code.json` — plain
   JSON with an OAuth `access_token`/`refresh_token` pair. The active slot and
   regional API hosts come from kimi-code's `config.toml`. Access tokens expire, so
   the collector refreshes them exactly the way the CLI does: under a `flock`
   on the sibling `kimi-code.lock`, a form POST of the refresh token to
   `auth.kimi.com/api/oauth/token` with the public client id. The server
   issues single-use refresh tokens, so the rotated pair is always persisted
   back to the credentials file (mode 0600, atomic replace) — both this
   collector and the CLI keep working from the same file. Tokens go only to
   hosts under `kimi.com` or `kimi.ai` over HTTPS and never anywhere else.

When the refresh token itself expires (the CLI shows the same), run
`kimi login`, and the tab recovers on the next scan.

## What it shows

- Z.ai: plan tier (lite/standard/pro), the 5-hour session window, the 7-day
  token window, and the monthly web-search allowance — from the `api.z.ai`
  usage monitor.
- Kimi: the weekly quota and per-window limits (e.g. the 5-hour session) —
  from the same `api.kimi.com` usage endpoint the kimi-cli `/usage` command
  renders.

## Requirements

- Omarchy (Quattro) with the built-in **Agents** widget enabled
  (`omarchy plugin list` shows `omarchy.agents` enabled).
- `python3` (the Kimi collector additionally uses stdlib `fcntl` on Linux).
- For Z.ai: the `cryptography` package (used by every Arch/omarchy install
  that runs zcode; `omarchy pkg add python-cryptography` otherwise).
- For Kimi: a sign-in from [Kimi Code](https://www.kimi.com/code/docs/en/) (`kimi login`).

## Install

```sh
omarchy plugin add ~/code/omarchy-agent-usage-zcode --enable
```

## Remove

```sh
omarchy plugin remove smo.agent-usage-zcode
rm -f ~/.local/state/omarchy/agents/usage/zai.json ~/.local/state/omarchy/agents/usage/kimi.json
```

The panel has no expiry for records, so removing the last-written files stops
the (now stale) tabs from lingering.

## Development

```sh
omarchy plugin validate .
qmllint -I /usr/share/omarchy/shell Service.qml
collectors/omarchy-agent-usage-zcode | jq .
collectors/omarchy-agent-usage-kimi | jq .
```

The Kimi collector can be pointed at a mock endpoint for testing the parsing
without a live login: `KIMI_USAGE_URL` overrides the usage endpoint (plain
HTTP is allowed for loopback hosts only) and `KIMI_API_KEY` bypasses the
credentials file.

## License

MIT
