#!/usr/bin/env python3
"""
Phase 4 Step 1: Punctuation Model Evaluation Script

Evaluates two punctuation/truecasing models on all 100 benchmark cases:
  - Candidate A: 1-800-BAD-CODE/punct_cap_seg_47_language (~40M, ~2-5ms)
  - Candidate B: 1-800-BAD-CODE/xlm-roberta_punctuation_fullstop_truecase (~278M, ~10-30ms)

Measures:
  - Per-category punctuation F1 (period, comma, question mark, exclamation)
  - Truecasing accuracy (per-word capitalization match)
  - Word preservation rate (model shouldn't change content words)
  - Latency on Apple Silicon

Tests two pipeline orderings:
  A) After deterministic cleanup (self-correction → fillers → spoken forms → punct model)
  B) Before filler removal (self-correction → punct model → fillers → spoken forms)

Usage:
    cd /path/to/aawaaz
    source .venv/bin/activate
    python3 scripts/punct_model_eval.py [--skip-ordering-b] [--verbose]
"""

import json
import re
import sys
import time
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path


# ── Test Case Extraction ─────────────────────────────────────────────────────

@dataclass
class TestCase:
    id: str
    category: str
    input_text: str
    expected: str
    cleanup_level: str  # light, medium, full, heavy
    context_app: str  # Notes, Safari, Xcode, Terminal, Messages, Mail
    context_bundle: str
    context_field_type: str  # singleLine, multiLine

    @property
    def is_code_terminal(self) -> bool:
        return self.context_app in ("Xcode", "Terminal")


def parse_test_cases_from_swift(swift_path: str) -> list[TestCase]:
    """Parse test cases from CleanupQualityTests.swift."""
    with open(swift_path, encoding="utf-8") as f:
        content = f.read()

    # Extract the test cases array region
    start = content.find("return [")
    if start == -1:
        raise ValueError(f"Cannot find 'return [' in {swift_path}")

    end = content.find("    ]\n    }()", start)
    if end == -1:
        end = content.find("        ]\n    }()", start)
    if end == -1:
        raise ValueError(f"Cannot find closing ']' of test case array in {swift_path}")

    cases_text = content[start:end]

    # Context variable mappings
    context_map = {
        "def": ("Notes", "com.apple.Notes", "multiLine"),
        "single": ("Safari", "com.apple.Safari", "singleLine"),
        "code": ("Xcode", "com.apple.dt.Xcode", "multiLine"),
        "term": ("Terminal", "com.apple.Terminal", "multiLine"),
        "chat": ("Messages", "com.apple.MobileSMS", "multiLine"),
        "email": ("Mail", "com.apple.mail", "multiLine"),
    }

    # Parse each CleanupTestCase(...)
    pattern = re.compile(
        r'CleanupTestCase\(\s*'
        r'id:\s*"([^"]+)",\s*'
        r'category:\s*"([^"]+)",\s*'
        r'input:\s*"((?:[^"\\]|\\.)*)",\s*'
        r'expected:\s*"((?:[^"\\]|\\.)*)",\s*'
        r'cleanupLevel:\s*\.(\w+),\s*'
        r'context:\s*(\w+)\s*'
        r'\)',
        re.DOTALL
    )

    cases = []
    for m in pattern.finditer(cases_text):
        tc_id = m.group(1)
        category = m.group(2)
        input_text = m.group(3).replace('\\"', '"').replace('\\n', '\n')
        expected = m.group(4).replace('\\"', '"').replace('\\n', '\n')
        cleanup_level = m.group(5)
        ctx_var = m.group(6)

        if ctx_var not in context_map:
            raise ValueError(f"Unknown context variable '{ctx_var}' in test case '{tc_id}'")

        app, bundle, field_type = context_map[ctx_var]

        cases.append(TestCase(
            id=tc_id,
            category=category,
            input_text=input_text,
            expected=expected,
            cleanup_level=cleanup_level,
            context_app=app,
            context_bundle=bundle,
            context_field_type=field_type,
        ))

    # Validate extraction
    ids = [tc.id for tc in cases]
    if len(ids) != len(set(ids)):
        dupes = [x for x in ids if ids.count(x) > 1]
        raise ValueError(f"Duplicate test case IDs: {set(dupes)}")

    return cases


# ── Deterministic Pipeline (Python approximation) ────────────────────────────

# Default filler words from TextProcessingConfig.swift
DEFAULT_FILLER_WORDS = ["um", "uh", "erm", "hmm", "you know", "basically", "literally"]

# "you know" guard words: don't remove "you know" if preceded by these
YOU_KNOW_GUARD_WORDS = {
    "do", "did", "didn't", "don't", "doesn't", "if", "whether", "that",
    "could", "would", "should", "can", "will", "might", "may",
    "won't", "couldn't", "wouldn't", "shouldn't", "shall",
}

# Self-correction markers (ordered by priority)
STANDALONE_RESTART_MARKERS = [
    "let me start over", "let me rephrase", "scratch that", "actually no",
    "never mind", "nevermind", "forget that", "forget it", "start over",
    "no no no", "no no",
]

IMPLICIT_CORRECTION_MARKERS = [
    "oops i meant", "on second thought", "wait hold on", "no make that",
    "oh sorry", "or rather", "no wait", "nah use", "correction",
]

# Markers that need leading punctuation (comma, period) to trigger
PUNCTUATION_GATED_MARKERS = ["i mean", "sorry", "wait"]


def apply_self_correction(text: str) -> str:
    """Simplified self-correction detection mirroring SelfCorrectionDetector.swift.

    Handles standalone restart markers, implicit markers, and comma-delimited corrections.
    Loops until no more markers are found (handles cascading corrections).
    """
    # Phase 1: Standalone restart markers - loop until none found
    changed = True
    while changed:
        changed = False
        lower = text.lower()
        for marker in STANDALONE_RESTART_MARKERS:
            idx = lower.rfind(marker)
            if idx != -1:
                after = text[idx + len(marker):].strip()
                if after.startswith(","):
                    after = after[1:].strip()
                if after:
                    text = after
                    changed = True
                    break

    # Phase 2: Implicit correction markers
    lower = text.lower()
    for marker in IMPLICIT_CORRECTION_MARKERS:
        idx = lower.find(marker)
        if idx != -1:
            after = text[idx + len(marker):].strip()
            if after.startswith(","):
                after = after[1:].strip()
            if after:
                text = after
                lower = text.lower()
                break

    # Phase 3: Punctuation-gated markers (need comma/period before them)
    for marker in PUNCTUATION_GATED_MARKERS:
        pattern = re.compile(
            r',\s*' + re.escape(marker) + r'\s*,?\s*',
            re.IGNORECASE,
        )
        m = pattern.search(text)
        if m:
            before = text[:m.start()].strip()
            after = text[m.end():].strip()
            if after:
                text = before + " " + after if before else after
                break

    return text


def apply_post_correction_capitalization(original: str, corrected: str, is_code_terminal: bool) -> str:
    """Capitalize first char after significant self-correction (>50% word reduction)."""
    if is_code_terminal:
        return corrected
    before_words = len(original.split())
    after_words = len(corrected.split())
    if before_words > 0 and after_words > 0:
        if after_words / before_words <= 0.5:
            if corrected and corrected[0].islower():
                corrected = corrected[0].upper() + corrected[1:]
    return corrected


def remove_fillers(text: str, filler_words: list[str] | None = None) -> str:
    """Remove filler words, mirroring FillerWordRemover.swift."""
    if filler_words is None:
        filler_words = DEFAULT_FILLER_WORDS

    # Sort by length descending (so "you know" matches before "you")
    sorted_fillers = sorted(filler_words, key=len, reverse=True)

    result = text
    for filler in sorted_fillers:
        escaped = re.escape(filler)
        # Handle optional surrounding commas
        pattern = re.compile(r'(,\s*)?\b' + escaped + r'\b(\s*,)?', re.IGNORECASE)

        if filler == "you know":
            # Guard: don't remove if preceded by guard word
            def guarded_replace(m):
                start = m.start()
                preceding = result[:start].rstrip()
                last_word = preceding.split()[-1].lower() if preceding.split() else ""
                if last_word in YOU_KNOW_GUARD_WORDS:
                    return m.group(0)  # Keep it
                return ""
            result = pattern.sub(guarded_replace, result)
        else:
            result = pattern.sub("", result)

    # Cleanup
    result = re.sub(r'\s{2,}', ' ', result)        # Collapse spaces
    result = re.sub(r'\s+([.,!?;:])', r'\1', result)  # Space before punct
    result = re.sub(r'^\s*,\s*', '', result)         # Orphaned comma at start
    result = re.sub(r',\s*,', ',', result)           # Double commas
    result = result.strip()
    return result


# Spoken form normalization patterns
UNAMBIGUOUS_PATTERNS = [
    ("question mark", "?"),
    ("exclamation point", "!"),
    ("exclamation mark", "!"),
    ("open parenthesis", "("),
    ("close parenthesis", ")"),
    ("open paren", "("),
    ("close paren", ")"),
    ("open bracket", "["),
    ("close bracket", "]"),
    ("underscore", "_"),
    ("ampersand", "&"),
    ("at sign", "@"),
    ("percent sign", "%"),
    ("dollar sign", "$"),
    ("equals sign", "="),
]

KNOWN_EXTENSIONS = {
    "js", "ts", "jsx", "tsx", "py", "rb", "rs", "go", "swift", "java",
    "kt", "c", "cpp", "h", "cs", "php", "html", "css", "scss", "json",
    "xml", "yaml", "yml", "toml", "md", "txt", "pdf", "doc", "docx",
    "xls", "xlsx", "ppt", "pptx", "csv", "log", "env", "sh", "bash",
    "zsh", "fish", "conf", "cfg", "ini", "lock", "png", "jpg", "jpeg",
    "gif", "svg", "mp3", "mp4", "wav", "mov", "zip", "tar", "gz",
    "com", "org", "net", "io", "dev", "app", "ai", "co", "edu", "gov",
    "me", "us", "uk",
}


def normalize_spoken_forms(text: str, unambiguous_only: bool = False) -> str:
    """Normalize spoken forms to written symbols, mirroring SpokenFormNormalizer.swift."""
    result = text

    if not unambiguous_only:
        # URL patterns: "https colon slash slash X dot Y" → "https://X.Y"
        result = re.sub(
            r'\b(https?)\s+colon\s+slash\s+slash\s+',
            r'\1://',
            result, flags=re.IGNORECASE
        )

        # Email: "X at Y dot Z" → "X@Y.Z" (basic pattern)
        result = re.sub(
            r'(\w+)\s+at\s+(\w+)\s+dot\s+(\w+)',
            lambda m: f"{m.group(1)}@{m.group(2)}.{m.group(3)}"
            if m.group(3).lower() in KNOWN_EXTENSIONS
            else m.group(0),
            result
        )

        # Path segments: "slash X slash Y" → "/X/Y" (chain slashes)
        result = re.sub(
            r'(?:\bslash\s+)(\w+(?:\s+slash\s+\w+)*)',
            lambda m: "/" + re.sub(r'\s+slash\s+', '/', m.group(1)),
            result,
            flags=re.IGNORECASE,
        )

        # Dotted names: "X dot Y" where Y is a known extension
        def dotted_replace(m):
            before = m.group(1)
            after = m.group(2)
            if after.lower() in KNOWN_EXTENSIONS:
                return f"{before}.{after}"
            return m.group(0)
        result = re.sub(r'(\w+)\s+dot\s+(\w+)', dotted_replace, result)

        # Label colons: "re colon" → "Re:"
        result = re.sub(
            r'\b(re|fwd|fw|cc|bcc|subject|to|from|note|bug report|action item)\s+colon\s*',
            lambda m: m.group(1).title() + ": ",
            result, flags=re.IGNORECASE
        )

        # Command patterns: "dash dash X" → "--X", "dash X" → "-X"
        result = re.sub(r'\bdash\s+dash\s+(\w+)', r'--\1', result)
        result = re.sub(r'\bdash\s+(\w+)', r'-\1', result)

    # Unambiguous patterns (always applied)
    for spoken, written in UNAMBIGUOUS_PATTERNS:
        result = re.sub(
            r'\b' + re.escape(spoken) + r'\b',
            written,
            result, flags=re.IGNORECASE
        )

    # Ellipsis
    result = re.sub(r'\bdot\s+dot\s+dot\b', '...', result)

    # Symbol spacing cleanup
    result = re.sub(r'\s+([_&@%$=\[\]()])', r'\1', result)
    result = re.sub(r'([_&@%$=\[\](])\s+', r'\1', result)

    # Collapse spaces and trim
    result = re.sub(r'\s{2,}', ' ', result)
    return result.strip()


def run_deterministic_pipeline(tc: TestCase) -> str:
    """Run the 3-stage deterministic cleanup pipeline."""
    text = tc.input_text

    # Stage 1: Self-correction detection
    original = text
    text = apply_self_correction(text)
    text = apply_post_correction_capitalization(original, text, tc.is_code_terminal)

    # Stage 2: Filler removal
    text = remove_fillers(text)

    # Stage 3: Spoken-form normalization
    text = normalize_spoken_forms(text, unambiguous_only=tc.is_code_terminal)

    return text


def run_pipeline_ordering_b(tc: TestCase) -> str:
    """Pipeline ordering B: self-correction → punct model input (with fillers still present).

    Only runs self-correction, keeps fillers for the punct model to handle.
    """
    text = tc.input_text

    # Stage 1: Self-correction only
    original = text
    text = apply_self_correction(text)
    text = apply_post_correction_capitalization(original, text, tc.is_code_terminal)

    return text


# ── Punctuation/Casing Evaluation Metrics ─────────────────────────────────────

PUNCT_CHARS = {'.', ',', '?', '!', ':', ';'}


def extract_punct_labels(text: str) -> list[tuple[str, str]]:
    """Extract (word, trailing_punct) pairs from text.

    Returns list of (normalized_word, punct_after) where punct_after is
    the punctuation character(s) following the word, or '' if none.
    """
    # Split into tokens, preserving punctuation attached to words
    tokens = re.findall(r"[\w']+|[.,!?;:]", text)

    labels = []
    i = 0
    while i < len(tokens):
        token = tokens[i]
        if token in PUNCT_CHARS or (len(token) == 1 and not token.isalnum()):
            # This is standalone punctuation — attach to previous word
            if labels:
                word, prev_punct = labels[-1]
                labels[-1] = (word, prev_punct + token)
            i += 1
            continue

        # Check if next token is punctuation
        punct_after = ""
        while i + 1 < len(tokens) and tokens[i + 1] in PUNCT_CHARS:
            punct_after += tokens[i + 1]
            i += 1

        labels.append((token.lower(), punct_after))
        i += 1

    return labels


def compute_punct_f1(predicted_labels: list[tuple[str, str]],
                     expected_labels: list[tuple[str, str]]) -> dict:
    """Compute punctuation F1 scores by type.

    Aligns words between predicted and expected, then computes per-type F1.
    Returns None for F1 if neither predicted nor expected have any punctuation
    (N/A case — e.g., short inputs without expected punctuation).
    """
    # Build alignment using sequential matching
    aligned_pairs = align_word_sequences(predicted_labels, expected_labels)

    # Per punctuation type: count TP, FP, FN
    punct_types = {'.': 'period', ',': 'comma', '?': 'question', '!': 'exclamation',
                   ':': 'colon', ';': 'semicolon'}
    counts = {ptype: {'tp': 0, 'fp': 0, 'fn': 0} for ptype in punct_types.values()}
    counts['any'] = {'tp': 0, 'fp': 0, 'fn': 0}

    for pred_punct, exp_punct in aligned_pairs:
        for char, ptype in punct_types.items():
            pred_has = char in pred_punct
            exp_has = char in exp_punct
            if pred_has and exp_has:
                counts[ptype]['tp'] += 1
                counts['any']['tp'] += 1
            elif pred_has and not exp_has:
                counts[ptype]['fp'] += 1
                counts['any']['fp'] += 1
            elif not pred_has and exp_has:
                counts[ptype]['fn'] += 1
                counts['any']['fn'] += 1

    # Compute F1 for each type. Use None for N/A (no punctuation in either).
    results = {}

    for ptype, c in counts.items():
        total = c['tp'] + c['fp'] + c['fn']
        if total == 0:
            # No punctuation of this type in either prediction or expected → N/A
            results[ptype] = {'precision': None, 'recall': None, 'f1': None,
                              'tp': 0, 'fp': 0, 'fn': 0, 'na': True}
        else:
            precision = c['tp'] / (c['tp'] + c['fp']) if (c['tp'] + c['fp']) > 0 else 0
            recall = c['tp'] / (c['tp'] + c['fn']) if (c['tp'] + c['fn']) > 0 else 0
            f1 = 2 * precision * recall / (precision + recall) if (precision + recall) > 0 else 0
            results[ptype] = {'precision': precision, 'recall': recall, 'f1': f1,
                              'tp': c['tp'], 'fp': c['fp'], 'fn': c['fn'], 'na': False}

    return results


def align_word_sequences(pred_labels: list[tuple[str, str]],
                         exp_labels: list[tuple[str, str]]) -> list[tuple[str, str]]:
    """Align predicted and expected word sequences, returning paired punct labels.

    Uses simple sequential matching — words that match are aligned.
    Returns list of (pred_punct, exp_punct) for aligned positions.
    """
    aligned = []
    pi, ei = 0, 0

    while pi < len(pred_labels) and ei < len(exp_labels):
        pred_word, pred_punct = pred_labels[pi]
        exp_word, exp_punct = exp_labels[ei]

        if pred_word == exp_word:
            aligned.append((pred_punct, exp_punct))
            pi += 1
            ei += 1
        else:
            # Try to find match by looking ahead
            found_pred = False
            found_exp = False

            # Look ahead in expected for current pred word
            for look in range(1, min(4, len(exp_labels) - ei)):
                if ei + look < len(exp_labels) and exp_labels[ei + look][0] == pred_word:
                    # Skip unmatched expected words (they have FN punctuation)
                    for skip in range(look):
                        aligned.append(("", exp_labels[ei + skip][1]))
                    aligned.append((pred_punct, exp_labels[ei + look][1]))
                    ei += look + 1
                    pi += 1
                    found_exp = True
                    break

            if not found_exp:
                # Look ahead in predicted for current exp word
                for look in range(1, min(4, len(pred_labels) - pi)):
                    if pi + look < len(pred_labels) and pred_labels[pi + look][0] == exp_word:
                        # Skip unmatched predicted words
                        for skip in range(look):
                            aligned.append((pred_labels[pi + skip][1], ""))
                        aligned.append((pred_labels[pi + look][1], exp_punct))
                        pi += look + 1
                        ei += 1
                        found_pred = True
                        break

                if not found_pred:
                    # No match found — both advance
                    aligned.append((pred_punct, exp_punct))
                    pi += 1
                    ei += 1

    # Handle remaining
    while pi < len(pred_labels):
        aligned.append((pred_labels[pi][1], ""))
        pi += 1
    while ei < len(exp_labels):
        aligned.append(("", exp_labels[ei][1]))
        ei += 1

    return aligned


def compute_truecasing_accuracy(predicted: str, expected: str) -> dict:
    """Compare capitalization patterns between predicted and expected.

    Only compares words that appear in both strings (aligned by content).
    """
    pred_words = re.findall(r"[\w']+", predicted)
    exp_words = re.findall(r"[\w']+", expected)

    # Align by lowercase match
    aligned = []
    pi, ei = 0, 0
    while pi < len(pred_words) and ei < len(exp_words):
        if pred_words[pi].lower() == exp_words[ei].lower():
            aligned.append((pred_words[pi], exp_words[ei]))
            pi += 1
            ei += 1
        else:
            # Try lookahead
            found = False
            for look in range(1, min(4, len(exp_words) - ei)):
                if ei + look < len(exp_words) and pred_words[pi].lower() == exp_words[ei + look].lower():
                    ei += look
                    aligned.append((pred_words[pi], exp_words[ei]))
                    pi += 1
                    ei += 1
                    found = True
                    break
            if not found:
                pi += 1

    if not aligned:
        return {'accuracy': 0.0, 'total': 0, 'correct': 0, 'errors': []}

    correct = 0
    errors = []
    for pred_w, exp_w in aligned:
        if pred_w == exp_w:
            correct += 1
        else:
            # Check if it's a casing difference
            if pred_w.lower() == exp_w.lower():
                errors.append((pred_w, exp_w))
            else:
                correct += 1  # Word was changed — not a casing error

    total = len(aligned)
    return {
        'accuracy': correct / total if total > 0 else 0.0,
        'total': total,
        'correct': correct,
        'errors': errors[:5],  # Show first 5 errors
    }


def compute_word_preservation(model_output: str, pipeline_input: str) -> dict:
    """Check if the punct model preserved all content words (didn't add/remove words).

    Uses Counter-based comparison to catch duplicate drops/additions.
    """
    input_words = [w.lower() for w in re.findall(r"[\w']+", pipeline_input)]
    output_words = [w.lower() for w in re.findall(r"[\w']+", model_output)]

    input_counts = Counter(input_words)
    output_counts = Counter(output_words)

    # Words dropped (in input but not enough in output)
    dropped = []
    for word, count in input_counts.items():
        diff = count - output_counts.get(word, 0)
        if diff > 0:
            dropped.extend([word] * diff)

    # Words added (in output but not enough in input)
    added = []
    for word, count in output_counts.items():
        diff = count - input_counts.get(word, 0)
        if diff > 0:
            added.extend([word] * diff)

    total_words = max(len(input_words), 1)
    changes = len(dropped) + len(added)

    return {
        'preserved': changes == 0,
        'input_word_count': len(input_words),
        'output_word_count': len(output_words),
        'dropped_words': dropped[:5],
        'added_words': added[:5],
        'preservation_rate': 1.0 - changes / (total_words + len(added)),
    }


# ── Model Runner ──────────────────────────────────────────────────────────────

class PunctModelRunner:
    """Wrapper for running punctuation models via the `punctuators` library."""

    def __init__(self, model_id: str, name: str):
        self.model_id = model_id
        self.name = name
        self._model = None

    def load(self):
        from punctuators.models import PunctCapSegModelONNX
        print(f"  Loading {self.name} ({self.model_id})...", end="", flush=True)
        start = time.perf_counter()
        self._model = PunctCapSegModelONNX.from_pretrained(self.model_id)
        load_time = time.perf_counter() - start
        print(f" done ({load_time:.1f}s)")
        return load_time

    def predict(self, text: str) -> str:
        """Run inference and return punctuated/truecased text."""
        if not text.strip():
            return text

        results = self._model.infer(
            [text],
            apply_sbd=True,
            overlap=16,
        )

        # Results format: [[sentence1, sentence2, ...]]
        if results and results[0]:
            return " ".join(results[0])
        return text


# ── Main Evaluation ──────────────────────────────────────────────────────────

@dataclass
class CaseResult:
    id: str
    category: str
    input_text: str
    expected: str
    pipeline_input: str  # Text fed to punct model (after deterministic cleanup)
    model_output: str
    model_name: str
    ordering: str  # "A" or "B"
    latency_ms: float
    punct_f1: dict = field(default_factory=dict)
    truecasing: dict = field(default_factory=dict)
    word_preservation: dict = field(default_factory=dict)
    exact_match: bool = False


def evaluate_model(model: PunctModelRunner, cases: list[TestCase],
                   ordering: str = "A", verbose: bool = False) -> list[CaseResult]:
    """Run a model on all test cases and compute metrics."""
    results = []

    # Warmup run
    model.predict("hello world how are you")

    for tc in cases:
        # Get pipeline input based on ordering
        if ordering == "A":
            pipeline_input = run_deterministic_pipeline(tc)
        else:
            pipeline_input = run_pipeline_ordering_b(tc)

        # Run model
        start = time.perf_counter()
        raw_model_output = model.predict(pipeline_input)
        latency_ms = (time.perf_counter() - start) * 1000

        # For ordering B, apply remaining pipeline stages after punct model
        if ordering == "B":
            model_output = remove_fillers(raw_model_output)
            model_output = normalize_spoken_forms(model_output, unambiguous_only=tc.is_code_terminal)
        else:
            model_output = raw_model_output

        # Compute metrics — word preservation compares raw model output to its input
        # (not post-processed output, to avoid attributing deterministic changes to the model)
        pred_labels = extract_punct_labels(model_output)
        exp_labels = extract_punct_labels(tc.expected)
        punct_f1 = compute_punct_f1(pred_labels, exp_labels)
        truecasing = compute_truecasing_accuracy(model_output, tc.expected)
        word_pres = compute_word_preservation(raw_model_output, pipeline_input)

        exact = model_output.strip() == tc.expected.strip()

        result = CaseResult(
            id=tc.id,
            category=tc.category,
            input_text=tc.input_text,
            expected=tc.expected,
            pipeline_input=pipeline_input,
            model_output=model_output,
            model_name=model.name,
            ordering=ordering,
            latency_ms=latency_ms,
            punct_f1=punct_f1,
            truecasing=truecasing,
            word_preservation=word_pres,
            exact_match=exact,
        )
        results.append(result)

        if verbose:
            icon = "✅" if exact else "❌"
            print(f"  {icon} [{tc.id}]")
            print(f"     Input:    \"{tc.input_text}\"")
            print(f"     Pipeline: \"{pipeline_input}\"")
            print(f"     Output:   \"{model_output}\"")
            print(f"     Expected: \"{tc.expected}\"")
            print(f"     Latency:  {latency_ms:.1f}ms")
            if not exact:
                any_f1 = _f1_value(punct_f1, 'any')
                print(f"     Punct F1: {_fmt_f1(any_f1)}")
                print(f"     Casing:   {truecasing.get('accuracy', 0):.2f}")
            print()

    return results


def _f1_value(punct_f1_dict: dict, ptype: str) -> float | None:
    """Get F1 value from punct_f1 dict, returning None for N/A cases."""
    entry = punct_f1_dict.get(ptype, {})
    if entry.get('na', False):
        return None
    return entry.get('f1', 0)


def _avg_f1(values: list[float | None]) -> float | None:
    """Average F1 values, excluding None (N/A) entries."""
    valid = [v for v in values if v is not None]
    if not valid:
        return None
    return sum(valid) / len(valid)


def _fmt_f1(val: float | None) -> str:
    """Format F1 value for display, showing N/A for None."""
    if val is None:
        return "  N/A"
    return f"{val:>5.2f}"


def print_summary(results: list[CaseResult], model_name: str, ordering: str):
    """Print per-category summary of results."""
    print(f"\n{'='*80}")
    print(f"  {model_name} — Ordering {ordering}")
    print(f"{'='*80}\n")

    # Group by category
    by_category = defaultdict(list)
    for r in results:
        by_category[r.category].append(r)

    # Separate code/terminal from prose
    prose_categories = []
    guardrail_categories = []
    for cat in sorted(by_category.keys()):
        if cat == "code-terminal":
            guardrail_categories.append(cat)
        else:
            prose_categories.append(cat)

    # Header
    print(f"  {'Category':<25} {'Exact':>5} {'P-F1':>6} {'C-F1':>6} {'Q-F1':>6} {'All-F1':>6} "
          f"{'TrueCase':>8} {'WordPres':>8} {'Lat(ms)':>8}")
    print(f"  {'─'*25} {'─'*5} {'─'*6} {'─'*6} {'─'*6} {'─'*6} {'─'*8} {'─'*8} {'─'*8}")

    total_exact = 0
    total_count = 0
    all_punct_f1s = defaultdict(list)
    all_truecasing = []
    all_word_pres = []
    all_latencies = []

    for cat in prose_categories + guardrail_categories:
        cases = by_category[cat]
        n = len(cases)
        exact_count = sum(1 for r in cases if r.exact_match)

        # Aggregate punct F1 (excluding N/A)
        period_f1s = [_f1_value(r.punct_f1, 'period') for r in cases]
        comma_f1s = [_f1_value(r.punct_f1, 'comma') for r in cases]
        question_f1s = [_f1_value(r.punct_f1, 'question') for r in cases]
        any_f1s = [_f1_value(r.punct_f1, 'any') for r in cases]
        truecasing_accs = [r.truecasing.get('accuracy', 0) for r in cases]
        word_pres_rates = [r.word_preservation.get('preservation_rate', 0) for r in cases]
        latencies = [r.latency_ms for r in cases]

        avg_period = _avg_f1(period_f1s)
        avg_comma = _avg_f1(comma_f1s)
        avg_question = _avg_f1(question_f1s)
        avg_any = _avg_f1(any_f1s)
        avg_truecasing = sum(truecasing_accs) / n if n else 0
        avg_word_pres = sum(word_pres_rates) / n if n else 0
        avg_latency = sum(latencies) / n if n else 0

        prefix = "  " if cat not in guardrail_categories else "⚠ "
        print(f"{prefix}{cat:<25} {exact_count:>2}/{n:<2} {_fmt_f1(avg_period)} {_fmt_f1(avg_comma)} "
              f"{_fmt_f1(avg_question)} {_fmt_f1(avg_any)} {avg_truecasing:>7.2f} "
              f"{avg_word_pres:>7.2f} {avg_latency:>7.1f}")

        if cat not in guardrail_categories:
            total_exact += exact_count
            total_count += n
            for r in cases:
                for ptype in ['period', 'comma', 'question', 'any']:
                    f1_val = _f1_value(r.punct_f1, ptype)
                    if f1_val is not None:
                        all_punct_f1s[ptype].append(f1_val)
                all_truecasing.append(r.truecasing.get('accuracy', 0))
                all_word_pres.append(r.word_preservation.get('preservation_rate', 0))
                all_latencies.append(r.latency_ms)

    # Totals (prose only)
    n_prose = total_count
    print(f"  {'─'*25} {'─'*5} {'─'*6} {'─'*6} {'─'*6} {'─'*6} {'─'*8} {'─'*8} {'─'*8}")
    if n_prose > 0:
        print(f"  {'TOTAL (prose)':<25} {total_exact:>2}/{n_prose:<2}"
              f" {_fmt_f1(_avg_f1(all_punct_f1s['period']))}"
              f" {_fmt_f1(_avg_f1(all_punct_f1s['comma']))}"
              f" {_fmt_f1(_avg_f1(all_punct_f1s['question']))}"
              f" {_fmt_f1(_avg_f1(all_punct_f1s['any']))}"
              f" {sum(all_truecasing)/n_prose:>7.2f}"
              f" {sum(all_word_pres)/n_prose:>7.2f}"
              f" {sum(all_latencies)/n_prose:>7.1f}")

    # Latency stats
    if all_latencies:
        sorted_lat = sorted(all_latencies)
        p50 = sorted_lat[len(sorted_lat) // 2]
        p95 = sorted_lat[int(len(sorted_lat) * 0.95)]
        print(f"\n  Latency: avg={sum(all_latencies)/len(all_latencies):.1f}ms, "
              f"p50={p50:.1f}ms, p95={p95:.1f}ms")


def print_comparison(results_a: list[CaseResult], results_b: list[CaseResult],
                     ordering: str = "A"):
    """Print side-by-side comparison of two models."""
    print(f"\n{'='*80}")
    print(f"  HEAD-TO-HEAD COMPARISON — Ordering {ordering}")
    print(f"{'='*80}\n")

    # Build lookup
    a_by_id = {r.id: r for r in results_a}
    b_by_id = {r.id: r for r in results_b}

    # Group by category
    categories = sorted(set(r.category for r in results_a))
    prose_cats = [c for c in categories if c != "code-terminal"]

    print(f"  {'Category':<25} {'A-Exact':>7} {'B-Exact':>7} {'A-PunctF1':>9} {'B-PunctF1':>9} "
          f"{'A-TCase':>7} {'B-TCase':>7} {'A-Lat':>6} {'B-Lat':>6}")
    print(f"  {'─'*25} {'─'*7} {'─'*7} {'─'*9} {'─'*9} {'─'*7} {'─'*7} {'─'*6} {'─'*6}")

    a_total_exact = 0
    b_total_exact = 0
    total_count = 0

    for cat in prose_cats:
        a_cases = [r for r in results_a if r.category == cat]
        b_cases = [r for r in results_b if r.category == cat]
        n = len(a_cases)

        a_exact = sum(1 for r in a_cases if r.exact_match)
        b_exact = sum(1 for r in b_cases if r.exact_match)
        a_pf1_vals = [_f1_value(r.punct_f1, 'any') for r in a_cases]
        b_pf1_vals = [_f1_value(r.punct_f1, 'any') for r in b_cases]
        a_pf1 = _avg_f1(a_pf1_vals)
        b_pf1 = _avg_f1(b_pf1_vals)
        a_tc = sum(r.truecasing.get('accuracy', 0) for r in a_cases) / n if n else 0
        b_tc = sum(r.truecasing.get('accuracy', 0) for r in b_cases) / n if n else 0
        a_lat = sum(r.latency_ms for r in a_cases) / n if n else 0
        b_lat = sum(r.latency_ms for r in b_cases) / n if n else 0

        print(f"  {cat:<25} {a_exact:>2}/{n:<2}{'':<2} {b_exact:>2}/{n:<2}{'':<2} "
              f"{_fmt_f1(a_pf1):>8}{'':<1} {_fmt_f1(b_pf1):>8}{'':<1} "
              f"{a_tc:>6.2f}{'':<1} {b_tc:>6.2f}{'':<1} {a_lat:>5.1f}{'':<1} {b_lat:>5.1f}")

        a_total_exact += a_exact
        b_total_exact += b_exact
        total_count += n

    print(f"  {'─'*25} {'─'*7} {'─'*7} {'─'*9} {'─'*9} {'─'*7} {'─'*7} {'─'*6} {'─'*6}")
    print(f"  {'TOTAL (prose)':<25} {a_total_exact:>2}/{total_count:<2}    "
          f"{b_total_exact:>2}/{total_count:<2}")

    # Show cases where models differ
    print(f"\n  Cases where models differ (Ordering {ordering}):")
    print(f"  {'─'*70}")
    diff_count = 0
    for tc_id in sorted(a_by_id.keys()):
        a = a_by_id[tc_id]
        b = b_by_id[tc_id]
        if a.model_output.strip() != b.model_output.strip():
            diff_count += 1
            if diff_count <= 20:  # Show first 20
                winner = ""
                a_f1 = _f1_value(a.punct_f1, 'any') or 0
                b_f1 = _f1_value(b.punct_f1, 'any') or 0
                if a_f1 > b_f1 + 0.05:
                    winner = " ← A wins"
                elif b_f1 > a_f1 + 0.05:
                    winner = " → B wins"
                print(f"  [{tc_id}] ({a.category}){winner}")
                print(f"    Expected: \"{a.expected}\"")
                print(f"    A output: \"{a.model_output}\"")
                print(f"    B output: \"{b.model_output}\"")
                print()

    print(f"  Total differing cases: {diff_count}/{len(a_by_id)}")


def print_decision_recommendation(results_a_ord_a: list[CaseResult],
                                  results_b_ord_a: list[CaseResult],
                                  model_a_load_time: float,
                                  model_b_load_time: float):
    """Print final decision recommendation."""
    print(f"\n{'='*80}")
    print("  DECISION GATE")
    print(f"{'='*80}\n")

    # Key categories for decision
    key_categories = {"hinglish", "grammar", "names-technical", "single-line"}
    prose_categories = {r.category for r in results_a_ord_a if r.category != "code-terminal"}

    # Compute overall metrics for each model
    def model_metrics(results, categories):
        cases = [r for r in results if r.category in categories]
        n = len(cases)
        if n == 0:
            return {}
        return {
            'exact_match': sum(1 for r in cases if r.exact_match) / n,
            'punct_f1': _avg_f1([_f1_value(r.punct_f1, 'any') for r in cases]),
            'period_f1': _avg_f1([_f1_value(r.punct_f1, 'period') for r in cases]),
            'comma_f1': _avg_f1([_f1_value(r.punct_f1, 'comma') for r in cases]),
            'question_f1': _avg_f1([_f1_value(r.punct_f1, 'question') for r in cases]),
            'truecasing': sum(r.truecasing.get('accuracy', 0) for r in cases) / n,
            'word_preservation': sum(r.word_preservation.get('preservation_rate', 0) for r in cases) / n,
            'avg_latency_ms': sum(r.latency_ms for r in cases) / n,
        }

    a_all = model_metrics(results_a_ord_a, prose_categories)
    b_all = model_metrics(results_b_ord_a, prose_categories)
    a_key = model_metrics(results_a_ord_a, key_categories)
    b_key = model_metrics(results_b_ord_a, key_categories)

    print("  Overall Metrics (prose categories, Ordering A):")
    print(f"  {'Metric':<25} {'Candidate A':>12} {'Candidate B':>12} {'Winner':>8}")
    print(f"  {'─'*25} {'─'*12} {'─'*12} {'─'*8}")

    metrics = [
        ('Punct F1 (all)', 'punct_f1'),
        ('Period F1', 'period_f1'),
        ('Comma F1', 'comma_f1'),
        ('Question F1', 'question_f1'),
        ('Truecasing Acc', 'truecasing'),
        ('Word Preservation', 'word_preservation'),
        ('Avg Latency (ms)', 'avg_latency_ms'),
    ]

    for label, key in metrics:
        a_val = a_all.get(key, 0)
        b_val = b_all.get(key, 0)
        if a_val is None and b_val is None:
            print(f"  {label:<25} {'N/A':>12} {'N/A':>12} {'N/A':>8}")
        elif key == 'avg_latency_ms':
            winner = "A" if a_val < b_val else "B"
            print(f"  {label:<25} {a_val:>11.1f} {b_val:>11.1f} {'A ←' if winner == 'A' else 'B →':>8}")
        else:
            a_v = a_val if a_val is not None else 0
            b_v = b_val if b_val is not None else 0
            winner = "A" if a_v > b_v + 0.02 else ("B" if b_v > a_v + 0.02 else "tie")
            print(f"  {label:<25} {a_v:>11.3f} {b_v:>11.3f} "
                  f"{'A ←' if winner == 'A' else ('B →' if winner == 'B' else 'tie'):>8}")

    print(f"\n  Key Categories (hinglish, grammar, names-technical, single-line):")
    print(f"  {'Metric':<25} {'Candidate A':>12} {'Candidate B':>12} {'Winner':>8}")
    print(f"  {'─'*25} {'─'*12} {'─'*12} {'─'*8}")

    for label, key in metrics:
        a_val = a_key.get(key, 0)
        b_val = b_key.get(key, 0)
        if a_val is None and b_val is None:
            print(f"  {label:<25} {'N/A':>12} {'N/A':>12} {'N/A':>8}")
        elif key == 'avg_latency_ms':
            winner = "A" if a_val < b_val else "B"
            print(f"  {label:<25} {a_val:>11.1f} {b_val:>11.1f} {'A ←' if winner == 'A' else 'B →':>8}")
        else:
            a_v = a_val if a_val is not None else 0
            b_v = b_val if b_val is not None else 0
            winner = "A" if a_v > b_v + 0.02 else ("B" if b_v > a_v + 0.02 else "tie")
            print(f"  {label:<25} {a_v:>11.3f} {b_v:>11.3f} "
                  f"{'A ←' if winner == 'A' else ('B →' if winner == 'B' else 'tie'):>8}")

    print(f"\n  Model Load Time: A={model_a_load_time:.1f}s, B={model_b_load_time:.1f}s")
    print(f"  Model Size: A=~160MB (ONNX), B=~280MB (ONNX)")

    # Decision logic (treat None as 0 for comparisons)
    def _or0(v):
        return v if v is not None else 0

    b_quality_advantage = (
        _or0(b_all.get('punct_f1')) > _or0(a_all.get('punct_f1')) + 0.05
        or _or0(b_key.get('punct_f1')) > _or0(a_key.get('punct_f1')) + 0.05
        or _or0(b_all.get('truecasing')) > _or0(a_all.get('truecasing')) + 0.05
    )

    a_quality_sufficient = (
        _or0(a_all.get('comma_f1')) >= 0.5
        and _or0(a_all.get('truecasing')) >= 0.85
    )

    print(f"\n  Decision Criteria:")
    print(f"  • A comma F1 ≥ 0.50: {'✅' if _or0(a_all.get('comma_f1')) >= 0.5 else '❌'} "
          f"(actual: {_or0(a_all.get('comma_f1')):.3f})")
    print(f"  • A truecasing ≥ 0.85: {'✅' if _or0(a_all.get('truecasing')) >= 0.85 else '❌'} "
          f"(actual: {_or0(a_all.get('truecasing')):.3f})")
    print(f"  • B quality advantage (>5pt): {'YES' if b_quality_advantage else 'NO'}")

    if a_quality_sufficient and not b_quality_advantage:
        print(f"\n  ✅ RECOMMENDATION: Candidate A (punct_cap_seg_47_language)")
        print(f"     Reason: Quality is sufficient and speed advantage is significant.")
    elif b_quality_advantage:
        print(f"\n  ✅ RECOMMENDATION: Candidate B (xlm-roberta_punctuation_fullstop_truecase)")
        print(f"     Reason: B has a clear quality advantage that justifies the extra latency.")
    else:
        print(f"\n  ⚠️ RECOMMENDATION: Candidate A (tentative — comma F1 or truecasing weak)")
        print(f"     Reason: A is faster, but may need further evaluation on speech-like input.")


def save_results(all_results: dict, output_path: str):
    """Save detailed results to JSON for later analysis."""

    def make_serializable(obj):
        if isinstance(obj, CaseResult):
            d = {
                'id': obj.id,
                'category': obj.category,
                'input_text': obj.input_text,
                'expected': obj.expected,
                'pipeline_input': obj.pipeline_input,
                'model_output': obj.model_output,
                'model_name': obj.model_name,
                'ordering': obj.ordering,
                'latency_ms': obj.latency_ms,
                'exact_match': obj.exact_match,
                'punct_f1_any': _f1_value(obj.punct_f1, 'any'),
                'truecasing_accuracy': obj.truecasing.get('accuracy', 0),
                'word_preservation_rate': obj.word_preservation.get('preservation_rate', 0),
            }
            return d
        return obj

    output = {}
    for key, results in all_results.items():
        output[key] = [make_serializable(r) for r in results]

    with open(output_path, 'w') as f:
        json.dump(output, f, indent=2)
    print(f"\n  Results saved to {output_path}")


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Phase 4 Step 1: Punctuation Model Evaluation")
    parser.add_argument("--skip-ordering-b", action="store_true",
                        help="Skip pipeline ordering B evaluation")
    parser.add_argument("--verbose", "-v", action="store_true",
                        help="Show per-case details")
    parser.add_argument("--output", "-o", default="punct-model-eval-results.json",
                        help="Output JSON file path")
    args = parser.parse_args()

    # Find project root
    script_dir = Path(__file__).parent
    project_root = script_dir.parent
    swift_test_path = project_root / "Aawaaz" / "Tests" / "CleanupQualityTests.swift"

    if not swift_test_path.exists():
        print(f"ERROR: Cannot find test cases at {swift_test_path}")
        sys.exit(1)

    # Parse test cases
    print("━━━ Phase 4 Step 1: Punctuation Model Evaluation ━━━\n")
    print("Parsing test cases from Swift...", end="")
    cases = parse_test_cases_from_swift(str(swift_test_path))
    print(f" found {len(cases)} cases across {len(set(tc.category for tc in cases))} categories\n")

    if len(cases) != 100:
        print(f"\nERROR: Expected 100 test cases but found {len(cases)}. "
              "Parser may be broken or test file changed.")
        sys.exit(1)

    # Load models
    print("Loading models:")
    model_a = PunctModelRunner(
        "pcs_47lang",
        "Candidate A (punct_cap_seg_47lang)"
    )
    model_b = PunctModelRunner(
        "1-800-BAD-CODE/xlm-roberta_punctuation_fullstop_truecase",
        "Candidate B (xlm-roberta)"
    )
    load_time_a = model_a.load()
    load_time_b = model_b.load()
    print()

    all_results = {}

    # ── Ordering A: After full deterministic cleanup ──
    print("━━━ Ordering A: After deterministic cleanup ━━━\n")

    print(f"Running Candidate A...")
    results_a_ord_a = evaluate_model(model_a, cases, ordering="A", verbose=args.verbose)
    print_summary(results_a_ord_a, model_a.name, "A")
    all_results["candidate_a_ordering_a"] = results_a_ord_a

    print(f"\nRunning Candidate B...")
    results_b_ord_a = evaluate_model(model_b, cases, ordering="A", verbose=args.verbose)
    print_summary(results_b_ord_a, model_b.name, "A")
    all_results["candidate_b_ordering_a"] = results_b_ord_a

    # Comparison
    print_comparison(results_a_ord_a, results_b_ord_a, "A")

    # ── Ordering B: Before filler removal ──
    if not args.skip_ordering_b:
        print("\n━━━ Ordering B: Before filler removal ━━━\n")

        print(f"Running Candidate A...")
        results_a_ord_b = evaluate_model(model_a, cases, ordering="B", verbose=args.verbose)
        print_summary(results_a_ord_b, model_a.name, "B")
        all_results["candidate_a_ordering_b"] = results_a_ord_b

        print(f"\nRunning Candidate B...")
        results_b_ord_b = evaluate_model(model_b, cases, ordering="B", verbose=args.verbose)
        print_summary(results_b_ord_b, model_b.name, "B")
        all_results["candidate_b_ordering_b"] = results_b_ord_b

        print_comparison(results_a_ord_b, results_b_ord_b, "B")

    # Decision
    print_decision_recommendation(results_a_ord_a, results_b_ord_a, load_time_a, load_time_b)

    # Save results
    save_results(all_results, args.output)

    print("\n━━━ Evaluation Complete ━━━\n")


if __name__ == "__main__":
    main()
