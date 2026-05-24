# modelops

**A learn-by-doing workspace for the Apple-silicon model pipeline:** download → (optionally abliterate) → convert → quantize → serve via oMLX.

This folder is intentionally **not scripted**. The commands below are the workflow; running them yourself is how you learn the toolchain. The only "automation" here is `pyproject.toml`, which declares the Python tools you'll use.

## What this gives you

A reproducible Python environment (managed by [`uv`](https://docs.astral.sh/uv/)) containing:

| Tool | Role |
|------|------|
| `hf` (huggingface-hub) | Download models from HuggingFace, upload your outputs back |
| `mlx_lm.convert` | HF safetensors → MLX safetensors (format adapt), plus a baseline naive quantizer including `mxfp8` |
| `heretic` | Automated [abliteration](https://github.com/p-e-w/heretic) (optional in the workflow; pre-installed so it's ready when you want it) |

System-level (installed via Nix, available everywhere):

| Tool | Role |
|------|------|
| `uv` | Project + venv manager (what runs everything in here) |
| `hf` | Same `hf` CLI, system-wide for ad-hoc use |
| `llama-quantize`, `llama-cli`, ... (from `llama-cpp`) | GGUF tooling, for the rare cases you need GGUF runtime |

Quantization to MLX is owned by **oMLX's built-in [oQ](https://github.com/jundot/omlx/blob/main/docs/oQ_Quantization.md)** — a calibration-driven, mixed-precision quantizer. It runs in the oMLX server (admin panel at `http://localhost:8000/admin`), **not** in this venv. We document the hand-off below.

## Default contract

- **Input:** HuggingFace **safetensors** — either raw HF (e.g. `meta-llama/...`, `Qwen/...`) or pre-converted MLX (`mlx-community/...`).
- **Output:** MLX safetensors, ready to drop into `~/.omlx/models/` and serve.
- **GGUF is not a supported input.** GGUF → MLX reverse paths are brittle; almost every model on HF also has an upstream safetensors release — use that. If you specifically want GGUF *output* for Ollama, see the [GGUF appendix](#appendix-gguf).

## Layout

```
modelops/
├── pyproject.toml      # declarative Python deps (committed)
├── uv.lock             # pinned versions incl. heretic git SHA (committed)
├── .python-version     # 3.12 (committed)
├── .gitignore          # ignores .venv/, models/, outputs/
├── README.md           # this file
├── models/             # HF downloads land here (gitignored)
└── outputs/            # your converted / abliterated artifacts (gitignored)
```

---

## First-time setup

From this folder:

```bash
modelops          # cd alias to this folder (set in home.nix)
uv sync           # creates .venv/ from pyproject.toml + uv.lock
```

Sanity-check:

```bash
uv run hf --help
uv run mlx_lm.convert --help
uv run heretic --help
```

If `hf` asks for auth (needed for gated models like Llama, for uploads, etc.):

```bash
uv run hf auth login
```

---

## Workflow

### 1. Download from HuggingFace

```bash
# Pre-converted MLX (simplest):
uv run hf download mlx-community/Qwen2.5-Coder-32B-Instruct-bf16 \
  --local-dir models/qwen-coder-32b

# Or raw HF safetensors (needs the convert step below):
uv run hf download Qwen/Qwen2.5-Coder-32B-Instruct \
  --local-dir models/qwen-coder-32b-hf
```

`HF_HUB_ENABLE_HF_TRANSFER=1` activates the Rust-based fast download path. The dependency is already installed via the `hf_transfer` extra; enable the env var in your shell:

```bash
export HF_HUB_ENABLE_HF_TRANSFER=1
```

(or prefix individual `uv run hf download ...` commands with it).

### 2. Convert HF → MLX (only if your source is raw HF, not `mlx-community/*`)

```bash
uv run mlx_lm.convert \
  --hf-path models/qwen-coder-32b-hf \
  --mlx-path outputs/qwen-coder-32b-mlx
```

This is a **format adapter**, not a quantizer — leave `-q` off. Output is bf16/fp16 MLX safetensors.

### 3. (Optional) Abliterate with Heretic

[Abliteration](https://github.com/p-e-w/heretic) computationally removes a model's refusal direction by orthogonalizing specific projection matrices against an estimated "refusal direction" in the residual stream. It's a research/customization tool — useful when a model over-refuses on benign prompts, when you want to study alignment internals, or for uncensored derivative work.

Heretic automates the manual abliteration workflows (FailSpy's `abliterator`, Sumandora's `remove-refusals`) by using Bayesian optimization over per-layer ablation strength against a dual objective: minimize refusals on a harmful prompt set while minimizing KL divergence on a benign prompt set.

```bash
uv run heretic outputs/qwen-coder-32b-mlx \
  --save outputs/qwen-coder-32b-mlx-abl
```

See `uv run heretic --help` for the current flag set (target layers, n-trials, calibration sets, etc.). Run at **fp16/bf16, before quantization** — quantizing first distorts the activations Heretic measures.

### 4. Quantize

You have two routes. Pick based on what you want.

#### Route A — oMLX `oQ` (recommended)

oQ is a data-driven mixed-precision quantizer: it runs calibration inference, measures per-layer sensitivity (MSE of float-vs-quantized outputs), and boosts bits where they matter. **Output is standard MLX safetensors** — usable in any MLX runtime, not just oMLX.

1. Stage the model into oMLX's model directory:

   ```bash
   cp -R outputs/qwen-coder-32b-mlx ~/.omlx/models/qwen-coder-32b-mlx
   # or symlink if you'd rather not duplicate:
   ln -s "$PWD/outputs/qwen-coder-32b-mlx" ~/.omlx/models/qwen-coder-32b-mlx
   ```

2. Open `http://localhost:8000/admin` → **Models** → **oQ Quantization** tab.
3. Pick the source model and an **oQ level**:

   | Level | Target bpw | Use case |
   |-------|-----------:|----------|
   | oQ2   | ~2.9 | extreme compression (RAM-constrained) |
   | oQ3   | ~3.5 | balanced |
   | oQ3.5 | ~3.8 | quality-balanced |
   | **oQ4** | **~4.6** | **default; recommended starting point** |
   | oQ5   | ~5.5 | high quality |
   | oQ6   | ~6.5 | near-lossless |
   | oQ8   | ~8.6 | near-lossless (mxfp8 base, gs=32) |

   Levels 2–6 use affine quant (gs=64); level 8 uses mxfp8 (gs=32). oQ+ (with GPTQ weight optimization) is opt-in inside the same tab.

4. The server pauses inference while quantizing (clients will see 503s). When done, the quantized model appears as a separately loadable entry.

See [oQ_Quantization.md](https://github.com/jundot/omlx/blob/main/docs/oQ_Quantization.md) for the full algorithm description.

#### Route B — `mlx-lm` naive quant (fast baseline)

Useful for a quick A/B against oQ at the same bits, or when you just want a fast 8-bit version and don't want to wait on calibration.

```bash
# Affine 4-bit (gs=64), the mlx-lm default:
uv run mlx_lm.convert \
  --hf-path outputs/qwen-coder-32b-mlx \
  -q --q-bits 4 --q-group-size 64 \
  --mlx-path outputs/qwen-coder-32b-mlx-q4
```

For `mxfp8`, the exact flag name has drifted across mlx-lm releases — run `uv run mlx_lm.convert --help` and look for `--quant-type` or `--q-mode` (or similar) supporting `mxfp8`. The **intent** is uniform mxfp8 quantization, applied as a single weight-cast pass with no calibration. Expect seconds-to-minutes, vs minutes for oQ8 — at the cost of no per-layer sensitivity awareness.

### 5. Serve

```bash
# If you used Route A (oQ), it's already in ~/.omlx/models/
# If you used Route B (mlx-lm), stage it:
cp -R outputs/qwen-coder-32b-mlx-q4 ~/.omlx/models/qwen-coder-32b-mlx-q4
```

Refresh `http://localhost:8000/admin` → Models tab; the new model should auto-detect. Load / pin / set TTL from the UI.

### 6. (Optional) Upload to HuggingFace

**Primary path: oMLX admin → "oQ Uploader" tab.** It generates a model card with the quantization details (bit-allocation breakdown, calibration info, oMLX version) and pushes to your HF account. This is the path designed for oQ outputs.

**Fallback (any model, scripted):**

```bash
uv run hf upload <your-username>/<repo-name> outputs/<dir> . --repo-type model
```

Run `uv run hf auth login` once first if you haven't.

---

## Maintenance

Upgrade one package (the typical case — e.g. bump Heretic to latest `main`):

```bash
uv lock --upgrade-package heretic-llm
uv sync
# run a small smoke test, then commit uv.lock
```

Bump everything within the version constraints in `pyproject.toml`:

```bash
uv lock --upgrade
uv sync
```

Validate by running steps 1–4 end-to-end on a small model (e.g. `Qwen/Qwen2.5-0.5B`) before committing the updated lockfile.

---

## Appendix: GGUF

The MLX pipeline above does not consume GGUF. If you specifically need GGUF *output* (e.g. for Ollama or `llama-cli`), the system-level `llama-cpp` install provides:

```bash
# Convert HF safetensors → GGUF (fp16 base):
# (use llama.cpp's convert_hf_to_gguf.py — installed alongside llama-cpp, path may
#  vary; run `which llama-quantize` and check the same directory)

# Quantize GGUF → smaller K-quant:
llama-quantize input.fp16.gguf output.Q4_K_M.gguf Q4_K_M

# Smoke-run:
llama-cli -m output.Q4_K_M.gguf -p "hello"
```

**GGUF → MLX is not supported here.** If a model is published only as GGUF, you're almost always better off finding the original HF safetensors upload (search the model card for the upstream link) than attempting a reverse conversion.
