# Dictation quality update

This note records what changed, why it changed, and the evidence from the actual local models. The fixtures are supplied/public text and synthetic speech; no private microphone recordings or dictated text were sent to a service.

## Changes on October 28, 2026

Polished uses **Qwen3 4B Instruct 2507, four-bit**, replacing the 0.6B editor. Its prompt asks for complete English/Russian grammar correction while preserving names, facts, language and form of address. Transcript tags separate dictated commands from instructions to the editor. The repeat-token penalty was removed because the installed MLX implementation penalized tokens from the input too, which conflicts with copying names and otherwise-correct words.

Short prose now receives model editing. Standalone filenames have an explicit fast path, rather than the former blanket shortcut for all takes of eight words or fewer. High-confidence number/weekday retractions and compound-subject repairs are prepared before editing; the model remains responsible for broader grammar. Ordinary apologies and deliberate `X, not Y` contrasts are preserved.

`Cloud. Md.` becomes the explicitly requested known spelling `CLAUDE.md`; common filename extensions and explicit English/Russian quotation commands are normalized. The model preserves existing quotation boundaries. This cannot establish quote boundaries that are ambiguous in the recognized words, nor recover a word absent from the recording or recognizer output.

Accepted edits receive number, weekday, capitalization/name, filename, negation, condition, beginning, word-overlap and ending checks. Apple NaturalLanguage lemmas allow inflection corrections without treating every changed word as lost content. These are conservative checks, not a proof of general semantic equivalence. Rejections safely fall back and log a content-free reason. Model output is checked again after number/layout formatting.

Long single-block prose gets conservative paragraph formatting if the model omits it; existing paragraphs and lists are retained. Copied prose receives one trailing space, while stored history and literal filenames remain unchanged.

## Recognition choice

VoiceType retains Parakeet TDT v3 and selects its rebuilt `.int8V2` encoder. Upstream found that the original compressed encoder could corrupt words with certain trailing audio. The replacement corrected three published reproductions. This is a specific bug fix, not proof that it caused Nikita’s missing “Send” or that all recognition errors are solved. It is already supported by the pinned library, so no dependency update or custom runtime was needed. [Upstream fix](https://github.com/FluidInference/FluidAudio/pull/872), [Original issue](https://github.com/FluidInference/FluidAudio/issues/760).

## Measured local checks

Hardware: Apple M5, 24 GB memory. Models run on this Mac; synthetic audio is generated with the installed Samantha and Milena voices. Editing tests use fixed transcripts to isolate editing from recognition.

| Check | Result |
|---|---|
| Original 0.6B pipeline | Reproduced unresolved dates/budgets, short grammar bypass and Russian editing failures |
| 1.7B comparison | Faster, but earlier held-out Russian grammar stayed broken and one run introduced “Have Adobe approved…” |
| Selected 4B editor | Fifteen fixtures pass: long proposal, corrected instructions, short grammar, intentional contrast, Russian correction/grammar, filename, quoted speech, literal filename, duration, English/Russian lists, the alternate list introduction and two additional grammar cases |
| Selected editing latency | About 0.4–1.9s for short prose; 3.46s for the long proposal; around 2ms for a literal filename |
| MLX peak allocation | 2,891,617,404 bytes; excludes CoreML and other app/process memory |
| Original encoder replay | English 0.156s; Russian 0.126s after load |
| Rebuilt encoder replay | English 0.252s; Russian 0.137s after load; required instructions/dates preserved |
| Automated suite | All 78 checks pass with the three local-model/replay opt-ins enabled; no skips or failures |
| Packaging failure test | Passed |

Timing includes local fixture preparation/edit validation where applicable, excludes microphone capture and physical paste, and is not a broad accuracy or speed benchmark. The two encoder replays cannot measure a population word-error rate. The four-second optional editing deadline prevents unbounded waiting; slower, busy or rejected edits still use fallback. Long dictations can exceed this budget.

Commands and fixture expectations are in `SPEC.md` and the quality test files. Local validation logs are under ignored `.build/final-quality-validation.log`, `.build/quality-validation.log` and `.build/model-smoke.log`; fixture text printed there is synthetic/public. Routine application logs never include transcript contents.

## NVIDIA Nemotron 3.5 Transcribe

The October 28 release is **not** the earlier Nemotron 3.5 ASR Streaming 0.6B. The new model has 34B total parameters, around 4.3B active including its audio encoder, and supports English and Russian. NVIDIA reports long-form WER 10.98 versus Parakeet v3’s 13.37 under that benchmark. This is evidence for an accuracy candidate, not proof on short dictation or this Mac. Its current published compatibility lists NVIDIA hardware on Linux/Windows; a supported full-model integration in VoiceType’s Swift/CoreML/MLX stack was not established. We did not download or run it. [Official model card](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B).

Parakeet Ultra is a more practical later ASR comparison: ready Mac/CoreML assets, the v3 architecture and English/Russian support. Our pinned library lacks its version selector, so it needs a separately verified loader or a carefully tested dependency update. It was researched but not installed. [Upstream documentation](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/ParakeetUltra.md).

Wispr’s cloud infrastructure and latency engineering help explain its responsiveness; its published 700ms figure is an engineering expectation, not a guarantee for every take. VoiceType still does full recognition and editing after release, so a local streaming pipeline is a separate future performance project. [Wispr engineering explanation](https://wisprflow.ai/post/technical-challenges).

## Action record and release status

1. Reproduced the old editing failures before changing the app.
2. Compared 0.6B, 1.7B and 4B editors on the same text; selected the 4B quality result.
3. Added focused cleanup/validation regression checks and executed the real local models.
4. Compared original and rebuilt recognition encoders on identical synthetic audio.
5. Updated implementation and README/specification documentation. Packaged and installed `/Applications/VoiceType.app`; validated its resources and ad-hoc signature. Confirmed the installed process runs and logs successful polish-model warmup.
6. Attempted native UI inspection through the computer-use tool. App selection by full path launches the app, but accessibility inspection repeatedly times out; no screenshot or Preferences-window verification is claimed.

Live microphone, Bluetooth, sleep/wake, insertion into another app and native UI appearance remain manual verification. General speech accuracy and Wispr-equivalent latency are not claimed from these checks. Optional complexity/duplication/mutation CLI tools named in the workspace principles are not installed; regression checks and manual code review were used.

## Duration versus ordinal repair

A later test reproduced the exact reported error without speech recognition or the editor: the linked NeMo normalizer changed `Make a ten second video.` to `Make 12th video.` It also changed written `10 second` to `10 2nd`. This is a reproducible post-recognition formatting defect; it does not establish what the recognizer heard in the user's individual take.

`TranscriptNormalizer` now shields unambiguous duration spans while native normalization handles the rest. It converts each number separately through the existing native engine, preserves the duration unit, and hyphenates singular duration modifiers before nouns. Temporary markers use a separate Unicode plane from the dependency's own masking protocol. Original private-use characters are escaped to prevent collisions.

Checks include ten/fifteen/twenty-five seconds, decimal durations, minutes, existing hyphens, capitalization, genuine `twelfth`/`second` ordinals, dates, money and unchanged Russian normalization. The ambiguous bare wording `twenty second` retains the native ordinal interpretation; explicit `20 second`, `20-second` and plural `twenty seconds` are duration forms. We do not blindly rewrite `12th` into a duration.

Action record: first captured the native formatter's failing output; added duration/ordinal regression checks; implemented the boundary repair without changing dependencies; ran all 65 model-enabled checks successfully. The local followup test log is `.build/duration-validation.log`. Release installation follows the same validated packaging process.

## Explicit spoken lists

The old unavailable-model path reproduced the user's list as a single paragraph, including a period after its introduction. The repair recognizes sequential `number one/two…`, numeric equivalents, or Russian `пункт/номер` markers starting clauses. A sequence without an introduction is also accepted when it clearly starts with those markers. It requires at least two nonempty, consecutive items beginning at one; incomplete sequences and quoted marker phrases are not guessed into a list.

The introduction receives a colon and each item gets its own numbered line. Question/exclamation introductions retain that punctuation. The local model is explicitly told to keep the full wording and order. Fallback cleans each parsed item separately so whole-text whitespace cleanup cannot flatten the list again. Ordinary “number one priority” phrases remain prose.

Validation treats parsed labels as layout, rather than factual amounts, then compares the contents of each item as well as the whole transcript. Missing items and clear reordering fail validation; currency, amounts, names, negation and boundaries remain checked within their original item. These checks are conservative safeguards, not a proof of arbitrary semantic equivalence.

Action record: wrote and observed the failing fallback test first; added six focused core list checks; added a native-normalization integration check; exercised English/Russian list fixtures with the actual local editor. Final combined verification is recorded in `.build/list-validation.log`. No new model, dependency, UI or network service is introduced by this change.

Combined verification passed all 73 checks (60 core, 13 integration), including the fourteen real-editor fixtures. Installation uses the existing transactional packaging script and the installed process/build identity is checked separately. This backend change adds no new visual UI.

## List generalization and recognition language

The next user fixture, "We're gonna need three things happen. Number 1, fix the backend. Number 2, install the new model, number 3, rewrite the entire content," exposed an overly restrictive introduction keyword check. New regressions failed before the repair. Sequential labels now require clause boundaries instead of words such as "list" or "constraints"; ordinary product-number references stay prose. The real editor produced "We're gonna need three things to happen:" and all three numbered items in 0.99s. The unavailable-model path also preserves the structure.

Parakeet receives audio, not the editor's proofreading prompt. It detects languages automatically; a short phonetic filename has less context to distinguish languages. That is a plausible explanation for the reported Cyrillic output, but the original audio and intermediate output are unavailable, so the failing stage is not established. The editor's instruction to preserve language can then retain an already-Cyrillic transcript. [NVIDIA model documentation](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3).

Preferences now offers Auto (unchanged default), English and Russian. The pinned FluidAudio decoder implements these choices as Latin/Cyrillic token filtering using its available top candidates. It does not accept a natural-language prompt, distinguish all languages sharing an alphabet, or guarantee a matching candidate. A fixed script can affect foreign names and mixed-language filenames, so Auto remains available. The choice persists and is captured at recording start. No additional model or service is introduced.

Synthetic Samantha audio saying "spec dot pie file" returned `Spec.py file` with both Auto and English. Existing English/Russian audio replays also pass. This sample did not reproduce the user's Cyrillic failure and is not proof of accuracy for their microphone or accent. The new Preferences control retains the existing native form design; computer-use app inspection still times out, so no screenshot verification is claimed.

Action record: reproduced the new list failure; replaced the keyword restriction with clause-boundary recognition; exercised fallback and the actual local editor; added saved-language/recording-consistency checks and recognition replay; updated README/specification. All 78 checks pass (61 core, 17 integration), including fifteen real-editor fixtures, with no skips. Packaging failure checks pass separately. Combined verification is recorded in `.build/language-list-validation.log`; installation follows the same transactional packaging process.
