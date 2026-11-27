# Security Policy

## Supported versions

MacCL is a young project with a single active line. Fixes land in the latest
release only.

| Version | Supported |
| ------- | --------- |
| 0.1.3 (latest) | ✅ |
| older 0.1.x | ❌ — please update |

## Reporting a vulnerability

Please **don't open a public issue** for a security problem.

Use GitHub's private reporting instead:
[**Report a vulnerability**](https://github.com/Trano89/MacCL/security/advisories/new).
It's private between you and the maintainer until a fix is out.

Expect a first reply within a few days. This is a spare-time project, so please
be patient — and do let me know if you plan to disclose publicly, so a fix can be
ready in time.

## What MacCL does by design

Some behaviours look alarming but are the intended function of the app. Knowing
them helps you judge what is — and isn't — a vulnerability.

- **The agent executes commands on your machine.** MacCL drives the Claude Code
  CLI, whose whole purpose is to read files, edit them and run shell commands in
  the working directory you choose. The default permission mode is *all tools*,
  meaning no confirmation prompt. Pick the working directory deliberately, and
  use *Plan* mode if you want the agent to think without acting.
- **Ollama traffic is unauthenticated, and plain HTTP by default.** Ollama has
  no notion of accounts, and MacCL sends a fixed placeholder token
  (`ANTHROPIC_AUTH_TOKEN=ollama`) that no server checks. An `https://` URL is
  accepted if you front Ollama with a TLS reverse proxy — but MacCL cannot send
  a real credential, so a proxy requiring bearer auth won't work. Exposing a
  server to your network means anyone who can reach that address can use your
  models. Keep it on a trusted network.
- **Conversations are stored in clear text**, as JSON under
  `~/Library/Application Support/MacCL/conversations/`. They contain whatever
  the agent read, which may include source code and secrets. They're yours to
  delete.
- **Diagnostic logs** at `~/Library/Logs/MacCL/maccl.log` capture the child
  process's stderr. Known key shapes are masked before writing — Anthropic,
  OpenAI, GitHub, GitLab, Slack, AWS, JWTs, and unbroken 40+ character base64
  runs. It is a safety net, not a guarantee: an unrecognised format, or a secret
  printed in fragments, will get through. Review a log before sharing it.
- **The app is ad-hoc signed, not notarized**, so Gatekeeper blocks it on first
  launch. On macOS 14, right-click → *Open*. On macOS 15 and later, try to open
  it once, then go to System Settings → Privacy & Security → *Open Anyway*. Only
  run builds you made yourself or downloaded from this repository's
  [releases](https://github.com/Trano89/MacCL/releases).

## What counts as a vulnerability here

Things worth reporting: a way to make MacCL send a conversation to a server the
user didn't choose; command injection through a server URL, model name or
attachment path; secrets leaking into the log despite redaction; anything that
makes the app execute code outside the Claude Code CLI's own sandboxing rules.
