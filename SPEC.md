# VoiceType reliability and latency repair

VoiceType is a local macOS dictation app. This repair addresses the October 4 audit while preserving existing uncommitted work and the English/Russian workflows.

## Contract
GOAL: Deliver one complete transcript per accepted recording; keep optional polishing within a 2-second waiting budget even when inference is slow. Measure each post-recording stage so idle regressions can be diagnosed.

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
- Failed permission/focus checks still post paste keys; logs falsely claim insertion was verified.
- The start/stop cues are suppressed merely because Bluetooth is the output, or the waveform stays behind the app receiving dictation.
- Per-take changes to the macOS default input race Core Audio teardown and can crash the process.
- Packaging silently reuses an old executable or replaces the working app after a failed build.
- A successful build is not installed in `/Applications`, or an old copy keeps running after install.
- MANUAL: real microphone, Bluetooth, app focus, and idle/sleep latency require a live desktop session; record verification limits explicitly.

## Built on top of
- Existing pinned FluidAudio 0.15.7 (Apache-2.0): local ASR and audio conversion. Avoid a dependency upgrade during repair.
- Existing pinned MLX Swift / MLX Swift LM (MIT): inference; use generateTask and await GPU completion for cleanup.
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

## How to run and test
- Tests: `swift test --disable-automatic-resolution`
- Installed-model smoke test: `VOICETYPE_MODEL_SMOKE=1 VOICETYPE_METALLIB="$PWD/VoiceType.app/Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib" VOICETYPE_SMOKE_AUDIO=/tmp/voicetype-smoke.aiff swift test --skip-build --filter LocalModelSmokeTests`
- Packaging failure test: `python3 -m unittest discover -s Tests/PackagingTests`
- Package: `./package_app.sh`
- Run: `open VoiceType.app`
- Logs: `log stream --style compact --predicate 'subsystem == "com.nikti.VoiceType"'`
- Manual matrix: short/long English and Russian; 20 consecutive takes; early hotkey release; Bluetooth connect/disconnect; 5/15 minute idle; sleep/wake; missing accessibility permission; history write failure; target app closes/switches.

## Status
Updated: 2026-10-04
- Built: session-owned startup/recording/processing; cancellation-safe polish deadline; idle warmup; sample-rate-safe audio capture; guarded paste; delivery before history; stage timing; transactional packaging; cleanup fidelity fixes; audible cues; cross-app waveform panel; stable input routing.
- Verified: 41 Swift checks pass (one opt-in model smoke test skips by default), including cue delivery and cross-app panel regressions. The packaging failure test passes, and the rebuilt release bundle's resources and signature validate.
- Measured with generated speech: repeated recognition 0.11–0.31s and repeated polishing 0.37–0.41s after model load. These figures exclude real microphone, focus, and sleep/wake behavior.
- Changed from plan: the fidelity guard is 60% after the live model smoke test caught a rewrite that omitted “meeting notes” at the old 50% threshold.
- Next: manually exercise the matrix above using the real microphone and target applications, including idle/sleep and Bluetooth.
- Watch out for: the bundle is ad-hoc signed, so replacing it can require Accessibility permission to be enabled again.
