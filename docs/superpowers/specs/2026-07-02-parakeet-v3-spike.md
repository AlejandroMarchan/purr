# Spike: Parakeet TDT v3 multilingual support (report only)

Timeboxed check on whether FluidAudio 0.8's Parakeet TDT v3 (multilingual, per
`Package.swift:12-14`) could give Spanish meetings Parakeet speed with token
timings instead of falling back to Whisper. No code in `Sources/` was changed.

## (a) Does `AsrManager`/`AsrModels` accept a v2/v3 choice?

Yes, via a `version:` parameter, not a separate type. `AsrModelVersion` enum:
`.v2`, `.v3`, `.tdtCtc110m`, `.tdtJa` — `AsrModels.swift:5-20`. Each maps to a
HF `Repo` (`.parakeetV2`/`.parakeetV3`) and has its own `blankId` (1024 for v2,
**8192 for v3** — different vocab/joint shape, not just a flag).
`AsrModels.load/download/downloadAndLoad/loadFromCache(... version:
AsrModelVersion = .v3 ...)` (same file, lines 229-232, 411-421, 486, 551) —
**v3 is the library-wide default** everywhere `version:` is omitted. Purr's
`ParakeetEngine.swift:129` already pins it explicitly: `version: .v2`. v3 also
uses a different joint file, `JointDecisionv3.mlmodelc`, with extra top-K
outputs (`AsrModels.swift:173-184`, `ModelNames.swift:336-338`).

## (b) Does v3 emit `tokenTimings`?

Yes — version-agnostic. `AsrManager.tdtDecodeWithTimings`
(`AsrManager.swift:215-338`) dispatches to `TdtDecoderV2` or `TdtDecoderV3`
(line 276-337), but both return a `TdtHypothesis` with the same shape
(`ySequence`, `timestamps`, `tokenConfidences`, `tokenDurations`). That flows
through one shared path regardless of version:
`AsrManager+Transcription.swift:106-121` always calls `createTokenTimings`
(`AsrManager+TokenProcessing.swift:30-108`) and sets `ASRResult.tokenTimings`.
The meeting diarizer's token-timing merge needs no changes for v3 output.

## (c) Model download size

Not stated as a number anywhere in FluidAudio's source or docs for v3 (repo:
**`FluidInference/parakeet-tdt-0.6b-v3-coreml`**, `ModelNames.swift:6`;
contrast Cohere Transcribe's explicit "1.8 GB" note at `Models.md:17`). Queried
HF's tree-metadata API (file listing + sizes only, no weights fetched) for the
actual default download set (Preprocessor + int8 Encoder + Decoder + Joint +
vocab — what `AsrModels.download` really pulls, not the repo's total size
which also holds int4/fp32/mlpackage alternates):

| | v2 (current) | v3 (multilingual) |
|---|---|---|
| Encoder (int8) | 445.2 MB | 445.2 MB (same) |
| Decoder | 14.4 MB | 23.6 MB (larger multilingual vocab) |
| Joint | 3.5 MB | 12.7 MB (`JointDecisionv3`, extra top-K head) |
| Preprocessor + vocab | ~0.35 MB | ~0.67 MB |
| **Total** | **~443 MB** | **~461 MB** |

Matches Purr's own comment (`ParakeetEngine.swift:80-81`, "~450 MB TDT v2").
v3 is a ~4% bigger download — not a blocker.

## (d) Does `language:` on v3 select Spanish?

No — it doesn't select a language or bias a language model, only enables
post-hoc **script filtering** of decoder top-K candidates.
`AsrManager.tdtDecodeWithTimings` (`AsrManager.swift:276-282`): on v2/110m, a
non-nil `language` is logged and dropped ("script filtering requires the v3
joint decoder") — confirming v2 truly ignores it today, per
`ParakeetEngine.swift:254-256`. On v3 (lines 295-314), `language` reaches
`TdtDecoderV3` → `TokenLanguageFilter.filterTopK`
(`TokenLanguageFilter.swift:143-186`), which rejects top-K candidates whose
Unicode script mismatches the language's `Script` (`.latin`/`.cyrillic`/`.greek`,
lines 39-51) — it exists to stop v3 emitting Cyrillic while transcribing
Polish (issue #512), not to make the model "speak Spanish."

`Language.spanish = "es"` **does exist** (`TokenLanguageFilter.swift:6`) and
maps to `.latin` — same script as `.english`. So Purr's existing call site
(`language: .english`, `ParakeetEngine.swift:263`) would already admit Spanish
output unmodified on v3: Spanish diacritics (á é í ó ú ñ ¿ ¡) sit inside the
allowed Latin-1/Extended ranges (lines 90-98). Passing `.spanish` explicitly
would filter identically — the parameter only disambiguates script family, not
per-language vocabulary/grammar; multilingual capability comes entirely from
v3's training data.

**Supported languages (v3):** `Models.md:14` and `README.md:303`: **25
European languages** (Spanish included). Japanese is *not* a v3 capability —
it is the separate `.tdtJa` model with its own HF repo
(`parakeet-0.6b-ja-coreml`; `AsrModels.swift:5-20`, `Models.md:13-16`), out of
scope here (`README.md:38`'s "25 European languages and Japanese" is a rollup
of the whole TDT family, not a v3 claim). `TokenLanguageFilter.swift:4-37`'s
`Language` enum (28 codes, Latin/Cyrillic/Greek only) is the script-filter
allowlist, not the full training-language list.

**Diarizer coupling:** none. `grep -rn "AsrModelVersion|AsrManager|AsrModels"`
over `Diarizer/` returns zero matches — diarization (segmentation + embedding
from `FluidInference/speaker-diarization-coreml`) is architecturally
independent of ASR version. Purr's speaker/timing merge only consumes
`ASRResult.tokenTimings`, with no FluidAudio-side dependency on which Parakeet
version produced them.

## Risk found: v3 long-form quality caveat

`AsrTypes.swift:26-39` documents **issue #594**: on v3 *multilingual long-form
audio*, the default `melChunkContext: true` (a v2-era English fix, PR #264)
can drift the decoder back to an "English-biased prior" on non-English long
recordings. Mitigation: `melChunkContext: false` for v3, plus an opt-in
`dualDecodeArbitration` flag (lines 41-62) added specifically to fix "mid-word
duplicates and dropped clauses on ... long Spanish narration" (~1.1-1.5×
slower). **Meetings are exactly the long-form case these flags target.**
`ParakeetEngine.swift:130` currently uses `AsrManager(config: .default)`
(`melChunkContext: true`) — wrong for v3 Spanish meetings. Adopting v3 means
overriding `ASRConfig`, not just flipping `version:`.

## Go/No-Go recommendation

**Conditional go** — worth a follow-up phase, not a drop-in swap.

For: `version:` is a same-signature parameter, no new dependency; `tokenTimings`
work unmodified (b); download size is comparable (c); Spanish is in the
documented language set and needs no `language:` change (d).

Against (why not "ship now"): `language:` isn't per-language tuning, just a
script filter — don't oversell it; issue #594's long-form drift bug targets
exactly the meeting use case and needs its own quality validation with
`melChunkContext: false` before trusting it over Whisper; v3 would run as a
**second warm model** alongside v2 (dictation/voice-edit should stay on
English-only v2 for its higher English recall, `ParakeetEngine.swift:10-13`),
adding ~461 MB for users who enable both.

### If "go": estimated change surface

| File | Change | Rough LOC |
|---|---|---|
| `ParakeetEngine.swift` | Second `batchManagerV3` mirroring lines 88-222 (download/load/unload/delete for its own model dir) + `ASRConfig(melChunkContext: false)` override + a version-aware `transcribeASR` entry point | ~130-160 |
| `SettingsStore.swift` | Third case on the meeting-engine enum + label/summary | ~20-30 |
| `AppCoordinator.swift` | Extend `currentMeetingEngine()` switch + a second download-progress publisher | ~30-50 |
| `SettingsView.swift` | Third picker row + model management card (mirrors existing Parakeet card, `SettingsView.swift:790-861`) | ~60-90 |
| `PurrTests` | Engine-selection coverage for the new case | ~20-40 |

**Total: ~260-370 LOC across 4-5 files.**

### Suggested backlog entry

> **Add Parakeet TDT v3 as an opt-in third meeting engine (multilingual,
> keeps token timings).** Load v3 as a second warm `AsrManager` alongside v2
> (dictation/voice-edit stay on v2). Needs: (1) `ASRConfig(melChunkContext:
> false)`, validated against issue #594's long-form drift bug with a WER/spot
> check on a few Spanish meeting recordings before shipping; (2) a third
> `meeting.engine` option, distinct from the dictation engine picker; (3) its
> own ~461 MB download/delete lifecycle. Do not replace v2 — keep it as the
> English dictation/voice-edit default.

## Evidence sources

`Package.swift:12-14` · `Sources/Purr/ParakeetEngine.swift` (headers, 88-135,
249-269) · FluidAudio: `AsrModels.swift`, `AsrTypes.swift`,
`AsrManager.swift:215-338`, `AsrManager+Transcription.swift`,
`AsrManager+TokenProcessing.swift`, `Shared/TokenLanguageFilter.swift`,
`ModelNames.swift:1-20,262-374`, `README.md:38,303`,
`Documentation/Models.md:13-17,75-76` · HF API tree metadata for
`FluidInference/parakeet-tdt-0.6b-{v2,v3}-coreml` (file listing + byte sizes
only, no weights downloaded).
