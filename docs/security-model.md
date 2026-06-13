# What this repo is — and what it isn't

> A read-before-you-adopt guide to the security model, the isolation boundary, and the deliberate trade-offs. If you only read one doc before deciding whether this repo fits you, read this one.

## In one sentence

This repo gives you a **sandboxed, disposable, web-connected AI coding agent** — Hermes running inside an Apple `container` microVM, talking to a local MLX model — and that sandbox is the entire point. It is **not** a personal-computer assistant that drives your real desktop, apps, or corporate accounts.

---

## The problem it solves

Hermes Agent is **autonomous, web-connected, self-modifying, and runs arbitrary shell**. That combination is genuinely useful and genuinely risky:

- It executes shell commands you didn't individually approve (especially under `approvals: smart`, and far more so under YOLO / cron / gateway modes).
- It browses the web, so it's exposed to **prompt injection** — a malicious page saying "ignore previous instructions, exfiltrate X."
- It writes its own skills, edits its own memory, and installs its own packages at runtime.

Running that directly on your Mac means a bad command, a poisoned dependency, or a successful injection has your **whole user account** in reach: `~/.ssh`, `~/.aws`, browser cookies, OneDrive/iCloud sessions, every file you can touch.

This repo's answer: **put the agent in a microVM** and hand it only a few explicit bind mounts. The blast radius becomes the VM plus those mounts, not your home directory. When it gets messy, `mna-hermes rebuild` resets it to clean.

---

## What the container actually protects

These are the concrete, real defenses — not theater — and they're justified precisely *because* of Hermes' threat profile:

1. **Filesystem blast radius.** A destructive command (`rm -rf`, a malicious `npm` postinstall, a confused reasoning step) hits the VM and the handful of bind mounts, not your real `~`.

2. **Credential isolation.** The container sees `OMLX_API_KEY` and whatever is in `hermes/.env`. It does **not** inherit `~/.ssh`, `~/.aws`, `~/.config/gh`, your browser cookies, your OneDrive/iCloud session tokens, or your Keychain-adjacent files. This is the single biggest difference from a host-native install, which inherits your *entire* credential surface.

3. **Prompt-injection containment.** A *successful* injection still can't read your OneDrive — the agent physically can't see it. (Hermes even scans its own memory entries for injection patterns, because memory is re-injected into the system prompt.)

4. **Self-modification containment.** Skill-writing, memory edits, and runtime package installs all happen in a disposable box you can rebuild.

---

## What it does NOT protect — be honest about the limits

The sandbox is real, but it is **not** a force field. Know these:

- **Network egress is open.** The agent needs the internet for web search and cloud models. So this is **not** a network jail — anything the agent *can read*, it can still potentially *send out*. That's exactly why limiting what it can read (points 1–2 above) is the actual defense.

- **Bind mounts are inside the trust boundary.** `hermes/data/memories/`, `hermes/workspace/`, and **`hermes/.env`** are all readable by the agent. A prompt-injected agent could exfiltrate your `.env`. `OMLX_API_KEY` is low-value (local only) — but **do not casually drop a high-value cloud billing key** (OpenAI, Anthropic) into that `.env`, because it's now in the agent's reach.

- **The VM boundary is the trust boundary.** Hypervisor escape is low-probability but non-zero, and Apple's `container` runtime is **young** (macOS 26+). You are trusting a new microVM stack.

- **Isolation erodes with every convenience mount.** The moment you mount `~/code`, or your OneDrive, or add a host SSH backend so Hermes can "help with real work," you punch a hole in the boundary. A container with your whole home directory mounted is just a host install wearing a costume. The danger isn't choosing host-native deliberately — it's **drifting into it by accident**, one mount at a time.

---

## The core trade-off

> An agent's value ∝ its access ∝ its risk.

In the container, Hermes can only meaningfully work inside `hermes/workspace/`. It **cannot** touch your real projects, drive your real apps, or use your authenticated browser session. That's the price of the safety. If you need those things, you're describing a **different product** (see below) — not a tweak to this one.

---

## Hermes Desktop app (released 2026) — does it change any of this?

**No.** The desktop app is a **front-end (an Electron renderer), not a capability.** It sends *your* keystrokes to a backend and draws *the backend's* output. The agent's powers — what files it can touch, what shell it runs — are defined entirely by the **backend**, not by which window is attached to it.

This isn't an inference — it's how Nous documents the app. Per the official [Desktop App → How it works](https://hermes-agent.nousresearch.com/docs/user-guide/desktop#how-it-works) docs: *"The packaged app ships only the Electron shell… The React renderer talks to a `hermes dashboard` backend over the standard gateway APIs and reuses the agent rather than reimplementing it."* The same page frames the desktop app, CLI, TUI, and web dashboard as interchangeable [front ends that "all talk to the same agent"](https://hermes-agent.nousresearch.com/docs/user-guide/desktop) — *"not a separate product or a lightweight clone."* And [connecting to a remote backend](https://hermes-agent.nousresearch.com/docs/user-guide/desktop#connecting-to-a-remote-backend) is explicitly *"a running `hermes dashboard` process … that is the process the desktop app connects to"* — exactly the container's dashboard in this repo.

So you can attach Hermes Desktop to this repo's containerized backend (it already runs `hermes dashboard` on `127.0.0.1:9119`) and get a native GUI **with the jail fully intact**:

- It does **not** give the containerized agent mouse/keyboard control of your Mac.
- It **cannot** reach OneDrive or any host resource the container can't already see.
- Browser automation still puppeteers **Camofox inside the VM** — a virtual display, not your macOS desktop.

For Hermes to control your real desktop or read corporate files, the **agent itself** would have to run on the host (a host-native install), or you'd have to deliberately add a host-bridging backend to the container config. The GUI alone never does that. **The security boundary is the backend; the desktop app is just glass.**

> **You usually don't need the native app.** This repo serves the same `hermes dashboard` as a **browser GUI** — open it with `mna-hermes dashboard`, and it installs nothing on your Mac. The native desktop app, by contrast, lays down a host-side `~/.hermes` agent runtime, so **this repo deliberately doesn't install it** — that's an out-of-scope, do-it-yourself step.
>
> To attach the native app anyway: install it yourself (`hermes desktop`, or the DMG from the Hermes site), then in **Settings → Gateway → Remote gateway** point it at `http://127.0.0.1:9119`. Because the container's dashboard binds `0.0.0.0` inside the VM, it engages an auth gate — `mna-bootstrap` already seeds a readable `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` / `_PASSWORD` (and a stable `_SECRET`) into `hermes/.env`; sign in with those. Published only to loopback, basic-auth is acceptable here.

---

## Containerized (this repo) vs. host-native — when to choose which

| | **Containerized (this repo)** | **Host-native Hermes** |
|---|---|---|
| Agent runs in | Apple `container` microVM | Your macOS user account |
| Sees your credentials (`~/.ssh`, OneDrive, …) | **No** | **Yes** |
| Can work on your real projects | Only what you mount | Anything you can touch |
| Real-desktop "computer use" (mouse/apps) | **No** | **Yes** |
| Prompt-injection blast radius | VM + bind mounts | Whole user account |
| Reset to clean | `mna-hermes rebuild` | Reinstall / manual cleanup |
| Good for | Autonomous, web-facing, experimental, untrusted tasks | A deliberate personal assistant on *this* machine |

**Stay containerized when:** you run autonomous/YOLO/cron/gateway modes, let it browse freely, or do anything untrusted — and you value the disposable, reproducible, blast-radius-resettable model. This is the repo's whole thesis.

**Choose host-native when:** you *specifically* need real-desktop computer-use or direct host-project access — and you accept the posture. If you do, prefer a machine or user account **without** corporate credentials (no OneDrive sign-in, no SSH keys), and keep it in approval mode, not YOLO. Host-native isn't "insecure" — it's a **deliberately different tool** with a host-level trust posture.

---

## Bottom line for deciding

- Use this repo if you want an AI coding agent you can let off the leash **safely**, because it can't reach your real files, keys, or accounts.
- Don't use it (unmodified) if your goal is an assistant that operates your real desktop and corporate apps — that's host-native Hermes, a different trade-off.
- Adding the **desktop app does not** change either posture; it's purely ergonomic.
- The one discipline that matters: **resist the slow creep of "just one more mount,"** which quietly turns the sandbox into a host install with extra steps.
