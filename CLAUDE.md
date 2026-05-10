# CLAUDE.md — OBS Session Pipeline

Maintainer notes for the OBS recording → transcript → summary pipeline. The README is the source of truth for *running* the pipeline; this file is for an agent (you) modifying it.

## What this is

Four-stage Bash pipeline that converts OBS-recorded TTRPG sessions into structured outlines:

```
recordings/*.mp4 → audio/*.wav → transcripts/*.srt → transcripts/*.txt → summaries/*--<model>.md
                  pipeline/extract_audio   pipeline/transcribe_audio   pipeline/clean_transcript   pipeline/summarize_session
```

The four core pipeline stages live under `scripts/pipeline/`. Optional helpers (refiner, auditor, linter, session-clearer) live under `scripts/utils/`. `run.sh` at the workspace root chains the four pipeline stages in order; nothing in `utils/` is part of the standard run.

**Audio-only inputs are a supported path.** If the user has audio files (`.wav`, `.m4a`, `.mp3`, `.flac`, `.ogg`, `.aac`) but no `.mp4`, they place the audio directly in `audio/`. Stage 1 finds no `.mp4` and exits 0 cleanly with an informational log line; Stage 2's whisper-cli accepts any of those formats unchanged. Don't add code that errors out on a missing `recordings/` or empty Stage-1 output — that breaks this path. The README's "Starting from audio files (no video)" section is the operator-facing version.

The final `.md` outline is hand-carried to a Claude conversation in a campaign-specific Obsidian workspace for narrative synthesis with campaign-aware tone, character voices, and player-vs-GM information splits. **This pipeline produces neutral structured input for that synthesis pass — do not bake campaign voice or interpretation into stages 1–4.**

## Inviolable constraints

- **Never modify `recordings/*.mp4`.** The source recordings are irreplaceable. ffmpeg's `-i` is the only legitimate access path, and only as a read input.
- **Preserve idempotency.** Every pipeline stage skips if its output for a given input already exists. Running the chain repeatedly after each session must remain safe and cheap.
- **Don't break the model-tag suffix on summaries.** Filenames are `<session>--<sanitized-model>.md`. Multiple models can A/B test on the same session because of this; do not flatten back to `<session>.md`.

## Conventions

- **Logging**: use `log` / `logerr` from `_lib.sh` (sourced via the `BASH_SOURCE[0]` dance at the top of each pipeline script). Don't introduce raw `echo` / `echo … >&2` for user-facing output — they miss the timestamp prefix and are inconsistent with the rest of the pipeline.
- **`rm`**: use `command rm -f` to bypass the user's `rm -i` shell alias. Plain `rm` will hang waiting for confirmation that scripts can't deliver.
- **Atomic writes**: for outputs the script generates itself (cleaner, summarizer), write to `"$dst.tmp"` first and `mv` on success. For outputs from external tools that write the final file directly (ffmpeg, whisper-cli), `rm -f "$dst"` on failure to clean up partials so the next run retries.
- **Path resolution**: every pipeline subdirectory is derived from `WORKSPACE_DIR`, set in `_lib.sh` (default `$HOME/Movies/OBS`, override via `export WORKSPACE_DIR=...`). Scripts use `RECORDINGS_DIR="$WORKSPACE_DIR/recordings"`, `AUDIO_DIR`, `TRANSCRIPTS_DIR`, `SUMMARIES_DIR`. Per-campaign data files live in `$CONFIG_DIR` (default `$WORKSPACE_DIR/config`); scripts reference them as `$CONFIG_DIR/names.txt` and `$CONFIG_DIR/name_variants.txt`. Never reintroduce a hard-coded absolute path literal in a script — that breaks the new-machine and new-campaign setup paths documented in the README. The defaults live in `_lib.sh`; don't duplicate them elsewhere.
- **No Python dependencies.** Stay in Bash plus standard CLI tools (ffmpeg, whisper-cpp, awk, jq, curl, ollama). Whisperx-driven Python dep-hell is why this pipeline exists in its current shape; don't reintroduce it.
- **Wrapper functions over inline prefix patterns.** When adding cross-cutting behavior across many call sites (logging, timing, formatting), define a helper in `_lib.sh` rather than asking the caller to remember a prefix.

## Where documentation lives

Per-script doc comments were deliberately removed in favor of `README.md`. Don't reintroduce long comment blocks in scripts. Tunables get a single `# See README "..."` pointer; the README has the explanation. CLAUDE.md (this file) covers maintainer conventions; README.md covers operator instructions.

## Adding a new pipeline stage

Follow the existing pattern:

1. Source `_lib.sh` at the top — this also brings in `WORKSPACE_DIR`.
2. Define directory variables with descriptive names (e.g. `RECORDINGS_DIR`, `AUDIO_DIR`, `TRANSCRIPTS_DIR`, `SUMMARIES_DIR`) as `"$WORKSPACE_DIR/<lowercase-subdir>"` (never as a hard-coded literal). Reference shared data files via `$CONFIG_DIR/names.txt` and `$CONFIG_DIR/name_variants.txt`.
3. Expose tunables as `${VAR:-default}` env-var-overridable constants near the top.
4. Pre-flight: check required tools, check input dir exists, `mkdir -p` the output dir.
5. Glob input files (`shopt -s nullglob` … `shopt -u nullglob`). Under `set -u` on bash 3.2 (macOS default), do not blindly expand `"${arr[@]}"` for an array that may be empty after a no-match glob — guard with `[[ ${#arr[@]} -gt 0 ]]` or only reference the array inside a body that's known non-empty.
6. Track `script_start=$(date +%s)`. Per-file: `file_start=$(date +%s)` and append `($(fmt_duration ...))` to the success line.
7. Loop with skip-if-exists check before any expensive work.
8. End-of-run: `log "Done. ... (total $(fmt_duration $(($(date +%s) - script_start))))"`.
9. Update README.md with the new stage's section, tunables table, and any new pipeline-diagram entry.
10. Decide whether the new stage is core (one of the always-run pipeline stages) or optional. Place it in `scripts/pipeline/` or `scripts/utils/` accordingly. Sourcing pattern for both: `source "$SCRIPT_DIR/../_lib.sh"`. Reference shared data files via `$CONFIG_DIR/names.txt` (set in `_lib.sh`) so the script doesn't depend on its own location.
11. Update `utils/clear_session.sh` if the new stage produces files that should be cleared during a full reset, AND `run.sh` (at workspace root) if it should be part of the standard chain.

## Directory structure

```
$WORKSPACE_DIR/        README.md, CLAUDE.md, run.sh,
                       recordings/, audio/, transcripts/, summaries/,
                       config/, scripts/
recordings/            raw .mp4 (never modified)
audio/                 .wav (16 kHz mono PCM, ffmpeg output) — also accepts user-provided .wav/.m4a/.mp3/.flac/.ogg/.aac for audio-only mode
transcripts/           .srt + .json + .txt side by side (whisper.cpp emits .srt+.json; cleaner emits .txt)
summaries/             .md, model-tagged (Ollama). `--refined.md` suffix marks refiner output.
config/                names.txt + names.example.txt, name_variants.txt + name_variants.example.txt,
                       summary_prompt.txt + summary_prompt.example.txt,
                       refine_prompt.txt + refine_prompt.example.txt,
                       settings.conf + settings.example.conf
                       (the .txt/.conf actuals are gitignored; .example.* are tracked templates;
                        scripts fall back to .example.* when the actual is missing)
scripts/               _lib.sh
scripts/pipeline/      extract_audio.sh, transcribe_audio.sh, clean_transcript.sh, summarize_session.sh
scripts/utils/         refine_summary.sh, audit_summaries.sh, lint_glossary.sh, clear_session.sh
README.md              operator-facing pipeline docs
CLAUDE.md              this file
```

Don't add new directories without checking with the user — they previously rejected `Cleaned/` as "not descriptive" and asked for `.txt` to live alongside `.srt` in `transcripts/`.

## Names glossary

`config/names.txt` (canonical names, used by Stages 2 + 4) and `config/name_variants.txt` (variant→canonical rewrites, post-pass after Stage 4) share the same template/actual + helper-function pattern:

- Parsed in `_lib.sh` via `read_names()` (blanks + `#`-comments stripped, whitespace trimmed) and applied in `apply_name_variants()` (perl-based whole-word substitution with `!`-prefix opting into capitalized-only for English-word collisions like `!Phoenix -> Phaenix`).
- Overridable via `NAMES_FILE` / `VARIANTS_FILE`; missing files are graceful (empty glossary, passthrough rewrite) — don't add fail-on-missing checks.
- When adding a new stage that benefits from name awareness, reuse `read_names "$NAMES_FILE"` rather than introducing a parallel parser.

## Per-campaign / per-machine config files

Everything under `config/` follows the same template + actual pattern: `<name>.example.{txt,conf}` is tracked in git (the shipped default), `<name>.{txt,conf}` is gitignored (the user's customization). Five pairs in total: `names`, `name_variants`, `summary_prompt`, `refine_prompt`, `settings`. The first two are pure data; the prompt files are loaded by the summarizer/refiner with fallback to `.example.txt` when the actual is absent; `settings.conf` is sourced from `_lib.sh` if present.

**Don't propagate template-file edits to the actuals (or vice versa) without explicit user direction.** The `.example.*` is the maintainer's shipped default; the `.txt`/`.conf` is per-user data. They have different roles. The README's "Customizing for your campaign" section is the operator-facing version.

## Things to ask about, not assume

- New external dependencies (anything beyond what's already required: ffmpeg, whisper-cpp, ollama, jq, perl).
- New directories or restructuring.
- Changing the file-naming conventions in any output dir.
- Changing the prompt files at `config/summary_prompt.example.txt` or `config/refine_prompt.example.txt` — those are the shipped defaults tuned for the downstream Claude synthesis pass and shouldn't drift without intent. (Users override via the gitignored `summary_prompt.txt` / `refine_prompt.txt`; treat that as user-driven.)
- Editing `names.txt` or `name_variants.txt` content. They are user-owned per-campaign data; pre-population at creation was a one-time bootstrap. Treat subsequent edits as user-driven (a deliberate exception: when the user explicitly tells you to add a name or rule in conversation, that's user-driven — go ahead).
- Changing `WORKSPACE_DIR`'s default value in `_lib.sh` — that's the new-machine setup point. Pin it down in conversation before touching it.
