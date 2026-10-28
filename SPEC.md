# VoiceType reliability and dictation quality

VoiceType is a local macOS dictation app. This repair addresses the October 4 audit while preserving existing uncommitted work and the English/Russian workflows.

## Contract
GOAL: Deliver one complete transcript per accepted recording; keep optional polishing within a four-second waiting budget even when inference is slow. Measure each post-recording stage so idle regressions can be diagnosed.

October 28 quality goal: improve Polished grammar and explicit spoken corrections on English/Russian fixtures while retaining instructions, conditions, intended numbers, filenames and quotation boundaries. Copy finished prose with one trailing space. The user prefers balanced accuracy and speed and accepts a few seconds for better grammar; the measured editor replaces the old two-second polish limit with a four-second bound.

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
- Saving history fails and prevents delivery, or every take reloads all history before pasting.
- Cleanup turns Russian digits into English words, changes legitimate "ill", damages "uh-huh", or removes grammatical "had had".
- Polished drops the opening instruction, keeps a retracted budget/date, changes an amount in an intentional contrast, or leaves the supplied grammar fixture broken.
- Model/rules results are mislabeled, fallback has no reason, or stronger-model speed is claimed without running it on this Mac.
- Failed permission/focus checks still post paste keys; logs falsely claim insertion was verified.
- The start/stop cues are suppressed merely because Bluetooth is the output, or the waveform stays behind the app receiving dictation.
- Per-take changes to the macOS default input race Core Audio teardown and can crash the process.
- Packaging silently reuses an old executable or replaces the working app after a failed build.
- A successful build is not installed in `/Applications`, or an old copy keeps running after install.
- MANUAL: real microphone, Bluetooth, app focus, and idle/sleep latency require a live desktop session; record verification limits explicitly.

## Built on top of
- Existing pinned FluidAudio 0.15.7 (Apache-2.0): local ASR and audio conversion. Avoid a dependency upgrade during repair.
- Existing pinned MLX Swift / MLX Swift LM (MIT): inference; use generateTask and await GPU completion for cleanup.
- Qwen3-4B-Instruct-2507 4-bit (Apache-2.0): local editor selected after 0.6B, 1.7B and 4B comparisons; no dependency upgrades. Existing FluidAudio `.int8V2` selects a rebuilt Parakeet v3 encoder without changing the recognizer architecture.
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

## Build sequence
1. Write failing cleanup, lifecycle, deadline and delivery/paste policy regressions.
2. Implement core safeguards; integrate capture, transcription, polishing and delivery.
3. Repair packaging and update README/architecture documentation.
4. Run automated checks, package and verify the release, document manual limits.

Quality continuation: run failing real-model grammar/correction checks; improve editing instructions and validation; compare local model candidates with identical fixtures; package the measured choice. Keep Parakeet ASR unless a replacement has a verified Mac runtime and better measured results.

## How to run and test
- Tests: `swift test --disable-automatic-resolution`
- Quality fixtures: `VOICETYPE_POLISH_QUALITY=1 VOICETYPE_METALLIB=/Applications/VoiceType.app/Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib swift test --filter PolishedQualityTests`; optional `VOICETYPE_POLISH_MODEL=0.6b|1.7b|4b` compares editors.
- Recorded-file replay: `VOICETYPE_SPEECH_QUALITY=/absolute/directory/with/english.aiff/and/russian.aiff swift test --filter SpeechQualityTests`; `VOICETYPE_SPEECH_ENCODER=original` compares the earlier encoder.
- Installed-model smoke test: `VOICETYPE_MODEL_SMOKE=1 VOICETYPE_METALLIB="$PWD/VoiceType.app/Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib" VOICETYPE_SMOKE_AUDIO=/tmp/voicetype-smoke.aiff swift test --skip-build --filter LocalModelSmokeTests`
- Packaging failure test: `python3 -m unittest discover -s Tests/PackagingTests`
- Package: `./package_app.sh`
- Run: `open VoiceType.app`
- Logs: `log stream --style compact --predicate 'subsystem == "com.nikti.VoiceType"'`
- Manual matrix: short/long English and Russian; 20 consecutive takes; early hotkey release; Bluetooth connect/disconnect; 5/15 minute idle; sleep/wake; missing accessibility permission; history write failure; target app closes/switches.

## Status
Updated: 2026-10-28
- Built: session-owned startup/recording/processing; cancellation-safe polish deadline; idle warmup; sample-rate-safe audio capture; guarded paste; delivery before history; stage timing; transactional packaging; cleanup fidelity fixes; audible cues; cross-app waveform panel; stable input routing.
- Built quality update: Qwen3 4B Instruct; a full grammar editing prompt with transcript/data separation; explicit number/weekday repair preparation; short-take editing; facts/boundaries validation; known filenames and spoken quotation commands; readable paragraph fallback; trailing insertion space; rebuilt Parakeet encoder; reason-coded fallback logs.
- Verified: all 62 Swift checks pass with all model/replay opt-ins enabled, including eleven editing fixtures and English/Russian synthetic audio. Packaging failure protection passes. The release bundle installs in `/Applications`, validates its signature/resources, launches, and logs successful model warmup.
- Measured on this Apple M5/24 GB: editing about 0.4–1.9s for shorter prose and 3.46s for the 100-word proposal; literal filename about 2ms. New encoder replay about 0.14–0.25s after load. Peak MLX allocation 2.89 GB, not whole-app RAM. These figures exclude live microphone, insertion, Bluetooth, idle and sleep/wake behavior.
- Release state: implementation and local-model verification complete. Native UI inspection times out in the computer-use tool; screenshots, live microphone, Bluetooth and physical insertion remain unverified. See `docs/DICTATION_QUALITY.md` for the release evidence and limits.
- Watch out for: the bundle is ad-hoc signed, so replacing it can require Accessibility permission to be enabled again.
