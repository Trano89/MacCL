# MacCL

**A native Mac interface layered on top of the [Claude Code CLI](https://code.claude.com), wired to [Ollama](https://ollama.com) — so you get the full Claude Code CLI toolset (shell, file editing, search, web, sub-agents) powered by the brain of your choice: Anthropic's cloud models, or a local Ollama LLM, even one running on another machine in your home network.**

![The MacCL interface](docs/img/maccl.svg)

## What is this?

The Claude Code CLI is a coding agent that runs in a terminal: you tell it what you want in plain language, and it reads your files, writes code, runs commands and tests until the job is done. Its power comes from its **tools** — shell access, file editing, code search, web fetching, sub-agents — but its home is a terminal window, and out of the box it only talks to Anthropic's models.

MacCL is an **overlay**: a real Mac app wrapped around the unmodified Claude Code CLI. It doesn't reimplement the agent — it launches the official `claude` CLI in the background, speaks its streaming protocol, and turns the raw terminal output into an interface. Your conversations are saved and organized in a sidebar. Every tool the CLI uses — running a command, editing a file, searching — shows up in the chat as a small card you can expand. You can watch the model think, drag files and screenshots straight into the conversation, and switch between light and dark mode.

And this is the heart of the project: **the Claude Code CLI's tools, with the LLM of your choice.**

- **Anthropic's models** (Opus, Sonnet, Haiku…) — the smartest option, using your existing Claude subscription or API key, exactly as the CLI does on its own.
- **A local LLM through Ollama** — free and private, running entirely on your own hardware. Ollama speaks Anthropic's API natively, so MacCL simply points the Claude Code CLI at your Ollama server — local or remote — and the whole agentic tool loop (shell, edits, tests, retries) runs on your own model. The machine with the GPU doesn't even have to be the Mac you're sitting at.

```
MacCL.app (the interface)
   │
   ▼
Claude Code CLI (the agent + its tools)  ── runs here, or over SSH on another machine
   ├──►  Anthropic cloud   (Opus, Sonnet, Haiku…)
   └──►  Ollama server      (your LLM — this Mac, or any machine nearby)
```

Two axes, and they're independent: **which brain** thinks (Anthropic or Ollama), and **which machine** the agent works on. A conversation can run a local Ollama model against a project on a server across the room, or Anthropic's Opus against a folder on this Mac — any combination.

Nothing is hidden: every conversation shows the CLI command behind it — the model, the flags, the server it talks to, the machine it runs on — so you can always see what the app asked the agent to do. Honest by design.

One more thing worth knowing: **each conversation is tied to the server you picked for it.** If that machine goes offline, the conversation waits and tells you — it never quietly switches your work to a different computer.

## Features

- Persistent conversations with resume, grouping, and running cost
- Any model, per conversation: Anthropic (Opus, Sonnet, Haiku, Fable) or Ollama — with automatic discovery of servers on your network
- Work on a **remote machine over SSH**: connect with user, address and password, browse its folders from inside the app, and the agent runs *there*
- Live view of the model's reasoning; effort level adjustable mid-conversation
- Live token gauge per conversation, with one-click context compaction when it grows too big
- Attachments: images (for vision models), text files, anything else by reference
- A library of Markdown instruction files injected into the system prompt
- Models stay loaded on the server between turns — no waiting for reloads
- Light / dark / automatic theme, 12 accent colors
- Interface in 5 languages (EN, FR, DE, PT, ES)
- Manage the models of any Ollama server from inside the app — `pull`, `rm`, `cp`, `create` — even on a remote machine
- Adjustable reply-length cap, when a long agentic turn hits the CLI's output-token ceiling
- Built-in update check against this repository's releases (Settings → About)

## Installation

**The easy way:** download the DMG from the [latest release](https://github.com/Trano89/MacCL/releases/latest), open it, and drag **MacCL** into **Applications**. On first launch macOS will block it (the app is self-signed): right-click → *Open* on macOS 14, or open it once then allow it from System Settings → Privacy & Security on macOS 15+.

**From source** — you'll need macOS 14 or newer, Swift 6 (comes with Xcode), and the [Claude Code CLI](https://code.claude.com) installed and signed in (`claude` available in your terminal). For local models: [Ollama](https://ollama.com) 0.14 or newer, with at least one model pulled (`ollama pull qwen3-coder:30b`). To work on a remote machine over SSH, that machine needs its own `claude`, installed and signed in.

```bash
git clone https://github.com/Trano89/MacCL.git
cd MacCL
./scripts/build.sh        # builds and installs /Applications/MacCL.app
```

That's it — MacCL is now in your Applications folder, ready to launch from Spotlight or the Dock. The app is self-signed, so it runs locally without notarization. Re-run the same script to update after pulling changes.

## Setup

**Anthropic models** — nothing to do. The app reuses the sign-in from your `claude` CLI.

**Ollama on this Mac** — nothing to do either. `http://localhost:11434` is detected automatically.

**Ollama on another machine** — by default Ollama only listens to its own computer, so the first step happens *on the machine that holds the models*: let it accept connections from the network.

In the Ollama app, that's a single switch — **Settings → Expose Ollama to the network**:

![Ollama settings: expose to the network](docs/img/ollama-network.svg)

On a headless server, the same thing as an environment variable:

```bash
OLLAMA_HOST=0.0.0.0 ollama serve
```

Then, back in MacCL: hit **Scan** to sweep your network — or just type the machine's IP address (`192.168.1.20` is enough; `http://` and port `11434` are filled in for you). The conversation is then bound to that machine.

**Models on the server** — click the server chip → *Manage models*: see what's installed (with sizes), delete with one click, or type terminal-style commands — `pull qwen3:14b`, `rm llama3:8b`, `cp a b`, `create fast from qwen3:8b num_ctx 8192`. Works the same on a remote machine — it's all Ollama's HTTP API.

**Working on another machine (SSH)** — click the folder chip → **SSH machine** → *Connect to a machine*. Enter the user, the address, and the password (leave it empty to use your SSH keys or `~/.ssh/config`), then browse the remote folders and pick your project. Folders that are git repositories or already carry a `CLAUDE.md` are flagged, so a project is easy to spot.

From then on the Claude Code CLI **runs on that machine**: its shell, its edits, its searches all happen over there, and no file is copied back and forth. Two things to know:

- The `claude` CLI must be installed and signed in on the remote machine. MacCL checks before spending a turn and says so plainly if it isn't.
- The first connection to a machine shows its SSH host-key fingerprint and waits for you to confirm it. MacCL never trusts a key on its own — an agent running with permissions on someone else's server is not something to hand out on a guess.

Passwords are stored in the macOS Keychain, never in the preferences or the conversation files. Nothing extra to install: MacCL uses OpenSSH's own askpass mechanism, which ships with macOS.

> If the model is an Ollama running on *this* Mac, MacCL opens a reverse tunnel so the remote agent reaches it — because `localhost` means something else once the agent is elsewhere. If the tunnel can't be established, the session fails loudly rather than silently talking to a different Ollama.

**Coding instructions** — sidebar → *Manage instructions*: Markdown files you edit inside the app, ticked to be injected into the system prompt. A conversation can also get its own instructions when you create it. The project `CLAUDE.md` tab edits the file in the working folder — on the remote machine too, when that's where you're working.

**Permissions** — from fully autonomous (*all tools*) to plan-only (the agent thinks but never executes), chosen per conversation.

> Going further (context window size, keeping models in memory): the app's Settings explain the relevant Ollama server options, with values ready to copy.

## Under the hood

```
Sources/MacCL/
├── App/              SwiftUI entry point + Settings window
├── Models/           Protocol decoding, model catalog, settings, persistence
├── Engine/           ClaudeSession (drives the CLI), SSHClient, OllamaClient, discovery
├── ViewModels/       ChatViewModel (conversation orchestration)
└── Views/            Sidebar, chat, message rows, tool cards, Settings…
```

Conversations are plain JSON files in `~/Library/Application Support/MacCL/conversations/` — readable, backup-friendly, yours.

## License

[MIT](LICENSE). MacCL is an independent project by **Trano89**, not affiliated with Anthropic or Ollama. "Claude" and "Claude Code" are trademarks of Anthropic; this app drives the official CLI installed on your machine.
