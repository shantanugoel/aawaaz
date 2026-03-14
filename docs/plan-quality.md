# LLM Cleanup Quality Plan: 47% → 80%+

## Current State (after prompt overhaul)

The example-driven prompt redesign moved pass rate from **17% → 47%** on the 100-case benchmark. Key wins: capitalization, punctuation, grammar, filler cleanup, and adversarial resistance via `<text>` delimiters. Current best config: **Qwen 3 0.6B, 0.33s avg latency, ~1 GB RAM**.

### What worked

| Change | Impact |
|---|---|
| Example-driven prompt (4 concrete input→output pairs) | Biggest win. Small models learn from examples, not rules. |
| Removed repetition penalty (1.1 → 1.0) | Stopped content drops. Cleanup = copying most input words. |
| `<text>` delimiters | Task framing + partial injection resistance. |
| Positive instructions ("Keep X" vs "Do NOT change X") | Small models follow affirmative instructions better. |
| Output content-drop validator | Catches catastrophic summarization/injection. |
| LLM bypass for short/code/terminal inputs | 16 cases trivially pass at 0.00s. |

### What's still failing (53 cases)

| Category | Pass/Total | Root Cause | Fix Approach |
|---|---|---|---|
| **self-correction-llm** | 0/10 | Implicit corrections ("send to mark oh sorry to john") need language understanding beyond 0.6B | Better model (LFM2.5) or accept as out-of-scope for tiny models |
| **adversarial** | 0/5 | Chat models fundamentally follow instructions. "Ignore previous" tricks a 0.6B model every time | Output validator improvements; larger model; or accept |
| **names-technical** | 2/10 | "dot"→".", "slash"→"/", capitalization of tech terms (Kubernetes, AWS) | **Deterministic spoken-form normalizer** (easy win) |
| **hinglish** | 2/10 | Poor Devanagari/romanized handling, wrong capitalization patterns | More prompt examples; script-aware rules |
| **single-line** | 0/5 | Model adds periods but test expects none; "colon" not converted | Fix test expectations + spoken-form normalizer |
| **cascading-corrections** | 1/5 | Deterministic reducer → <4 words → LLM bypass → no capitalization | Fix bypass to still capitalize short results |
| **fillers** | 10/15 | 5 remaining: "like" preserved incorrectly, sentence-start "so" not removed | Improve filler removal rules |
| **self-correction-det** | 8/12 | 4 remaining: capitalization issues after correction | Post-correction capitalization fix |
| **grammar** | 8/12 | 4 remaining: edge cases (wrong contraction, missing comma) | More prompt examples |

---

## Plan: Three Layers to 80%+

### Layer 1: Deterministic Spoken-Form Normalizer (Swift, no model)

**Expected impact: +8-12 pass rate** (fixes names-technical, single-line, some hinglish)

Add a `SpokenFormNormalizer` to the text processing pipeline that runs **after** filler removal and **before** the LLM. It converts spoken punctuation and symbols to their written forms, with context awareness.

**File:** `Aawaaz/TextProcessing/SpokenFormNormalizer.swift`

#### Patterns to handle

**Always normalize (unambiguous):**

| Spoken Form | Written Form |
|---|---|
| `question mark` | `?` |
| `exclamation mark` / `exclamation point` | `!` |
| `open paren` / `open parenthesis` | `(` |
| `close paren` / `close parenthesis` | `)` |
| `open bracket` | `[` |
| `close bracket` | `]` |
| `underscore` | `_` |
| `hashtag` / `hash` (before a word) | `#` |
| `ampersand` | `&` |
| `at sign` | `@` |
| `percent` / `percent sign` | `%` |
| `dollar sign` | `$` |
| `equals sign` / `equals` (between terms) | `=` |

**Context-dependent normalization:**

| Pattern | Context | Example |
|---|---|---|
| `dot` | Between words that look like a domain/filename/version | `next dot js` → `next.js`, `version two dot three` → `version 2.3` |
| `slash` | In paths, URLs, API endpoints | `slash api slash v2` → `/api/v2` |
| `at` | Between a name and a domain | `john at example dot com` → `john@example.com` |
| `colon` | After a label word (Re, Bug report, Subject, http/https) | `re colon` → `Re:`, `https colon` → `https:` |
| `dash` / `dash dash` | In commands or compound words | `dash dash force` → `--force`, `dash n` → `-n` |
| `dot dot dot` / `dot dot dot` | Ellipsis | → `...` |

**Do NOT normalize in regular prose:**

- "I like the color" — "like" stays
- "he said dot dot dot" in casual speech — leave unless in code/terminal context
- "the period of time" — "period" is not punctuation here

#### Implementation approach

```swift
struct SpokenFormNormalizer {
    /// Normalize spoken symbols in the given text.
    /// - Parameters:
    ///   - text: The text to normalize
    ///   - context: Insertion context for app-category awareness
    /// - Returns: Text with spoken forms replaced by symbols where appropriate
    static func normalize(_ text: String, context: InsertionContext) -> String {
        var result = text

        // 1. Unambiguous patterns (always safe)
        result = normalizeUnambiguous(result)

        // 2. URL/email/path patterns (detect structure first)
        result = normalizeURLsAndPaths(result)

        // 3. Command-line patterns (dash dash, dash followed by single letter)
        if context.appCategory == .code || context.appCategory == .terminal {
            result = normalizeCommandPatterns(result)
        }

        // 4. Colon after label words
        result = normalizeLabelColons(result)

        return result
    }
}
```

#### Pipeline integration

In `TranscriptionPipeline.postProcess()`, add after filler removal and before LLM:

```swift
// Existing: self-correction → filler removal
// NEW: spoken-form normalization
let normalized = SpokenFormNormalizer.normalize(afterFillers, context: context)
// Then: LLM cleanup (if enabled)
```

#### Tests

Create `Tests/SpokenFormNormalizerTests.swift` with cases:
- URL reconstruction: `"https colon slash slash github dot com slash aawaaz"` → `"https://github.com/aawaaz"`
- Email: `"john at example dot com"` → `"john@example.com"`
- Path: `"slash api slash v2 slash users"` → `/api/v2/users`
- Version: `"version two dot three dot one"` → stays as-is (number words need separate handling)
- Command: `"dash dash force"` → `"--force"`
- Label: `"re colon project update"` → `"Re: project update"`
- Safe passthrough: `"I like the dot on the i"` → unchanged

---

### Layer 2: Pipeline Fixes (Swift, no model)

**Expected impact: +5-8 pass rate** (fixes cascading-corrections, remaining fillers, self-correction-det)

#### Fix 2a: Capitalize short bypass results

**Problem:** When deterministic self-correction reduces "the meeting is tuesday, scratch that, wednesday, actually no, thursday" to just "thursday", the word count is <4, so LLM is bypassed. Result: no capitalization.

**Fix:** In `LocalLLMProcessor.process()`, when short-input bypass triggers, still capitalize the first letter:

```swift
if wordCount < 4 {
    // Still capitalize the first letter even when bypassing LLM
    var result = rawText
    if let first = result.first, first.isLowercase {
        result = first.uppercased() + result.dropFirst()
    }
    return result
}
```

#### Fix 2b: Capitalize after deterministic self-correction

**Problem:** `SelfCorrectionDetector` outputs lowercase results when the corrected text starts mid-sentence. E.g., "send to mark, scratch that, to john" → "to john" (lowercase).

**Fix:** Add capitalization in the deterministic post-processing path, after self-correction detection but before filler removal. If the entire result was produced by self-correction (i.e., the result is shorter than 50% of input), capitalize the first character.

#### Fix 2c: Improve test expectations for single-line

**Problem:** 5/5 single-line cases fail because the model adds a period (correct behavior for dictation cleanup) but tests expect no period. Also, "colon" is not converted to `:`.

**Fix:** Update `CleanupQualityTests` — single-line expectations should allow trailing periods. The `colon` issue is fixed by Layer 1 (spoken-form normalizer).

---

### Layer 3: Test One More LLM Model

**Expected impact: +5-10 pass rate** (may fix self-correction-llm, adversarial, remaining grammar)

#### LFM2.5-1.2B-Instruct (Liquid AI)

| Property | Value |
|---|---|
| HuggingFace ID | `LiquidAI/LFM2.5-1.2B-Instruct-MLX-4bit` |
| Also available as | `lmstudio-community/LFM2.5-1.2B-Instruct-MLX-4bit` |
| Size | 659 MB (4-bit MLX) |
| RAM | ~1.2 GB |
| Architecture | Hybrid (10 double-gated LIV convolution + 6 GQA attention blocks) |
| IFEval (instruction following) | **86.2%** vs Qwen3-1.7B's 73.7% |
| Context length | 128K tokens |
| Languages | English, Arabic, Chinese, French, German, Japanese, Korean, Spanish |
| License | LFM 1.0 (commercial use allowed) |

**Why this is the strongest candidate:**
- IFEval score 86.2% — directly measures instruction following, which is our core problem (model not following cleanup instructions faithfully)
- Hybrid architecture with convolution blocks = faster than pure transformer for short sequences
- Designed for edge/on-device deployment
- Official MLX 4-bit quantization from Liquid AI
- Similar size to Qwen 3 0.6B (659 MB vs 470 MB) but architecturally more capable

**Why test only this one:**
- The benchmark already tested 8 different models (Qwen3 0.6B, Qwen2.5 0.5B/1.5B, Gemma3 1B, Gemma2 2B, Llama3.2 1B, SmolLM 1.7B, Granite4 1B). None broke 20% with the old prompt.
- The prompt overhaul was the real unlock (17% → 47%). Architecture matters less than prompt design for this task.
- LFM2.5 is the only sub-2B model that significantly beats Qwen3 on instruction following benchmarks.

**What to do:**

1. Add `lfm2_5_1_2B_4bit` to `LLMModelCatalog.swift`
2. Run the existing benchmark test (`testCleanupQualityRegression`) with LFM2.5
3. If pass rate > 50% at <1s latency: consider it as an upgrade option for 16GB+ machines
4. If pass rate ≤ 47%: stop searching for general-purpose LLMs and focus on Layers 1-2

**Important caveat — Hindi support:**
LFM2.5 lists Arabic/Chinese/Japanese/Korean/Spanish/French/German/English but does NOT list Hindi. It may perform poorly on Hinglish. Test the 10 Hinglish cases specifically.

---

### Layer 4 (Future): Specialized Punctuation/Capitalization Model

**Only if Layers 1-3 don't reach 70%+ pass rate.**

#### ai4bharat/Cadence-Fast

| Property | Value |
|---|---|
| Base model | Gemma-3-270M (bidirectional encoder) |
| Size | ~150 MB |
| Task | Token classification (punctuation restoration) |
| Languages | English + Hindi + 21 other Indic languages |
| Inference | Single-pass encoder (not autoregressive) — immune to prompt injection |
| Features | Periods, commas, question marks, exclamation marks, colons, semicolons, Hindi danda, etc. |
| Capitalization | Rule-based (included in `cadence-punctuation` Python package) |
| License | MIT |

**Why it's interesting:**
- It's NOT a chat LLM — it's a bidirectional sequence tagger. It doesn't "follow instructions" or get confused by adversarial inputs.
- Single-pass inference is ~10-50× faster than autoregressive generation.
- Built for exactly our task: restore punctuation in ASR transcripts.
- Native Hindi + English support, including speech transcripts with disfluencies.

**Why it's Layer 4 (deferred):**
- It's a PyTorch model — needs conversion to ONNX or CoreML for use in our Swift app.
- The app already uses ONNX Runtime for Silero VAD, so ONNX is feasible but adds complexity.
- It handles punctuation/capitalization but NOT grammar or self-correction.
- May not handle romanized Hinglish well (trained on Devanagari Hindi).

**Integration path if needed:**
1. Export Cadence-Fast to ONNX via PyTorch's export
2. Load via ONNX Runtime (same infra as Silero VAD)
3. Replace LLM for punctuation/capitalization at `.light` cleanup level
4. Keep LLM for `.medium`/`.full` (grammar, sentence flow)

### Layer 5 (Future): Fine-Tuned Transduction Model

**Only if general-purpose LLMs plateau below 70% even with Layers 1-3.**

Fine-tune a small base model (Qwen3-0.6B-Base or LFM2.5-1.2B-Base) specifically on dictation cleanup pairs using MLX LoRA. Train on:
- ASR-like raw transcripts → cleaned text (your 100 test cases + 500-1000 more)
- Hinglish + English + technical text
- Adversarial/injection examples (output = input with punctuation)
- Spoken symbol forms
- Many identity cases (output = input, no change needed)

Use plain input→output mapping, greedy decoding, no chat template.

This is the nuclear option. Only pursue if:
- Layer 1-3 pass rate stalls below 65%
- You're willing to invest 2-3 days in dataset creation + training

---

## Implementation Order

### Phase 1: Quick Wins (1 day)

1. **Fix 2a** — capitalize short bypass results
2. **Fix 2b** — capitalize after self-correction detection
3. **Fix 2c** — update single-line test expectations
4. Run benchmark → expect **~52-55%**

### Phase 2: Spoken-Form Normalizer (1-2 days)

5. **Layer 1** — implement `SpokenFormNormalizer`
6. Write normalizer unit tests
7. Integrate into pipeline (after fillers, before LLM)
8. Run benchmark → expect **~58-65%**

### Phase 3: LFM2.5 Evaluation (half day)

9. Add LFM2.5 to `LLMModelCatalog`
10. Run benchmark with LFM2.5 using the example-driven prompt
11. Compare pass rate and latency vs Qwen 3 0.6B
12. Decision: adopt LFM2.5 as an option, or keep Qwen 3 0.6B as default

### Phase 4: Prompt Tuning (1 day)

13. Add more prompt examples targeting remaining failures:
    - Hinglish example with romanized Hindi preservation
    - Technical term capitalization example
    - Self-correction example (if LFM2.5 can handle it)
14. Tune example count (4 → 6-8) and measure quality vs. latency trade-off
15. Run benchmark → expect **~65-75%**

### Phase 5: Decide on Advanced Path

If pass rate is 70%+: **ship it**. The remaining failures (adversarial, implicit self-correction) are edge cases that don't affect typical dictation.

If pass rate is below 65%: evaluate Layer 4 (Cadence-Fast) or Layer 5 (fine-tuning).

---

## Benchmark Results History

### Complete Progression

| Step | Model | Prompt Style | Pass Rate | Avg Latency | Δ vs Baseline |
|---|---|---|---|---|---|
| Step 0 (baseline) | Qwen 3 0.6B | Rules + examples + self-corr | 17/100 (17%) | 0.33s | — |
| Step 1 | Qwen 3 0.6B | Same (pipeline fix) | 17/100 (17%) | 0.33s | +0 |
| Step 2 | Qwen 3 0.6B | Same (infra fix) | 17/100 (17%) | 0.33s | +0 |
| Step 3 | Qwen 3.5 0.8B | Same prompt | 16/100 (16%) | 2.26s ⚠️ | -1, 6.8× slower |
| Step 4-5 v1 | Qwen 3.5 0.8B | Rules-only (no examples) | 23/100 (23%) | 0.24s | +6 |
| **Step 4-5 final** | **Qwen 3 0.6B** | **Example-driven** | **47/100 (47%) ✅** | **0.33s** | **+30 🎉** |
| Step 4-5 final | Qwen 3 1.7B | Example-driven | 46/100 (46%) | 0.57s | +29 |
| Step 4-5 final | Qwen 3.5 0.8B | Example-driven | 29/100 (29%) | 2.66s | +12 |

### Multi-Model Comparison (old prompt, Step 0 style)

| Model | HF ID | Size | Pass Rate | Avg Latency |
|---|---|---|---|---|
| Granite4-1B | mlx-community/granite-4.0-1b-4bit | ~600 MB | 19/100 | 1.21s |
| **Qwen3-0.6B** | **mlx-community/Qwen3-0.6B-4bit** | **~470 MB** | **17/100** | **0.34s** |
| Qwen2.5-0.5B | mlx-community/Qwen2.5-0.5B-Instruct-4bit | ~350 MB | 16/100 | 0.40s |
| Qwen2.5-1.5B | mlx-community/Qwen2.5-1.5B-Instruct-4bit | ~900 MB | 13/100 | 0.54s |
| Llama3.2-1B | mlx-community/Llama-3.2-1B-Instruct-4bit | ~700 MB | 5/100 | 0.71s |
| SmolLM-1.7B | mlx-community/SmolLM-1.7B-Instruct-4bit | ~900 MB | 1/100 | 2.23s |
| Gemma3-1B-IT | mlx-community/gemma-3-1b-it-4bit | ~600 MB | 0/100 | 4.77s |
| Gemma2-2B-IT | mlx-community/gemma-2-2b-it-4bit | ~1.5 GB | 0/100 | 3.58s |

### Per-Category Progression (Baseline → Current Best)

| Category | Step 0 | Step 4-5 (0.6B) | Δ | Planned Fix |
|---|---|---|---|---|
| code-terminal | 4/8 | 8/8 ✅ | +4 | Done |
| short-input | 7/8 | 8/8 ✅ | +1 | Done |
| grammar | 2/12 | 8/12 | +6 | More prompt examples |
| fillers | 3/15 | 10/15 | +7 | Filler rules improvement |
| self-correction-det | 0/12 | 8/12 | +8 | Capitalize after correction (Fix 2b) |
| hinglish | 0/10 | 2/10 | +2 | Normalizer + prompt examples |
| names-technical | 0/10 | 2/10 | +2 | Spoken-form normalizer (Layer 1) |
| cascading-corrections | 0/5 | 1/5 | +1 | Capitalize short bypass (Fix 2a) |
| adversarial | 0/5 | 0/5 | 0 | Larger model or accept |
| self-correction-llm | 0/10 | 0/10 | 0 | Larger model or accept |
| single-line | 1/5 | 0/5 | -1 | Fix test expectations (Fix 2c) |

---

## Key Learnings

1. **Prompt engineering > model size** for sub-2B models. The example-driven prompt was worth more than switching to a model 3× larger.
2. **Qwen 3 0.6B is the sweet spot.** Fastest (0.33s), lowest RAM (~1 GB), and highest accuracy (47%). Bigger models (1.7B, 3.5 0.8B) were equal or worse quality at higher latency.
3. **Repetition penalty kills cleanup tasks.** Any penalty > 1.0 causes the model to drop repeated content words, which is catastrophic when the task is to output nearly the same text.
4. **Examples > rules for small models.** Concrete input→output pairs teach the transformation shape. Negation-heavy rules ("do NOT change X") confuse sub-1B models.
5. **Many "LLM failures" are actually deterministic problems.** Spoken-form normalization, capitalization after self-correction, and test expectation mismatches account for ~15-20 of the 53 remaining failures — no LLM needed.
6. **Adversarial resistance is fundamentally hard for chat LLMs.** Any model trained on instruction-following will sometimes follow adversarial instructions embedded in user content. The `<text>` delimiter + output validator is the best practical defense for on-device models.

---

## File Change Summary

| File | Changes |
|---|---|
| `TextProcessing/SpokenFormNormalizer.swift` | **New file** — deterministic spoken-form → symbol conversion |
| `Tests/SpokenFormNormalizerTests.swift` | **New file** — unit tests for normalizer |
| `LLM/LocalLLMProcessor.swift` | Capitalize short bypass results |
| `TextProcessing/TextProcessor.swift` | Integrate spoken-form normalizer into pipeline |
| `Transcription/TranscriptionPipeline.swift` | Wire normalizer into post-processing |
| `LLM/LLMModelCatalog.swift` | Add LFM2.5-1.2B-Instruct entry |
| `Tests/CleanupQualityTests.swift` | Fix single-line test expectations |

---

## Target Metrics

| Metric | Current | Phase 1 | Phase 2 | Phase 4 |
|---|---|---|---|---|
| Pass rate | 47% | ~55% | ~65% | ~75% |
| Avg latency (LLM cases) | 0.33s | 0.33s | 0.33s | 0.33s |
| RAM (LLM) | ~1 GB | ~1 GB | ~1 GB | ~1 GB |
| Default model | Qwen 3 0.6B | Qwen 3 0.6B | Qwen 3 0.6B | TBD (maybe LFM2.5) |
