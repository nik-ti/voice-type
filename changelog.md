# Changelog

Notable VoiceType changes, newest first. Earlier history is summarized from the git log.

## 2026-11-17 — Polished mode: model decides, not rules; upgrade to Qwen3 8B
- Changed: Polished mode sends the raw recognized speech to the model with instructions and worked examples. The model now owns grammar, numbers, lists and paragraphs. Removed the regex list detector, spoken-correction and grammar pre-passes, paragraph splitter, filename rules and the 14-check validator that threw away good model edits (the cause of "the 1st part"). Regular mode is unchanged, and Polished falls back to it.
- Changed: switched the model from Qwen3 4B Instruct to Qwen3 8B after a 40-case comparison (4B, 8B, Gemma 3 12B). The fixed instructions are cached between takes, so 8B averages about 0.95 s per take. The waiting limit now grows with length (3 s + 50 ms/word, max 12 s) instead of a flat 4 s.
- Verified: comparison on this Mac (M5, 24 GB): old pipeline 22/34; new 8B 39/40 (mean 0.95 s, max 4.2 s); details in `docs/DICTATION_QUALITY.md`. Full suite with model opt-ins passed; memory test growth 36 MB with an empty buffer cache.
- Remaining: casual "Me and Sarah were" is kept rather than rewritten. Live microphone use not yet re-checked after install. The first Polished take after the update waits for a 4.6 GB model download. The old 4B model (2.1 GB) is still cached in `~/Library/Caches/models` for rollback.

## 2026-11-16 — Fix the multi-day slowdown (GPU memory buildup)
- Changed: the polish model's GPU buffer cache is now capped at 128 MB and emptied after every take. Before, MLX kept every freed scratch buffer "for reuse" with no practical limit. After 7 days the app held 17 GB of GPU memory on a 24 GB Mac, which pushed the system into 17 GB of swap and slowed every stage, including polishing past its 4-second budget into the rules fallback.
- Changed: each polish logs `polish_gpu_memory active_mb=… cache_mb=…` (no dictated text) so any future buildup shows up in the logs.
- Verified: new `PolishMemoryTests` (real Qwen3 4B, 20 takes of varied length). Before the fix the cache grew from 712 MB to 4,078 MB (+3.4 GB). After it, growth was 0 MB, with the 20 takes slightly faster (28.7 s vs 30.9 s). Full suite with model opt-ins passed (61 core, 18 integration, 3 opt-in skips), plus the packaging test. Installed build `20261117T004222Z`; fresh footprint 2.2 GB.
- Remaining: multi-day behavior can only be confirmed by real use. Check with `footprint $(pgrep -f VoiceType.app/Contents/MacOS)`; it should stay near 2–3 GB.
- Next: Polished cleanup still relies on regex list and grammar passes that override the model (see the 2026-11-16 research notes in the session). A redesign is pending the user's decisions.

## 2026-11-03 — Lists and recognition language
- Alternate spoken list introductions format correctly. Added an Auto/English/Russian recognition-language preference.

## 2026-10-28 — Polished quality update
- Switched the editor to Qwen3 4B Instruct, a rebuilt Parakeet encoder, fact/boundary validation, filename and quotation handling, duration repair, and spoken-list formatting. Details in `docs/DICTATION_QUALITY.md`.

## 2026-10-06 — Reliability repair
- Session-owned recording, deadline-bounded polishing, guarded paste, stage timing logs, start-cue lag fix, transactional install to `/Applications`. Removed the old 5-minute model keepalive timer.

## 2026-02-10 — Post-inactivity slowdown attempt
- Added a keepalive timer to stop macOS paging the model out after idle. It treated the symptom; the real cause was the uncapped GPU cache fixed on 2026-11-16.

## 2026-02-04 — Initial app
- Menu-bar dictation with Fn hotkey, Parakeet recognition, Regular and Polished modes, auto-paste.
