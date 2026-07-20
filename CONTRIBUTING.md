# Contributing to MacCL

Thanks for taking an interest. MacCL is a small, focused project: a native macOS
interface over the Claude Code CLI. Issues, ideas and pull requests are welcome.

## Getting set up

You'll need **macOS 14+**, **Swift 6** (ships with Xcode), and the
[Claude Code CLI](https://code.claude.com) installed and signed in. For anything
touching local models, also [Ollama](https://ollama.com) 0.14 or newer.

```bash
git clone https://github.com/Trano89/MacCL.git
cd MacCL
swift build                 # quick compile check
./scripts/build.sh          # builds and installs /Applications/MacCL.app
```

`scripts/build.sh` builds release by default (pass `debug` to override),
assembles the bundle in a temp folder, signs it ad-hoc, quits any running
instance, then replaces `/Applications/MacCL.app`. The replace is `rm -rf` +
`cp -R`, not an atomic swap — if it's interrupted midway, just re-run it.

## Verifying a change

**There is no test suite yet** — so changes are verified by running the app. Be
honest in your PR about what you actually exercised.

Useful while debugging:

- **Log file**: `~/Library/Logs/MacCL/maccl.log` — the `claude` child process's
  stderr and the app's own diagnostics land here.
- **Conversations**: `~/Library/Application Support/MacCL/conversations/` — one
  readable JSON file per conversation.
- **The command shown in the transcript** comes from the same builder as the
  real spawn, but it is not copy-pasteable as-is: the system prompt appears as a
  `$(cat instructions/*.md)` placeholder, and three environment variables set on
  every spawn (`CLAUDE_CODE_MAX_OUTPUT_TOKENS`, `API_TIMEOUT_MS`,
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`) are deliberately left out. Use it
  to see the flags, not to replay a session byte-for-byte.

A test target would be a genuinely welcome contribution — the decoding layer
(`Models/StreamJSON.swift`, `Models/JSONValue.swift`) and `Utils/URLValidator.swift`
are pure and easy to cover.

## Layout

```
Sources/MacCL/
├── App/          SwiftUI entry point + Settings window
├── Models/       Protocol decoding, model catalog, settings, persistence
├── Engine/       ClaudeSession (drives the CLI), OllamaClient, discovery, updates
├── Utils/        URL validation, appearance coordination
├── ViewModels/   ChatViewModel — conversation orchestration
└── Views/        Sidebar, chat, message rows, tool cards, panels, Settings
```

## Invariants worth knowing

These aren't style preferences — each one was learned by breaking it.

1. **Don't reimplement the agent.** The app launches the official `claude` CLI
   and speaks its stream-json protocol. Behaviour belongs to the CLI.
2. **The flags displayed must be the flags that run.** All three surfaces —
   transcript, new-conversation preview, actual spawn — call one builder
   (`SessionConfig.cliArguments`); its `forDisplay` flag substitutes only the
   system-prompt value with a readable placeholder. Never format a command by
   hand for display: extend the builder instead.
3. **A conversation is bound to its server.** If it goes offline, the
   conversation waits and says so — never silently switch to another machine.
4. **Every user-facing string goes through `L10n.t`**, with all five languages
   filled in (`Models/Localization.swift`) — the table's tuple type makes a
   partial translation a compile error. Two traps: a missing *key* renders as the
   raw key (nothing warns you), and a *duplicate* key crashes the app at launch,
   since it's a Swift dictionary literal.
5. **Don't swallow errors.** `try?` that hides a failure is how conversations
   used to vanish without trace. Log through `AppLog` and surface what the user
   needs to act on.
6. **Keep the launch command minimal.** A CLI flag is only added when it changes
   something; session-level settings travel in-band (e.g. `/effort`).

## Style

Match the surrounding code — naming, spacing, comment density. Comments explain
**why**, not what: prefer "without this, a backgrounded turn is lost" over
"set the flag".

## Commits and pull requests

- Descriptive commit messages, English or French, both are fine. Say what
  changed and why.
- One concern per pull request.
- Fill in the PR template: what, why, and how you verified it.

## Reporting bugs

Open an [issue](https://github.com/Trano89/MacCL/issues/new/choose). The bug
template asks for your MacCL version, macOS version, and whether you're on
Anthropic or Ollama — those three answers resolve most reports quickly.
