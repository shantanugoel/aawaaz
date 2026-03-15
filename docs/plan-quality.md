# LLM Cleanup Quality Plan: 47% → 85%+

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
| **adversarial** | 0/5 | Chat models fundamentally follow instructions. "Ignore previous" tricks a 0.6B model every time | Output validator improvements; Cadence-Fast immune to injection; larger model; or accept |
| **names-technical** | 2/10 | "dot"→".", "slash"→"/", capitalization of tech terms (Kubernetes, AWS) | **Deterministic spoken-form normalizer** + Whisper prompt conditioning |
| **hinglish** | 2/10 | Poor Devanagari/romanized handling, wrong capitalization patterns | Cadence-Fast (native Hindi support) + prompt examples + Whisper prompt tuning |
| **single-line** | 0/5 | Model adds periods but test expects none; "colon" not converted | Fix test expectations + spoken-form normalizer |
| **cascading-corrections** | 1/5 | Deterministic reducer → <4 words → LLM bypass → no capitalization | Fix bypass to still capitalize short results |
| **fillers** | 10/15 | 5 remaining: "like" preserved incorrectly, sentence-start "so" not removed | Improve filler removal rules |
| **self-correction-det** | 8/12 | 4 remaining: capitalization issues after correction | Post-correction capitalization fix |
| **grammar** | 8/12 | 4 remaining: edge cases (wrong contraction, missing comma) | Cadence-Fast handles punctuation; LLM focuses on grammar only; context injection |

---

## Competitive Analysis: WisprFlow

Understanding the market leader's approach helps identify what matters most.

**WisprFlow architecture (cloud-only):**
- ASR inference: <200ms server-side
- LLM inference: <200ms (fine-tuned Llama on Baseten with TensorRT-LLM)
- Total latency budget: <700ms end-to-end (p99)
- Processes 1 billion dictated words per month

**WisprFlow's quality advantages:**
- **Context-conditioned ASR** — incorporates speaker qualities, surrounding context, and user history to resolve ambiguous audio
- **Personalized LLM formatting** — maintains individual style preferences (dash usage, capitalization rules, punctuation choices). They note "LLMs are phenomenal at recall, but very low precision" for style
- **Deep context awareness** — reads active app name, recipient names from emails, surrounding text in apps like Notion (not password fields). On Android, analyzes text visible near the dictation field
- **Style adaptation per app category** — professional for email, casual for Slack, code-aware for IDEs
- **Learning from corrections** — captures device-level edits, determines edit applicability across contexts, trains local RL policies, aligns LLM output to individual style preferences
- **Self-correction handling** — "We should meet tomorrow, no wait, let's do Friday" → "We should meet up on Friday."

**Where Aawaaz can compete:**
- WisprFlow is cloud-only → privacy-conscious users prefer on-device
- WisprFlow requires subscription → Aawaaz can be free/one-time purchase
- WisprFlow's context awareness and per-user personalization are replicable on-device
- The gap is not model size — it's context injection and personalization

**Sources:** [WisprFlow Technical Challenges](https://wisprflow.ai/post/technical-challenges), [WisprFlow on Baseten](https://www.baseten.co/resources/customers/wispr-flow/), [WisprFlow Context Awareness](https://docs.wisprflow.ai/articles/4678293671-feature-context-awareness)

---

## Plan: Nine Layers to 85%+

### Layer 0: Evaluation Overhaul — LLM-as-Judge

**Expected impact: Rebaseline from 47% to ~58% with zero code changes**

The current 47% pass rate likely *underestimates* actual quality by 10-15 points. Exact string matching penalizes acceptable alternatives:

| Input | Expected | Actual | Verdict |
|---|---|---|---|
| "meeting on tuesday" | "Meeting on Tuesday" | "Meeting on Tuesday." | FAIL (trailing period) |
| "i will send it" | "I'll send it" | "I will send it." | FAIL (contraction preference) |
| "lets meet at 3" | "Let's meet at 3" | "Let's meet at 3." | FAIL (period) |
| "the api is at slash users" | "The API is at /users" | "The API is at /users." | FAIL (period) |

These are all *correct* cleanup outputs. The test is wrong, not the model.

**Implementation:**

Add an LLM-as-Judge scoring pass alongside exact match. Use Claude API (or GPT-4) as a judge on failing cases.

```python
# Offline scoring script (not in the app)
prompt = """
Score this dictation cleanup on four dimensions (0.0 to 1.0):

1. Semantic preservation: Does the output mean the same as the input?
2. Formatting quality: Is punctuation, capitalization, spacing correct?
3. Content fidelity: Were all content words preserved (no hallucination/drops)?
4. Intent match: Would a reasonable user accept this output?

Input (raw dictation): {input}
Expected output: {expected}
Actual output: {actual}

Score each dimension, then give an overall PASS/FAIL.
A case PASSES if all dimensions score >= 0.75.
"""
```

**Keep the exact-match test as a regression gate** but use the judge score as the primary quality metric. This prevents wasting effort on cases that are already acceptable.

**What you gain:**
- Accurate baseline (probably ~58% instead of 47%)
- Tells you which remaining failures are *real* problems worth fixing vs evaluation noise
- Prevents wasting effort on cases that are already acceptable
- Multi-dimensional scoring reveals whether the problem is punctuation, grammar, content preservation, or hallucination — guiding which layer to invest in

**Other evaluation approaches worth knowing about:**
- **BERTScore** — uses contextual embeddings for semantic similarity. Handles synonyms/paraphrases. 59% alignment with human judgment (vs 47% for BLEU). Available as `bert-score` Python package.
- **HEVAL** — hybrid evaluation for ASR, combines semantic correctness and error rate. 49x faster than BERTScore. Published at ICASSP 2024.
- **SeMaScore** — semantic evaluation metric designed specifically for ASR tasks. Presented at Interspeech 2024.

**Cost:** ~2 hours to build a Python script. One-time Claude API cost for 53 failing cases is negligible (~$0.10).

**Latency/memory:** Zero — offline evaluation only.

---

### Layer 1: Deterministic Spoken-Form Normalizer (Swift, no model)

**Expected impact: +8-12 pass rate** (fixes names-technical, single-line, some hinglish)

**Status: Implementation started** — `SpokenFormNormalizer.swift` exists with unambiguous patterns, URLs, emails, paths, dotted names, label colons, command-line patterns, and ellipsis handling.

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

### Layer 1b: Number/Date Inverse Text Normalization (Swift, no model)

**Expected impact: +3-5 pass rate** (fixes number/date cases in names-technical, grammar, hinglish)

The SpokenFormNormalizer handles symbols but completely misses **number normalization**, which is a large class of dictation errors that no LLM handles well:

| Spoken | Expected Written | Current output |
|---|---|---|
| "one hundred twenty three" | "123" | "one hundred twenty three" |
| "march fifteenth twenty twenty six" | "March 15th, 2026" | "march fifteenth twenty twenty six" |
| "two thirty PM" | "2:30 PM" | "two thirty PM" |
| "fifty dollars" | "$50" | "fifty dollars" |
| "ninety nine point five percent" | "99.5%" | "ninety nine point five percent" |
| "eight hundred five five five one two three four" | "805-555-1234" | "eight hundred five five five one two three four" |

#### Implementation approach

**Option A — Lean (recommended for v1):** ~200 lines of Swift
- Cardinal numbers: word sequences → digits using a lookup + accumulator pattern
  - Ones: one→1, two→2, ..., nineteen→19
  - Tens: twenty→20, thirty→30, ..., ninety→90
  - Multipliers: hundred→×100, thousand→×1000, million→×1000000
  - Accumulate: "one hundred twenty three" → 100 + 20 + 3 → "123"
- Ordinals: "first"→"1st", "second"→"2nd", "twenty third"→"23rd"
- Phone numbers: detect 7-10 digit sequences in word form, format as XXX-XXX-XXXX
- Times: "X thirty"→"X:30", "X fifteen"→"X:15", plus AM/PM handling
- Context guard: only normalize in dictation contexts, not in prose ("I have two dogs" stays as-is in creative writing, becomes "I have 2 dogs" in notes)

**Option B — Comprehensive:** Port NVIDIA NeMo's ITN WFST rules to Swift
- NeMo handles numbers, dates, times, currency, measures, ordinals, addresses
- WFST-based (finite state transducers) — fully deterministic and fast
- The rule set is open-source (Python/Pynini): [NeMo ITN paper (arXiv:2104.05055)](https://arxiv.org/abs/2104.05055)
- Heavy lift but handles every edge case including "two and a half million dollars" → "$2.5M"
- Also has a neural approach: **Thutmose Tagger** — SOTA sentence accuracy on English and Russian

**Interesting research:** [Interspeech 2024 paper by Choi et al.](https://www.isca-archive.org/interspeech_2024/choi24_interspeech.html) proposes K-ITN model that uses LLMs for context-dependent ITN — resolving ambiguities like "two" → "2" vs "two" → "too". Worth monitoring.

**Pipeline position:** After SpokenFormNormalizer, before Cadence-Fast/LLM.

**Latency:** <1ms (pure string manipulation with lookup tables).
**Memory:** ~0 (in-memory lookup tables, negligible).

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

### Layer 3: Whisper Prompt Conditioning (zero-cost quality boost)

**Expected impact: +3-5 pass rate** (improves names-technical, grammar upstream of the pipeline)

The plan previously treated ASR output as a fixed input. It's not — Whisper's `initial_prompt` parameter conditions the decoder's style, capitalization, and vocabulary with **zero latency cost**.

#### How Whisper prompt conditioning works

Whisper reads the last 224 tokens (~900 characters) of the `initial_prompt`. A well-punctuated prompt makes Whisper produce punctuated output. Including proper nouns makes Whisper spell them correctly.

#### Static prompt (always set)

```swift
// In Whisper configuration
let initialPrompt = """
Hello, this is a properly formatted dictation with correct punctuation. \
Technical terms like Kubernetes, PostgreSQL, TypeScript, Next.js, React, \
AWS, Docker, and Terraform should be spelled correctly. \
Names and places should be capitalized properly.
"""
```

**What this changes upstream:**
- Whisper starts outputting capitalized sentences with periods/commas more consistently
- Technical terms that Whisper currently mangles (`kubernetties` → `Kubernetes`) get spelled correctly when in the prompt
- Grammar and punctuation arrive cleaner, reducing LLM cleanup burden

#### Dynamic prompt (context-dependent)

Inject context-specific vocabulary into the Whisper prompt:

```swift
// If user is writing an email to "Sarah Chen"
let dynamicPrompt = basePrompt + " Sarah Chen, Q3 report, marketing budget."

// If user is in a code editor
let dynamicPrompt = basePrompt + " git commit, pull request, npm install, API endpoint."
```

This is especially powerful for names — Whisper will spell injected proper nouns correctly instead of guessing.

#### Hinglish-specific prompt tuning

Experiment with `language` parameter:
- `language="hi"` — Whisper produces Devanagari-heavy output, better for Hindi-dominant speech
- `language="en"` — Whisper produces English-heavy output, may miss Hindi words
- No language set — Whisper auto-detects, may flip between segments

For Hinglish users, setting `language="hi"` with a romanized-Hindi prompt may give the best code-switching behavior. Test empirically.

**Hinglish-specific ASR models worth evaluating:**
- **Whisper-Hindi2Hinglish-Apex** ([Oriserve](https://huggingface.co/Oriserve/Whisper-Hindi2Hinglish-Apex)): Fine-tuned Whisper specifically for Hindi/Hinglish, ~42% average improvement over pretrained Whisper. Uses dynamic layer freezing. Ranked #1 on Speech-To-Text Arena.
- **IndicWhisper-JAX** ([GitHub](https://github.com/parthiv11/IndicWhisper-JAX)): Optimized speech-to-text for Hindi, English, and Hinglish.
- **Language family-based prompt tuning** ([arXiv:2412.19785](https://arxiv.org/html/2412.19785v1)): Hindi, Gujarati, Marathi, Bengali share prompts within the Indo-Aryan family for better Whisper performance. Custom tokenizer reduces Hindi token count from 27 to 19 tokens.

**Research references:** [Whisper Prompt Understanding Study (arXiv:2406.05806)](https://arxiv.org/html/2406.05806v2), [OpenAI Whisper Prompting Guide](https://developers.openai.com/cookbook/examples/whisper_prompting_guide), [Sotto Blog](https://sotto.to/blog/improve-whisper-accuracy-prompts)

**Latency:** 0ms added (prompt conditioning is just setting a parameter).
**Memory:** 0 bytes added.

---

### Layer 4: Surrounding Text Context Injection

**Expected impact: +5-8 pass rate** (improves grammar, hinglish, single-line by giving the LLM context)

This is WisprFlow's key quality differentiator. They read surrounding text from the focused app and inject it into the LLM prompt. Aawaaz already has the infrastructure (`InsertionContext` with `appCategory`, `fieldType`, and AX API access for text insertion) but doesn't use the most valuable signal: **what text is already on screen**.

#### What to capture

```swift
// Extension to InsertionContext — you already use AX for text insertion
extension InsertionContext {
    /// Grab ~200 characters before the cursor position from the focused text field
    var surroundingText: String? {
        guard let element = focusedElement else { return nil }
        guard let fullText = element.value(forAttribute: .value) as? String else { return nil }
        guard let range = element.value(forAttribute: .selectedTextRange) else { return nil }
        // Extract up to 200 chars before cursor
        let cursorPos = range.location
        let start = max(0, cursorPos - 200)
        return String(fullText[start..<cursorPos])
    }
}
```

#### What to inject into the LLM prompt

```
The user is dictating in [Mail], continuing after:
"Hi Sarah,\n\nThanks for sending the Q3 report. I wanted to follow up on"

Clean up the following dictation:
<text>the budget numbers you mentioned specifically the marketing spend which seemed higher than expected</text>
```

#### What this enables

| Scenario | Without context | With context |
|---|---|---|
| Continuing a sentence | LLM capitalizes first word (wrong) | LLM sees incomplete sentence → lowercase continuation |
| Email to "Sarah" | LLM may lowercase names | LLM sees "Sarah" in context → consistent capitalization |
| Code comment | LLM formats as prose | LLM sees `//` or `/*` → code comment style |
| Slack message | LLM adds periods/formality | LLM sees casual thread → casual tone |
| Professional doc | LLM may be too casual | LLM sees "Q3 report" → maintains formal register |

#### Privacy considerations

Must exclude sensitive contexts:
- Password fields (check `AXSubrole` for `AXSecureTextField`)
- Banking/financial apps (maintain a blocklist like WisprFlow's 136+ banking app list)
- Any field where `isSecureTextEntry` is true
- Context never leaves the device — this is on-device only, so privacy is inherent

#### Prompt budget management

Surrounding context competes with the system prompt for the model's attention window. Limit to ~200 chars (< 60 tokens) and place *before* the cleanup instruction so the model prioritizes the task over context memorization.

**Reference:** [Superwhisper's context implementation](https://superwhisper.com/docs/modes/super) uses Application Context, Selected Text Context, and Clipboard Context similarly.

**Latency:** ~1-2ms for AX API query (negligible).
**Memory:** ~0 (a string in the prompt).

---

### Layer 5: Cadence-Fast — Dedicated Punctuation/Capitalization Model

**Expected impact: +10-15 pass rate** (major improvements across grammar, single-line, names-technical, hinglish)

**This should NOT be deferred.** The 0.6B Qwen model is currently doing *three jobs at once*: punctuation, capitalization, and grammar/style cleanup. Punctuation and capitalization are the hardest for a small autoregressive model because they require bidirectional context. Cadence-Fast is a **270M bidirectional encoder** — architecturally superior for exactly this task, and it can't hallucinate or follow injection prompts.

#### ai4bharat/Cadence-Fast

| Property | Value |
|---|---|
| Base model | Gemma-3-270M (bidirectional encoder via MNTP) |
| Size | ~150 MB |
| Task | Token classification (punctuation restoration) |
| Punctuation classes | 30 distinct classes including Indic-specific symbols |
| Languages | English + Hindi + 21 other Indic languages |
| Inference | Single-pass encoder (not autoregressive) — immune to prompt injection |
| Features | Periods, commas, question marks, exclamation marks, colons, semicolons, Hindi danda, etc. |
| Capitalization | Rule-based (included in `cadence-punctuation` Python package) |
| Performance | 93.8% of full Cadence (1B) performance |
| License | MIT |

#### Why this is the highest-impact model addition

1. **Offloads the hardest task from Qwen.** Punctuation and capitalization become deterministic. The LLM prompt simplifies to "fix grammar and improve sentence flow" — a much easier task for a 0.6B model.
2. **Bidirectional > autoregressive for punctuation.** Cadence sees the whole sentence at once. Qwen generates left-to-right and often gets end-of-sentence punctuation wrong.
3. **Native Hindi support.** Cadence supports all 22 Indian scheduled languages. Qwen does NOT list Hindi. For Hinglish cases, Cadence handles punctuation dramatically better.
4. **Immune to adversarial inputs.** It's a token classifier, not a chat model. "Ignore previous instructions" is just text to tag — it can't follow injected commands.
5. **Fast.** Single-pass encoder inference is ~10-30ms, not 330ms of autoregressive generation.

#### Revised pipeline with Cadence-Fast

```
ASR (Whisper, prompt-conditioned)
    ↓
Deterministic cleanup (TextProcessor)
├── Self-correction detection
├── Filler removal
├── Spoken-form normalization
└── Number/date ITN
    ↓
Cadence-Fast (punctuation + capitalization)  ← NEW LAYER
    ↓
LLM (grammar + style ONLY)  ← SIMPLIFIED TASK
    ↓
Text insertion
```

**What changes for the LLM:** With punctuation and capitalization already handled, the LLM system prompt becomes simpler and more focused. The model can focus on grammar corrections, sentence flow, and style adaptation — tasks where autoregressive generation is actually superior. Could drop to `.light` cleanup level for most cases with better results.

#### Implementation path

1. Export Cadence-Fast to ONNX via PyTorch's `torch.onnx.export`
2. Load via ONNX Runtime (same infrastructure already used for Silero VAD)
3. Run as token classifier: input tokens → output labels (PERIOD, COMMA, QUESTION, CAPITALIZE, etc.)
4. Apply labels to reconstruct punctuated/capitalized text
5. Feed to LLM for grammar only

#### Alternative: CoreML conversion

If ONNX Runtime adds too much complexity, Cadence-Fast can be converted to CoreML:
```bash
# Via coremltools
import coremltools as ct
traced = torch.jit.trace(model, sample_input)
mlmodel = ct.convert(traced, inputs=[ct.TensorType(shape=sample_input.shape)])
mlmodel.save("CadenceFast.mlpackage")
```

CoreML has the advantage of Apple's hardware acceleration (Neural Engine) on M-series chips.

#### Other punctuation/capitalization models worth knowing about

| Model | Architecture | Size | Languages | Notes |
|---|---|---|---|---|
| **AssemblyAI Universal-2-TF** | BERT (110M) + BART (139M) two-stage | ~250M total | English | 81.2% human preference; handles punctuation + truecasing + ITN. [arXiv:2501.05948](https://arxiv.org/html/2501.05948v1) |
| **deepmultilingualpunctuation** | XLM-RoBERTa | ~278M | Multilingual | Open-source PyPI package. [GitHub](https://github.com/oliverguhr/deepmultilingualpunctuation) |
| **AssemblyAI Truecaser** | Canine + BiLSTM (character-level) | ~50M | English | 39% F1 improvement on mixed-case words, 20% on acronyms. [Blog](https://www.assemblyai.com/blog/introducing-our-new-punctuation-restoration-and-truecasing-models) |

**Research references:**
- [Cadence on HuggingFace](https://huggingface.co/ai4bharat/Cadence)
- [Cadence-Fast on HuggingFace](https://huggingface.co/ai4bharat/Cadence-Fast)
- [Mark My Words paper (arXiv:2506.03793)](https://arxiv.org/abs/2506.03793)

**Latency:** ~10-30ms (single-pass encoder, not autoregressive). Total pipeline: 0.33s → ~0.36s.
**Memory:** ~150-200MB additional. Total: ~1.2 GB, still well within budget.

---

### Layer 6: Test One More LLM Model

**Expected impact: +5-10 pass rate** (may fix self-correction-llm, adversarial, remaining grammar)

**Note:** With Cadence-Fast handling punctuation/capitalization, the LLM's job is now grammar + style only. This makes model evaluation more meaningful — we're testing grammar capability, not punctuation capability.

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
4. If pass rate ≤ 47%: stop searching for general-purpose LLMs and focus on other layers

**Important caveat — Hindi support:**
LFM2.5 lists Arabic/Chinese/Japanese/Korean/Spanish/French/German/English but does NOT list Hindi. It may perform poorly on Hinglish. Test the 10 Hinglish cases specifically. With Cadence-Fast handling Hindi punctuation, the LLM only needs to handle Hindi grammar — a smaller gap.

---

### Layer 7: User Correction Tracking (Personalization — Long-Term Moat)

**Expected impact: Not measurable on 100-case benchmark (personalization). This is the feature that makes users *stay*.**

WisprFlow's deepest competitive moat is personalization — they track what users edit after dictating and adapt future output. Aawaaz currently has zero personalization.

#### Phase 1: Capture correction pairs (start now, use later)

Track when the user edits text within ~30 seconds of dictation insertion:

```swift
struct CorrectionPair {
    let originalDictation: String    // what Aawaaz inserted
    let userEdit: String             // what the user changed it to
    let appContext: InsertionContext  // what app, what field type
    let timestamp: Date
}

// Store in a local SQLite database
// Key: (original, edit, app_bundle_id, field_type, timestamp)
```

**How to detect edits:**
- After inserting text, monitor the focused text field via AX API for ~30 seconds
- If the text content changes in the region where you inserted, capture the diff
- Use a simple debounce — wait for 2 seconds of no changes before capturing

**Storage:** SQLite database, ~1MB per 10,000 correction pairs. Negligible.

#### Phase 2: Build user-specific overrides (after ~50 corrections)

Analyze correction patterns:

| Pattern | Detection | Action |
|---|---|---|
| User always capitalizes "React" but Aawaaz outputs "react" | Same word corrected 3+ times | Add to capitalization override dictionary |
| User prefers "don't" over "do not" | Contraction preference in 5+ edits | Add contraction preference to LLM prompt |
| User removes trailing periods in Slack | Period removed in chat context 5+ times | Suppress trailing periods for chat apps |
| User always types "LGTM" not "Looks good to me" | Abbreviation preference in 3+ edits | Add abbreviation to deterministic replacement |

```swift
// User-specific dictionary, injected into LLM prompt
struct UserStylePreferences {
    var capitalizationOverrides: [String: String]  // "react" → "React"
    var contractionPreference: ContractionStyle     // .contracted or .expanded
    var trailingPeriodPreference: [AppCategory: Bool]  // .chat → false
    var abbreviations: [String: String]             // "looks good to me" → "LGTM"
}
```

#### Phase 3: Fine-tune LoRA adapters on user data (future)

After accumulating 500+ correction pairs, fine-tune Qwen LoRA adapters on the user's specific (input, correction) pairs. This is what WisprFlow does with their "local RL policies."

MLX supports LoRA/QLoRA fine-tuning on quantized models directly via `mlx-lm`. Memory usage is ~3.5x lower than full precision — feasible on Apple Silicon.

**Why start capturing now:** The data is the moat. Even if you don't use it for months, having a correction database from day one means you can train personalization models later with real user data.

**Latency:** 0ms for dictation (corrections captured asynchronously). Dictionary lookups add <1ms.
**Memory:** SQLite database ~1MB. Dictionary in memory ~negligible.

---

### Layer 8 (Future): Fine-Tuned Transduction Model

**Only if general-purpose LLMs plateau below 70% even with Layers 1-7.**

#### Approach A: Denoising LM (most promising research direction)

The "Denoising LM" paper ([arXiv:2405.15216](https://arxiv.org/abs/2405.15216)) is highly relevant:
- Tested models at 69M, 155M, 484M, and 1B parameters
- Trained on synthetic data: TTS generates audio from clean text, ASR transcribes it to produce noisy hypotheses, model learns noisy→clean mapping
- Training data: 800M words from text corpora, 1:9 real:synthetic mixing ratio
- Even 69M parameter model showed strong improvement (WER 5.3% → 3.3% on LibriSpeech test-other)
- Key insight: you can train the model with **text-only data** by simulating ASR errors

**Application to Aawaaz:**
1. Take a large corpus of well-written English+Hinglish text
2. Simulate ASR errors: remove punctuation, lowercase everything, add fillers, add spoken number words, add spoken symbols
3. Train Qwen3-0.6B-Base (not instruct) on (simulated-ASR, clean) pairs with LoRA
4. No chat template needed — plain input→output mapping, greedy decoding

#### Approach B: GECToR-style sequence tagging

Grammarly's [GECToR](https://github.com/grammarly/gector) uses sequence tagging (not seq2seq) for grammatical error correction:
- 10x faster inference than Transformer seq2seq
- Uses custom token-level transformations to map input to corrections
- Pre-trained on synthetic data, fine-tuned in two stages
- Could replace the LLM entirely for grammar correction at ~10ms inference

#### Approach C: Direct LoRA fine-tuning on dictation pairs

Fine-tune Qwen3-0.6B-Base or LFM2.5-1.2B-Base on dictation cleanup pairs using MLX LoRA:
- Train on: ASR-like raw transcripts → cleaned text (100 test cases + 500-1000 more)
- Hinglish + English + technical text
- Adversarial/injection examples (output = input with punctuation)
- Spoken symbol forms
- Many identity cases (output = input, no change needed)

Use plain input→output mapping, greedy decoding, no chat template.

This is the nuclear option. Only pursue if:
- Layer 1-7 pass rate stalls below 70%
- You're willing to invest 2-3 days in dataset creation + training

---

### Layer 9 (Future): Apple Foundation Models API

**Available in macOS 26 (shipping fall 2026).**

Apple's on-device Foundation Models framework provides a ~3B parameter model to third-party apps:
- Free inference, works offline, all data stays on-device
- Guided generation (structured output) built in
- Entity extraction, text refinement, summarization are listed use cases
- No model download required — ships with the OS
- Apple-optimized for Neural Engine acceleration on M-series chips

This could eventually replace Qwen entirely:
- Larger model (3B vs 0.6B) with better instruction following
- Zero download/setup friction for users
- Guided generation prevents hallucination

**Action:** When macOS 26 beta lands, benchmark Foundation Models on the 100-case test suite. If it beats Qwen at lower latency, add it as the default backend with Qwen as fallback for macOS 15.

**Reference:** [Apple Foundation Models documentation](https://developer.apple.com/documentation/FoundationModels), [Apple Foundation Models Tech Report](https://machinelearning.apple.com/research/apple-foundation-models-tech-report-2025)

---

## Additional Research: Techniques Worth Monitoring

### Constrained Decoding for the LLM

The current `outputDroppedTooMuch` check (rejects if >40% content dropped) is a crude version of constrained decoding. More principled approaches exist:

| Technique | Description | Reference |
|---|---|---|
| **N-best Constrained Decoding** | Force the LLM to only generate sentences within the ASR N-best hypothesis list | [arXiv:2409.09554](https://arxiv.org/abs/2409.09554) |
| **N-best Closest Decoding** | Generate unconstrained, then find the hypothesis with smallest Levenshtein distance | Same paper |
| **DOMINO** | Regex/grammar constraints aligned to BPE subwords, zero overhead | ICML 2024 |
| **XGrammar** | Grammar constraints with minimal overhead | [GitHub](https://github.com/mlc-ai/xgrammar) |

These prevent the hallucination/summarization problem more elegantly than post-hoc validation. Worth exploring if the LLM continues to produce content drops.

### Whisper Word-Level Confidence Scores

Use per-word confidence scores to tell the LLM which words might be wrong:

- **whisper-timestamped**: DTW on cross-attention weights provides per-word confidence. [GitHub](https://github.com/linto-ai/whisper-timestamped)
- **Stable-ts**: Access predicted timestamp tokens without additional inference
- Recent paper ([arXiv:2502.13446](https://arxiv.org/abs/2502.13446)): fine-tune Whisper to produce scalar confidence scores

Application: flag words below confidence threshold (e.g., 0.90) in the LLM prompt so it knows which words to potentially correct vs which to preserve exactly.

### Disfluency Detection Research

- **H-UDM (Hierarchical Unconstrained Disfluency Modeling)**: EACL 2024, eliminates need for extensive manual annotation
- **Audio-based disfluency detection**: directly from audio without transcription, outperforms ASR-based text approaches (Microsoft Research 2024)
- **LLM-based detection**: LLaMA 3 70B evaluated for disfluency detection (2024 STIL workshop paper)
- Target classes: filled pauses, repetitions, revisions, restarts, partial words

---

## Implementation Order (Revised)

### Phase 0: Evaluation Overhaul (2 hours)

1. **Layer 0** — build LLM-as-Judge scoring script
2. Re-score all 53 failing cases → establish true baseline
3. Expected rebaseline: **47% → ~58%** (no code changes, judge scoring)

### Phase 1: Quick Wins (1 day)

4. **Fix 2a** — capitalize short bypass results
5. **Fix 2b** — capitalize after self-correction detection
6. **Fix 2c** — update single-line test expectations
7. Run benchmark → expect **~63%** (with judge scoring)

### Phase 2: Spoken-Form & Number Normalization (1-2 days)

8. **Layer 1** — complete `SpokenFormNormalizer` integration (implementation already started)
9. **Layer 1b** — implement `NumberNormalizer` (cardinal/ordinal numbers, times)
10. Write unit tests for both normalizers
11. Integrate into pipeline (after fillers, before LLM)
12. Run benchmark → expect **~68%**

### Phase 3: Whisper & Context (1 day)

13. **Layer 3** — add Whisper prompt conditioning (static + dynamic)
14. **Layer 4** — capture surrounding text via AX API, inject into LLM prompt
15. Run benchmark → expect **~73%**

### Phase 4: Cadence-Fast Integration (2-3 days)

16. Export Cadence-Fast to ONNX or CoreML
17. Integrate into pipeline between normalizers and LLM
18. Simplify LLM prompt to grammar-only (remove punctuation/capitalization instructions)
19. Run benchmark → expect **~80-83%**

### Phase 5: LFM2.5 Evaluation (half day)

20. Add LFM2.5 to `LLMModelCatalog`
21. Run benchmark with grammar-only prompt (Cadence handles punctuation)
22. Compare pass rate and latency vs Qwen 3 0.6B
23. Decision: adopt LFM2.5 as an option, or keep Qwen 3 0.6B as default
24. Run benchmark → expect **~83-85%**

### Phase 6: Prompt Tuning (1 day)

25. Add more prompt examples targeting remaining grammar failures:
    - Hinglish example with romanized Hindi preservation
    - Self-correction example (if LFM2.5 can handle it)
    - Grammar-focused examples (contractions, comma usage)
26. Tune example count (4 → 6-8) and measure quality vs. latency trade-off
27. Run benchmark → expect **~85%+**

### Phase 7: Personalization Foundation (ongoing)

28. Implement correction pair capture (background, non-blocking)
29. Build user-specific override dictionary after 50+ corrections
30. This is an ongoing effort, not a one-time phase

### Phase 8: Decide on Advanced Path

If pass rate is 80%+: **ship it**. The remaining failures (adversarial, implicit self-correction) are edge cases that don't affect typical dictation.

If pass rate is below 75%: evaluate Layer 8 (fine-tuning via Denoising LM or GECToR).

If on macOS 26: evaluate Apple Foundation Models as Qwen replacement.

---

## Benchmark Results History

### Complete Progression

| Step | Model | Prompt Style | Pass Rate | Avg Latency | Δ vs Baseline |
|---|---|---|---|---|---|
| Step 0 (baseline) | Qwen 3 0.6B | Rules + examples + self-corr | 17/100 (17%) | 0.33s | — |
| Step 1 | Qwen 3 0.6B | Same (pipeline fix) | 17/100 (17%) | 0.33s | +0 |
| Step 2 | Qwen 3 0.6B | Same (infra fix) | 17/100 (17%) | 0.33s | +0 |
| Step 3 | Qwen 3.5 0.8B | Same prompt | 16/100 (16%) | 2.26s | -1, 6.8× slower |
| Step 4-5 v1 | Qwen 3.5 0.8B | Rules-only (no examples) | 23/100 (23%) | 0.24s | +6 |
| **Step 4-5 final** | **Qwen 3 0.6B** | **Example-driven** | **47/100 (47%)** | **0.33s** | **+30** |
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
| code-terminal | 4/8 | 8/8 | +4 | Done |
| short-input | 7/8 | 8/8 | +1 | Done |
| grammar | 2/12 | 8/12 | +6 | Cadence-Fast + grammar-only LLM prompt + context injection |
| fillers | 3/15 | 10/15 | +7 | Filler rules improvement |
| self-correction-det | 0/12 | 8/12 | +8 | Capitalize after correction (Fix 2b) |
| hinglish | 0/10 | 2/10 | +2 | Cadence-Fast (native Hindi) + Whisper prompt tuning + context |
| names-technical | 0/10 | 2/10 | +2 | Spoken-form normalizer + Whisper prompt conditioning |
| cascading-corrections | 0/5 | 1/5 | +1 | Capitalize short bypass (Fix 2a) |
| adversarial | 0/5 | 0/5 | 0 | Cadence-Fast immune to injection; accept remaining for LLM |
| self-correction-llm | 0/10 | 0/10 | 0 | Better model (LFM2.5) or accept |
| single-line | 1/5 | 0/5 | -1 | Fix test expectations (Fix 2c) + context-aware formatting |

---

## Key Learnings

1. **Prompt engineering > model size** for sub-2B models. The example-driven prompt was worth more than switching to a model 3× larger.
2. **Qwen 3 0.6B is the sweet spot.** Fastest (0.33s), lowest RAM (~1 GB), and highest accuracy (47%). Bigger models (1.7B, 3.5 0.8B) were equal or worse quality at higher latency.
3. **Repetition penalty kills cleanup tasks.** Any penalty > 1.0 causes the model to drop repeated content words, which is catastrophic when the task is to output nearly the same text.
4. **Examples > rules for small models.** Concrete input→output pairs teach the transformation shape. Negation-heavy rules ("do NOT change X") confuse sub-1B models.
5. **Many "LLM failures" are actually deterministic problems.** Spoken-form normalization, capitalization after self-correction, and test expectation mismatches account for ~15-20 of the 53 remaining failures — no LLM needed.
6. **Adversarial resistance is fundamentally hard for chat LLMs.** Any model trained on instruction-following will sometimes follow adversarial instructions embedded in user content. The `<text>` delimiter + output validator is the best practical defense for on-device models. Cadence-Fast (non-LLM) is inherently immune.
7. **Exact string matching underestimates quality.** Many "failures" are acceptable alternatives (trailing periods, contraction preferences). LLM-as-Judge scoring is needed for accurate quality measurement.
8. **Context is the competitive moat, not model size.** WisprFlow uses much larger models server-side, but their quality advantage comes primarily from context injection (surrounding text, app awareness, user history) and personalization (learning from corrections).
9. **Decompose the LLM's task.** Rather than asking a 0.6B model to do punctuation + capitalization + grammar + style simultaneously, offload punctuation/capitalization to a specialized model (Cadence-Fast) and let the LLM focus on grammar/style only.
10. **Upstream improvements compound.** Whisper prompt conditioning improves ASR output → cleaner input to the deterministic pipeline → less work for the LLM → better final quality. Each layer's output is the next layer's input.

---

## File Change Summary

| File | Changes |
|---|---|
| `TextProcessing/SpokenFormNormalizer.swift` | **Exists** — deterministic spoken-form → symbol conversion |
| `TextProcessing/NumberNormalizer.swift` | **New file** — number/date/time inverse text normalization |
| `Tests/SpokenFormNormalizerTests.swift` | **Exists** — unit tests for normalizer |
| `Tests/NumberNormalizerTests.swift` | **New file** — unit tests for number normalizer |
| `LLM/LocalLLMProcessor.swift` | Capitalize short bypass results; simplify prompt (grammar-only with Cadence) |
| `TextProcessing/TextProcessor.swift` | Integrate spoken-form normalizer + number normalizer into pipeline |
| `Transcription/TranscriptionPipeline.swift` | Wire normalizers + Cadence-Fast into post-processing; add Whisper prompt conditioning |
| `TextInsertion/InsertionContext.swift` | Add `surroundingText` property via AX API |
| `Models/CadenceFastModel.swift` | **New file** — ONNX/CoreML wrapper for Cadence-Fast inference |
| `LLM/LLMModelCatalog.swift` | Add LFM2.5-1.2B-Instruct entry |
| `Tests/CleanupQualityTests.swift` | Fix single-line test expectations; add LLM-as-Judge scoring |
| `Persistence/CorrectionStore.swift` | **New file** — SQLite storage for user correction pairs |
| `TextProcessing/UserStylePreferences.swift` | **New file** — user-specific formatting overrides |
| `scripts/judge_score.py` | **New file** — offline LLM-as-Judge evaluation script |

---

## Target Metrics (Revised)

| Metric | Current | Phase 0-1 | Phase 2-3 | Phase 4-5 | Phase 6+ |
|---|---|---|---|---|---|
| Pass rate (exact match) | 47% | ~55% | ~62% | ~75% | ~80% |
| Pass rate (judge score) | ~58% | ~63% | ~68-73% | ~80-83% | ~85%+ |
| Avg latency (LLM cases) | 0.33s | 0.33s | 0.33s | 0.36s (+Cadence) | 0.36s |
| RAM (total models) | ~1 GB | ~1 GB | ~1 GB | ~1.2 GB (+Cadence) | ~1.2-2.2 GB |
| Default model | Qwen 3 0.6B | Qwen 3 0.6B | Qwen 3 0.6B | Qwen 3 0.6B | TBD (maybe LFM2.5) |
| Pipeline stages | 4 | 4 | 5 (+numbers) | 6 (+Cadence) | 6 |

---

## Architecture: Current vs Target Pipeline

### Current (47%)

```
Whisper → SelfCorrection → FillerRemoval → SpokenFormNorm → LLM (punct+caps+grammar+style) → Insert
```

### Target (85%+)

```
Whisper (prompt-conditioned)
    ↓
SelfCorrection → FillerRemoval → SpokenFormNorm → NumberNorm
    ↓
Cadence-Fast (punctuation + capitalization — bidirectional, 10-30ms)
    ↓
LLM (grammar + style ONLY — simplified task, context-injected)
    ↓
UserStyleOverrides (personalization dictionary)
    ↓
Insert (with correction tracking)
```

**Key architectural shift:** The LLM goes from being the *only* quality layer to being the *final* quality layer in a multi-stage pipeline. Each stage handles what it's best at:
- Deterministic rules: symbols, numbers, fillers, self-correction (0ms, perfect precision)
- Bidirectional encoder: punctuation, capitalization (10-30ms, high recall)
- Autoregressive LLM: grammar, style, tone (330ms, context-aware)
- User overrides: personalization (0ms, learned preferences)
