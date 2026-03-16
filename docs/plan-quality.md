# LLM Cleanup Quality Plan: 47% → 85%+

## Current State (after Phase 0-1-2-2.5-3-4S2-6 implementation + bug fixes)

The example-driven prompt redesign moved pass rate from **17% → 47%** on the 100-case benchmark. Phase 0-1-2 implementation (LLM-as-Judge, pipeline fixes, SpokenFormNormalizer) moved the measured scores to **50% exact-match, 61% judge pass rate**. Phase 2.5 (stabilization + deterministic fixes) moved scores to **64% exact-match, 79% judge pass rate**. Phase 3 (Whisper prompt conditioning + surrounding text context injection) maintains scores at **65% exact-match, 78% judge pass rate**. Phase 4 Step 2 (punctuation model Swift integration) moved scores to **61% exact-match, 84% judge pass rate** — exact match dropped slightly (expected outputs were tuned pre-punct-model) but real quality improved significantly. Bug fixes (input gating, normalization, memory leak, settings UI) maintain scores at **61% exact-match, 84% judge pass rate**. Phase 6 (prompt tuning — 3 conditional examples, Hindi particle rule, self-correction instruction, content-drop guard fix) moved scores to **62% exact-match, 85% judge pass rate**. Current best config: **Qwen 3 0.6B + xlm-roberta punct model, 0.37s LLM + 0.07s punct avg latency, ~2 GB RAM**.

> **Benchmark note:** Phase 3 scores (65% exact, 78% judge) are from a clean run with all layers active. The context injection instruction is conditional — only included when surrounding text is present, so benchmark tests (which have no surrounding text) run with the same prompt as Phase 2.5-P4. Score fluctuations vs Phase 2.5-P4 (64/79) are within normal LLM variance for a 0.6B model.

### What worked

| Change | Impact |
|---|---|
| Example-driven prompt (4 concrete input→output pairs) | Biggest win. Small models learn from examples, not rules. |
| Removed repetition penalty (1.1 → 1.0) | Stopped content drops. Cleanup = copying most input words. |
| `<text>` delimiters | Task framing + partial injection resistance. |
| Positive instructions ("Keep X" vs "Do NOT change X") | Small models follow affirmative instructions better. |
| Output content-drop validator | Catches catastrophic summarization/injection. |
| LLM bypass for short/code/terminal inputs | 16 cases trivially pass at 0.00s. |
| Post-correction capitalization (Fix 2a/2b) | Fixes lowercase output after self-correction and short bypass. |
| LLM-as-Judge evaluation (Layer 0) | Reveals 11 "false failures" — acceptable alternatives scored as fails by exact match. |
| SpokenFormNormalizer (Layer 1) | Deterministic URL/email/path/colon/dash conversion. **Implemented but awaiting benchmark verification.** |

### What's still failing (39 cases by judge, 50 by exact match)

| Category | Exact | Judge | Root Cause | Fix Approach |
|---|---|---|---|---|
| **self-correction-llm** | 5/10 | 7/10 | ~~Implicit corrections ("oh sorry", "no make that") need language understanding or expanded deterministic markers~~ **Fixed in Phase 2.5 P3.** 3 remaining: "well actually" (skipped — too ambiguous), LLM capitalization variance | ✅ Mostly done — 7/10 judge (+7 from 0) |
| **adversarial** | 1/5 | 2/5 | Chat models fundamentally follow instructions. 2/5 rescued by judge as acceptable passthrough | Punct model (token classifier) immune to injection; accept remaining for LLM |
| **names-technical** | 4/10 | 6/10 | Tech term capitalization (Kubernetes, AWS); spoken-form edge cases | Whisper prompt conditioning |
| **hinglish** | 2/10 | 3/10 | Missing punctuation/capitalization on Hinglish text; formatting_quality avg 0.44 | Punct model (Hindi Danda F1 96-97%) + Whisper prompt tuning; defer to Phase 4 |
| **single-line** | 4/5 | 5/5 | ~~Minor formatting edge cases~~ **Fixed in Phase 2.5 P4.** 1 remaining: LLM doesn't capitalize proper noun "John" | ✅ Mostly done — 5/5 judge |
| **cascading-corrections** | 4/5 | 5/5 | ~~Self-correction detector strips too aggressively~~ **Fixed in Phase 2.5 P2.** 1 remaining case needs semantic matching | ✅ Mostly done |
| **fillers** | 10/15 | 12/15 | 3 remaining after judge: "like" preserved incorrectly, sentence-start "so" not removed | Improve filler removal rules |
| **self-correction-det** | 9/12 | 11/12 | ~~Prefix loss in some corrections~~ **Mostly fixed in Phase 2.5 P2.** 3 remaining need LLM-level understanding | Overlap merge improved; remaining deferred |
| **grammar** | 8/12 | 11/12 | 1 remaining after judge: edge cases (comma placement, sentence splitting) | Punct model + grammar-only LLM prompt + context injection |

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

### Layer 0: Evaluation Overhaul — LLM-as-Judge ✅ DONE

**Status: Complete.** `scripts/llm_judge.py` (645 lines) scores failing cases on 4 dimensions using Gemini. Rebaselined from 47% exact to 61% judge pass rate (+14 points from judge rescue).

**Expected impact: Rebaseline from 47% to ~58% with zero code changes**
**Actual impact: Rebaselined to 61% judge pass (exceeded prediction)**

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

### Layer 1: Deterministic Spoken-Form Normalizer (Swift, no model) ✅ IMPLEMENTED

**Expected impact: +8-12 pass rate** (fixes names-technical, single-line, some hinglish)

**Status: Implementation complete** — `SpokenFormNormalizer.swift` (365 lines) with unambiguous patterns, URLs, emails, paths, dotted names, label colons, command-line patterns, and ellipsis handling. Integrated into `TextProcessor.swift:63`. 24 unit tests passing. **Awaiting benchmark verification** — current benchmark results appear to predate integration.

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

**Pipeline position:** After SpokenFormNormalizer, before punctuation model/LLM.

**Latency:** <1ms (pure string manipulation with lookup tables).
**Memory:** ~0 (in-memory lookup tables, negligible).

---

### Layer 2: Pipeline Fixes (Swift, no model) — Partially Done

**Expected impact: +5-8 pass rate** (fixes cascading-corrections, remaining fillers, self-correction-det)

#### Fix 2a: Capitalize short bypass results ✅ DONE

**Problem:** When deterministic self-correction reduces "the meeting is tuesday, scratch that, wednesday, actually no, thursday" to just "thursday", the word count is <4, so LLM is bypassed. Result: no capitalization.

**Fix:** Implemented in `LocalLLMProcessor.swift:74-81`. When short-input bypass triggers, capitalizes the first letter.

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

#### Fix 2b: Capitalize after deterministic self-correction ✅ DONE

**Problem:** `SelfCorrectionDetector` outputs lowercase results when the corrected text starts mid-sentence. E.g., "send to mark, scratch that, to john" → "to john" (lowercase).

**Fix:** Implemented in `TextProcessor.swift:37-50` + `SelfCorrectionDetector.swift:165-167`. If the entire result was produced by self-correction (≤50% of input words remain), capitalizes the first character in non-code/terminal contexts.

#### Fix 2c: Improve test expectations for single-line ✅ DONE

**Problem:** 5/5 single-line cases fail because the model adds a period (correct behavior for dictation cleanup) but tests expect no period. Also, "colon" is not converted to `:`.

**Fix:** Trailing period expectations updated. Colon conversion implemented in SpokenFormNormalizer and verified working. Post-LLM first-letter capitalization added to `LocalLLMProcessor.capitalizeStartIfAppropriate()`. Post-colon capitalization added for sentence-start labels in SpokenFormNormalizer. Current results: 4/5 exact match, 5/5 judge pass.

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

### Layer 5: Dedicated Punctuation/Capitalization Model — Evaluation & Selection

**Expected impact: +10-15 pass rate** (major improvements across grammar, single-line, names-technical, hinglish)

**This should NOT be deferred.** The 0.6B Qwen model is currently doing *three jobs at once*: punctuation, capitalization, and grammar/style cleanup. Punctuation and capitalization are the hardest for a small autoregressive model because they require bidirectional context. A dedicated **bidirectional encoder** is architecturally superior for exactly this task, and it can't hallucinate or follow injection prompts.

#### Why this is the highest-impact model addition

1. **Offloads the hardest task from Qwen.** Punctuation and capitalization become deterministic. The LLM prompt simplifies to "fix grammar and improve sentence flow" — a much easier task for a 0.6B model.
2. **Bidirectional > autoregressive for punctuation.** Encoder models see the whole sentence at once. Qwen generates left-to-right and often gets end-of-sentence punctuation wrong.
3. **Hindi support.** Hinglish punctuation (formatting_quality avg 0.44) is the worst dimension. A model with native Hindi support handles this dramatically better than Qwen (which does NOT list Hindi).
4. **Immune to adversarial inputs.** Token classifiers can't follow injected instructions — "Ignore previous instructions" is just text to tag.
5. **Fast.** Single-pass encoder inference is ~2-30ms, not 330ms of autoregressive generation.

#### Candidate Models to Evaluate

Three models were identified through deep research. The original plan proposed Cadence-Fast, but research revealed significant deployment concerns and two stronger alternatives.

##### Candidate A: `1-800-BAD-CODE/punct_cap_seg_47_language` (PRIMARY — Recommended)

| Property | Value |
|---|---|
| HuggingFace | [1-800-BAD-CODE/punct_cap_seg_47_language](https://huggingface.co/1-800-BAD-CODE/punct_cap_seg_47_language) |
| Architecture | Custom 6-layer Transformer encoder (512-dim), SentencePiece tokenizer (64k vocab), multi-head pipeline |
| Parameters | **~40M** |
| Disk size | ~160 MB (ONNX) |
| Languages | **47 languages** including English, Hindi, Chinese, Japanese, Arabic |
| Punctuation classes | ~17 post-punctuation + pre-punctuation (language-specific: Danda, Arabic question mark, CJK stops) |
| Capitalization/Truecasing | **Neural** per-character multi-label (handles NATO, McDonald's, mRNA, API, iOS) |
| Sentence segmentation | **Yes** (bonus — can detect sentence boundaries for better downstream processing) |
| ONNX | **Native** — distributed as ONNX + SentencePiece (no export work needed) |
| License | Apache 2.0 |
| Max sequence length | **128 tokens** (handles longer via overlapping sliding windows in `punctuators` package) |
| F1 (English) | Period: 88.3%, Comma: 67.9%, Truecasing: 90.5% |
| F1 (Hindi) | Danda: **96.9%**, Truecasing: **92.7%** |
| Python package | `punctuators` on PyPI (clean ONNX inference wrapper) |
| Est. inference | **~2-5ms** on Apple Silicon |

**Why this is the top candidate:**
- **7x smaller** than Cadence-Fast (40M vs 270M) → 5-7x faster inference
- **Neural truecasing** with per-character predictions — handles proper nouns, acronyms, mixed-case (NATO, iPhone, mRNA). Cadence-Fast only has rule-based capitalization (capitalize after period)
- **Native ONNX** — zero export work. Load directly via ONNX Runtime or convert to CoreML
- **Hindi Danda F1 is 96.9%** — excellent for Hinglish punctuation
- **Sentence segmentation** included — free bonus that neither Cadence-Fast nor the LLM provides
- Apache 2.0 license

**Weaknesses:**
- Trained on **news data only**, not speech transcripts — may struggle with conversational/disfluent text
- **128-token max** per sliding window (see token limits section below)
- Lower comma F1 (67.9%) compared to larger models

##### Candidate B: `1-800-BAD-CODE/xlm-roberta_punctuation_fullstop_truecase` (FALLBACK — Higher Quality)

| Property | Value |
|---|---|
| HuggingFace | [1-800-BAD-CODE/xlm-roberta_punctuation_fullstop_truecase](https://huggingface.co/1-800-BAD-CODE/xlm-roberta_punctuation_fullstop_truecase) |
| Architecture | XLM-RoBERTa base encoder + same multi-head pipeline as Candidate A |
| Parameters | ~278M |
| Disk size | ~1.1 GB FP32 / **~280 MB INT8** |
| Languages | **47 languages** including English, Hindi, Arabic, Chinese, Japanese |
| Punctuation classes | ~17 post-punctuation + pre-punctuation + acronym class |
| Capitalization/Truecasing | **Neural** per-character — **99.59% micro F1** (English), **95.3%** (Hindi) |
| Sentence segmentation | **Yes** |
| ONNX | **Native** |
| License | Apache 2.0 |
| Max sequence length | **128 tokens** (same sliding window approach) |
| Downloads | **~331k/month** (very popular, production-proven) |
| F1 (English) | Period: 92.4%, Comma: 78.8%, Question: 80.5% |
| F1 (Hindi) | Danda: **97.8%**, Truecasing: **95.3%** |
| Est. inference | ~10-30ms (similar to Cadence-Fast) |

**Why this is the quality fallback:**
- **Best truecasing quality available** — 99.59% micro F1 on English, 95.3% Hindi
- **331k downloads/month** — the most battle-tested punctuation model on HuggingFace
- **Higher F1 across all marks** — Period 92.4%, Comma 78.8%, Question 80.5%
- **XLM-RoBERTa backbone is robust to noisy input** — pre-trained on 2.5TB of CommonCrawl data across 100 languages, which includes web text with noise, typos, and informal language. While the fine-tuning was on news data, the backbone's exposure to messy web text gives it better noise tolerance than the smaller custom encoder. For speech transcripts with fillers and disfluencies, this robustness matters — the model won't catastrophically fail on unusual input patterns, it just may not punctuate disfluent regions optimally
- Same ONNX tooling and `punctuators` API as Candidate A (easy to swap)
- Similar size to Cadence-Fast but with native ONNX and neural truecasing

**Weaknesses:**
- **Same speed as Cadence-Fast** (~10-30ms), not faster
- Larger disk (needs INT8 quantization to reach ~280 MB)
- Also trained on news data (same caveat as Candidate A)

##### Candidate C: `ai4bharat/Cadence-Fast` (DEPRIORITIZED — Deployment Concerns)

| Property | Value |
|---|---|
| HuggingFace | [ai4bharat/Cadence-Fast](https://huggingface.co/ai4bharat/Cadence-Fast) |
| Architecture | Gemma-3-270M (bidirectional encoder via MNTP) + linear classification head |
| Parameters | 270M |
| Disk size | **1.07 GB** (safetensors F32) / ~125 MB (INT4, needs quantization) |
| Languages | English + Hindi + 21 other Indic languages (23 total) |
| Punctuation classes | 30 (including Indic-specific: Danda, Urdu marks, Arabic commas, Santali mucaad) |
| Capitalization/Truecasing | **Rule-based only** (capitalize after sentence-ending punctuation) |
| ONNX | **Not available** — requires custom export of bidirectional Gemma-3 |
| License | MIT |
| Max sequence length | **300 tokens** (sliding window) |
| Downloads | ~1,823/month (low adoption) |
| Performance | "93.8% of full Cadence" (unsubstantiated — metric/benchmark not specified) |
| F1 (written text, focus labels) | ~0.74 macro (estimated from 93.8% of Cadence's 0.79) |
| F1 (speech transcripts, focus labels) | ~0.59 macro (estimated from 93.8% of Cadence's 0.62) |

**Why deprioritized:**

| Concern | Detail |
|---------|--------|
| **No ONNX/CoreML export exists** | Nobody has exported it. The bidirectional attention modification on Gemma-3 is non-standard — standard ONNX exporters assume causal attention. Would require custom `torch.onnx.export` handling of the attention mask hack |
| **Capitalization is rule-based only** | Not neural. Just "capitalize after period/question mark". Cannot handle proper nouns (Kubernetes, AWS), acronyms (NATO), or mixed-case (iPhone, mRNA) — exactly the cases failing in names-technical |
| **1.07 GB on disk (F32)** | Much larger than the "~150 MB" originally estimated. INT4 quantization to ~125 MB needs work and may degrade quality |
| **Custom model code** | Requires `trust_remote_code=True`. Uses `modeling_gemma3_punctuation.py` — non-standard HuggingFace integration |
| **"93.8%" claim is unsubstantiated** | The Mark My Words paper (arXiv:2506.03793) doesn't mention Cadence-Fast at all. The figure appears only in the model card with no metric or benchmark specified |
| **Low adoption** | ~1,823 downloads/month. Known bugs: pipe characters in batch mode, Hindi punctuation wrongly applied to Marathi |
| **Stronger Indic coverage but weaker English** | 30 Indic punct classes is overkill for Aawaaz (primarily English + Hinglish). Extra classes may dilute English accuracy |

**Still worth knowing about:** Cadence-Fast's strength is deep Indic language coverage (22 languages with script-specific marks). If Aawaaz later needs Marathi/Tamil/Bengali/Gujarati support, Cadence becomes relevant. For English + Hindi/Hinglish, Candidates A and B are superior choices.

#### Comparison Matrix

| Property | Candidate A (punct_cap_seg_47) | Candidate B (xlm-r_punct_truecase) | Candidate C (Cadence-Fast) |
|----------|-------------------------------|-------------------------------------|---------------------------|
| Parameters | **40M** | 278M | 270M |
| Disk (deployable) | **~160 MB** | ~280 MB (INT8) | ~125 MB (INT4, needs work) |
| ONNX native | **Yes** | **Yes** | No (custom export needed) |
| Neural truecasing | **Yes** (90.5% EN, 92.7% HI) | **Yes** (99.6% EN, 95.3% HI) | No (rule-based) |
| Sentence segmentation | **Yes** | **Yes** | No |
| Hindi Danda F1 | **96.9%** | **97.8%** | ~0.74 macro (all labels) |
| English Period F1 | 88.3% | **92.4%** | ~0.74 macro (all labels) |
| English Comma F1 | 67.9% | **78.8%** | not reported separately |
| Est. latency (Apple Silicon) | **~2-5ms** | ~10-30ms | ~10-30ms |
| Max seq length | 128 tokens | 128 tokens | **300 tokens** |
| Noise tolerance | Lower (news-trained) | **Higher** (XLM-R backbone) | Medium (speech data in training) |
| License | Apache 2.0 | Apache 2.0 | MIT |
| Deployment effort | **Low** | Low | **High** |

#### Token/Sequence Length Limits

Both Candidate A and B have a **128-token max sequence length** per inference window. This is an important constraint to handle correctly:

**Impact on Aawaaz:**
- Typical dictation utterances are short: 5-50 words (~7-70 tokens). **128 tokens covers the vast majority of inputs with no windowing needed.**
- Longer dictation sessions (paragraph-length) may exceed 128 tokens and require sliding window processing.
- The `punctuators` Python package handles this automatically with overlapping windows and prediction merging. The Swift implementation must replicate this logic.

**Sliding window implementation requirements:**
- Split input into overlapping chunks of 128 tokens (e.g., stride of 96 tokens, overlap of 32)
- Run inference on each chunk independently
- Merge predictions in overlap regions (take predictions from the chunk where the token is most centered — i.e., farthest from chunk boundaries, where encoder attention is strongest)
- Stitch punctuated chunks back together

**Candidate C (Cadence-Fast) has a 300-token window**, which is more generous but still requires windowing for very long inputs. However, for Aawaaz's typical utterance lengths, this difference is rarely exercised.

**Recommendation:** Implement the sliding window logic in Swift as a generic wrapper (`PunctuationModelRunner`) that handles chunking/merging regardless of which model is selected. This also future-proofs against model swaps. For the initial prototype, a simple "truncate to 128 tokens" fallback is acceptable since most dictation utterances are well under this limit.

#### Pipeline Position: Why Punctuation Goes AFTER Deterministic Cleanup

The pipeline ordering matters. There are arguments for placing the punctuation model earlier (before deterministic cleanup), but after analysis, **after deterministic cleanup and before LLM** remains the correct position:

**Why NOT before self-correction detection:**
- Self-correction markers ("scratch that", "no wait", "oh sorry") rely on raw unpunctuated flow. If punctuated first — "Send to Mark. Oh sorry, to John." — the detector now needs to work across sentence boundaries, which breaks existing pattern matching.
- The detector is optimized for unpunctuated ASR output.

**Why NOT before filler removal:**
- Fillers ("um", "uh", "like") are noise the punct model hasn't seen in training (both candidates trained on clean news text). Fillers would confuse the model and produce incorrect punctuation: "Um, I wanted to, like, go there." → then filler removal creates orphaned commas.
- Removing fillers first gives the punct model cleaner input matching its training distribution.

**Why NOT before SpokenFormNorm:**
- SpokenFormNormalizer converts "slash api slash v2" → "/api/v2". If punctuated first, the model might insert periods or commas in the middle of what's really a URL path.

**Why AFTER deterministic cleanup works best:**
- The punct model receives clean, filler-free, self-correction-resolved text — matching its training distribution (clean written text).
- Punctuation provides sentence structure that helps the downstream LLM with grammar decisions.
- Capitalization from the punct model gives the LLM properly-cased input, simplifying its task.

**However, test both orderings during evaluation.** The XLM-RoBERTa model (Candidate B) may be robust enough to handle fillers and disfluencies due to its pre-training on noisy CommonCrawl data. If it scores higher when placed before filler removal in benchmarks, that ordering should be adopted.

```
ASR (Whisper, prompt-conditioned)
    ↓
Deterministic cleanup (TextProcessor)
├── Self-correction detection
├── Filler removal
├── Spoken-form normalization
└── Number/date ITN
    ↓
Punctuation model (punct + truecasing — bidirectional encoder, 2-30ms)  ← NEW LAYER
    ↓
LLM (grammar + style ONLY — simplified task, context-injected)  ← SIMPLIFIED TASK
    ↓
Text insertion
```

**What changes for the LLM:** With punctuation and capitalization already handled by the encoder, the LLM system prompt becomes simpler and more focused. The model can focus on grammar corrections, sentence flow, and style adaptation — tasks where autoregressive generation is actually superior. Could drop to `.light` cleanup level for most cases with better results.

#### Implementation path

1. **Prototype in Python** — `pip install punctuators`, run the 100 benchmark cases through both Candidate A and B to measure exact F1 on our test suite
2. **Select winner** — compare quality, latency, and noise tolerance. If Candidate A's quality is sufficient (especially comma F1), prefer it for speed. If commas/questions are weak, use Candidate B
3. **ONNX → CoreML conversion** — convert winner's ONNX model to CoreML `.mlpackage` via `coremltools` for ANE acceleration. Alternatively, use ONNX Runtime with CoreML execution provider
4. **Implement Swift wrapper** — `PunctuationModelRunner.swift` handling tokenization (SentencePiece), sliding window chunking/merging, ONNX/CoreML inference, and label-to-text reconstruction
5. **Integrate into pipeline** — wire between SpokenFormNormalizer and LLM in `TextProcessor`
6. **Simplify LLM prompt** — remove punctuation/capitalization instructions, focus on grammar + style only
7. **Benchmark** — run full 100-case suite with judge scoring

#### Other models worth knowing about (not recommended for Phase 4 but useful context)

| Model | Architecture | Size | Languages | Notes |
|---|---|---|---|---|
| **ai4bharat/Cadence** (full) | Gemma-3-1B bidirectional | 1B / ~2 GB | 23 Indic + EN | Quality ceiling for Indic (0.79 macro F1 focus labels). Too large for on-device (~100-200ms). |
| **sherpa-onnx Edge-Punct** | CNN + BiLSTM | **2-5M / 7 MB INT8** | English only | Fastest possible (~1-3ms). Native Swift/iOS bindings via sherpa-onnx. CC-BY-4.0. Only 3 punct marks, no Hindi. |
| **unikei/distilbert-base-re-punctuate** | DistilBERT (66M) | 250 MB | English only | Proven **3.5ms on Apple ANE** (Apple's own benchmark). ONNX available. No Hindi. |
| **AssemblyAI Universal-2-TF** | BERT + BART two-stage | ~250M | English | 81.2% human preference; handles punct + truecasing + ITN. NOT open source (API only). |
| **deepmultilingualpunctuation** | XLM-RoBERTa | ~278M | Multilingual | Open-source PyPI package. Same backbone as Candidate B but fewer features (no truecasing). [GitHub](https://github.com/oliverguhr/deepmultilingualpunctuation) |
| **CNN+BiLSTM (arXiv:2407.13142)** | CNN + BiLSTM | **~2M** | English | 1/40th transformer size, 2.5x faster. Code available. English only. Basis for sherpa-onnx Edge-Punct model. |

**Research references:**
- [Cadence / Mark My Words paper (arXiv:2506.03793)](https://arxiv.org/abs/2506.03793)
- [1-800-BAD-CODE punctuators package (GitHub)](https://github.com/1-800-BAD-CODE/punctuators)
- [Light-weight CNN+BiLSTM on-device model (arXiv:2407.13142)](https://arxiv.org/abs/2407.13142)
- [Apple: Deploying Transformers on ANE (ml-ane-transformers)](https://github.com/apple/ml-ane-transformers)
- [DistilBERT on ANE benchmarks](https://github.com/anentropic/experiments-coreml-ane-distilbert)
- [Lightweight streaming punct+caps (ScienceDirect 2025)](https://www.sciencedirect.com/science/article/abs/pii/S0167639325000846)

**Latency:** ~2-5ms (Candidate A) or ~10-30ms (Candidate B). Total pipeline: 0.31s → ~0.32-0.34s.
**Memory:** ~160 MB (Candidate A) or ~280 MB INT8 (Candidate B). Total: ~1.16-1.28 GB, well within budget.

---

### Layer 6: Test One More LLM Model

**Expected impact: +5-10 pass rate** (may fix self-correction-llm, adversarial, remaining grammar)

**Note:** With the punctuation model handling punctuation/capitalization, the LLM's job is now grammar + style only. This makes model evaluation more meaningful — we're testing grammar capability, not punctuation capability.

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
LFM2.5 lists Arabic/Chinese/Japanese/Korean/Spanish/French/German/English but does NOT list Hindi. It may perform poorly on Hinglish. Test the 10 Hinglish cases specifically. With the punctuation model handling Hindi punctuation, the LLM only needs to handle Hindi grammar — a smaller gap.

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

### Phase 0: Evaluation Overhaul ✅ DONE

1. **Layer 0** — build LLM-as-Judge scoring script ✅ (`scripts/llm_judge.py`)
2. Re-score all failing cases → establish true baseline ✅ (`llm-judge-results.json` + `llm-judge-results-report.txt`)
3. ~~Expected rebaseline: **47% → ~58%**~~ → **Actual: 50% exact, 61% judge** (exceeded prediction)

### Phase 1: Quick Wins ✅ DONE

4. **Fix 2a** — capitalize short bypass results ✅
5. **Fix 2b** — capitalize after self-correction detection ✅
6. **Fix 2c** — update single-line test expectations ⚠️ (trailing periods done; colon depends on normalizer verification)
7. ~~Run benchmark → expect **~63%** (with judge scoring)~~ → **Actual: 61% judge** (close to prediction; normalizer impact not yet reflected)

### Phase 2: Spoken-Form & Number Normalization — Partially Done

8. **Layer 1** — `SpokenFormNormalizer` implementation complete ✅ (365 lines, 24 tests, integrated)
9. **Layer 1b** — `NumberNormalizer` ❌ NOT IMPLEMENTED
10. Unit tests: SpokenFormNormalizer ✅, NumberNormalizer ❌
11. Pipeline integration: SpokenFormNormalizer ✅, NumberNormalizer ❌
12. ~~Run benchmark → expect **~68%**~~ → **Pending clean rerun** (normalizer impact not yet reflected in results)

### Phase 2.5: Stabilization & Benchmark Rebaseline

**Goal:** Verify that implemented deterministic layers are actually affecting benchmark outputs, fix cascading correction prefix loss, rescue implicit self-corrections with deterministic markers, and establish a clean baseline before Phase 3.

**Exit criteria for moving to Phase 3:**
- ✅ SpokenFormNormalizer is confirmed working in benchmark traces (path/URL/label-colon cases show conversion)
- ✅ Cascading corrections preserve sentence structure (not just the final word)
- ✅ Single-line expectations are aligned with intended behavior
- ✅ Judge score is re-run on fresh results and used as the new baseline
- Expected judge score after Phase 2.5: ~~**~68-72%**~~ → **Actual: 79% (exceeded target by +7-11 points)**

#### Priority 1: Rebaseline SpokenFormNormalizer (S) — ✅ DONE

The benchmark results in `llm-judge-results.json` are inconsistent with current source — spoken-form patterns (slash, colon, dot) are not converting in the benchmark output despite `SpokenFormNormalizer` being called in `TextProcessor.process()`. Most likely the benchmark was run before full integration.

- [x] Clean rebuild and rerun quality benchmark (`llm_quality_tests.sh`)
- [x] Add explicit per-stage trace output in `CleanupQualityTests.testCleanupQualityRegression()`:
  - Print `afterSpokenForms` as a separate stage (previously merged with `afterFillers`)
  - Refactored pipeline to call `SelfCorrectionDetector`, `FillerWordRemover`, and `SpokenFormNormalizer` directly instead of through `TextProcessor.process()` which ran SpokenFormNormalizer implicitly twice
  - Extracted `runDeterministicStages()` helper to avoid duplicating the capitalization logic across `testCleanupQualityRegression()` and `testModelComparison()`
  - Trace now shows 4 distinct stages: INPUT → AFTER SELF-CORR → AFTER FILLERS → AFTER SPKN-FRM → AFTER LLM
- [x] Add focused regression checks that SpokenFormNormalizer is converting in these specific benchmark inputs:
  - `slash api slash v2 slash users` → `/api/v2/users` ✅ (testAPIPath)
  - `https colon slash slash github dot com slash aawaaz` → `https://github.com/aawaaz` ✅ (testHTTPSUrl)
  - `re colon project update` → `Re: project update` ✅ (testReColon)
  - `bug report colon app crashes` → `Bug report: app crashes` ✅ (testBugReportColon)
  - All 34 SpokenFormNormalizerTests pass
- [x] Rerun `scripts/llm_judge.py` on fresh results ✅

**Completed work:** Build succeeds, 95 deterministic tests pass (0 failures). The test pipeline now faithfully shows SpokenFormNormalizer's impact as a separate trace stage, fixing the diagnostic blind spot where spoken-form conversions were invisible.

**Benchmark results (fresh run, March 2026):**

| Metric | Previous | Current | Delta |
|--------|----------|---------|-------|
| Exact-match | 50/100 (50%) | 52/100 (52%) | +2 |
| Judge pass | 61/100 (61%) | 71/100 (71%) | +10 |
| Judge rescued | 11 | 19 | +8 |

Per-category changes (exact → judge):
| Category | Previous | Current | Notes |
|----------|----------|---------|-------|
| names-technical | 2/10 → 3/10 | 4/10 → 8/10 | **+5 judge** — SpokenFormNormalizer URL/path/dot conversions now visible and working |
| hinglish | 2/10 → 3/10 | 2/10 → 5/10 | +2 judge |
| grammar | 8/12 → 10/12 | 8/12 → 11/12 | +1 judge |
| self-correction-det | 8/12 → 10/12 | 8/12 → 11/12 | +1 judge |
| single-line | 3/5 → 3/5 | 2/5 → 4/5 | +1 judge (slight exact regression, but more rescued) |
| self-correction-llm | 0/10 → 0/10 | 0/10 → 0/10 | Still zero — needs Priority 3 markers |
| cascading-corrections | 1/5 → 2/5 | 1/5 → 2/5 | No change — needs Priority 2 fix |

**Key observations:**
- SpokenFormNormalizer is confirmed working in benchmark — `AFTER SPKN-FRM` trace shows URL/path/colon conversions on names-tech-2, names-tech-8, singleline-3, singleline-5
- The 71% judge score exceeds the predicted ~65-67%, largely driven by names-technical (+5) and hinglish (+2) judge rescues
- 28 real failures remain, primarily in: self-correction-llm (10), cascading-corrections (3), hinglish (5), adversarial (3)

**Expected impact:** ~~If normalizer is working correctly, expect names-technical to jump from 2/10 → ~5-6/10 exact and single-line from 3/5 → ~4-5/5 exact. Judge score should reach ~65-67%.~~ → **Actual: 71% judge (exceeded prediction). names-technical 4/10 exact, 8/10 judge. single-line 2/5 exact, 4/5 judge.**

#### Priority 2: Fix Cascading Correction Prefix Preservation (M) ✅

**Status: Complete.**

Three mechanisms were added to `SelfCorrectionDetector` to fix cascading correction prefix loss:

1. **Effective repair head** — `effectiveRepairHead(from:)` truncates repair at the next correction marker for fragment classification, preventing cascading markers from inflating token counts. The full repair is still used for stitching so the cascading loop handles remaining markers.

2. **Correction idiom stripping** — `stripCorrectionIdiom(from:)` recognizes "make it X" / "make that X" as idiomatic corrections, extracting the value portion. A `requireStrongAnchor` guard prevents false stripping of literal imperative speech (e.g., "make it happen").

3. **Overlap-based merge** — `tryOverlapMerge(before:repair:)` handles clause-starter repairs ("it's at four") by finding structural overlap with the suffix of `before` and merging at the overlap point. Guards against false positives: tail-length check prevents unrelated overlaps, copula check prevents weak preposition overlaps (e.g., "meet at noon" → "it's at risk").

**Changes:**
- `SelfCorrectionDetector.swift`: Added 3 new methods + `weakOverlapTokens`/`copulaTokens` sets, modified `mergeCorrection` and `repairLooksLikeFragment`
- `SelfCorrectionDetectorTests.swift`: Updated 1 test, added 12 new tests (43 total, was 21)

- [x] Modify `SelfCorrectionDetector` to preserve stable prefix across multi-correction passes
- [x] Add targeted unit tests for all 5 cascading-corrections benchmark cases
- [x] Verify `selfcorr-det-3` ("the meeting is at three, never mind, it's at four") also benefits (same root cause)

**Benchmark results (after Priority 2):**

| Metric | Before Priority 2 | After Priority 2 | Delta |
|--------|-------------------|-------------------|-------|
| Exact-match | 52/100 (52%) | 56/100 (56%) | **+4** |
| Judge pass | 71/100 (71%) | 70/100 (70%) | -1 (within noise) |
| Judge rescued | 19 | 14 | -5 (more exact matches need fewer rescues) |

Per-category changes (exact → judge):
| Category | Before | After | Notes |
|----------|--------|-------|-------|
| cascading-corrections | 1/5 → 2/5 | 4/5 → 5/5 | **+3 exact, +3 judge** — prefix preservation working |
| self-correction-det | 8/12 → 11/12 | 9/12 → 11/12 | **+1 exact** — selfcorr-det-3 fixed via overlap merge |
| names-technical | 4/10 → 8/10 | 4/10 → 6/10 | -2 judge (LLM variance) |
| grammar | 8/12 → 11/12 | 8/12 → 11/12 | No change |
| fillers | 10/15 → 12/15 | 10/15 → 12/15 | No change |

**Known limitation:** When a clause-starter repair has no structural overlap with the before text (e.g., "it's wednesday" correcting "tuesday"), the original prefix is lost. Fixing this would require semantic matching between day names, which is beyond current heuristics. The output is still acceptable ("it's thursday" instead of "the meeting is thursday").

#### Priority 3: Add High-Precision Implicit Self-Correction Markers (M) ✅

**Status: Complete.**

10% of the benchmark (self-correction-llm 0/10) failed because the LLM cannot resolve implicit corrections like "oh sorry", "wait hold on", "no make that". 9 high-precision multi-word triggers were added to `SelfCorrectionDetector` with extensive false-positive guards.

**Markers added (9 total):**
- `wait hold on` — strong restart signal
- `no wait` — strong restart signal
- `on second thought` — unambiguous reconsideration
- `nah use` — correction before alternative
- `or rather` — explicit replacement signal (with `biasFragmentMerge`)
- `no make that` — explicit replacement signal (with `biasFragmentMerge`)
- `oh sorry` — guarded: rejects apology continuations ("oh sorry for", "oh sorry about", "oh sorry I'm")
- `oops I meant` — guarded: rejects infinitive ("oops I meant to call")
- `correction` — guarded: rejects determiner-preceded ("the correction") and copula-followed ("correction is")

**Safety mechanisms:**
1. **Sentence-start guard** — implicit markers (no punctuation requirement, no standalone restart) at sentence start with no meaningful prior content are rejected to prevent false positives on standalone phrases like "oh sorry to interrupt"
2. **biasFragmentMerge flag** — forces fragment classification for "or rather" and "no make that" to enable prefix preservation, but skips bias when repair starts with a clause starter to avoid malformed merges
3. **Per-marker validation** — each ambiguous marker has specific guards against its most common non-correction usages
4. **Lead-in word expansion** — "hmm", "hm", "oops" added to lead-in set so they're stripped before markers

**Intentionally skipped:**
- `well actually` — too common as discourse filler in normal speech; case 4 remains unsolved
- bare `I meant` — "I meant to say thank you" has too many non-correction usages
- bare `correction` without guards — "the correction was minor" is a noun usage

**Changes:**
- `SelfCorrectionDetector.swift`: Added `biasFragmentMerge` to Marker struct, 9 new markers in `defaultMarkers`, expanded lead-in words, 4 validation guards in `isValidMarkerMatch`, modified `nextMarker` to return Marker object, threaded Marker through `resolveSentence` → `mergeCorrection`
- `SelfCorrectionDetectorTests.swift`: Added 20 new tests (63 total, was 43) — 9 positive tests for new markers, 11 negative tests for false-positive prevention

- [x] Add high-precision markers to `SelfCorrectionDetector` as a new tier
- [x] Add unit tests for each new trigger with both positive (correction) and negative (non-correction) cases
- [x] Oracle pre-implementation design review
- [x] Oracle post-implementation review + self-review
- [x] Fix all review findings (sentence-start guard, clause-starter bias fix, expanded validation)
- [x] Run benchmark to measure impact

**Benchmark results (after Priority 3):**

| Metric | Before Priority 3 | After Priority 3 | Delta |
|--------|-------------------|-------------------|-------|
| Exact-match | 56/100 (56%) | 61/100 (61%) | **+5** |
| Judge pass | 70/100 (70%) | 79/100 (79%) | **+9** |
| Judge rescued | 14 | 18 | +4 |

Per-category changes (exact → judge):
| Category | Before | After | Notes |
|----------|--------|-------|-------|
| self-correction-llm | 0/10 → 0/10 | 5/10 → 7/10 | **+5 exact, +7 judge** — implicit markers working |
| self-correction-det | 9/12 → 11/12 | 9/12 → 12/12 | **+1 judge** |
| cascading-corrections | 4/5 → 5/5 | 4/5 → 5/5 | No change |
| grammar | 8/12 → 11/12 | 8/12 → 11/12 | No change |
| fillers | 10/15 → 12/15 | 10/15 → 12/15 | No change |
| names-technical | 4/10 → 6/10 | 4/10 → 6/10 | No change |
| adversarial | 1/5 → 2/5 | 1/5 → 3/5 | **+1 judge** |
| single-line | 2/5 → 4/5 | 2/5 → 4/5 | No change |

**Self-correction-llm case-by-case breakdown:**
| Case | Input | Exact | Judge | Notes |
|------|-------|-------|-------|-------|
| 1 | "send it to mark oh sorry to john" | ✅ | ✅ | `oh sorry` marker + fragment merge |
| 2 | "call sarah wait hold on call john" | ❌ | ❌ | Deterministic correct, LLM didn't capitalize "john" |
| 3 | "I need five no make that six copies" | ✅ | ✅ | `no make that` + biasFragmentMerge |
| 4 | "the budget is ten thousand well actually fifteen thousand" | ❌ | ❌ | `well actually` intentionally skipped |
| 5 | "we should go left or rather right at the intersection" | ✅ | ✅ | `or rather` + biasFragmentMerge |
| 6 | "order the pasta hmm on second thought order the salad" | ❌ | ✅ | Deterministic correct, LLM missed period — judge rescued |
| 7 | "the file is in documents no wait it's in downloads" | ✅ | ✅ | `no wait` + overlap merge |
| 8 | "set the font to arial nah use helvetica instead" | ❌ | ✅ | Trailing "instead" — judge rescued |
| 9 | "reply to mike oops I meant reply to dave" | ❌ | ❌ | Deterministic correct, LLM didn't capitalize "dave" |
| 10 | "the train leaves at seven correction it leaves at nine" | ✅ | ✅ | `correction` marker + overlap merge |

**Expected impact:** ~~self-correction-llm from 0/10 → ~4-6/10 judge~~ → **Actual: 7/10 judge (exceeded prediction). +9 overall judge pass rate.**

#### Priority 4: Finish Single-Line Test Expectation Cleanup (S) ✅

**Status: Complete.**

Two deterministic fixes were added to address single-line test failures plus LLM judge parser was updated to support the current verbose test output format:

1. **Post-LLM first-letter capitalization** — `LocalLLMProcessor.capitalizeStartIfAppropriate()` ensures the first letter of LLM output is capitalized in non-code/terminal contexts. Guards against false capitalization of URLs (`http://`, `https://`, `www.`), emails, paths (`/`, `~/`), CLI flags (`-`, `--`), and handles (`@`). Applied to both the short-input bypass and main LLM processing paths.

2. **Post-colon capitalization for sentence-start labels** — `SpokenFormNormalizer.normalizeLabelColons()` now capitalizes the first word after the colon for labels that start a new phrase (re, subject, bug report, note, warning, todo, etc.). Excludes value-follower labels (from, to, cc, bcc, date, input, output, result) where the next word may be an email, data value, or identifier. Also guards against capitalizing URLs/emails/paths/flags after colons.

3. **LLM judge parser update** — `scripts/llm_judge.py` `parse_benchmark_results()` now supports both the compact format (`[id] ✅ 0.30s`) and the current verbose format (`━━━ [id] Category: ...` with `AFTER LLM:` and `RESULT:` lines).

**Changes:**
- `LocalLLMProcessor.swift`: Added `capitalizeStartIfAppropriate()` static method, called after LLM processing and in short-input bypass path
- `SpokenFormNormalizer.swift`: Added `sentenceStartLabels` set, refactored `normalizeLabelColons()` to capitalize after sentence-start labels with single-pass regex replacement (no stale index issues)
- `LocalLLMProcessorTests.swift`: New file — 12 tests for capitalization guard edge cases (URLs, emails, paths, flags, handles, code/terminal contexts)
- `SpokenFormNormalizerTests.swift`: Updated 3 existing tests, added 2 new test methods (9 assertions for value-follower and sentence-start label behavior)
- `scripts/llm_judge.py`: Updated parser to handle verbose benchmark output format

- [x] Add post-LLM first-letter capitalization guard
- [x] Add post-colon capitalization for sentence-start labels
- [x] Update SpokenFormNormalizer tests for new behavior
- [x] Add LocalLLMProcessor tests for capitalization guards
- [x] Oracle pre-implementation design review
- [x] Oracle post-implementation review + self-review
- [x] Fix review findings (short-input path, stale index, www. guard)
- [x] Fix LLM judge parser for current output format
- [x] Run benchmarks to measure impact

**Benchmark results (after Priority 4):**

| Metric | Before Priority 4 | After Priority 4 | Delta |
|--------|-------------------|-------------------|-------|
| Exact-match | 61/100 (61%) | 64/100 (64%) | **+3** |
| Judge pass | 79/100 (79%) | 79/100 (79%) | 0 |
| Judge rescued | 18 | 15 | -3 (more exact matches need fewer rescues) |

Per-category changes (exact → judge):
| Category | Before | After | Notes |
|----------|--------|-------|-------|
| single-line | 2/5 → 4/5 | 4/5 → 5/5 | **+2 exact, +1 judge** — capitalization fixes working |
| names-technical | 4/10 → 6/10 | 5/10 → 7/10 | **+1 exact, +1 judge** — post-LLM capitalization helped |
| self-correction-det | 9/12 → 12/12 | 9/12 → 12/12 | No change |
| cascading-corrections | 4/5 → 5/5 | 4/5 → 5/5 | No change |
| self-correction-llm | 5/10 → 7/10 | 5/10 → 7/10 | No change |
| grammar | 8/12 → 11/12 | 8/12 → 9/12 | -2 judge (LLM variance) |
| fillers | 10/15 → 12/15 | 10/15 → 11/15 | -1 judge (LLM variance) |

**Single-line case-by-case breakdown:**
| Case | Input | Exact | Judge | Notes |
|------|-------|-------|-------|-------|
| 1 | "this is a subject line for an email..." | ✅ | ✅ | Post-LLM capitalization fixed start |
| 2 | "meeting with john tomorrow at 3pm" | ❌ | ✅ | First letter now capitalized; "John" and "3pm" spacing remain LLM issues |
| 3 | "re colon um project update for q4" | ✅ | ✅ | Post-colon capitalization fixed "Project" |
| 4 | "search for best restaurants near me" | ✅ | ✅ | Was already passing |
| 5 | "um bug report colon app crashes on startup" | ✅ | ✅ | Was already passing |

#### Priority 5: NumberNormalizer — Decide Scope (M-L)

`NumberNormalizer` (Layer 1b) is NOT implemented. It handles "twenty three" → "23", "march fifteenth" → "March 15th", etc.

**Decision:** Defer full implementation to post-Phase 2.5 unless the clean rerun reveals it's blocking more cases than expected. Only 1-2 benchmark cases directly require number normalization (names-tech-9: "version two point three point one"). Cardinal numbers are a real user need but not the immediate benchmark bottleneck.

**Recommendation:** Implement lean cardinal numbers only if time permits after Priorities 1-3 are done. Do not block Phase 3 on this.

#### Explicitly Deferred

| Item | Deferred To | Reason |
|------|-------------|--------|
| Broad Hinglish punctuation/capitalization | Phase 4 (punct model) | Model-architecture problem — needs bidirectional encoder for reliable punct/caps on Hindi text. Candidates: punct_cap_seg_47 (Hindi Danda F1 96.9%) or xlm-r_punct_truecase (97.8%) |
| General formatting quality improvements | Phase 4 (punct model) | formatting_quality avg 0.52 is the worst dimension, but primarily driven by Hinglish and names-tech |
| Larger model for remaining self-correction-llm | Phase 5 (LFM2.5 eval) | 3 cases remaining after deterministic rescue: "well actually" (1), LLM capitalization (2) |
| Tech-term capitalization (Kubernetes, AWS, NGINX) | Phase 3 (Whisper prompt) | Better solved upstream via Whisper prompt conditioning |
| "you know" as content vs filler | Future | Context-dependent disambiguation — "you know what I mean like" vs "you know that project" |
| Filler "like" in embedded positions | Future | Needs syntactic context to distinguish "I like the color" from "we should like go" |

### Phase 3: Whisper & Context ✅ Done

13. ✅ **Layer 3** — Whisper prompt conditioning (static + dynamic). Enhanced static prompts with category-specific tech vocabulary (code, terminal, email, chat, document). Added `appCategory` parameter to `WhisperManager.transcribe()` for dynamic category-based prompt selection at session start.
14. ✅ **Layer 4** — Surrounding text context injection via AX API. Added `surroundingText` to `InsertionContext` with `captureSurroundingText()` (reads ~200 chars before cursor from focused AX element). Injected into LLM prompt as `<context_before>` block. System prompt instruction is conditional — only included when surrounding text is present, avoiding overhead on the 0.6B model for cases without context.
15. ✅ Benchmark: **65% exact / 78% judge** (vs 64%/79% Phase 2.5-P4). Neutral — context infrastructure is in place without regression. The benchmark tests don't exercise surrounding text (all have `surroundingText: nil`), so the context feature's benefit will only show in production use.

### Phase 4: Punctuation Model Evaluation & Integration (2-3 days)

**Step 1: Python prototype evaluation (half day)** ✅ COMPLETED

16. `uv pip install punctuators` in `.venv`, wrote `scripts/punct_model_eval.py` to run all 100 benchmark cases through both candidate models:
    - **Candidate A:** `1-800-BAD-CODE/punct_cap_seg_47_language` (~40M, ~2-5ms native, ~63ms Python)
    - **Candidate B:** `1-800-BAD-CODE/xlm-roberta_punctuation_fullstop_truecase` (~278M, ~10-30ms native, ~247ms Python)
17. Measured per-category punctuation F1 (period, comma, question, colon, semicolon), truecasing accuracy, word preservation rate, and latency on Apple Silicon
18. Tested pipeline ordering A (after deterministic cleanup) — primary. Ordering B skipped in final run (A is the expected production ordering).
19. **Decision gate result:**
    - Candidate A fails quality bar: comma F1 = 0.17 (need ≥0.50), truecasing = 0.82 (need ≥0.85), **fatal `<unk>` token corruption** on single-char words ("I" → `<unk>`) and CamelCase words
    - **Candidate B selected**: punct F1 0.78, truecasing 0.91, word preservation 1.00 (perfect), ~4× slower but acceptable
    - Candidate B wins on every quality metric; A wins only on latency
    - Key: Hinglish punct F1 0.84 vs 0.62, truecasing 0.94 vs 0.70

    **Phase 4 Step 1 Evaluation Summary (Ordering A, prose categories):**

    | Metric | Candidate A | Candidate B | Winner |
    |---|---|---|---|
    | Exact Match | 15/92 (16%) | 35/92 (38%) | B |
    | Punct F1 (all) | 0.72 | 0.78 | B |
    | Period F1 | 0.74 | 0.81 | B |
    | Comma F1 | 0.17 | 0.25 | B |
    | Question F1 | 0.67 | 0.88 | B |
    | Truecasing Accuracy | 0.82 | 0.91 | B |
    | Word Preservation | 0.79 | 1.00 | B |
    | Avg Latency (Python) | 63ms | 247ms | A |
    | Model Size (ONNX) | ~160MB | ~280MB | A |

    **Key observations:**
    - Both models struggle with commas (F1: A=0.17, B=0.25) — LLM will still need to handle comma placement
    - short-input cases (8 total) all get trailing periods added — production may need to strip trailing periods for very short inputs
    - Code/terminal guardrail: both models over-capitalize and add unwanted periods — spoken-form-only path (skip punct model) may be needed for code contexts
    - Candidate A's `<unk>` corruption is a dealbreaker — single-char words like "I" become `<unk>`, CamelCase like "getUserById" → "GET<UNK>SER<UNK>Y<UNK>D"

**Step 2: Swift integration (1-2 days)** ✅ COMPLETED

20. Used ONNX Runtime with CoreML execution provider (ANE acceleration) — model stays as ONNX, no CoreML conversion needed
21. Implemented three new files:
    - `SentencePieceTokenizer.swift` (~300 lines): Minimal Swift SentencePiece unigram tokenizer with protobuf parser, trie-based Viterbi encoding, NFKC normalization. Validated against 100 Python reference cases (15 golden tests).
    - `PunctuationModelRunner.swift` (~400 lines): Actor wrapping ONNX Runtime inference. Handles model loading with CoreML EP for ANE, sliding window with 16-token overlap, prediction merging, text reconstruction matching Python PCSCollector exactly. ANE togglable via `punctuationModelUseANE` setting with automatic CPU fallback.
    - `PunctuationModelRunnerTests.swift`: 6 tests including golden reference validation (6/6 match), latency measurement (~115ms CPU), ANE toggle reload, edge cases.
22. Integrated into pipeline between SpokenFormNormalizer and LLM in `TranscriptionPipeline.postProcess()`:
    - Skipped for code/terminal contexts (prevents over-capitalization/unwanted periods)
    - Latency logged per inference with actual execution provider label
    - Model files referenced from HuggingFace cache (`~/.cache/huggingface/hub/models--1-800-BAD-CODE--xlm-roberta_punctuation_fullstop_truecase/`)
    - Required one-time model conversion: bool outputs → int32 (ONNX Runtime Swift bindings don't support bool tensor type)
23. Softened LLM prompt: changed "Capitalize sentence starts…Add periods…" to "The text may already have punctuation and capitalization from a prior stage. Adjust only if clearly wrong."
24. Added user settings: `punctuationModelEnabled` (default: true), `punctuationModelUseANE` (default: true) in AppState with UserDefaults persistence
25. Benchmark results:

    | Metric | Phase 3 (before) | Phase 4 Step 2 (after) | Delta |
    |---|---|---|---|
    | Exact Match | 65/100 (65%) | 61/100 (61%) | -4 |
    | Judge Pass Rate | 78/100 (78%) | 84/100 (84%) | **+6** |
    | Avg Punct Latency | — | 0.08s (CPU) | new |
    | Avg LLM Latency | 0.31s | 0.31s | 0 |
    | Real Failures (judge) | ~22 | 15 | **-7** |

    **Key observations:**
    - Exact match dropped 4 points because expected outputs were tuned to the pre-punct-model pipeline; the punct model produces slightly different (often better) formatting
    - Judge pass rate improved +6 points: punct model handles capitalization and periods reliably, freeing the LLM to focus on grammar
    - 15 real failures remain, primarily in: adversarial (4/5 fail), names-technical (6/10 fail), hinglish (3/10 fail)
    - Punct model latency is ~80ms avg (CPU), acceptable as it runs in parallel with dictation pauses
    - Short-input category: 0% exact match but 100% judge pass — model adds correct capitalization/periods that differ from hand-tuned expected outputs
    - Code/terminal bypass works correctly: 8/8 pass with no punct model interference

26. **Bug fixes (post-integration):**
    - **"?" → "." corruption:** The punct model was trained on unpunctuated text. When Whisper output already contained punctuation, the model doubled it ("?" → "??"), and the LLM then normalized "??" to ".". Fixed with three-layer defense:
      - `isAlreadyPunctuated()` heuristic: skips model if text contains `?`/`!`, 2+ sentence-ending marks, or any internal sentence-ending mark (period not at the very end). Single trailing period still runs the model (useful for run-ons).
      - `normalizeForModel()`: lowercases + strips sentence punctuation before inference (matches training distribution). Preserves punctuation between digits (e.g., "3.14", "10:30").
      - `sanitizePunctuation()`: post-model safety net that collapses `..` → `.`, `??` → `?`, `!!` → `!`, and removes spaces before punctuation.
    - **Settings UI:** Added "Punctuation & Capitalization" section to PostProcessingSettingsView with toggles for Punctuation Model enable/disable and ANE on/off. Made section visible regardless of LLM mode (punct model is independent of LLM).
    - **Memory leak:** `LocalLLMProcessor.unloadModel()` now calls `MLX.Memory.clearCache()` after releasing the model container. Without this, MLX's Metal buffer pool cached GPU buffers indefinitely, causing memory to grow monotonically when switching models. Also added in `LLMModelManager` after download-only container is discarded.
    - **Test coverage:** Added 4 new tests for `isAlreadyPunctuated`, `normalizeForModel`, `sanitizePunctuation`, and `testSkipOnPunctuatedInput`. All 10 punct model tests pass. Benchmarks unchanged: **61% exact, 84% judge** (expected — fixes only affect pre-punctuated input from Whisper, not the unpunctuated benchmark inputs).

### Phase 5: LFM2.5 Evaluation (half day)

20. Add LFM2.5 to `LLMModelCatalog`
21. Run benchmark with grammar-only prompt (Cadence handles punctuation)
22. Compare pass rate and latency vs Qwen 3 0.6B
23. Decision: adopt LFM2.5 as an option, or keep Qwen 3 0.6B as default
24. Run benchmark → expect **~83-85%**

### Phase 6: Prompt Tuning (1 day) ✅ DONE

25. ✅ Added 3 conditional prompt examples (for `.medium`/`.full` cleanup levels):
    - Self-correction example: "well actually" → keep corrected version
    - Sentence-splitting example: independent clauses get period, not comma
    - Hinglish continuity example: don't split at Hindi-English boundary
26. ✅ Tuned example count from 4 → 7 (4 base + 3 conditional for medium/full). Latency increased from 0.31s → 0.37s avg (+0.06s, acceptable).
27. ⏭️ Skipped spoken-slash prompt example — SpokenFormNormalizer handles this pre-LLM, so the model never sees raw "slash" tokens. Added Hinglish continuity and sentence-splitting examples instead (higher impact).
28. ✅ Benchmark: **62% exact / 85% judge** (up from 61%/84%). Hit the ~85%+ target.

**Additional changes:**
- Added global Hindi particle rule: "ki", "toh", "hai" are not sentence boundaries
- Added self-correction instruction for medium/full cleanup levels
- Made content-drop guard self-correction-aware (relaxed threshold when input contains correction markers like "well actually")
- Added 5 unit tests for prompt composition and content-drop guard behavior

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

| Step | Model | Prompt Style | Pass Rate (Exact) | Pass Rate (Judge) | Avg Latency | Δ vs Baseline |
|---|---|---|---|---|---|---|
| Step 0 (baseline) | Qwen 3 0.6B | Rules + examples + self-corr | 17/100 (17%) | — | 0.33s | — |
| Step 1 | Qwen 3 0.6B | Same (pipeline fix) | 17/100 (17%) | — | 0.33s | +0 |
| Step 2 | Qwen 3 0.6B | Same (infra fix) | 17/100 (17%) | — | 0.33s | +0 |
| Step 3 | Qwen 3.5 0.8B | Same prompt | 16/100 (16%) | — | 2.26s | -1, 6.8× slower |
| Step 4-5 v1 | Qwen 3.5 0.8B | Rules-only (no examples) | 23/100 (23%) | — | 0.24s | +6 |
| **Step 4-5 final** | **Qwen 3 0.6B** | **Example-driven** | **47/100 (47%)** | — | **0.33s** | **+30** |
| Step 4-5 final | Qwen 3 1.7B | Example-driven | 46/100 (46%) | — | 0.57s | +29 |
| Step 4-5 final | Qwen 3.5 0.8B | Example-driven | 29/100 (29%) | — | 2.66s | +12 |
| **Phase 0-1-2** | **Qwen 3 0.6B** | **Example-driven + Fix 2a/2b** | **50/100 (50%)** | **61/100 (61%)** | **0.33s** | **+33 exact, judge baseline** |
| **Phase 2.5-P4** | **Qwen 3 0.6B** | **+ post-LLM capitalization + post-colon cap** | **64/100 (64%)** | **79/100 (79%)** | **0.31s** | **+47 exact, +18 judge** |
| **Phase 3** | **Qwen 3 0.6B** | **+ Whisper prompt conditioning + context injection** | **65/100 (65%)** | **78/100 (78%)** | **0.31s** | **+48 exact, +17 judge** |
| **Phase 4 Step 1** | **Qwen 3 0.6B** | **(no code change — same as Phase 3; punct model eval only)** | **65/100 (65%)** | **82/100 (82%)** | **0.31s** | **+48 exact, +21 judge** |
| **Phase 4 Step 2** | **Qwen 3 0.6B** | **+ xlm-roberta punct model** | **61/100 (61%)** | **84/100 (84%)** | **0.31s** | **+44 exact, +23 judge** |
| **Phase 6** | **Qwen 3 0.6B** | **+ prompt tuning (7 examples, Hindi rule, self-corr instruction)** | **62/100 (62%)** | **85/100 (85%)** | **0.37s** | **+45 exact, +24 judge** |

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

| Category | Step 0 | Step 4-5 (exact) | Phase 0-1-2 (exact) | Phase 0-1-2 (judge) | Phase 2.5-P2 (exact) | Phase 2.5-P2 (judge) | Phase 2.5-P3 (exact) | Phase 2.5-P3 (judge) | Phase 2.5-P4 (exact) | Phase 2.5-P4 (judge) | Phase 3 (exact) | Phase 3 (judge) | Ph4-S1 (exact) | Ph4-S1 (judge) | Ph4-S2 (exact) | Ph4-S2 (judge) | Ph6 (exact) | Ph6 (judge) | Next Fix |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| code-terminal | 4/8 | 8/8 | 8/8 | 8/8 | 8/8 | 8/8 | 8/8 | 8/8 | 8/8 | 8/8 | 8/8 | 8/8 | 8/8 | 8/8 | 8/8 | 8/8 | 8/8 | 8/8 | ✅ Done |
| short-input | 7/8 | 8/8 | 8/8 | 8/8 | 8/8 | 8/8 | 8/8 | 8/8 | 8/8 | 8/8 | 8/8 | 8/8 | 8/8 | 8/8 | 0/8 | 8/8 | 0/8 | 8/8 | ✅ Done |
| grammar | 2/12 | 8/12 | 8/12 | 10/12 | 8/12 | 11/12 | 8/12 | 11/12 | 8/12 | 9/12 | 8/12 | 9/12 | 8/12 | 11/12 | 8/12 | 10/12 | 8/12 | 9/12 | LLM variance; comma splice persists for grammar-6 |
| fillers | 3/15 | 10/15 | 10/15 | 12/15 | 10/15 | 12/15 | 10/15 | 12/15 | 10/15 | 11/15 | 10/15 | 12/15 | 10/15 | 12/15 | 11/15 | 15/15 | 11/15 | 15/15 | ✅ Done |
| self-correction-det | 0/12 | 8/12 | 8/12 | 10/12 | **9/12** | **11/12** | 9/12 | **12/12** | 9/12 | **12/12** | 9/12 | **12/12** | 9/12 | **12/12** | 10/12 | 12/12 | 10/12 | 12/12 | ✅ Done |
| hinglish | 0/10 | 2/10 | 2/10 | 3/10 | 2/10 | 3/10 | 2/10 | 3/10 | 2/10 | 5/10 | 2/10 | 4/10 | 2/10 | 5/10 | 5/10 | 7/10 | **6/10** | **8/10** | Punct model boundary errors at Hindi particles |
| names-technical | 0/10 | 2/10 | 2/10 | 3/10 | 4/10 | 6/10 | 4/10 | 6/10 | **5/10** | **7/10** | 5/10 | 6/10 | 5/10 | 6/10 | 2/10 | 4/10 | 2/10 | **5/10** | Deterministic technical normalization / lexicon |
| cascading-corrections | 0/5 | 1/5 | 1/5 | 2/5 | **4/5** | **5/5** | 4/5 | 5/5 | 4/5 | 5/5 | 4/5 | 5/5 | 4/5 | 5/5 | 5/5 | 5/5 | 5/5 | 5/5 | ✅ Done |
| adversarial | 0/5 | 0/5 | 0/5 | 2/5 | 1/5 | 2/5 | 1/5 | 3/5 | 1/5 | 2/5 | 1/5 | 2/5 | 1/5 | 3/5 | 0/5 | 1/5 | 0/5 | 1/5 | Accept remaining; punct model immune |
| self-correction-llm | 0/10 | 0/10 | 0/10 | 0/10 | 0/10 | 0/10 | **5/10** | **7/10** | 5/10 | 7/10 | 6/10 | 7/10 | 6/10 | 7/10 | 9/10 | 9/10 | 9/10 | 9/10 | 1 remaining: punct model masks "well actually" |
| single-line | 1/5 | 0/5 | 3/5 | 3/5 | 2/5 | 4/5 | 2/5 | 4/5 | **4/5** | **5/5** | 4/5 | 5/5 | 4/5 | 5/5 | 3/5 | 5/5 | 3/5 | 5/5 | ✅ Done |

---

## Key Learnings

1. **Prompt engineering > model size** for sub-2B models. The example-driven prompt was worth more than switching to a model 3× larger.
2. **Qwen 3 0.6B is the sweet spot.** Fastest (0.33s), lowest RAM (~1 GB), and highest accuracy (47%). Bigger models (1.7B, 3.5 0.8B) were equal or worse quality at higher latency.
3. **Repetition penalty kills cleanup tasks.** Any penalty > 1.0 causes the model to drop repeated content words, which is catastrophic when the task is to output nearly the same text.
4. **Examples > rules for small models.** Concrete input→output pairs teach the transformation shape. Negation-heavy rules ("do NOT change X") confuse sub-1B models.
5. **Many "LLM failures" are actually deterministic problems.** Spoken-form normalization, capitalization after self-correction, and test expectation mismatches account for ~15-20 of the 53 remaining failures — no LLM needed.
6. **Adversarial resistance is fundamentally hard for chat LLMs.** Any model trained on instruction-following will sometimes follow adversarial instructions embedded in user content. The `<text>` delimiter + output validator is the best practical defense for on-device models. Token classifiers (punct models) are inherently immune.
7. **Exact string matching underestimates quality.** Many "failures" are acceptable alternatives (trailing periods, contraction preferences). LLM-as-Judge scoring is needed for accurate quality measurement.
8. **Context is the competitive moat, not model size.** WisprFlow uses much larger models server-side, but their quality advantage comes primarily from context injection (surrounding text, app awareness, user history) and personalization (learning from corrections).
9. **Decompose the LLM's task.** Rather than asking a 0.6B model to do punctuation + capitalization + grammar + style simultaneously, offload punctuation/capitalization to a specialized bidirectional encoder and let the LLM focus on grammar/style only.
10. **Upstream improvements compound.** Whisper prompt conditioning improves ASR output → cleaner input to the deterministic pipeline → less work for the LLM → better final quality. Each layer's output is the next layer's input.
11. **LLM-as-Judge reveals the true quality gap.** Exact match understates quality by ~11 points (50% exact vs 61% judge). Formatting quality (avg 0.52) and intent match (avg 0.47) are the worst dimensions — both primarily fixable by a dedicated punctuation model, not LLM tuning.
12. **Benchmark harness must match pipeline stages.** When the pipeline adds stages (SpokenFormNormalizer), the benchmark trace labels and pipeline steps must be updated to match. Stale benchmarks create diagnostic confusion.
13. **Cascading self-corrections need prefix preservation.** The current greedy approach to multiple corrections in one utterance loses sentence structure. Each correction should replace only the corrected segment, not discard the stable prefix.
14. **Implicit self-corrections are partially deterministic.** While "oh sorry", "wait hold on", and "no make that" look like they need LLM understanding, they're actually high-precision deterministic triggers. The boundary between deterministic and LLM-required is further out than initially assumed.
15. **Post-LLM deterministic guards catch reliable model weaknesses.** Small models consistently miss sentence-start capitalization. A deterministic guard after LLM output is safe, effective, and costs nothing — fixing 3 cases in this instance. Guard against known non-prose patterns (URLs, emails, paths, flags) to avoid false positives.
16. **Conditional prompt instructions are critical for small models.** Adding an always-present `<context_before>` instruction to the system prompt caused a 4-point regression (64→60% exact, 79→75% judge) on the 0.6B model — even though the instruction was unused in benchmarks. Making it conditional (only included when surrounding text exists) recovered to 65%/78%. Small models have limited attention budgets; every unused instruction is wasted capacity.
17. **Benchmark scores plateau when features target production-only scenarios.** Phase 3's context injection benefits real users (surrounding text helps continuity/capitalization) but can't be measured by the benchmark (which feeds raw text without cursor context). This is expected — the benchmark measures the pipeline's baseline, not its ceiling.
18. **Upstream pipeline stages can mask LLM prompt patterns.** The punct model transforms "well actually" into ", well, actually" with commas, which prevents the LLM from recognizing it as a self-correction trigger even when the prompt includes an explicit example. Pipeline ordering matters — deterministic correction should run before punctuation model to preserve correction markers.
19. **Conditional examples per cleanup level prevent contradiction.** A self-correction example (which teaches content deletion) contradicts `.light` mode's instruction to "Keep all words the same." Making examples conditional by cleanup level avoids this. The approach: base examples for all levels, specialized examples only for `.medium`/`.full`.
20. **Prompt tuning has diminishing returns at 85%+.** The remaining failures are mostly upstream (punct model boundary errors, technical normalization) or inherently hard (adversarial). Further prompt examples won't help cases where the LLM sees already-corrupted input from earlier pipeline stages.

---

## File Change Summary

| File | Status | Changes |
|---|---|---|
| `TextProcessing/SpokenFormNormalizer.swift` | ✅ Done | Deterministic spoken-form → symbol conversion (365 lines, all patterns) |
| `TextProcessing/NumberNormalizer.swift` | ❌ Not started | Number/date/time inverse text normalization |
| `Tests/SpokenFormNormalizerTests.swift` | ✅ Done | 36 unit tests covering all pattern types + post-colon capitalization |
| `Tests/NumberNormalizerTests.swift` | ❌ Not started | Unit tests for number normalizer |
| `LLM/LocalLLMProcessor.swift` | ✅ Done | Capitalize short bypass results (Fix 2a) + post-LLM first-letter capitalization guard (Phase 2.5 P4) + **conditional `<context_before>` block support** (Phase 3) + **Phase 6: Hindi particle rule, self-correction instruction/examples (medium/full), content-drop guard with correction-marker awareness** |
| `TextProcessing/TextProcessor.swift` | ✅ Done | SpokenFormNormalizer integrated; Fix 2b capitalization |
| `TextProcessing/SelfCorrectionDetector.swift` | ✅ Done | Fix 2b capitalization + prefix preservation (Phase 2.5 P2) + **implicit correction markers with biasFragmentMerge, validation guards, sentence-start guard** (Phase 2.5 P3) |
| `Transcription/TranscriptionPipeline.swift` | ✅ Done | TextProcessor wired in; Whisper prompt conditioning via `sessionAppCategory` (captured at session start); context injection via `captureSurrounding: true` at finalize time |
| `TextInsertion/InsertionContext.swift` | ✅ Done | Added `surroundingText` property via AX API; `captureSurroundingText()`, `isSecureField()` (fail-closed), `getFocusedElement()` with CF type guard; `captureSurrounding` parameter on `current()` |
| `Models/PunctuationModelRunner.swift` | ❌ Not started | ONNX/CoreML wrapper for punctuation model inference (SentencePiece tokenizer, 128-token sliding window, label reconstruction) |
| `LLM/LLMModelCatalog.swift` | ❌ Not started | Add LFM2.5-1.2B-Instruct entry |
| `Tests/CleanupQualityTests.swift` | ✅ Done | Fix 2c fully applied; per-stage trace working |
| `Tests/LocalLLMProcessorTests.swift` | ✅ Done | **New file** — 20 unit tests: 12 for post-LLM capitalization guard (Phase 2.5 P4) + 3 for context injection / category prompts (Phase 3) + **5 for Phase 6 prompt composition + content-drop guard** |
| `Persistence/CorrectionStore.swift` | ❌ Not started | SQLite storage for user correction pairs |
| `TextProcessing/UserStylePreferences.swift` | ❌ Not started | User-specific formatting overrides |
| `scripts/llm_judge.py` | ✅ Done | LLM-as-Judge evaluation script — supports both compact and verbose benchmark output formats |
| `Transcription/TranscriptionPipeline.swift` | ✅ Done | See above |
| `TextInsertion/InsertionContext.swift` | ✅ Done | See above |
| `Models/PunctuationModelRunner.swift` | **New file** — ONNX/CoreML wrapper for punctuation model inference (SentencePiece tokenizer, 128-token sliding window, label reconstruction) |
| `LLM/LLMModelCatalog.swift` | Add LFM2.5-1.2B-Instruct entry |
| `Tests/CleanupQualityTests.swift` | Fix single-line test expectations; add LLM-as-Judge scoring |
| `Persistence/CorrectionStore.swift` | **New file** — SQLite storage for user correction pairs |
| `TextProcessing/UserStylePreferences.swift` | **New file** — user-specific formatting overrides |
| `scripts/judge_score.py` | **New file** — offline LLM-as-Judge evaluation script |

---

## Target Metrics (Revised)

| Metric | Baseline | Phase 0-1-2 (actual) | Phase 2.5-P2 (actual) | Phase 2.5-P3 (actual) | Phase 2.5-P4 (actual) | Phase 3 (actual) | Phase 4 (actual) | Phase 6 (actual) |
|---|---|---|---|---|---|---|---|---|
| Pass rate (exact match) | 47% | **50%** | **56%** | **61%** | **64%** | **65%** | **61%** | **62%** |
| Pass rate (judge score) | ~58% (est.) | **61%** | **70%** | **79%** | **79%** | **78%** | **84%** | **85%** |
| Avg latency (LLM cases) | 0.33s | 0.33s | 0.34s | 0.32s | 0.31s | 0.31s | 0.31s | 0.37s |
| RAM (total models) | ~1 GB | ~1 GB | ~1 GB | ~1 GB | ~1 GB | ~1 GB | ~2 GB | ~2 GB |
| Default model | Qwen 3 0.6B | Qwen 3 0.6B | Qwen 3 0.6B | Qwen 3 0.6B | Qwen 3 0.6B | Qwen 3 0.6B | Qwen 3 0.6B | Qwen 3 0.6B |
| Pipeline stages | 4 | 5 (+SpokenForm) | 5 | 5 | 5 | 5 | 6 (+punct model) | 6 |

---

## Architecture: Current vs Target Pipeline

### Current (62% exact / 85% judge)

```
Whisper (prompt-conditioned, category-aware) → SelfCorrection → FillerRemoval → SpokenFormNorm → PunctModel (xlm-roberta, punct+truecasing) → LLM (grammar+style, 7 examples, context-injected) → Insert
```

### Target (85%+)

```
Whisper (prompt-conditioned)
    ↓
SelfCorrection → FillerRemoval → SpokenFormNorm → NumberNorm
    ↓
PunctuationModel (punct + truecasing — bidirectional encoder, 2-30ms, 128-token sliding window)
    ↓
LLM (grammar + style ONLY — simplified task, context-injected)
    ↓
UserStyleOverrides (personalization dictionary)
    ↓
Insert (with correction tracking)
```

**Punctuation model candidates:** punct_cap_seg_47 (~40M, ~2-5ms) or xlm-r_punct_truecase (~278M, ~10-30ms). Selected via Phase 4 evaluation. Both provide neural truecasing + sentence segmentation via native ONNX, 47 languages including Hindi.

**Key architectural shift:** The LLM goes from being the *only* quality layer to being the *final* quality layer in a multi-stage pipeline. Each stage handles what it's best at:
- Deterministic rules: symbols, numbers, fillers, self-correction (0ms, perfect precision)
- Bidirectional encoder: punctuation, capitalization (2-30ms, high recall, 128-token windows)
- Autoregressive LLM: grammar, style, tone (330ms, context-aware)
- User overrides: personalization (0ms, learned preferences)
