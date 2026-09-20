# Talk to Arturo, live, in the browser

A walkthrough for getting a **live voice conversation with Arturo** — the assistant
that fronts [OrchestraOS](https://github.com/Tulum-DAO/orchestraos) — working end to
end: the Gemini proxy/bridge on the server, the browser call, and the **"Ask Arturo"
badge** on every page turning into a live call **inside its own pane, with live
captions of what you say and what Arturo says**.

Everything here was read from the code on `Tulum-DAO/orchestraos` `main` at
`da1298c` (2026-09-20) with file paths and line numbers, so you can check it rather
than trust it. Where the default install is broken, the walkthrough says so, gives
the one-line workaround, and links the issue.

**Time:** ~30 min on top of a working `orchestra up`. **Cost:** a Gemini API key
(Google AI Studio; the Live API is what carries the audio — the free tier works for
trying it).

---

## 0. How the voice path actually works (read this once)

There are **two different "Gemini" things** in an OrchestraOS install, and people
conflate them:

| Piece | What it is | Port | Key |
|---|---|---|---|
| **Arturo brain / "Gemini proxy"** — `services/arturo/arturo-proxy.py` | The text-turn service every UI calls (`POST /text`). Picks a brain: your logged-in agent CLI (`claude` / `agy` / `codex`) with **no key**, or Gemini's OpenAI-compatible API when `GEMINI_API_KEY` is set. Also hosts the ElevenLabs/Hume push-to-talk routes. | `:5071` (`[arturo] port`) | optional |
| **Gemini Live bridge** — `services/arturo/gemini_live_bridge.py`, mounted at the gateway's `/live` | The **live voice call**: a bidirectional WebSocket to Google's Live API (`models/gemini-2.5-flash-native-audio-preview-09-2025`, voices Fenrir/Charon/Puck/Orus/Aoede/Kore). 16 kHz PCM up, 24 kHz PCM down, JSON transcript events. | on the gateway (`[gateway] port`) | **required:** `GEMINI_API_KEY` |

The browser never holds a key or the gateway bearer. The chain for a live call is:

```
browser  dashboard/src/lib/voiceSession.ts
   │  wss://<dashboard host>/api/voice/live?voice=Fenrir        (session cookie / JWT)
   ▼
Node API  api/src/routes/voice-live.ts   (adds "Authorization: Bearer <gateway token>")
   │  ws://127.0.0.1:<gateway port>/live
   ▼
gateway   scripts/watch_gateway.py::handle_gemini_live  (line 4740)
   │
   ▼
bridge    services/arturo/gemini_live_bridge.py::GeminiLiveSession
   │  wss://generativelanguage.googleapis.com/…BidiGenerateContent
   ▼
Google Gemini Live API
```

Two design facts that decide how "live transcription" has to be built:

1. **The server transcribes Arturo, not you.** `gemini_live_bridge.py` requests
   `output_audio_transcription` only and says why (line ~302: *"USER captions are
   intentionally NOT server-transcribed … the client renders the user's words live
   ON-DEVICE"*). So *your* captions come from the browser's `SpeechRecognition`
   (Chrome/Edge) — `VoiceSession.startDictation()` already does this and also sends
   each final phrase upstream as `{event:"user_turn"}`.
2. **The dashboard already has one working live-call button** — in the *agent
   composer* (`dashboard/src/components/agent/VoiceControls.tsx`, mounted by
   `Composer.tsx`). The **"Ask Arturo" pill is text-only** (`ArturoPill.tsx` imports a
   `Mic` icon but wires no voice) and the Arturo home's mic/voice-mode buttons are
   rendered `disabled` with no handler (`ArturoHome.tsx:371,375`). Section 4 fixes the
   pill by reusing the composer's path — no new server code.

---

## 1. Base install

Follow `docs/INSTALL.md` in the orchestraos repo. Condensed:

```bash
# one logged-in agent CLI first (claude / agy / codex), then:
git clone https://github.com/Tulum-DAO/orchestraos.git orchestraos && cd orchestraos
make install
./bin/orchestra init            # data dir (~/.orchestra), orchestra.toml, venv, npm, builds, gateway token
$EDITOR orchestra.toml          # [runtimes] enabled = ["claude"]  (whichever you logged in to)
./bin/orchestra doctor          # every row OK
./bin/orchestra up
open http://127.0.0.1:8891/     # Arturo is the main page
```

`orchestra init` writes the gateway bearer to `<data dir>/state/watch-gateway-token`
(`orchestra_cli/init_cmd.py:258`) and `orchestra up` exports `WATCH_GATEWAY_TOKEN_FILE`,
`WATCH_GATEWAY_URL`, `ORCHESTRA_DIR` etc. to every service (`orchestra_cli/settings.py`,
env block at ~line 195).

---

## 2. The Gemini proxy / brain (`:5071`) — get `/health` to say `voice`

`[arturo]` in `orchestra.toml`:

```toml
[arturo]
enabled = true
port = 5071
brain = "auto"      # api if GEMINI_API_KEY is set, else the first authed CLI, else none
```

Put the key in the environment `orchestra up` runs under (do **not** rely on a secrets
file — see §3.3):

```bash
export GEMINI_API_KEY=AIza...        # Google AI Studio → "Get API key"
./bin/orchestra down && ./bin/orchestra up
```

Verify by effect (loopback only — the service binds `127.0.0.1`):

```bash
curl -s 127.0.0.1:5071/health | python3 -m json.tool
```

You want:

```json
{ "status": "ok",
  "brain": { "kind": "api", "model": "..." },      # or kind:"runtime" if you kept the CLI brain
  "mode": "voice", "voice": true, ... }
```

`mode` is `voice` when any of `GEMINI_API_KEY` / `ELEVENLABS_API_KEY` /
`CARTESIA_API_KEY` / `HUME_API_KEY` is present (`docs/ARTURO.md`, "Text turn"). If it says
`text-only`, the key is not in the service's environment — `orchestra doctor` prints the
`arturo:brain` row it sees (`orchestra_cli/doctor.py:252-269`).

The same health is reachable through the API from the browser side:
`curl -s http://127.0.0.1:8891/api/arturo/health` (dashboard → API → gateway → `:5071`).

> You can keep `brain = "auto"` with **no** key for *text* and still add
> `GEMINI_API_KEY` only for the Live bridge — the bridge reads the key itself
> (`gemini_live_bridge.py:113`), independent of which brain answers text turns.

---

## 3. Three default-install mismatches you must configure around (as of `da1298c`)

Each one silently kills the browser call on a fresh install. Each has a one-line
workaround and a filed issue.

### 3.1 The voice WebSocket dials port 9091; the gateway listens on 8890 — [#84](https://github.com/Tulum-DAO/orchestraos/issues/84)

`api/src/routes/voice-live.ts:48`:
```ts
const GATEWAY_WS_URL = process.env.WATCH_GATEWAY_WS_URL || 'ws://127.0.0.1:9091';
```
`settings.py` exports `WATCH_GATEWAY_URL` (http) but never `WATCH_GATEWAY_WS_URL`, and
`orchestra.example.toml` sets `[gateway] port = 8890`. Symptom in the browser:
*"voice bridge upstream error: connect ECONNREFUSED 127.0.0.1:9091"*.

**Workaround (pick one):**
```toml
[gateway]
port = 9091          # make the default agree with the API's default
```
or run the API with `WATCH_GATEWAY_WS_URL=ws://127.0.0.1:8890` in its environment.

Check: `ss -ltnp | grep -E ':(8890|9091)\b'` — the gateway must be listening on the port the
API dials.

### 3.2 Transcript cards read a hard-coded token path — [#85](https://github.com/Tulum-DAO/orchestraos/issues/85)

`api/src/routes/voice.ts:13` reads `~/.config/jarvis/watch-gateway-token` and ignores
`WATCH_GATEWAY_TOKEN_FILE`, so `GET /api/voice/call?call_id=` (what the transcript card
fetches after a call) answers 503 → "transcript unavailable". The live call itself is
unaffected (`voice-live.ts` honours the env var).

**Workaround:**
```bash
mkdir -p ~/.config/jarvis && ln -sf ~/.orchestra/state/watch-gateway-token ~/.config/jarvis/watch-gateway-token
```
(use your `[data] dir` if you changed it).

### 3.3 The bridge pins `ORCHESTRA_DIR` to the checkout, not the data dir — [#86](https://github.com/Tulum-DAO/orchestraos/issues/86)

`gemini_live_bridge.py:15` — `ORCHESTRA_DIR = ARTURO_DIR.parent.parent`. Two effects:

- it looks for `GEMINI_API_KEY` in `<repo>/.env.secrets` first, then the environment —
  so **export the key in the environment** (§2) and you are fine;
- it writes each call's journal to `<repo>/state/voice-calls/<id>.json`, while the
  gateway serves transcripts from `<data dir>/state/voice-calls`
  (`watch_gateway.py:3614`). Without this the card is never found.

**Workaround:**
```bash
mkdir -p ~/.orchestra/state/voice-calls && mkdir -p <repo>/state && ln -sfn ~/.orchestra/state/voice-calls <repo>/state/voice-calls
```

### Quick checker

`scripts/check-voice-path.sh` in this repo runs all of the above as measurements
(ports, token file, key in the API's environment, health mode) and prints what is
wrong. Run it from the orchestraos checkout: `bash /path/to/check-voice-path.sh`.

---

## 4. Prove the existing call works before touching the badge

The agent composer's call button is the reference path — use it first so you know the
server side is right.

1. Open the dashboard **on `http://127.0.0.1:8891`** (localhost is a *secure context*, so
   `getUserMedia` and `SpeechRecognition` are allowed; over a LAN use
   `ssh -L 8891:127.0.0.1:8891 user@host`, or serve it under HTTPS). Use **Chrome or
   Edge** — `SpeechRecognition` is what captions your own voice, and Firefox/Safari do
   not ship it (`voiceSession.ts` reports this honestly rather than failing silently).
2. Open any agent's page. The composer shows a **Mic** (dictation into the textbox) and,
   while the textbox is empty, a **phone** button (`VoiceControls.tsx`: `showCallButton`).
3. Press the phone. Allow the microphone. You should hear Arturo's voice within a few
   seconds and see nothing else change yet — that is expected: the composer only routes
   *user* captions into the textbox and drops Arturo's transcript
   (`VoiceControls.tsx` `onPartial: … if (role === 'user')`).
4. Speak. With the Mic held/toggled at the same time, your words appear in the textbox
   live (interim) and commit (final).
5. Hang up (phone-off). The composer receives `[voice-call: vc_live_… <path>]`; sending
   it renders a **transcript card** that fetches the journal by id
   (`VoiceCallCard.tsx` → `GET /api/voice/call`). If it says "transcript unavailable", it
   is §3.2 or §3.3.

Server-side evidence while a call is up:

```bash
tail -f ~/.orchestra/logs/gateway.log        # supervisor writes <data>/logs/<service>.log
ls -la ~/.orchestra/state/voice-calls/       # vc_live_<id>.json appears (status: live → ended)
```

---

## 5. Make the "Ask Arturo" badge a live call in its own pane, with live captions

This is the change in [`patches/0001-pill-live-voice.patch`](patches/0001-pill-live-voice.patch),
also open as **PR [#83](https://github.com/Tulum-DAO/orchestraos/pull/83)**. It touches two
files and adds **no server code**:

- `dashboard/src/components/arturo/ArturoPill.tsx`
- `dashboard/src/components/arturo/arturo.css` (one rule)

### What it does

- Creates one `VoiceSession` (the same class the composer uses) inside the pill.
- **Call button** in the pill's control row (phone / phone-off), next to Send.
- Starts the call with the pill's page context — `{route, focusedEntity}` is the first
  JSON frame on the socket, the same contract the composer sends — so Arturo knows what
  you are looking at.
- **Immediately starts `startDictation()`** so your words are captioned on-device; each
  final phrase is also pushed upstream as `{event:"user_turn"}` (that code already lives
  in `VoiceSession`).
- Renders **two live rows** at the bottom of the thread while text is partial (yours on
  the right, Arturo's on the left, italic), and commits each final phrase as a normal
  turn — so the conversation reads like a chat transcript, live.
- On hang-up appends `Call ended (<id>). [voice-call: <id> <path>]` as a turn, so the
  card id is in the pane.
- Every unavailable path (no WebSocket, no mic permission, no `SpeechRecognition`, bridge
  error) renders an honest first-person reason as a row in the thread — never a silent
  no-op.

### Apply it

```bash
cd orchestraos
git fetch origin pull/83/head:pill-live-voice && git checkout pill-live-voice
#   or:  git apply /path/to/patches/0001-pill-live-voice.patch
cd dashboard
npx tsc -p tsconfig.app.json --noEmit     # must be clean (it was, at da1298c)
npm run guard                              # one-truth guard: ok
npm run build                              # writes dashboard/dist — the live served dashboard
```

Reload the dashboard. On **any page**, tap **Ask Arturo** → the pane opens → tap the
**phone**. Talk. Your words appear on the right as you speak, Arturo's on the left as
the server streams its transcript, and you hear the reply. Hang up with the phone-off.

### What was and was not verified

- Verified: TypeScript typecheck clean, `npm run guard` clean, tier-1/tier-2 host gates
  on the diff both 0 (no operator hostnames in the change).
- **Not yet verified with a real microphone** — the author's environment has no browser.
  The by-effect checklist for a reviewer is §4 steps 1–5 with the pill instead of the
  composer, plus: `ls ~/.orchestra/state/voice-calls/` shows a new `vc_live_*.json`
  during the call, and after hang-up the pane's last row carries its id.

### Known follow-ups (not in the patch)

- The pill's live turns are **in-pane only**; they are not written into the server-side
  thread (`/api/arturo/threads`). Persisting them means teaching `arturo-proxy.py`'s
  thread store about voice turns, or sending the `[voice-call:]` marker as a text turn
  the way the composer does.
- Voice selection is fixed to `Fenrir`; the bridge accepts `?voice=` (six voices) — a
  picker in the pill is a few lines.
- `SpeechRecognition` is `en-US` and Chrome/Edge only (`voiceSession.ts:startDictation`).

---

## 6. Troubleshooting, by symptom

| You see | It means | Do |
|---|---|---|
| pill/composer: *"voice isn't configured yet: this browser can't access the microphone"* | not a secure context, or permission denied | open on `127.0.0.1` / HTTPS; allow mic |
| *"voice bridge unavailable: watch-gateway bearer token missing at …"* | API can't read the token file | check `WATCH_GATEWAY_TOKEN_FILE` in the API's env; `orchestra init` again writes it |
| *"voice bridge upstream error: connect ECONNREFUSED 127.0.0.1:9091"* | §3.1 | `[gateway] port = 9091` or `WATCH_GATEWAY_WS_URL` |
| *"voice bridge upstream rejected the connection (HTTP 401)"* | token file content ≠ what the gateway loaded | restart gateway; both read the same file |
| call connects, silence, then closes; gateway log `GEMINI_API_KEY missing on server` | §2 / §3.3 | export the key in `orchestra up`'s environment, restart |
| you hear Arturo but no captions of *you* | `SpeechRecognition` absent (Firefox/Safari) or dictation not started | Chrome/Edge; the pill patch starts it for you |
| transcript card: *"transcript unavailable"* | §3.2 or §3.3 | symlinks above |
| `/health` says `"mode": "text-only"` | no vendor key in the service's env | §2 |

---

## 7. Where each fact came from

| Claim | File:line (orchestraos `da1298c`) |
|---|---|
| bridge model + voices | `services/arturo/gemini_live_bridge.py:37-50` |
| key lookup order (`.env.secrets` then env) | `gemini_live_bridge.py:113-119` |
| user captions not server-transcribed | `gemini_live_bridge.py:~302`, `dashboard/src/lib/voiceSession.ts:17-21` |
| gateway `/live` route + `?voice=` | `scripts/watch_gateway.py:4740, 4821` |
| API WS proxy, cookie/JWT auth, CSWSH guard | `api/src/routes/voice-live.ts` (tests: `voice-live.test.ts`) |
| WS URL default 9091 | `voice-live.ts:48`; gateway default port `orchestra.example.toml:12-15` |
| token path hard-coded | `api/src/routes/voice.ts:13` vs `orchestra_cli/init_cmd.py:258` |
| journals written under repo root | `gemini_live_bridge.py:15, 224-242` vs `watch_gateway.py:3614` |
| composer call button | `dashboard/src/components/agent/VoiceControls.tsx`, `Composer.tsx:81` |
| pill is text-only; home buttons disabled | `ArturoPill.tsx`, `ArturoHome.tsx:371,375` |
| `/health` mode semantics | `docs/ARTURO.md` "Text turn — the path every UI uses" |

License: Apache-2.0, same as OrchestraOS.
