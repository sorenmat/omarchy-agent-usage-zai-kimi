# Agent Usage: Z.ai (zcode)

An Omarchy (Quattro) **service plugin** that adds a **Z.ai (GLM Coding Plan)**
usage tab to Omarchy's built-in **Agents** panel — the panel that already ships
Claude, Codex, and Fireworks tabs.

Unlike other Z.ai collectors, this one needs no API key and no opencode
sign-in: it authenticates with the login you already have in the
**zcode desktop app**.

## How it works

The built-in `omarchy.agents` panel draws one tab per JSON record in
`~/.local/state/omarchy/agents/usage/`. Omarchy runs its packaged
`omarchy-agent-usage-*` collectors itself, but only scans `OMARCHY_PATH/bin`,
so third-party providers need their own publisher.

This plugin is a headless `service` that:

1. Runs the bundled Python collector every 5 minutes (and on shell start).
2. Validates the collector's JSON output.
3. Publishes the record to the usage state directory with atomic writes.

## Authentication

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

## What it shows

- Plan tier (lite/standard/pro)
- The 5-hour session token window
- The 7-day token window
- The monthly web-search allowance

straight from the `api.z.ai` usage monitor.

## Requirements

- Omarchy (Quattro) with the built-in **Agents** widget enabled
  (`omarchy plugin list` shows `omarchy.agents` enabled).
- `python3` with the `cryptography` package (used by every Arch/omarchy
  install that runs zcode; `omarchy pkg add python-cryptography` otherwise).

## Install

```sh
omarchy plugin add ~/code/omarchy-agent-usage-zcode --enable
```

## Remove

```sh
omarchy plugin remove smo.agent-usage-zcode
rm -f ~/.local/state/omarchy/agents/usage/zai.json
```

The panel has no expiry for records, so removing the last-written file stops
the (now stale) tab from lingering.

## Development

```sh
omarchy plugin validate .
qmllint -I /usr/share/omarchy/shell Service.qml
collectors/omarchy-agent-usage-zcode | jq .
```

## License

MIT
