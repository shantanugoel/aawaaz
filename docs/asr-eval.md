# ASR Model Decision Report for Aawaaz

  ## Summary

  As of March 15, 2026, there is no obvious drop-in open model that is clearly better than whisper-large-v3-turbo
  on both accuracy and latency for Aawaaz’s current architecture.

  For Aawaaz specifically:

  - Your hard constraints are: fully local, Apple Silicon, low-latency short dictation, Hindi/English/Hinglish,
    and native macOS integration.
  - Under those constraints, the most promising accuracy upgrade is Qwen3-ASR-1.7B
    (https://huggingface.co/Qwen/Qwen3-ASR-1.7B), but it is not a near-term stack fit for your current Swift + wh
    isper.cpp architecture.
  - The most promising same-ecosystem upgrade candidate is Distil-Whisper distil-large-v3
    (https://huggingface.co/distil-whisper/distil-large-v3) because it already has a whisper.cpp-compatible path
    and official GGML weights, but it is English-focused, so it is risky for Hinglish/Hindi-first use.
  - The most promising latency-first alternative runtime is Moonshine (https://github.com/moonshine-ai/moonshine),
    but it is a poor strategic fit for Aawaaz because its non-English models are non-commercial, and its language
    strategy is more monolingual than code-switch-native.
  - NVIDIA Canary / Parakeet are strong models, but they are effectively disqualified for Aawaaz because the
    official deployment path is Linux + NVIDIA hardware / Riva / Triton, not Apple Silicon.
  - For Indian-language specialization, AI4Bharat IndicConformer 600M multilingual
    (https://huggingface.co/ai4bharat/indic-conformer-600m-multilingual) is worth watching, but it looks better as
    a Hindi-focused secondary mode than as a universal Aawaaz default.
  - Qwen3-ASR-Flash appears to have been the earlier/API branding; the official Qwen repo now positions the open-
    source Qwen3-ASR 0.6B / 1.7B models as the main offering, and the toolkit explicitly says the API was
    “formerly Qwen3-ASR-Flash”.

  ## Candidate Comparison

  | Model | What it is | Approx. size | CoreML/ANE path | Strengths for Aawaaz | Main blockers | Verdict |
  | --- | --- | --- | --- | --- | --- | --- |
  | Whisper large-v3-turbo (https://huggingface.co/openai/whisper-large-v3-turbo) | Current baseline | ~1.6 GB (Q8 GGML) | Yes — proven CoreML conversion, ANE-compatible | Mature, multilingual, MIT, already integrated, strong zero-shot robustness; known to hallucinate on silence | Not SOTA anymore on some newer benchmarks; fixed Whisper architecture constraints | Keep as baseline |
  | Qwen3-ASR-1.7B (https://huggingface.co/Qwen/Qwen3-ASR-1.7B) | New open ASR family, Jan 29 2026 tech report | ~3.4 GB FP16 / ~1.7 GB Q8 | Unlikely — non-Whisper architecture, no community CoreML path, would require significant conversion effort | Official Hindi support, 30 languages + 22 Chinese dialects, offline + streaming, vendor claims open-source SOTA and near commercial APIs; claims improved silence handling vs Whisper | Official stack is Python qwen-asr; streaming is only via vLLM; docs are CUDA/FlashAttention oriented, not Apple-native | Best accuracy candidate, not best shipping candidate |
  | Qwen3-ASR-0.6B (https://huggingface.co/Qwen/Qwen3-ASR-0.6B) | Smaller sibling | ~1.2 GB FP16 | Unlikely — same architecture constraints as 1.7B | Same language coverage, better efficiency, plausible future on-device option | Same runtime/integration problem; no first-party Apple-native path | Best future experiment candidate |
  | Distil-Whisper distil-large-v3 (https://huggingface.co/distil-whisper/distil-large-v3) | Whisper-family distilled model | ~1.5 GB (Q8 GGML) | Yes — Whisper-architecture, same CoreML conversion path as turbo | Officially compatible with whisper.cpp; official GGML weights; official claim of 6.3x latency vs large-v3 and strong long-form accuracy | Distilled on English-only data; will likely *degrade* Hindi/Hinglish quality vs turbo baseline, not just fail to improve it | Best near-term technical spike, but English-only lane |
  | Moonshine (https://github.com/moonshine-ai/moonshine) | Edge/live-streaming ASR stack | ~400 MB (base) / ~800 MB (large) | Possible architecture, but blocked by non-commercial license for non-English | Cross-platform, Swift/macOS support, designed for live latency, claims lower WER than Whisper large-v3 at top end; claims improved silence handling | Non-English models are under a non-commercial license; language-specific strategy is weak for Hinglish/code-switch | Not suitable as Aawaaz default |
  | NVIDIA Canary Flash 2.0 (https://build.nvidia.com/nvidia/canary-1b-asr/modelcard) | Multilingual ASR/AST | ~2 GB | No — NVIDIA/CUDA-only runtime | Supports Hindi and other languages; strong vendor benchmark position | Official deployment requires Riva 2.23+, NVIDIA GPU families, Linux/Triton | Wrong platform |
  | NVIDIA Parakeet RNNT 1.1B (https://build.nvidia.com/nvidia/parakeet-1_1b-rnnt-multilingual-asr/modelcard) | 25-language multilingual ASR | ~2.2 GB | No — NVIDIA/CUDA-only runtime | Includes Hindi; production-oriented punctuation-aware multilingual model | Same NVIDIA/Linux deployment lock-in | Wrong platform |
  | AI4Bharat IndicConformer 600M (https://huggingface.co/ai4bharat/indic-conformer-600m-multilingual) | 22-language Indian ASR | ~1.2 GB | Unlikely — NeMo/ONNX runtime, no community CoreML path | Indian-language specialist, MIT, 600M, multilingual across Indian languages | Not clearly code-switch-optimized; custom runtime path; less proven for mixed Hindi+English dictation | Good Hindi-mode candidate, not obvious global default |
  | Shunya Zero STT Hinglish (https://huggingface.co/shunyalabs/zero-stt-hinglish) | Hinglish-specialized Whisper-medium fine-tune | ~1.5 GB (FP16) | Yes — Whisper-architecture base | Directly targets Hindi-English code-switching | Limited benchmark rigor and ecosystem maturity; likely lower ceiling than newer large open models | Interesting niche benchmark only |

  ## What This Means for Aawaaz

  My recommendation is:

  1. Do not replace Whisper as the primary engine today.
      - For your current product constraints, Whisper still has the best combination of:
      - multilingual coverage
      - native/local Apple viability
      - mature C/C++ ecosystem
      - low integration risk
  2. Add two benchmark tracks instead of one risky swap.
      - Track A: Qwen3-ASR-0.6B and 1.7B
          - Goal: test whether the quality jump on Hindi/Hinglish is real enough to justify a future runtime split
            or sidecar process.
          - Expectation: best chance of beating Whisper on quality.
          - Risk: high integration cost.
          - Effort: multi-week exploration — requires Python runtime or sidecar process setup, new inference path,
            no existing whisper.cpp integration.
      - Track B: Distil-Whisper distil-large-v3
          - Goal: test whether you can get meaningful latency or English quality gains inside the current
            whisper.cpp-style path.
          - Expectation: easiest engineering spike.
          - Risk: distil-large-v3 was distilled on English-only data. It will likely *degrade* Hindi/Hinglish
            quality compared to the current turbo baseline, not just fail to improve it. This track is realistically
            an English-lane experiment, not a candidate for the Hinglish default.
          - Effort: 1–2 day spike — drop-in whisper.cpp model swap, mostly configuration changes.
  3. Treat Moonshine as a separate product direction, not a Whisper replacement.
      - It is compelling if Aawaaz ever adds:
      - English-first live captioning
      - ultra-low-latency voice UI
      - command-mode streaming
      - But it is not the right core engine for your current Hinglish-native dictation product.
  4. Ignore NVIDIA models for this app unless your architecture changes radically.
      - Their current official deployment assumptions are fundamentally misaligned with your local Apple-Silicon
        app.

  ## Important Interface / Architecture Implications

  If you later prototype beyond Whisper, the implementation boundary should change from “Whisper manager” to a
  generic ASR engine abstraction.

  That abstraction should explicitly model:

  - offline transcription support
  - streaming/interim support
  - language autodetect vs forced language
  - word/segment timestamps
  - prompt/context biasing
  - memory/load lifecycle
  - local runtime requirements

  The important decision here is architectural:

  - Whisper / Distil-Whisper fit a native in-process engine.
  - Qwen3-ASR currently looks more like a separate runtime service or sidecar.
  - Moonshine could fit in-process, but changes the segmentation/streaming assumptions enough that it should not
    be forced through Whisper-shaped APIs.

  ## Test Plan

  Benchmark the following on real Aawaaz-style utterances, not generic ASR corpora:

  - Languages
      - English
      - Hindi
      - Hinglish romanized
      - Hinglish with technical vocabulary
  - Scenarios
      - 2 to 8 second dictation bursts
      - noisy room
      - quiet whisper mode
      - code-editor terminology
      - names / proper nouns
      - app-context prompts
  - Metrics
      - end-to-end latency from speech end to inserted text
      - first interim latency if streaming
      - WER/CER
      - code-switch fidelity
      - punctuation quality
      - hallucination rate on silence
      - RAM footprint on 8 GB / 16 GB / 24 GB Apple Silicon
  - Acceptance bar
      - A model should only replace Whisper if it is either:
      - materially better on Hinglish/Hindi quality at similar latency, or
      - materially faster at similar quality,
      - without forcing a fragile runtime story.
      - Concrete thresholds for "materially better":
      - Quality: >5% relative WER improvement on the Hindi/Hinglish test set vs whisper-large-v3-turbo
      - Latency: >2x real-time-factor improvement at equivalent or better quality
      - RAM: must fit within a ~2 GB model memory budget (to remain viable on 8 GB Apple Silicon machines)
      - Silence: hallucination-on-silence rate must be equal to or lower than turbo baseline

  ## Assumptions and Defaults

  - I optimized for your chosen preferences: Balanced and Mostly native.
  - Integration-fit judgments are my inference from the official runtime docs and your current repo, not vendor-
    stated conclusions.
  - I excluded cloud-first recommendations from the final recommendation even when they look strong on Indian-
    language benchmarks, because Aawaaz’s spec is explicitly fully local.

  ## Sources

  - Aawaaz product/architecture context from your repo: docs/SPEC.md, docs/PLAN.md, ModelCatalog.swift,
    WhisperManager.swift
  - Qwen3-ASR official model card (https://huggingface.co/Qwen/Qwen3-ASR-1.7B)
  - Qwen3-ASR Toolkit official repo (https://github.com/QwenLM/Qwen3-ASR-Toolkit)
  - Whisper large-v3-turbo official model card (https://huggingface.co/openai/whisper-large-v3-turbo)
  - Distil-Whisper distil-large-v3 official model card (https://huggingface.co/distil-whisper/distil-large-v3)
  - Moonshine official repo (https://github.com/moonshine-ai/moonshine)
  - NVIDIA Canary official model card (https://build.nvidia.com/nvidia/canary-1b-asr/modelcard)
  - NVIDIA Parakeet multilingual official model card
    (https://build.nvidia.com/nvidia/parakeet-1_1b-rnnt-multilingual-asr/modelcard)
  - AI4Bharat IndicConformer 600M multilingual official model card
    (https://huggingface.co/ai4bharat/indic-conformer-600m-multilingual)
  - AI4Bharat Hindi IndicConformer official model card
    (https://huggingface.co/ai4bharat/indicconformer_stt_hi_hybrid_ctc_rnnt_large)
  - Shunya Zero STT Hinglish official model card (https://huggingface.co/shunyalabs/zero-stt-hinglish)
  - Sarvam Saarika docs (https://docs.sarvam.ai/api-reference-docs/getting-started/models/saarika) and streaming
    STT docs (https://docs.sarvam.ai/api-reference-docs/api-guides-tutorials/speech-to-text/streaming-api)