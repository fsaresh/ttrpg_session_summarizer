# OBS Session Pipeline

End-to-end workflow for turning OBS-recorded TTRPG sessions into structured outlines that Claude can synthesize into campaign notes.

## Quick start with an AI assistant

If you'd rather not work through the rest of this README yourself, paste the prompt below into Claude Code (or any Claude session with shell + file access) from inside a fresh clone of this repo. It'll read the docs, install dependencies, choose models for your hardware, populate `names.txt`/`name_variants.txt` from your answers, and offer to customize the system prompts:

```
I just cloned this OBS Session Pipeline repo. Set it up on my machine without making me read the docs.

First, read README.md and CLAUDE.md so you understand the pipeline. Then walk me through setup one question at a time — wait for my answer before moving on. Cover, in order:

1. My OS, RAM, and whether I'm on Apple Silicon. This drives model choices.
2. Install or verify deps: ffmpeg, whisper-cpp, ollama, jq, perl. For anything missing, give me the exact install command for my OS.
3. WORKSPACE_DIR location — default is $HOME/Movies/OBS. Confirm or change.
4. mkdir -p the directory structure under $WORKSPACE_DIR (recordings/, audio/, transcripts/, summaries/, config/, scripts/).
5. Ask where I want whisper.cpp models stored (default: $HOME/source/external/whisper_models) and where Ollama models should live (default: ~/.ollama/models). For non-default Ollama, remind me to export OLLAMA_MODELS in my shell rc *before* starting `ollama serve`. Then download the whisper.cpp model and `ollama pull` the LLM that matches my RAM tier per the README's "Hardware sizing" table. Don't assume defaults — ask first.
6. Copy the templates: config/names.example.txt → names.txt and config/name_variants.example.txt → name_variants.txt. Then ask me for player characters, major NPCs, important locations, and deities/factions/recurring proper nouns. Replace the placeholder entries with what I tell you, under appropriate `# === Section ===` headers.
7. Ask if I've noticed any specific name mistranscriptions yet (whisper hearing "Perry" instead of "Peri", etc.); if so, add them to name_variants.txt. If not, leave the example rules in place as illustration.
8. Show me config/summary_prompt.example.txt and ask whether I want to customize it. Reasons to customize: different game system with different conventions, non-TTRPG use case (interview transcripts, podcast notes, etc.), different output section structure. If I want changes, copy to config/summary_prompt.txt and edit it per my answers. Then do the same for config/refine_prompt.example.txt.
9. Show me the .env.example file at the repo root and ask whether I want to copy it to .env and customize. .env holds model paths, model tags, context size, and decoder thresholds; values there override anything I `export`-ed in my shell. Most people skip this — only relevant if I'm not using the default models or if I want to tune the advanced section.
10. Run scripts/utils/setup_check.sh — that validates dependencies, paths, the Ollama service, the model file, and the glossary in one shot.
11. Tell me what to do for my first session: where to drop the .mp4 (or audio file), then ./run.sh. Mention that scripts/utils/status.sh shows which sessions have been processed.

Don't dump everything at once. One topic per question, and pause for my response. If a step needs a long-running command (model downloads, ollama pull), tell me the time estimate up front.
```

If you'd rather drive setup manually, keep reading — the sections below cover the same ground as a checklist.

## Pipeline at a glance

```
recordings/ (.mp4)
    │  extract_audio.sh          ffmpeg: drop video, downmix to 16 kHz mono PCM, trim trailing silence
    ▼
audio/ (.wav)
    │  transcribe_audio.sh        whisper.cpp: speech-to-text → SRT
    ▼
transcripts/ (.srt + .json)
    │  clean_transcript.sh       strip structure, dedupe loops, mark low-confidence tokens with [?]
    ▼
transcripts/ (.txt, alongside .srt and .json)
    │  summarize_session.sh       local LLM via Ollama: structured-outline extraction
    ▼
summaries/ (<session>--<model>.md)
    │  hand to Claude
    ▼
Synthesized session notes
```

After every session, the standard run is:

```bash
"$WORKSPACE_DIR/run.sh"
# or, equivalently:
"$WORKSPACE_DIR/scripts/pipeline/extract_audio.sh" && \
  "$WORKSPACE_DIR/scripts/pipeline/transcribe_audio.sh" && \
  "$WORKSPACE_DIR/scripts/pipeline/clean_transcript.sh" && \
  "$WORKSPACE_DIR/scripts/pipeline/summarize_session.sh"
```

Every stage is idempotent: if a stage's output for a given session already exists, that session is skipped. Drop a new `.mp4` into `recordings/`, run the chain, and only the new session moves through.

`WORKSPACE_DIR` is the base directory for the pipeline. The default is `$HOME/Movies/OBS` (set in `scripts/_lib.sh`). On a new machine, either accept that default, change it in `_lib.sh`, or `export WORKSPACE_DIR=/path/to/your/obs` in your shell before running anything. All four pipeline subdirectories (`recordings/`, `audio/`, `transcripts/`, `summaries/`) are derived from `WORKSPACE_DIR`.

## Directory layout

```
$WORKSPACE_DIR/
├── README.md                 ← this file
├── CLAUDE.md                 ← maintainer notes
├── run.sh                    ← standard per-session entry point (chains Stages 1–4)
├── .env.example              ← shipped environment defaults (paths, model choices, tunables)
├── .env                      ← gitignored; copy from .env.example to customize
├── recordings/               ← raw OBS captures (.mp4) — populate yourself (skip if starting from audio)
├── audio/                    ← extracted audio (.wav) — created by Stage 1, or populated yourself for audio-only runs
├── transcripts/              ← whisper output (.srt + .json) + cleaned plain text (.txt) — created by Stages 2-3
├── summaries/                ← Ollama-generated outlines (.md) — created by Stage 4
├── config/                   ← per-campaign data files and system prompts
│   ├── names.example.txt        ← shipped template for names.txt
│   ├── name_variants.example.txt ← shipped template for name_variants.txt
│   ├── summary_prompt.example.txt ← shipped Stage-4 system prompt (TTRPG-tuned)
│   ├── refine_prompt.example.txt  ← shipped refiner system prompt
│   ├── names.txt                ← canonical proper nouns (gitignored; copy from .example.txt to customize)
│   ├── name_variants.txt        ← variant→canonical rewrites (gitignored; copy from .example.txt to customize)
│   ├── summary_prompt.txt       ← (gitignored, optional override; scripts fall back to .example.txt if absent)
│   └── refine_prompt.txt        ← (gitignored, optional override; scripts fall back to .example.txt if absent)
└── scripts/
    ├── _lib.sh                  ← shared helpers (logging, duration formatting, names parsing, name-variant rewriter); sources the .env file
    ├── pipeline/                ← the four core stages — one stage per script, run in order by ../run.sh
    │   ├── extract_audio.sh        ← Stage 1: mp4 → wav
    │   ├── transcribe_audio.sh     ← Stage 2: wav → srt + json (whisper.cpp)
    │   ├── clean_transcript.sh     ← Stage 3: srt/json → txt (with [?] markers on low-confidence tokens)
    │   └── summarize_session.sh    ← Stage 4: txt → md (Ollama, with name-variant post-pass)
    └── utils/                   ← optional helpers — never invoked by ../run.sh
        ├── setup_check.sh          ← validate machine setup: tools, paths, Ollama service, model files, glossary
        ├── status.sh               ← per-session pipeline state table (which sessions are done, partial, or pending)
        ├── refine_summary.sh       ← optional second-pass LLM review: transcript + draft summary → improved outline (writes <session>--<model>--refined.md)
        ├── audit_summaries.sh      ← report canonical-name and leaked-variant counts per summary; surfaces gaps in name_variants.txt
        ├── lint_glossary.sh        ← validate names.txt and name_variants.txt for duplicates, malformed rules, unknown canonicals
        └── clear_session.sh        ← delete Stage 2-4 artifacts for a session (keeps the .mp4 and .wav); supports --list and --yes
```

**Configuration model:** `.env.example` at the repo root is a single bash-sourced file holding all paths and tunables (workspace location, model choices, thresholds). On first setup, copy it to `.env` and edit. If you don't create `.env`, `.env.example` is sourced as fallback. Values in `.env` are authoritative — they override any same-named env var in your shell. Edit `.env` to change settings rather than `export`-ing in your shell rc; config lives in one place.

## Names glossary

`config/names.txt` holds canonical spellings of campaign proper nouns (PCs, NPCs, locations, etc.). Both Stage 2 and Stage 4 use it to keep names consistent across runs:

- **`pipeline/transcribe_audio.sh`** passes the glossary to whisper.cpp via `--prompt` (with `--carry-initial-prompt` so the bias persists across all 30-second decode chunks). Whisper is much more likely to produce, e.g., *Aelthorin Brydhwell* (canonical) instead of *Althoran Bridewell* (a plausible-English mistranscription) when the canonical spelling is in the prompt.
- **`pipeline/summarize_session.sh`** prepends the names list to the LLM's user message with a directive to normalize any variant spellings it still encounters. This catches things whisper got wrong despite the prompt bias.

**File format:** one name per line. Blank lines and `#`-comment lines are ignored. Add freely as new characters and locations enter play — a fuller glossary is strictly better.

**Override path:** `NAMES_FILE=/path/to/other.txt ./pipeline/transcribe_audio.sh` (e.g., a per-group glossary).
**Disable entirely:** `NAMES_FILE=/dev/null ./pipeline/...`

### Variant -> canonical post-pass

`config/name_variants.txt` is a deterministic backstop applied by `pipeline/summarize_session.sh` after the LLM returns. Even with the glossary in the user message, the model sometimes echoes transcript variants verbatim — particularly when a wrong form is also a real English word (e.g. `Phoenix` when the canonical is `Phaenix`) and the model has a strong prior on the common-English spelling. The post-pass rewrites known mistranscriptions to their canonical form via word-boundary substitution.

**File format:** one rule per line, `<variant> -> <canonical>`. Matches are whole-word and case-insensitive by default. Prefix a variant with `!` to require a capitalized initial letter — use this for variants that double as common English words so ordinary prose isn't rewritten (e.g., `!Phoenix -> Phaenix` rewrites the name "Phoenix" but leaves the mythological-creature word "phoenix" alone). Lines starting with `#` and blank lines are ignored.

Add new rules as new mistranscriptions appear in summaries.

**Override path:** `VARIANTS_FILE=/path/to/other.txt ./pipeline/summarize_session.sh`
**Disable entirely:** `VARIANTS_FILE=/dev/null ./pipeline/summarize_session.sh`

## One-time setup (new machine)

```bash
# 1. Install dependencies (perl is already on macOS; listed for non-mac systems).
brew install ffmpeg whisper-cpp ollama jq
brew services start ollama
# Linux equivalents: apt/dnf install ffmpeg jq perl; build whisper.cpp from source;
# install Ollama from https://ollama.com/download.

# 2. Bootstrap the environment file. .env.example ships with safe defaults;
#    if you don't create .env, those defaults apply automatically. Copy and
#    edit only if you want to change paths, models, or tunables.
cp .env.example .env
$EDITOR .env   # set WORKSPACE_DIR if you want it somewhere other than $HOME/Movies/OBS

# 3. Create the directory structure under your chosen WORKSPACE_DIR.
#    (If you accepted the default, that's $HOME/Movies/OBS.)
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/Movies/OBS}"
mkdir -p "$WORKSPACE_DIR"/{recordings,audio,transcripts,summaries,config,scripts}
# Then place this repo's scripts/ and config/ contents (and the .env file)
# in $WORKSPACE_DIR/.

# 4. Whisper.cpp model (~3 GB; large-v3 for best fantasy-name accuracy).
#    The default lives at $HOME/source/external/whisper_models/. To relocate
#    (e.g. external drive), set WHISPER_MODELS_DIR in your shell rc and use
#    the same path in `mkdir -p` and `curl -o` below; also set it in
#    config/settings.conf so the pipeline finds the file.
WHISPER_MODELS_DIR="${WHISPER_MODELS_DIR:-$HOME/source/external/whisper_models}"
mkdir -p "$WHISPER_MODELS_DIR"
curl -L -o "$WHISPER_MODELS_DIR/ggml-large-v3.bin" \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin

# 5. Ollama summarization model (~20 GB; pulls once, takes a while).
#    Ollama stores models at ~/.ollama/models by default; to relocate (disk
#    constraints, external drive), `export OLLAMA_MODELS=/path/to/dir` in
#    your shell rc *before* starting `ollama serve`, then `brew services
#    restart ollama`. The daemon reads it once at boot.
ollama pull qwen2.5:32b-instruct-q4_K_M

# 6. Bootstrap the per-campaign data files from the shipped templates.
#    .example.txt files are tracked in git; the actual customizable copies
#    are gitignored so each user's data stays local.
#
#    Required (otherwise the pipeline runs with an empty glossary):
cp "$WORKSPACE_DIR/config/names.example.txt"         "$WORKSPACE_DIR/config/names.txt"
cp "$WORKSPACE_DIR/config/name_variants.example.txt" "$WORKSPACE_DIR/config/name_variants.txt"

#    Optional — only copy these if you want to customize:
#      summary_prompt.txt   override the Stage-4 system prompt (e.g. for non-TTRPG)
#      refine_prompt.txt    override the refine-pass system prompt
#    If the .txt isn't present, scripts use the shipped .example.txt file.
# cp "$WORKSPACE_DIR/config/summary_prompt.example.txt" "$WORKSPACE_DIR/config/summary_prompt.txt"
# cp "$WORKSPACE_DIR/config/refine_prompt.example.txt"  "$WORKSPACE_DIR/config/refine_prompt.txt"
#
# Pipeline-wide settings (model paths, model tags, thresholds, temperatures)
# live in .env at the repo root — see step 2.

# 7. Edit config/names.txt and config/name_variants.txt — replace the
#    placeholder entries with your campaign's real PCs/NPCs/locations and
#    any mistranscriptions you've observed. See "Customizing for your
#    campaign" below for the workflow.
$EDITOR "$WORKSPACE_DIR/config/names.txt"
$EDITOR "$WORKSPACE_DIR/config/name_variants.txt"

# 8. Run the full setup check: dependencies installed, paths resolved,
#    Ollama up, model pulled, data files valid.
"$WORKSPACE_DIR/scripts/utils/setup_check.sh"

# 9. Drop your first source file in and run the pipeline:
#      OBS / video capture path: place the .mp4 in $WORKSPACE_DIR/recordings/
#      audio-only path:           place the audio file in $WORKSPACE_DIR/audio/
#                                 (.wav / .m4a / .mp3 / .flac / .ogg / .aac)
"$WORKSPACE_DIR/run.sh"
```

## Starting from audio files (no video)

The pipeline also works if your source is already an audio file rather than an OBS-captured `.mp4` — useful for podcast-style recordings, Zoom/Discord exports, or any recorder that doesn't produce video.

Drop the audio file directly into `$WORKSPACE_DIR/audio/` (any of `.wav`, `.m4a`, `.mp3`, `.flac`, `.ogg`, `.aac`). Stage 1 (`pipeline/extract_audio.sh`) finds no `.mp4` in `recordings/` and exits cleanly as a no-op. Stage 2's whisper-cli accepts any of those formats directly, so the rest of the pipeline runs unchanged. `run.sh` is the same entry point for both cases.

If you prefer to skip Stage 1 entirely, run the remaining stages individually:

```bash
"$WORKSPACE_DIR/scripts/pipeline/transcribe_audio.sh" && \
  "$WORKSPACE_DIR/scripts/pipeline/clean_transcript.sh" && \
  "$WORKSPACE_DIR/scripts/pipeline/summarize_session.sh"
```

The session filename used throughout downstream artifacts (`<session-stem>.srt`, `--<model>.md`, etc.) is derived from the audio file's basename. Pick a stable, unique stem — the maintainer's pattern is `YYYY-MM-DD_HH-MM-SS`, but any naming convention works as long as it's consistent.

## Customizing for your campaign

`config/names.txt` and `config/name_variants.txt` are **campaign-specific data files** and are gitignored. Each user populates them from the shipped `.example.txt` templates (step 6 of one-time setup) and grows them as their campaign progresses.

`names.txt`:
- Format is documented in the file's header comment. Every non-blank, non-`#` line is a canonical name.
- The section comments (`# === Player Characters ===`, etc.) are conventional and human-helpful but not required by any script.
- Add names freely as the campaign reveals them. A fuller glossary biases whisper.cpp toward correct spellings on the first pass.

`name_variants.txt`:
- Format is documented in the file's header comment.
- Seed it with English-word ambiguities like `!Phoenix -> Phaenix` and grow it from observed mistranscriptions.
- After each session, run `scripts/utils/audit_summaries.sh` — anything reported under "LEAKED VARIANTS" is a candidate for a new rule.
- Run `scripts/utils/lint_glossary.sh` after edits to catch typos, duplicates, and rules pointing to canonicals that aren't in `names.txt`.

Other settings tuned to the maintainer's setup that you may want to revisit:
- `.env` at the repo root — model paths, Ollama model tag, context size, decoder thresholds, and other per-machine settings. Copy from `.env.example` and edit. See "Hardware sizing" for what to choose per RAM tier.
- `config/summary_prompt.txt` and `config/refine_prompt.txt` — system prompts for Stage 4 and the refine pass, currently tuned for TTRPG session outlines and a downstream Claude prose-synthesis pass. Copy from the shipped `.example.txt` and edit if your game system or output structure needs something different (e.g., different section headings, non-TTRPG use cases). Scripts fall back to the `.example.txt` if you haven't created the override.

## Hardware sizing

The shipped defaults (whisper `large-v3` + Ollama `qwen2.5:32b-instruct-q4_K_M` at `NUM_CTX=65536`) target ~32 GB unified-memory Apple Silicon. On smaller or non-Apple-Silicon machines, downsize:

| RAM (unified or system) | Whisper model | Ollama model | `NUM_CTX` | Notes |
|---|---|---|---|---|
| 8 GB | `ggml-medium.en.bin` (~1.5 GB) | `llama3.2:3b-instruct-q4_K_M` (~2 GB) | `16384` | Tight; close other apps. Name accuracy will suffer — `medium.en` is English-only and weak on fantasy names; populate `name_variants.txt` aggressively to compensate. |
| 16 GB | `ggml-large-v3-turbo-q5_0.bin` (~1.5 GB) | `qwen2.5:7b-instruct-q4_K_M` (~5 GB) | `32768` | Comfortable mid-tier. Good speed, decent name accuracy. |
| 24 GB | `ggml-large-v3-turbo-q5_0.bin` or `ggml-large-v3.bin` | `qwen2.5:14b-instruct-q4_K_M` (~9 GB) | `32768`–`65536` | Strong accuracy at reasonable speed. |
| 32 GB | `ggml-large-v3.bin` (~3 GB) | `qwen2.5:32b-instruct-q4_K_M` (~20 GB) | `65536` | **Shipped defaults.** |
| 48 GB+ | `ggml-large-v3.bin` | `llama3.3:70b-instruct-q4_K_M` (~40 GB) | `65536`+ | Highest local quality. Still tight at 48 GB unified — close everything else. |

To switch models, edit `.env` at the repo root — values there take precedence over shell exports, so the file is the single source of truth:

```ini
# In .env:
MODEL_PATH=$HOME/source/external/whisper_models/ggml-large-v3-turbo-q5_0.bin
MODEL=qwen2.5:14b-instruct-q4_K_M
NUM_CTX=32768
```

**Non-Apple-Silicon machines** lose Metal acceleration in `whisper-cli` — expect 0.5–1× realtime on a modern x86 CPU instead of 5–10× realtime on M-series. Smaller whisper models help proportionally; `large-v3-turbo-q5_0` is a good first pick on non-Mac hardware.

**No GPU at all** for Ollama: small models (3–7B) run at 5–15 tokens/sec on a modern CPU and summarize a 3-hour session in a few minutes. Don't run `qwen2.5:32b` CPU-only — it'll take tens of minutes per summary.

**Low disk**: whisper models are 1.5–3 GB each, Ollama models 2–40 GB each — you only need one of each. Audio files are ~115 MB/hour; transcripts and summaries are tiny.

---

## Stage 1 — `pipeline/extract_audio.sh`

Reads `recordings/*.mp4`, writes `audio/*.wav`. The source mp4 is opened read-only; only the destination wav is written.

**What it does**
- Drops the video stream entirely
- Downmixes to mono and resamples to 16 kHz, the native rate whisper would resample to internally anyway
- Encodes as 16-bit PCM (lossless at this sample rate, ~115 MB/hour)
- Trims **trailing silence only** using `areverse → silenceremove → areverse`. Mid-session pauses (dramatic beats, rule-checks) are preserved; only the dead-air after the session genuinely ended gets cut. This avoids Whisper hallucinating during silence.

**Tunable env vars**

| Var | Default | Purpose |
|---|---|---|
| `SILENCE_THRESHOLD` | `-40dB` | Anything quieter counts as silence. Bump to `-35dB` if low-volume background hum isn't getting trimmed; back off to `-45dB` if real speech is being cut. Avoid going louder than `-30dB`. |
| `SILENCE_DURATION` | `10` | Seconds of silence required before trimming kicks in. Higher = safer (preserves long natural pauses); lower = more aggressive trimming. |

---

## Stage 2 — `pipeline/transcribe_audio.sh`

Reads `audio/*.wav`, writes `transcripts/*.srt` (timestamped subtitle file) and `transcripts/*.json` (per-token output including a confidence value `p` per token) via whisper.cpp. Runs on Apple Silicon Metal automatically. The `.json` is consumed by Stage 3 to mark low-confidence tokens; the `.srt` remains the human-readable timestamp reference.

**Tunable env vars**

| Var | Default | Purpose |
|---|---|---|
| `MODEL_PATH` | `~/source/external/whisper_models/ggml-large-v3.bin` | Whisper.cpp GGML model file. See "Model choices" below. |
| `WORD_THRESHOLD` | `0.95` | Confidence required for the model to emit a timestamp boundary. Higher = longer SRT segments. `0.01` (default) fragments per micro-pause; `0.95` gives multi-sentence chunks; `0.99` very long. |
| `ENTROPY_THRESHOLD` | `3.0` | Threshold above which a decode is declared "failed" and triggers temperature fallback. Repetition loops are low-entropy, so a higher threshold catches more loops. Default whisper.cpp value is `2.40`. |
| `TEMPERATURE_INC` | `0.5` | Temperature increment on each fallback retry. Bigger jump = better chance of escaping a loop on the first retry. Default whisper.cpp value is `0.2`. |
| `THREADS` | `8` | CPU thread count. Metal handles the heavy work on Apple Silicon; this mostly affects pre/post stages. |
| `LANGUAGE` | `en` | Two-letter ISO 639-1 code passed to whisper-cli (`--language`). Set to `auto` for auto-detection (occasionally misfires on opening music/silence). |
| `NAMES_FILE` | `config/names.txt` | Glossary of canonical proper nouns; passed to whisper.cpp via `--prompt`. See "Names glossary" above. |

The script also passes `--suppress-nst` (suppress non-speech tokens) unconditionally — this kills off most repetition-loop hallucinations triggered by `[BLANK_AUDIO]` / `[MUSIC]` token attractors, with no downside for session-note synthesis.

Whisper.cpp models are downloaded from <https://huggingface.co/ggerganov/whisper.cpp>. See [Hardware sizing](#hardware-sizing) for which model fits your RAM.

---

## Stage 3 — `pipeline/clean_transcript.sh`

Reads `transcripts/*.srt` (and `transcripts/*.json` if present), writes `transcripts/*.txt`. Bash + awk + jq; no external deps beyond what's already required.

**What it does**
- When the `.json` is present (post-confidence-flag pipeline): walks each segment's tokens, drops special tokens (e.g. `[_BEG_]`), appends `[?]` to any token whose probability is below `CONFIDENCE_THRESHOLD`, and concatenates tokens to form one segment per line. This preserves whisper's per-token uncertainty as an in-band signal that the summarizer (and downstream Claude synthesis) can read.
- When the `.json` is absent (legacy sessions transcribed before `--output-json-full` was wired in): falls back to stripping `.srt` indices and timestamp lines.
- In both paths: trims whitespace, then applies sliding-window line-level dedupe to drop repetition-loop residue (`AB AB AB`).

**Tunable env vars**

| Var | Default | Purpose |
|---|---|---|
| `DEDUPE_WINDOW` | `8` | How far back to look for an exact line repeat. Bump to 16 if longer-cycle loops get through; lower to 4 if legitimate repetition is being eaten. |
| `CONFIDENCE_THRESHOLD` | `0.5` | Tokens with whisper probability `p` below this get a trailing `[?]` marker in the cleaned text. Lower to `0.3` for fewer markers; raise to `0.7` for stricter flagging. Only applies when the JSON file is present. |

---

## Stage 4 — `pipeline/summarize_session.sh`

Reads `transcripts/*.txt`, writes `summaries/<session>--<model>.md` via a local LLM served by Ollama. The output filename includes the sanitized model tag (e.g. `2026-04-21_19-51-46--qwen2.5-32b-instruct-q4_K_M.md`) so multiple models can summarize the same session without conflict — useful for A/B testing models against each other.

The script bakes in a TTRPG-tuned system prompt that produces a structured outline with these sections: **Session beats / NPCs encountered / Key decisions and outcomes / Lore, clues, and worldbuilding / Items, magic, abilities of note / Character moments / Open threads / Notable quotes**. The prompt forbids invention and requires preserving all proper nouns verbatim.

**A/B testing models:** override `MODEL` per run; each model produces its own file alongside the others.

```bash
./pipeline/summarize_session.sh                                              # default model
MODEL=llama3.3:70b-instruct-q4_K_M ./pipeline/summarize_session.sh           # second pass
```

**Tunable env vars**

| Var | Default | Purpose |
|---|---|---|
| `MODEL` | `qwen2.5:32b-instruct-q4_K_M` | Ollama model tag. See "Model choices" below. |
| `NUM_CTX` | `65536` | Total context window (input + output). Ollama's default 2048 would truncate any real session. Bump if you ever record sessions that don't fit. |
| `SUMMARIZE_TEMPERATURE` | `0.3` | Lower = more faithful extraction. Bump to 0.5 only if outlines feel mechanical. |
| `OLLAMA_URL` | `http://localhost:11434` | Where Ollama is listening. Change if you remote-host it. |
| `NAMES_FILE` | `config/names.txt` | Glossary of canonical proper nouns; injected into the LLM's user message so it normalizes variant spellings. See "Names glossary" above. |
| `VARIANTS_FILE` | `config/name_variants.txt` | Deterministic variant→canonical rewrite rules applied to the LLM's output as a post-pass. See "Variant → canonical post-pass" above. |

Ollama models are pulled with `ollama pull <tag>`. See [Hardware sizing](#hardware-sizing) for the recommended tag per RAM tier.

---

## Stage 5 — Claude synthesis

Drop a session's `summaries/<session>--<model>.md` into a Claude conversation with a directive like:

> *Synthesize this into session notes for my campaign. Match the tone/voice of existing arc summaries in this conversation. Respect the player-known vs. GM-only information split.*

Claude weaves the structured outline into in-voice campaign prose, applies the campaign's themes, and keeps GM-only material out of the player-facing recap. This is the only stage that costs API tokens — Stages 1–4 reduce a 50–100K-token raw transcript to a 1–3K-token outline before the synthesis pass.

---

## Maintenance

Ollama models live under `~/.ollama/models` (override with `OLLAMA_MODELS` exported before `ollama serve` boots); whisper models under `$WHISPER_MODELS_DIR` (default `~/source/external/whisper_models/`, set in `config/settings.conf`). Use `ollama list` / `ollama rm <tag>` to inspect or free disk; re-pull models with `ollama pull <tag>` and re-download whisper bins with `curl -L -o`. Restart Ollama after upgrades with `brew services restart ollama`.

---

## Reprocessing a session

### Reset Stages 2-4 — `utils/clear_session.sh`

For "redo transcription, cleaning, and summarization", use the helper:

```bash
./utils/clear_session.sh 2026-04-21_19-51-46     # specific session
./utils/clear_session.sh 2026-04-21              # all sessions on that date
./utils/clear_session.sh 2026-04-21 -y           # skip the confirmation prompt
./utils/clear_session.sh 2026-04-21 -l           # list matching files; do not delete
```

This deletes the `.srt`, `.json`, and `.txt` from `transcripts/`, plus any model-tagged `.md` files from `summaries/`. The original `.mp4` in `recordings/` and the extracted `.wav` in `audio/` are never touched — `.wav` extraction is slow and rarely needs to change. If you do want to rerun Stage 1 (e.g., you tweaked `SILENCE_THRESHOLD`), delete the `.wav` manually first.

The script requires the argument to start with a full `YYYY-MM-DD` date so a short or empty prefix can't accidentally wipe a wide swath of artifacts. Then re-run the pipeline chain to rebuild from scratch.

### Partial reset — manual `rm`

For redoing just one or two stages, delete only those outputs. Summary files are tagged with the model name (`<session>--<model>.md`), so a wildcard glob clears all model variants at once.

```bash
SESSION="2026-04-21_19-51-46"

# rerun summary only (clears all models' summaries for this session):
rm "summaries/${SESSION}--"*.md

# rerun cleaning + summary:
rm "transcripts/${SESSION}.txt" "summaries/${SESSION}--"*.md

# rerun transcribing + cleaning + summary:
rm "transcripts/${SESSION}".{srt,txt} "summaries/${SESSION}--"*.md
```

Then `./run.sh` (or invoke each `scripts/pipeline/*.sh` stage individually) and only the deleted artifacts get rebuilt.

---

## Troubleshooting

**Repetition loops in transcripts** ("the same line repeated 6 times"). The transcriber already passes `--suppress-nst` and aggressive entropy/temperature settings. Stage 3's dedupe catches most of what gets through. If you still see them, `pipeline/clean_transcript.sh` with `DEDUPE_WINDOW=16` will catch longer cycles.

**Trailing dead air not getting trimmed.** Bump `SILENCE_THRESHOLD` toward zero (`-35dB`, then `-30dB`). Don't go louder than `-30dB` — quiet speech starts getting cut.

**Whisper segments are too fragmented.** Bump `WORD_THRESHOLD` toward 1.0. `0.95` is the default; `0.99` for very long segments.

**Ollama can't reach the service.** `brew services start ollama`, then verify with `curl -s localhost:11434/api/tags`. If it's stuck, `brew services restart ollama`.

**Ollama errors with "model not found".** `ollama pull <model-tag>` (the tag is what's set in `MODEL`, e.g. `qwen2.5:32b-instruct-q4_K_M`).

**Out of memory during summarization.** Drop to a smaller model (`qwen2.5:14b-instruct-q4_K_M`) or lower `NUM_CTX` (e.g. 32768).
