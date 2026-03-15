#!/usr/bin/env python3
"""
LLM-as-Judge Scoring Script for Aawaaz Dictation Cleanup Quality

Phase 0, Layer 0 of the quality improvement plan.

Scores all 100 test cases (focusing on the 53 failing ones) using an LLM judge
to determine whether actual outputs are semantically acceptable even when they
don't exactly match the expected output.

Four scoring dimensions (0.0 to 1.0):
  1. Semantic preservation — Does the output preserve the intended meaning?
  2. Formatting quality — Is punctuation, capitalization, spacing correct?
  3. Content fidelity — Were all content words preserved (no hallucination/drops)?
  4. Intent match — Would a reasonable user accept this as their dictated text?

A case PASSES if all dimensions score >= 0.75.

Usage:
    GEMINI_API_KEY=... python3 scripts/llm_judge.py [--results-file FILE] [--model MODEL]
"""

import argparse
import json
import os
import re
import sys
import time
from dataclasses import dataclass
from typing import Optional


# ── Data Structures ──────────────────────────────────────────────────────────

PASS_THRESHOLD = 0.75

@dataclass
class TestCase:
    id: str
    category: str
    input_text: str
    expected: str
    actual: str
    exact_match: bool
    context: str = "Notes"  # app context (Notes, Terminal, Xcode, Safari, etc.)


@dataclass
class JudgeScore:
    semantic_preservation: float
    formatting_quality: float
    content_fidelity: float
    intent_match: float
    overall_pass: bool
    reasoning: str

    @property
    def min_score(self) -> float:
        return min(
            self.semantic_preservation,
            self.formatting_quality,
            self.content_fidelity,
            self.intent_match,
        )

    @property
    def avg_score(self) -> float:
        return (
            self.semantic_preservation
            + self.formatting_quality
            + self.content_fidelity
            + self.intent_match
        ) / 4.0


@dataclass
class ScoredCase:
    test_case: TestCase
    judge_score: Optional[JudgeScore] = None


# ── Test Case Extraction (from Swift source) ─────────────────────────────────

def extract_test_cases_from_swift(swift_path: str) -> list[TestCase]:
    """Parse CleanupQualityTests.swift to extract all test case definitions."""
    with open(swift_path, "r") as f:
        content = f.read()

    # Match CleanupTestCase(...) blocks, including context
    pattern = re.compile(
        r'CleanupTestCase\(\s*'
        r'id:\s*"([^"]+)"\s*,\s*'
        r'category:\s*"([^"]+)"\s*,\s*'
        r'input:\s*"((?:[^"\\]|\\.)*)"\s*,\s*'
        r'expected:\s*"((?:[^"\\]|\\.)*)"\s*,\s*'
        r'cleanupLevel:\s*\.\w+\s*,\s*'
        r'context:\s*(\w+)',
        re.DOTALL,
    )

    # Map Swift variable names to descriptive context labels
    context_map = {
        "def": "Notes",
        "single": "Safari (single-line field)",
        "code": "Xcode (code editor)",
        "term": "Terminal",
        "chat": "Messages (chat)",
        "email": "Mail",
    }

    cases = []
    for m in pattern.finditer(content):
        ctx_var = m.group(5)
        tc = TestCase(
            id=m.group(1),
            category=m.group(2),
            input_text=m.group(3).replace('\\"', '"').replace("\\n", "\n"),
            expected=m.group(4).replace('\\"', '"').replace("\\n", "\n"),
            actual="",
            exact_match=False,
            context=context_map.get(ctx_var, ctx_var),
        )
        cases.append(tc)

    return cases


# ── Benchmark Result Parsing ─────────────────────────────────────────────────

def parse_benchmark_results(results_path: str, model_name: str = "Qwen3-0.6B-6bit") -> dict[str, str]:
    """Parse benchmark output file to extract actual outputs for a specific model.

    Returns a dict mapping test case ID → actual output string.
    """
    with open(results_path, "r") as f:
        lines = f.readlines()

    actuals: dict[str, str] = {}
    found_results = False

    for line in lines:
        stripped = line.strip()

        m_pass = re.match(r'\[([^\]]+)\]\s*✅', stripped)
        m_fail = re.match(r'\[([^\]]+)\]\s*❌\s*[\d.]+s\s+got:\s*"(.*)"$', stripped)

        if m_pass:
            found_results = True
            actuals[m_pass.group(1)] = "__EXACT_MATCH__"
        elif m_fail:
            found_results = True
            actuals[m_fail.group(1)] = m_fail.group(2)

        # Stop at first model summary line after collecting results
        if found_results and model_name in stripped and "passed" in stripped:
            break

    return actuals


def merge_cases_with_results(
    cases: list[TestCase], actuals: dict[str, str]
) -> list[TestCase]:
    """Merge extracted test cases with actual outputs from benchmark results."""
    for tc in cases:
        actual = actuals.get(tc.id, "")
        if actual == "__EXACT_MATCH__":
            tc.actual = tc.expected
            tc.exact_match = True
        else:
            tc.actual = actual
            tc.exact_match = actual.strip() == tc.expected.strip() if actual else False
    return cases


# ── LLM Judge ────────────────────────────────────────────────────────────────

JUDGE_PROMPT = """\
You are an expert evaluator for a dictation cleanup system. The system takes raw \
speech-to-text output and cleans it up (fix capitalization, punctuation, grammar, \
remove filler words, handle self-corrections).

The user is dictating into: **{context}**

Score this dictation cleanup result on four dimensions. Each score is 0.0 to 1.0.

**Scoring Dimensions:**

1. **Semantic preservation** (0.0–1.0): Does the output preserve the intended \
meaning of what the person dictated? Deduct for lost meaning, changed intent, \
or dropped important information. Self-corrections should be resolved (keep the \
corrected version, drop the original).

2. **Formatting quality** (0.0–1.0): Is punctuation, capitalization, and spacing \
correct for the target context? Consider: sentence-initial caps, proper noun caps, \
appropriate end punctuation (periods for statements, question marks for questions), \
comma usage. Minor style differences (e.g., period vs. no period on short phrases, \
comma placement variations) should score 0.85+, not 0.0.

3. **Content fidelity** (0.0–1.0): Were all content words preserved? No \
hallucinated words added, no important words dropped. Filler words (um, uh, like, \
basically, you know) SHOULD be removed — removing them is correct, not a fidelity \
violation. Self-correction removal is also correct.

4. **Intent match** (0.0–1.0): Would a reasonable user accept this as the cleaned \
version of their dictation? Consider: the user dictated something and expects \
clean, professional text back. Minor formatting differences are acceptable. \
Major meaning changes or garbled output are not.

**Context-specific guidelines:**
- For **Terminal/code** contexts: spoken forms like "dash", "slash" should be \
PRESERVED as-is (the system does not convert these in code/terminal contexts). \
Capitalization and punctuation are less important.
- For **single-line** contexts (search bars, subject lines): trailing periods \
may or may not be appropriate — don't penalize either way.
- For **chat** contexts: casual tone is acceptable, less punctuation is fine.
- For **prose** contexts (Notes, Mail): full punctuation and capitalization expected.

**Other guidelines:**
- A trailing period on a sentence that "expected" doesn't have (or vice versa) \
is a MINOR formatting difference, not a failure. Score formatting 0.85-0.95.
- Spoken forms not converted (e.g., "dot" not becoming ".", "slash" not becoming "/") \
are legitimate failures in content fidelity for prose contexts.
- Self-corrections not resolved (keeping both original and corrected text) is a \
semantic preservation failure.
- The actual output should be evaluated against the INPUT (what the user dictated), \
not just against the expected output. The expected output is a reference, but \
acceptable variations exist.

**Input (raw dictation):** {input}
**Expected output:** {expected}
**Actual output:** {actual}

Respond with ONLY a JSON object (no markdown, no code fences):
{{
  "semantic_preservation": <float>,
  "formatting_quality": <float>,
  "content_fidelity": <float>,
  "intent_match": <float>,
  "reasoning": "<one sentence explaining the verdict>"
}}
"""


def _parse_json_response(text: str, case_id: str) -> Optional[dict]:
    """Robustly parse JSON from LLM response, handling multi-line and nested content."""
    # Try direct parse first
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass

    # Find the outermost JSON object using brace matching
    start = text.find("{")
    if start == -1:
        print(f"  ⚠ No JSON object found for {case_id}: {text[:200]}")
        return None

    depth = 0
    in_string = False
    escape_next = False
    for i in range(start, len(text)):
        c = text[i]
        if escape_next:
            escape_next = False
            continue
        if c == "\\":
            escape_next = True
            continue
        if c == '"':
            in_string = not in_string
            continue
        if in_string:
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                try:
                    return json.loads(text[start : i + 1])
                except json.JSONDecodeError as e:
                    print(f"  ⚠ JSON parse error for {case_id}: {e}")
                    return None

    print(f"  ⚠ Unbalanced braces for {case_id}: {text[:200]}")
    return None


def judge_case_gemini(tc: TestCase, model: str = "gemini-2.5-flash", max_retries: int = 2) -> JudgeScore:
    """Score a single test case using Gemini as judge, with retry on parse failure."""
    from google import genai

    client = genai.Client(api_key=os.environ["GEMINI_API_KEY"])

    prompt = JUDGE_PROMPT.format(
        input=tc.input_text,
        expected=tc.expected,
        actual=tc.actual,
        context=tc.context,
    )

    for attempt in range(max_retries + 1):
        try:
            response = client.models.generate_content(
                model=model,
                contents=prompt,
                config={
                    "temperature": 0.0,
                    "max_output_tokens": 2048,
                    "response_mime_type": "application/json",
                },
            )

            text = response.text.strip()
            text = re.sub(r"^```(?:json)?\s*", "", text)
            text = re.sub(r"\s*```\s*$", "", text)

            data = _parse_json_response(text, tc.id)
            if data is not None:
                sem = float(data.get("semantic_preservation", 0))
                fmt = float(data.get("formatting_quality", 0))
                fid = float(data.get("content_fidelity", 0))
                intent = float(data.get("intent_match", 0))

                # Compute pass/fail locally from scores
                overall_pass = min(sem, fmt, fid, intent) >= PASS_THRESHOLD

                return JudgeScore(
                    semantic_preservation=sem,
                    formatting_quality=fmt,
                    content_fidelity=fid,
                    intent_match=intent,
                    overall_pass=overall_pass,
                    reasoning=str(data.get("reasoning", "")),
                )

            if attempt < max_retries:
                print(f"  ↻ Retrying {tc.id} (attempt {attempt + 2}/{max_retries + 1})...")
                time.sleep(1)

        except Exception as e:
            if attempt < max_retries:
                print(f"  ↻ Retrying {tc.id} after error: {e}")
                time.sleep(2)
            else:
                print(f"  ⚠ [{tc.id}] Failed after {max_retries + 1} attempts: {e}")

    # All retries exhausted — return None-like sentinel
    return JudgeScore(
        semantic_preservation=-1,
        formatting_quality=-1,
        content_fidelity=-1,
        intent_match=-1,
        overall_pass=False,
        reasoning="UNSCORED: judge failed to return valid response",
    )


# ── Reporting ────────────────────────────────────────────────────────────────

def print_report(scored_cases: list[ScoredCase]) -> str:
    """Generate and print a detailed report."""
    lines: list[str] = []

    def p(s=""):
        lines.append(s)
        print(s)

    def _is_unscored(sc: ScoredCase) -> bool:
        return (
            sc.judge_score is not None
            and sc.judge_score.semantic_preservation < 0
        )

    total = len(scored_cases)
    exact_pass = sum(1 for sc in scored_cases if sc.test_case.exact_match)
    unscored = sum(1 for sc in scored_cases if _is_unscored(sc))
    total_pass = sum(
        1
        for sc in scored_cases
        if sc.test_case.exact_match
        or (sc.judge_score and sc.judge_score.overall_pass and not _is_unscored(sc))
    )

    p("=" * 80)
    p("  AAWAAZ QUALITY BENCHMARK — LLM-as-Judge Evaluation")
    p("=" * 80)
    p()
    p(f"  Exact-match pass rate:  {exact_pass}/{total} ({exact_pass * 100 // total}%)")
    p(f"  Judge pass rate:        {total_pass}/{total} ({total_pass * 100 // total}%)")
    p(f"  Judge rescued:          {total_pass - exact_pass} cases")
    if unscored:
        p(f"  Unscored (judge error): {unscored} cases")
    p()

    # Per-category breakdown
    categories: dict[str, list[ScoredCase]] = {}
    for sc in scored_cases:
        cat = sc.test_case.category
        categories.setdefault(cat, []).append(sc)

    p("  PER-CATEGORY BREAKDOWN")
    p("  " + "-" * 76)
    p(f"  {'Category':<28} {'Exact':>6} {'Judge':>6} {'Total':>6}  {'Rescued':>7}")
    p("  " + "-" * 76)

    for cat in sorted(categories.keys()):
        cat_cases = categories[cat]
        cat_total = len(cat_cases)
        cat_exact = sum(1 for sc in cat_cases if sc.test_case.exact_match)
        cat_judge = sum(
            1
            for sc in cat_cases
            if sc.test_case.exact_match
            or (sc.judge_score and sc.judge_score.overall_pass and not _is_unscored(sc))
        )
        cat_rescued = cat_judge - cat_exact
        p(f"  {cat:<28} {cat_exact:>3}/{cat_total:<3} {cat_judge:>3}/{cat_total:<3} {cat_total:>6}  {'+' + str(cat_rescued):>7}")

    p()

    # Detailed results for non-exact-match cases
    p("  DETAILED RESULTS (non-exact-match cases)")
    p("  " + "-" * 76)

    for sc in scored_cases:
        if sc.test_case.exact_match:
            continue

        tc = sc.test_case
        js = sc.judge_score

        if js is None:
            p(f"  [{tc.id}] ⚠ No judge score")
            continue

        if _is_unscored(ScoredCase(test_case=tc, judge_score=js)):
            p(f"  [{tc.id}] ⚠ UNSCORED (judge parse failure)")
            p(f"    Input:    {tc.input_text[:80]}")
            p(f"    Actual:   {tc.actual[:80]}")
            p()
            continue

        verdict = "✅ PASS" if js.overall_pass else "❌ FAIL"
        p(f"  [{tc.id}] {verdict}")
        p(f"    Sem={js.semantic_preservation:.2f}  Fmt={js.formatting_quality:.2f}  "
          f"Fid={js.content_fidelity:.2f}  Int={js.intent_match:.2f}  "
          f"Avg={js.avg_score:.2f}")
        p(f"    Input:    {tc.input_text[:80]}")
        p(f"    Expected: {tc.expected[:80]}")
        p(f"    Actual:   {tc.actual[:80]}")
        p(f"    Reason:   {js.reasoning[:100]}")
        p()

    # Score distribution
    p("  SCORE DISTRIBUTION (non-exact-match cases)")
    p("  " + "-" * 76)

    non_exact = [
        sc for sc in scored_cases
        if not sc.test_case.exact_match and sc.judge_score and not _is_unscored(sc)
    ]

    if non_exact:
        dims = ["semantic_preservation", "formatting_quality", "content_fidelity", "intent_match"]
        for dim in dims:
            scores = [getattr(sc.judge_score, dim) for sc in non_exact]
            avg = sum(scores) / len(scores)
            low = min(scores)
            high = max(scores)
            below_75 = sum(1 for s in scores if s < 0.75)
            p(f"  {dim:<25} avg={avg:.2f}  min={low:.2f}  max={high:.2f}  below_0.75={below_75}")
        p()

    # Real failures
    real_failures = [
        sc for sc in scored_cases
        if not sc.test_case.exact_match
        and sc.judge_score
        and not sc.judge_score.overall_pass
        and not _is_unscored(sc)
    ]
    p(f"  REAL FAILURES (judge confirms): {len(real_failures)}")
    p("  " + "-" * 76)
    for sc in real_failures:
        tc = sc.test_case
        js = sc.judge_score
        lowest_dim = min(
            dims,
            key=lambda d: getattr(js, d),
        )
        p(f"  [{tc.id}] lowest: {lowest_dim}={getattr(js, lowest_dim):.2f} — {js.reasoning[:80]}")

    p()
    p("=" * 80)

    return "\n".join(lines)


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="LLM-as-Judge scoring for Aawaaz quality benchmark"
    )
    parser.add_argument(
        "--results-file",
        default="quality-speed-benchmark-step4-step5.txt",
        help="Benchmark results file to parse",
    )
    parser.add_argument(
        "--swift-file",
        default="Aawaaz/Tests/CleanupQualityTests.swift",
        help="Swift test file with test case definitions",
    )
    parser.add_argument(
        "--model",
        default="gemini-2.5-flash",
        help="Gemini model to use as judge",
    )
    parser.add_argument(
        "--model-name",
        default="Qwen3-0.6B-6bit",
        help="Model name in benchmark results to evaluate",
    )
    parser.add_argument(
        "--output",
        default="llm-judge-results.json",
        help="Output JSON file for detailed results",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="Judge all cases, not just failing ones",
    )
    args = parser.parse_args()

    if not os.environ.get("GEMINI_API_KEY"):
        print("Error: GEMINI_API_KEY environment variable not set")
        sys.exit(1)

    # Step 1: Extract test cases from Swift source
    print(f"📋 Extracting test cases from {args.swift_file}...")
    cases = extract_test_cases_from_swift(args.swift_file)
    print(f"   Found {len(cases)} test cases")

    # Step 2: Parse benchmark results
    print(f"📊 Parsing benchmark results from {args.results_file}...")
    actuals = parse_benchmark_results(args.results_file, args.model_name)
    print(f"   Found {len(actuals)} results for {args.model_name}")

    # Step 3: Merge
    cases = merge_cases_with_results(cases, actuals)
    exact_pass = sum(1 for tc in cases if tc.exact_match)
    print(f"   Exact-match: {exact_pass}/{len(cases)} ({exact_pass * 100 // len(cases)}%)")

    # Step 4: Determine which cases to judge
    only_failing = not args.all
    cases_to_judge = [
        tc for tc in cases if not tc.exact_match and tc.actual
    ] if only_failing else [tc for tc in cases if tc.actual]

    print(f"\n🤖 Judging {len(cases_to_judge)} cases with {args.model}...")

    scored: list[ScoredCase] = []
    judged_ids = {tc.id for tc in cases_to_judge}

    for tc in cases:
        if tc.id not in judged_ids:
            scored.append(ScoredCase(test_case=tc, judge_score=None))
            continue

        try:
            score = judge_case_gemini(tc, model=args.model)
            scored.append(ScoredCase(test_case=tc, judge_score=score))
            if score.semantic_preservation < 0:
                print(f"   ⚠ [{tc.id}] UNSCORED")
            else:
                verdict = "✅" if score.overall_pass else "❌"
                print(f"   {verdict} [{tc.id}] avg={score.avg_score:.2f}")
        except Exception as e:
            print(f"   ⚠ [{tc.id}] Error: {e}")
            scored.append(ScoredCase(test_case=tc, judge_score=None))
            time.sleep(2)

        time.sleep(0.3)

    # Step 5: Report
    print()
    report = print_report(scored)

    # Step 6: Save detailed results
    results_data = {
        "model_evaluated": args.model_name,
        "judge_model": args.model,
        "total_cases": len(cases),
        "exact_match_pass": exact_pass,
        "judge_pass": sum(
            1 for sc in scored
            if sc.test_case.exact_match
            or (sc.judge_score and sc.judge_score.overall_pass
                and sc.judge_score.semantic_preservation >= 0)
        ),
        "unscored": sum(
            1 for sc in scored
            if sc.judge_score and sc.judge_score.semantic_preservation < 0
        ),
        "cases": [
            {
                "id": sc.test_case.id,
                "category": sc.test_case.category,
                "input": sc.test_case.input_text,
                "expected": sc.test_case.expected,
                "actual": sc.test_case.actual,
                "exact_match": sc.test_case.exact_match,
                **(
                    {
                        "semantic_preservation": sc.judge_score.semantic_preservation,
                        "formatting_quality": sc.judge_score.formatting_quality,
                        "content_fidelity": sc.judge_score.content_fidelity,
                        "intent_match": sc.judge_score.intent_match,
                        "overall_pass": sc.judge_score.overall_pass,
                        "reasoning": sc.judge_score.reasoning,
                    }
                    if sc.judge_score
                    else {}
                ),
            }
            for sc in scored
        ],
    }

    with open(args.output, "w") as f:
        json.dump(results_data, f, indent=2)
    print(f"\n💾 Detailed results saved to {args.output}")

    report_path = args.output.replace(".json", "-report.txt")
    with open(report_path, "w") as f:
        f.write(report)
    print(f"📄 Text report saved to {report_path}")


if __name__ == "__main__":
    main()
