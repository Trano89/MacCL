## What

<!-- What changes, in a sentence or two. -->

## Why

<!-- The problem being solved. If it fixes an issue: Fixes #123 -->

## How it was verified

<!--
There's no test suite yet, so this section matters. Say what you actually ran —
"built and sent a turn on Ollama/qwen3-coder, watched the transcript" is a fine
answer. "Should work" is not.
-->

## Checklist

- [ ] `swift build` passes
- [ ] Installed the build (`./scripts/build.sh`), launched `/Applications/MacCL.app` and exercised the affected path
- [ ] New user-facing strings go through `L10n.t`, with all five languages filled in
- [ ] Errors are surfaced or logged (`AppLog`), not swallowed
- [ ] If the launch command changed: display and spawn still come from `SessionConfig.cliArguments`
