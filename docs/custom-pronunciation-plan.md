# Custom pronunciation dictionary plan

## Goal

Let a user enter a word or short phrase, record it three times, review what Voice heard, and save a local rule that makes future dictation more likely to produce the intended spelling.

Three examples are useful calibration evidence, but they are not enough to fine-tune Whisper. The first production version should combine decoder prompting with conservative post-transcription alias replacement. The audio remains useful for review and future pronunciation-aware matching, but it should not be described as model training.

## Proposed user flow

1. Open **Settings → Grammar → Custom Pronunciations**.
2. Enter the intended spelling, such as `Codex` or a person's name.
3. Record three short takes. Transcribe each take immediately with the active Whisper model and language.
4. Show each observed transcript. Let the user discard and repeat a bad/noisy take.
5. Propose unique aliases from the takes and let the user edit or disable each alias.
6. Save the entry. Show it in a searchable list with enabled, edit, re-record, and delete actions.
7. During dictation, pass enabled intended spellings as a Whisper initial prompt and apply boundary-aware alias corrections before optional refinement.

## Data model

`PronunciationEntry`

- stable UUID
- intended spelling
- language code (or language-agnostic)
- enabled flag
- normalized aliases observed across accepted takes
- three local audio-sample references plus duration and capture date
- active Whisper model identifier used during calibration
- created and updated dates

Store metadata as versioned JSON under Application Support. Keep WAV samples in an adjacent per-entry directory and never sync or upload them. Deleting an entry deletes its samples after confirmation.

## Runtime integration

1. Build a bounded initial prompt from enabled entries matching the active language. Enforce a token/character budget so a large dictionary does not degrade decoding.
2. After Whisper returns text, replace only explicit learned aliases using Unicode-aware word or phrase boundaries and case-preserving output.
3. Apply corrections before heuristic or llama.cpp refinement so refinement sees the intended spelling.
4. Keep an escape hatch: users can disable the dictionary globally and disable individual entries.

Avoid phonetic distance matching in v1. It risks changing ordinary words that merely sound similar. Only aliases explicitly confirmed by the user should be rewritten.

## Delivery slices

1. **Prototype (this branch):** compare three in-memory Settings layouts and validate the three-take/review state model. Recording and Whisper transcription are real; nothing persists.
2. **Capture foundation:** extract a dedicated recorder, request microphone access, validate duration/silence, retain temporary WAVs, and transcribe each take.
3. **Dictionary storage and editor:** versioned local store, entry list, re-record/delete, and privacy copy.
4. **Transcription integration:** bounded Whisper prompt plus exact alias correction, with unit tests for boundaries, casing, punctuation, overlaps, and multilingual text.
5. **Acceptance:** test real troublesome names/terms across clean and noisy speech; compare baseline and dictionary-enabled output; verify no unrelated replacements and no audio leaves the Mac.

## Prototype decision to make

Choose the clearest layout: A (guided steps), B (compact recorder), or C (take comparison). Also decide whether users need to inspect every observed transcript before saving, or whether the compact progress view is sufficient.
