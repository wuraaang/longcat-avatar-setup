#!/bin/bash
set -euo pipefail

# ============================================================
# 🐱 LongCat Avatar — GPUhub One-Shot Setup (FAST)
# Same as RunPod but with China-friendly mirrors
# ============================================================

echo "🐱 LongCat Avatar Setup (GPUhub/China) — Starting..."

# --- Override mirrors for China ---
export HF_MIRROR="https://hf-mirror.com"

# PyPI mirror (Tsinghua = fastest in China)
export PIP_INDEX_URL="${PIP_INDEX_URL:-https://pypi.tuna.tsinghua.edu.cn/simple}"
export PIP_TRUSTED_HOST="${PIP_TRUSTED_HOST:-pypi.tuna.tsinghua.edu.cn}"

echo "Using mirrors:"
echo "  HuggingFace: $HF_MIRROR"
echo "  PyPI: $PIP_INDEX_URL"
echo ""

# --- Run the main setup script ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/setup-runpod.sh"
