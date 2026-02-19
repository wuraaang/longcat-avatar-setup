#!/bin/bash
set -euo pipefail

# ============================================================
# 🐱 LongCat Avatar — GPUhub One-Shot Setup
# Same as RunPod but with China-friendly mirrors
# ============================================================

echo "🐱 LongCat Avatar Setup (GPUhub/China) — Starting..."

# --- Override mirrors for China ---
export HF_MIRROR="https://hf-mirror.com"
export HF_ENDPOINT="https://hf-mirror.com"

# GitHub can be slow from China — use ghproxy if needed
# Uncomment if github is too slow:
# export GITHUB_MIRROR="https://ghproxy.com/https://github.com"

export PIP_INDEX_URL="${PIP_INDEX_URL:-https://pypi.tuna.tsinghua.edu.cn/simple}"
export PIP_TRUSTED_HOST="${PIP_TRUSTED_HOST:-pypi.tuna.tsinghua.edu.cn}"

echo "Using mirrors:"
echo "  HuggingFace: $HF_ENDPOINT"
echo "  PyPI: $PIP_INDEX_URL"
echo ""

# --- Detect workspace dir ---
if [ -d "/workspace" ]; then
    export COMFYUI_DIR="/workspace/ComfyUI"
elif [ -d "/root" ]; then
    export COMFYUI_DIR="/root/ComfyUI"
else
    export COMFYUI_DIR="$HOME/ComfyUI"
fi

echo "ComfyUI will be installed at: $COMFYUI_DIR"
echo ""

# --- Run the main setup script ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/setup-runpod.sh"
