# OBS Session Pipeline

End-to-end workflow for turning OBS-recorded TTRPG sessions into structured outlines that Claude can synthesize into campaign notes.

## Pipeline at a glance

```
Recordings/ (.mp4)
    │  audio_extracter.sh          ffmpeg: drop video, downmix to 16 kHz mono PCM, trim trailing silence
    ▼
Audio/ (.wav)
    │  audio_transcriber.sh        whisper.cpp: speech-to-text → SRT
    ▼
Transcripts/ (.srt + .json)
    │  transcript_cleaner.sh       strip structure, dedupe loops, mark low-confidence tokens with [?]
    ▼
Transcripts/ (.txt, alongside .srt and .json)
    │  session_summarizer.sh       local LLM via Ollama: structured-outline extraction
    ▼
Summaries/ (<session>--<model>.md)
    │  hand to Claude
    ▼
Synthesized session notes
```

After every session, the standard run is:

```bash
"$OBS_DIR/Scripts/run_all.sh"
# or, equivalently:
"$OBS_DIR/Scripts/audio_extracter.sh" && \
  "$OBS_DIR/Scripts/audio_transcriber.sh" && \
  "$OBS_DIR/Scripts/transcript_cleaner.sh" && \
  "$OBS_DIR/Scripts/session_summarizer.sh"
```

Every stage is idempotent: if a stage's output for a given session already exists, that session is skipped. Drop a new `.mp4` into `Recordings/`, run the chain, and only the new session moves through.

`OBS_DIR` is the base directory for the pipeline. The default is `$HOME/Movies/OBS` (set in `Scripts/_lib.sh`). On a new machine, either accept that default, change it in `_lib.sh`, or `export OBS_DIR=/path/to/your/obs` in your shell before running anything. All four pipeline subdirectories (`Recordings/`, `Audio/`, `Transcripts/`, `Summaries/`) are derived from `OBS_DIR`.

## Directory layout

```
$OBS_DIR/
├── README.md                 ← this file
├── CLAUDE.md                 ← maintainer notes
├── Recordings/               ← raw OBS captures (.mp4) — populate yourself
├── Audio/                    ← extracted audio (.wav) — created by Stage 1
├── Transcripts/              ← whisper output (.srt + .json) + cleaned plain text (.txt) — created by Stages 2-3
├── Summaries/                ← Ollama-generated outlines (.md) — created by Stage 4
└── Scripts/
    ├── _lib.sh                 ← shared helpers (logging, duration formatting, names parsing, name-variant rewriter, OBS_DIR default)
    ├── audio_extracter.sh      ← Stage 1: mp4 → wav
    ├── audio_transcriber.sh    ← Stage 2: wav → srt + json (whisper.cpp)
    ├── transcript_cleaner.sh   ← Stage 3: srt/json → txt (with [?] markers on low-confidence tokens)
    ├── session_summarizer.sh   ← Stage 4: txt → md (Ollama, with name-variant post-pass)
    ├── run_all.sh              ← chain Stages 1-4 in sequence
    ├── refine_summary.sh       ← optional second-pass review: feed transcript + draft summary to LLM, get improved outline (writes <session>--<model>--refined.md)
    ├── audit_summaries.sh      ← report canonical-name and leaked-variant counts per summary; surfaces gaps in name_variants.txt
    ├── lint_glossary.sh        ← validate names.txt and name_variants.txt for duplicates, malformed rules, unknown canonicals
    ├── clear_session.sh        ← delete derived artifacts for a session (keeps the .mp4); supports --list and --yes
    ├── names.txt               ← campaign-specific canonical proper nouns (see "Names glossary" below)
    └── name_variants.txt       ← campaign-specific variant→canonical rewrites for the summarizer post-pass
```

## Names glossary

`Scripts/names.txt` holds canonical spellings of campaign proper nouns (PCs, NPCs, locations, etc.). Both Stage 2 and Stage 4 use it to keep names consistent across runs:

- **`audio_transcriber.sh`** passes the glossary to whisper.cpp via `--prompt` (with `--carry-initial-prompt` so the bias persists across all 30-second decode chunks). Whisper is much more likely to produce *Vholara Pholaren* instead of *Valara Falarin* when the name is in the prompt.
- **`session_summarizer.sh`** prepends the names list to the LLM's user message with a directive to normalize any variant spellings it still encounters. This catches things whisper got wrong despite the prompt bias.

**File format:** one name per line. Blank lines and `#`-comment lines are ignored. Add freely as new characters and locations enter play — a fuller glossary is strictly better.

**Override path:** `NAMES_FILE=/path/to/other.txt ./audio_transcriber.sh` (e.g., a per-group glossary).
**Disable entirely:** `NAMES_FILE=/dev/null ./...`

### Variant -> canonical post-pass

`Scripts/name_variants.txt` is a deterministic backstop applied by `session_summarizer.sh` after the LLM returns. Even with the glossary in the user message, the model sometimes echoes transcript variants verbatim — particularly when a wrong form is also a real English word (`Perry`, `Serene`) and the model has a strong prior on it. The post-pass rewrites known mistranscriptions to their canonical form via word-boundary substitution.

**File format:** one rule per line, `<variant> -> <canonical>`. Matches are whole-word and case-insensitive by default. Prefix a variant with `!` to require a capitalized initial letter — use this for variants that double as common English words so ordinary prose isn't rewritten (e.g., `!Serene -> Sareen` rewrites the name "Serene" but leaves the adjective "serene" alone). Lines starting with `#` and blank lines are ignored.

Add new rules as new mistranscriptions appear in summaries.

**Override path:** `VARIANTS_FILE=/path/to/other.txt ./session_summarizer.sh`
**Disable entirely:** `VARIANTS_FILE=/dev/null ./session_summarizer.sh`

## One-time setup (new machine)

```bash
# 1. Install dependencies (perl is already on macOS; listed for non-mac systems).
brew install ffmpeg whisper-cpp ollama jq
brew services start ollama
# Linux equivalents: apt/dnf install ffmpeg jq perl; build whisper.cpp from source;
# install Ollama from https://ollama.com/download.

# 2. Choose where the pipeline lives. The default in Scripts/_lib.sh is
#    $HOME/Movies/OBS — accept that, change it there, or override per-shell:
export OBS_DIR=/path/to/your/OBS

# 3. Create the directory structure.
mkdir -p "$OBS_DIR"/{Recordings,Audio,Transcripts,Summaries,Scripts}
# Then place this repo's Scripts/ contents in $OBS_DIR/Scripts/.

# 4. Whisper.cpp model (~3 GB; large-v3 for best fantasy-name accuracy).
mkdir -p ~/source/external/whisper_models
curl -L -o ~/source/external/whisper_models/ggml-large-v3.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin

# 5. Ollama summarization model (~20 GB; pulls once, takes a while).
ollama pull qwen2.5:32b-instruct-q4_K_M

# 6. Populate Scripts/names.txt and Scripts/name_variants.txt with this
#    campaign's PCs/NPCs/locations and known mistranscriptions. See
#    "Customizing for your campaign" below.

# 7. Drop your first .mp4 into $OBS_DIR/Recordings/ and run:
"$OBS_DIR/Scripts/run_all.sh"
```

## Customizing for your campaign

`Scripts/names.txt` and `Scripts/name_variants.txt` are **campaign-specific data files**. The repo ships them populated for the maintainer's current campaign — when you fork this for your own campaign, replace their contents.

`names.txt`:
- The structure (PCs / NPCs / Locations / Cosmology section comments) is conventional, not enforced; the only required pattern is the `# === Player Characters ===` header (used by future per-PC tooling and lints). Section comments aside, every non-blank, non-`#` line is treated as a canonical name.
- Add names freely as the campaign reveals them. A fuller glossary biases whisper.cpp toward correct spellings on the first pass.

`name_variants.txt`:
- Start mostly empty (or with seed rules for English-word ambiguities like `!Serene -> Sareen`).
- After each session, run `Scripts/audit_summaries.sh` — anything reported under "LEAKED VARIANTS" is a candidate for a new rule.
- Run `Scripts/lint_glossary.sh` after edits to catch typos, duplicates, and rules pointing to canonicals that aren't in `names.txt`.

Other settings tuned to the maintainer's setup that you may want to revisit:
- `MODEL` and `MODEL_PATH` defaults in `audio_transcriber.sh` and `session_summarizer.sh` — change if you use different whisper / Ollama models.
- `Scripts/session_summarizer.sh` system prompt — currently tuned for Pathfinder 2E session outlines and a downstream Claude prose-synthesis pass. Other systems / pipelines will want different section structure.

## Hardware sizing

The shipped defaults (whisper `large-v3` + Ollama `qwen2.5:32b-instruct-q4_K_M` at `NUM_CTX=65536`) target ~32 GB unified-memory Apple Silicon. On smaller or non-Apple-Silicon machines, downsize:

| RAM (unified or system) | Whisper model | Ollama model | `NUM_CTX` | Notes |
|---|---|---|---|---|
| 8 GB | `ggml-medium.en.bin` (~1.5 GB) | `llama3.2:3b-instruct-q4_K_M` (~2 GB) | `16384` | Tight; close other apps. Name accuracy will suffer — `medium.en` is English-only and weak on fantasy names; populate `name_variants.txt` aggressively to compensate. |
| 16 GB | `ggml-large-v3-turbo-q5_0.bin` (~1.5 GB) | `qwen2.5:7b-instruct-q4_K_M` (~5 GB) | `32768` | Comfortable mid-tier. Good speed, decent name accuracy. |
| 24 GB | `ggml-large-v3-turbo-q5_0.bin` or `ggml-large-v3.bin` | `qwen2.5:14b-instruct-q4_K_M` (~9 GB) | `32768`–`65536` | Strong accuracy at reasonable speed. |
| 32 GB | `ggml-large-v3.bin` (~3 GB) | `qwen2.5:32b-instruct-q4_K_M` (~20 GB) | `65536` | **Shipped defaults.** |
| 48 GB+ | `ggml-large-v3.bin` | `llama3.3:70b-instruct-q4_K_M` (~40 GB) | `65536`+ | Highest local quality. Still tight at 48 GB unified — close everything else. |

Override per-run instead of editing the scripts:
```bash
MODEL_PATH="$HOME/source/external/whisper_models/ggml-large-v3-turbo-q5_0.bin" \
MODEL=qwen2.5:14b-instruct-q4_K_M \
NUM_CTX=32768 \
"$OBS_DIR/Scripts/run_all.sh"
```

**Non-Apple-Silicon machines** lose Metal acceleration in `whisper-cli` — expect 0.5–1× realtime on a modern x86 CPU instead of 5–10× realtime on M-series. Smaller whisper models help proportionally; `large-v3-turbo-q5_0` is a good first pick on non-Mac hardware.

**No GPU at all** for Ollama: small models (3–7B) run at 5–15 tokens/sec on a modern CPU and summarize a 3-hour session in a few minutes. Don't run `qwen2.5:32b` CPU-only — it'll take tens of minutes per summary.

**Low disk**: whisper models are 1.5–3 GB each, Ollama models 2–40 GB each — you only need one of each. Audio files are ~115 MB/hour; transcripts and summaries are tiny.

To verify everything's wired up:

```bash
ffmpeg -version | head -1
whisper-cli --help >/dev/null && echo whisper ok
curl -s localhost:11434/api/tags | jq '.models[].name'
```

---

## Stage 1 — `audio_extracter.sh`

Reads `Recordings/*.mp4`, writes `Audio/*.wav`. The source mp4 is opened read-only; only the destination wav is written.

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

## Stage 2 — `audio_transcriber.sh`

Reads `Audio/*.wav`, writes `Transcripts/*.srt` (timestamped subtitle file) and `Transcripts/*.json` (per-token output including a confidence value `p` per token) via whisper.cpp. Runs on Apple Silicon Metal automatically. The `.json` is consumed by Stage 3 to mark low-confidence tokens; the `.srt` remains the human-readable timestamp reference.

**Tunable env vars**

| Var | Default | Purpose |
|---|---|---|
| `MODEL_PATH` | `~/source/external/whisper_models/ggml-large-v3.bin` | Whisper.cpp GGML model file. See "Model choices" below. |
| `WORD_THRESHOLD` | `0.95` | Confidence required for the model to emit a timestamp boundary. Higher = longer SRT segments. `0.01` (default) fragments per micro-pause; `0.95` gives multi-sentence chunks; `0.99` very long. |
| `ENTROPY_THRESHOLD` | `3.0` | Threshold above which a decode is declared "failed" and triggers temperature fallback. Repetition loops are low-entropy, so a higher threshold catches more loops. Default whisper.cpp value is `2.40`. |
| `TEMPERATURE_INC` | `0.5` | Temperature increment on each fallback retry. Bigger jump = better chance of escaping a loop on the first retry. Default whisper.cpp value is `0.2`. |
| `THREADS` | `8` | CPU thread count. Metal handles the heavy work on Apple Silicon; this mostly affects pre/post stages. |
| `NAMES_FILE` | `Scripts/names.txt` | Glossary of canonical proper nouns; passed to whisper.cpp via `--prompt`. See "Names glossary" above. |

The script also passes `--suppress-nst` (suppress non-speech tokens) unconditionally — this kills off most repetition-loop hallucinations triggered by `[BLANK_AUDIO]` / `[MUSIC]` token attractors, with no downside for session-note synthesis.

**Model choices** (download from https://huggingface.co/ggerganov/whisper.cpp)

| File | Size | Notes |
|---|---|---|
| `ggml-large-v3.bin` | ~3 GB | **Default.** Best accuracy on fantasy names. |
| `ggml-large-v3-turbo-q5_0.bin` | ~1.5 GB | ~5× faster, near-large-v3 quality. Good if speed matters. |
| `ggml-medium.en.bin` | ~1.5 GB | English-only, faster, weaker on names. |

---

## Stage 3 — `transcript_cleaner.sh`

Reads `Transcripts/*.srt` (and `Transcripts/*.json` if present), writes `Transcripts/*.txt`. Bash + awk + jq; no external deps beyond what's already required.

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

## Stage 4 — `session_summarizer.sh`

Reads `Transcripts/*.txt`, writes `Summaries/<session>--<model>.md` via a local LLM served by Ollama. The output filename includes the sanitized model tag (e.g. `2026-04-21_19-51-46--qwen2.5-32b-instruct-q4_K_M.md`) so multiple models can summarize the same session without conflict — useful for A/B testing models against each other.

The script bakes in a TTRPG-tuned system prompt that produces a structured outline with these sections: **Session beats / NPCs encountered / Key decisions and outcomes / Lore, clues, and worldbuilding / Items, magic, abilities of note / Character moments / Open threads / Notable quotes**. The prompt forbids invention and requires preserving all proper nouns verbatim.

**A/B testing models:** override `MODEL` per run; each model produces its own file alongside the others.

```bash
./session_summarizer.sh                                              # default model
MODEL=llama3.3:70b-instruct-q4_K_M ./session_summarizer.sh           # second pass
```

**Tunable env vars**

| Var | Default | Purpose |
|---|---|---|
| `MODEL` | `qwen2.5:32b-instruct-q4_K_M` | Ollama model tag. See "Model choices" below. |
| `NUM_CTX` | `65536` | Total context window (input + output). Ollama's default 2048 would truncate any real session. Bump if you ever record sessions that don't fit. |
| `TEMPERATURE` | `0.3` | Lower = more faithful extraction. Bump to 0.5 only if outlines feel mechanical. |
| `OLLAMA_URL` | `http://localhost:11434` | Where Ollama is listening. Change if you remote-host it. |
| `NAMES_FILE` | `Scripts/names.txt` | Glossary of canonical proper nouns; injected into the LLM's user message so it normalizes variant spellings. See "Names glossary" above. |
| `VARIANTS_FILE` | `Scripts/name_variants.txt` | Deterministic variant→canonical rewrite rules applied to the LLM's output as a post-pass. See "Variant → canonical post-pass" above. |

**Model choices** (after `ollama pull <name>`)

| Tag | Size | Notes |
|---|---|---|
| `qwen2.5:32b-instruct-q4_K_M` | ~20 GB | **Default.** Strong structured extraction, 128K context. |
| `qwen2.5:14b-instruct-q4_K_M` | ~9 GB | Faster, slightly weaker on names. Recommended for 24 GB machines. |
| `qwen2.5:7b-instruct-q4_K_M` | ~5 GB | Faster still; usable summary quality with a populated `name_variants.txt`. Recommended for 16 GB machines. |
| `llama3.3:70b-instruct-q4_K_M` | ~40 GB | Highest raw quality, RAM-tight on 48 GB unified memory. |
| `llama3.2:3b-instruct-q4_K_M` | ~2 GB | Fast, quality drops noticeably on fantasy names. Last-resort tier for 8 GB machines. |

**Switching models per run**: `MODEL=qwen2.5:14b-instruct-q4_K_M ./session_summarizer.sh`

---

## Tier 3 — Claude synthesis

Drop a session's `Summaries/<session>.md` into a Claude conversation with a directive like:

> *Synthesize this into Nature-party session notes for the Dalelands campaign. Match the tone/voice of existing arc summaries. Respect the player-known vs. GM-only split per the project CLAUDE.md.*

Claude weaves the structured outline into in-voice campaign prose, applies the campaign's themes, and keeps GM-only material out of the player-facing recap. This is the only stage that costs API tokens — Tiers 1 and 2 reduce a 50–100K-token raw transcript to a 1–3K-token outline before the synthesis pass.

---

## Maintenance

| Task | Command |
|---|---|
| Update Homebrew tools | `brew upgrade ffmpeg whisper-cpp ollama jq` |
| Restart Ollama after upgrade | `brew services restart ollama` |
| List installed Ollama models | `ollama list` |
| Refresh / re-pull a model | `ollama pull qwen2.5:32b-instruct-q4_K_M` |
| Remove a model (free disk) | `ollama rm <model>` |
| Update whisper.cpp model | re-download with `curl -L -o ...` |

Ollama models live under `~/.ollama/models`; whisper models live under `~/source/external/whisper_models/`.

---

## Reprocessing a session

### Full reset — `clear_session.sh`

For "redo everything except the original recording", use the helper:

```bash
./clear_session.sh 2026-04-21_19-51-46     # specific session
./clear_session.sh 2026-04-21              # all sessions on that date
./clear_session.sh 2026-04-21 -y           # skip the confirmation prompt
```

This deletes the matching `.wav` from `Audio/`, the `.srt` and `.txt` from `Transcripts/`, and any model-tagged `.md` files from `Summaries/`. The original `.mp4` in `Recordings/` is never touched. The script requires the argument to start with a full `YYYY-MM-DD` date so a short or empty prefix can't accidentally wipe a wide swath of artifacts. Then re-run the pipeline chain to rebuild from scratch.

### Partial reset — manual `rm`

For redoing just one or two stages, delete only those outputs. Summary files are tagged with the model name (`<session>--<model>.md`), so a wildcard glob clears all model variants at once.

```bash
SESSION="2026-04-21_19-51-46"

# rerun summary only (clears all models' summaries for this session):
rm "Summaries/${SESSION}--"*.md

# rerun cleaning + summary:
rm "Transcripts/${SESSION}.txt" "Summaries/${SESSION}--"*.md

# rerun transcribing + cleaning + summary:
rm "Transcripts/${SESSION}".{srt,txt} "Summaries/${SESSION}--"*.md
```

Then `cd Scripts && ./audio_extracter.sh && ./audio_transcriber.sh && ./transcript_cleaner.sh && ./session_summarizer.sh` from `OBS/Scripts/` and only the deleted artifacts get rebuilt.

---

## Troubleshooting

**Repetition loops in transcripts** ("the same line repeated 6 times"). The transcriber already passes `--suppress-nst` and aggressive entropy/temperature settings. Stage 3's dedupe catches most of what gets through. If you still see them, `transcript_cleaner.sh` with `DEDUPE_WINDOW=16` will catch longer cycles.

**Trailing dead air not getting trimmed.** Bump `SILENCE_THRESHOLD` toward zero (`-35dB`, then `-30dB`). Don't go louder than `-30dB` — quiet speech starts getting cut.

**Whisper segments are too fragmented.** Bump `WORD_THRESHOLD` toward 1.0. `0.95` is the default; `0.99` for very long segments.

**Ollama can't reach the service.** `brew services start ollama`, then verify with `curl -s localhost:11434/api/tags`. If it's stuck, `brew services restart ollama`.

**Ollama errors with "model not found".** `ollama pull <model-tag>` (the tag is what's set in `MODEL`, e.g. `qwen2.5:32b-instruct-q4_K_M`).

**Out of memory during summarization.** Drop to a smaller model (`qwen2.5:14b-instruct-q4_K_M`) or lower `NUM_CTX` (e.g. 32768).
