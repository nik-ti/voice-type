# VoiceType reliability and dictation quality

VoiceType is a local macOS dictation app. This repair addresses the October 4 audit while preserving existing uncommitted work and the English/Russian workflows.

## Contract
GOAL: Deliver one complete transcript per accepted recording; keep optional polishing within a waiting limit (3 seconds plus 50 ms per dictated word, at most 12 seconds) even when inference is slow. The app must stay as fast after days of running as after launch. Measure each post-recording stage so regressions can be diagnosed.

November 17 Polished goal: the local model, not hard-coded rules, decides grammar, numbers, lists and paragraphs, the way competing apps (VoiceInk, Wispr Flow) do. Regular mode stays rule-based. The user prefers balanced accuracy and speed and accepts a few seconds for long dictation. Copy finished prose with one trailing space.

CONSTRAINTS:
- Free, on-device inference; existing Swift, FluidAudio and MLX dependencies.
- Keep Regular and Polished modes, history, input selection, and hotkeys.
- The user authorized all audit fixes; no further approval needed for implementation.
- Every build must end up installed at `/Applications/VoiceType.app` (via `./package_app.sh`); never leave the app only in the project folder.

FORMAT:
- Updated source, regression tests, documentation, and a verified local VoiceType.app.
- Privacy-safe timing logs with build identity; no dictated text in application diagnostics.

FAILURE:
- Releasing the hotkey during startup leaves recording active.
- A second session overlaps processing or a stale result is pasted.
- Audio recovery duplicates samples, mixes sample rates, or discards the first spoken syllable after ready.
- Optional polishing waits for non-cooperative work beyond its deadline, or another inference overlaps unfinished GPU work.
- GPU memory keeps growing across takes, so the app gets slower the longer it runs (20 varied polishes must return to the starting memory).
- Saving history fails and prevents delivery, or every take reloads all history before pasting.
- Cleanup turns Russian digits into English words, changes legitimate "ill", damages "uh-huh", or removes grammatical "had had".
- Polished drops the opening instruction, keeps a retracted budget/date, changes an amount in an intentional contrast, or leaves the supplied grammar fixture broken.
- Polished writes prose ordinals and small counts as digits ("the 1st part", "2nd option"), or writes amounts, times, dates and percentages as words.
- Polished answers, obeys or replies to dictated questions and instructions instead of typing them.
- Polished translates Russian into English, or drops words that carry meaning or tone ("maybe", "I think", "by the way").
- The shipped Polished model passes fewer than all but two of the cleanup comparison cases.
- Model/rules results are mislabeled, fallback has no reason, or stronger-model speed is claimed without running it on this Mac.
- Regular-mode normalization turns an unambiguous duration such as "ten second video" into an ordinal such as "12th video", or a duration fix damages a genuine ordinal.
- Clear spoken enumeration ("number one… number two…", "first… second… third…") stays a prose block or loses an item; an ordinary sentence ("my number one priority", "first I went to the store and then…") becomes a list.
- An optional recognition language choice is lost on restart, does not reach the recognizer, changes an already-started take, or changes Auto's existing multilingual behavior.
- Failed permission/focus checks still post paste keys; logs falsely claim insertion was verified.
- The start/stop cues are suppressed merely because Bluetooth is the output, or the waveform stays behind the app receiving dictation.
- Per-take changes to the macOS default input race Core Audio teardown and can crash the process.
- Packaging silently reuses an old executable or replaces the working app after a failed build.
- A successful build is not installed in `/Applications`, or an old copy keeps running after install.
- MANUAL: real microphone, Bluetooth, app focus, and idle/sleep latency require a live desktop session; record verification limits explicitly.

## Built on top of
- Existing pinned FluidAudio 0.15.7 (Apache-2.0): local ASR and audio conversion. Avoid a dependency upgrade during repair.
- Existing pinned MLX Swift / MLX Swift LM (MIT): inference; use generateTask and await GPU completion for cleanup.
- Qwen3 8B 4-bit (Apache-2.0): local Polished model selected on 2026-11-17 over Qwen3 4B Instruct 2507 and Gemma 3 12B on the same cleanup cases; no dependency upgrades. Existing FluidAudio `.int8V2` selects a rebuilt Parakeet v3 encoder without changing the recognizer architecture.
- Swift concurrency and Apple ProcessInfo: separate deadline delivery from worker lifetime; scope user-initiated activity to active work.
- Research: https://github.com/ml-explore/mlx-swift-lm/blob/main/skills/mlx-swift-lm/references/generation.md
- Research: https://forums.swift.org/t/does-taskgroup-cancelall-require-active-co-operation-to-finish-properly/75057
- Research: https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/PrioritizeWorkAtTheAppLevel.html
- Research: https://developer.apple.com/documentation/appkit/nswindow/orderfrontregardless%28%29
- Research: https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct

## Decisions
- Reject overlapping starts instead of losing an earlier dictation. Early stop cancels startup and waits for microphone cleanup before another start.
- A microphone route change ends the current take and transcribes captured audio at its original rate; the next take uses the new device.
- Remove the full-recording VAD pass: it only trimmed leading silence and added a sequential inference pass; retain full audio to protect quiet words.
- Warm the polish model after load and at recording start when idle, never using a permanent keepalive timer. Busy/late models fall back to deterministic cleanup.
- Paste/copy before saving history; keep full history compatibility but insert new entries in memory instead of refetching.
- Check accessibility, target focus and clipboard ownership before one paste event. System event posting cannot prove insertion in arbitrary applications.
- Show the waveform immediately in a non-activating, cross-space panel and play cues on every accepted recording once capture starts/stops.
- Follow the stable macOS default input during each take. Apply an explicit Preferences choice once instead of changing and restoring the system input around every recording.
- Build release before packaging, stage the new bundle, validate resources/signature, then replace the old bundle.
- Auto remains the recognition default. Explicit English/Russian choices pass the pinned library's script-filter hint; they are not general text prompts or guaranteed language locks. Keep automatic cleanup-language detection based on the result.

## Build sequence
1. Write failing cleanup, lifecycle, deadline and delivery/paste policy regressions.
2. Implement core safeguards; integrate capture, transcription, polishing and delivery.
3. Repair packaging and update README/architecture documentation.
4. Run automated checks, package and verify the release, document manual limits.

Quality continuation: run failing real-model grammar/correction checks; improve editing instructions and validation; compare local model candidates with identical fixtures; package the measured choice. Keep Parakeet ASR unless a replacement has a verified Mac runtime and better measured results.

## How to run and test
- Tests: `swift test --disable-automatic-resolution`
- Cleanup comparison (real model, 40 cases, writes `.build/cleanup-eval/<model>-model-first.json`): `VOICETYPE_CLEANUP_EVAL=1 VOICETYPE_METALLIB=/Applications/VoiceType.app/Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib swift test --filter CleanupComparisonTests`; optional `VOICETYPE_EVAL_MODEL=8b|4b|gemma12b`.
- Memory check: same variables with `VOICETYPE_POLISH_QUALITY=1 … --filter PolishMemoryTests`.
- Recorded-file replay: `VOICETYPE_SPEECH_QUALITY=/absolute/directory/with/english.aiff/russian.aiff/technical.aiff swift test --filter SpeechQualityTests`; `VOICETYPE_SPEECH_ENCODER=original` compares the earlier encoder. Generate the public technical fixture with `say -v Samantha -o technical.aiff 'spec dot pie file.'`.
- Installed-model smoke test: `VOICETYPE_MODEL_SMOKE=1 VOICETYPE_METALLIB=/Applications/VoiceType.app/Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib VOICETYPE_SMOKE_AUDIO=/tmp/voicetype-smoke.aiff swift test --skip-build --filter LocalModelSmokeTests`
- Packaging failure test: `python3 -m unittest discover -s Tests/PackagingTests`
- Package: `./package_app.sh`
- Run: `open /Applications/VoiceType.app`
- Logs: `log stream --style compact --predicate 'subsystem == "com.nikti.VoiceType"'`
- Manual matrix: short/long English and Russian; 20 consecutive takes; early hotkey release; Bluetooth connect/disconnect; 5/15 minute idle; sleep/wake; missing accessibility permission; history write failure; target app closes/switches.
