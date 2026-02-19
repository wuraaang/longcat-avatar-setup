#!/bin/bash
set -euo pipefail

# ============================================================
# 🐱 LongCat Avatar — RunPod Setup
# For use with the official RunPod ComfyUI template
# ComfyUI is already installed at /workspace/ComfyUI
# ============================================================

echo "🐱 LongCat Avatar Setup — Starting..."
START_TIME=$(date +%s)

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# --- Auto-detect ComfyUI path ---
if [ -n "${COMFYUI_DIR:-}" ]; then
    : # User override
elif [ -d "/workspace/madapps/ComfyUI" ]; then
    COMFYUI_DIR="/workspace/madapps/ComfyUI"    # RunPod official template
elif [ -d "/workspace/ComfyUI" ]; then
    COMFYUI_DIR="/workspace/ComfyUI"             # Community templates
elif [ -d "/root/ComfyUI" ]; then
    COMFYUI_DIR="/root/ComfyUI"                  # GPUhub / manual install
else
    err "ComfyUI not found! Set COMFYUI_DIR manually: COMFYUI_DIR=/path/to/ComfyUI bash setup-runpod.sh"
fi

CUSTOM_NODES_DIR="$COMFYUI_DIR/custom_nodes"
MODELS_DIR="$COMFYUI_DIR/models"
HF_MIRROR="${HF_MIRROR:-}"

log "ComfyUI found at $COMFYUI_DIR"

# --- Step 1: System deps ---
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 1/4 — Extra dependencies"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

apt-get update -qq && apt-get install -y -qq ffmpeg libsndfile1 > /dev/null 2>&1 || warn "apt install skipped (may already be present)"
pip install librosa soundfile "huggingface_hub[cli]" -q
log "Audio & HF dependencies installed"

# --- Step 2: Install Kijai WanVideoWrapper (longcat_avatar branch) ---
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 2/4 — Kijai WanVideoWrapper"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

WRAPPER_DIR="$CUSTOM_NODES_DIR/ComfyUI-WanVideoWrapper"

if [ -d "$WRAPPER_DIR" ]; then
    cd "$WRAPPER_DIR"
    git fetch origin
    # Check if longcat_avatar branch exists
    if git branch -r | grep -q "origin/longcat_avatar"; then
        git checkout longcat_avatar 2>/dev/null || git checkout -b longcat_avatar origin/longcat_avatar
        git pull origin longcat_avatar
        log "WanVideoWrapper switched to longcat_avatar branch"
    else
        warn "longcat_avatar branch not found — it may have been merged into main"
        git checkout main 2>/dev/null || true
        git pull
        log "WanVideoWrapper updated (main branch)"
    fi
else
    git clone -b longcat_avatar https://github.com/kijai/ComfyUI-WanVideoWrapper.git "$WRAPPER_DIR" 2>/dev/null || \
    git clone https://github.com/kijai/ComfyUI-WanVideoWrapper.git "$WRAPPER_DIR"
    log "WanVideoWrapper cloned"
fi

cd "$WRAPPER_DIR"
pip install -r requirements.txt -q 2>/dev/null || warn "No requirements.txt (may be fine)"
log "WanVideoWrapper ready"

# --- Step 3: Download LongCat-Video-Avatar model weights ---
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 3/4 — Model weights (~30GB)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ☕ Go grab a coffee, this takes a while..."
echo ""

LONGCAT_DIR="$MODELS_DIR/LongCat"
mkdir -p "$LONGCAT_DIR"

# Set HF mirror if specified
if [ -n "$HF_MIRROR" ]; then
    export HF_ENDPOINT="$HF_MIRROR"
    log "Using HuggingFace mirror: $HF_MIRROR"
fi

# Download Avatar model
if [ -d "$LONGCAT_DIR/LongCat-Video-Avatar" ] && [ "$(find $LONGCAT_DIR/LongCat-Video-Avatar -name '*.safetensors' -o -name '*.bin' 2>/dev/null | head -1)" ]; then
    log "LongCat-Video-Avatar weights already present — skipping"
else
    log "Downloading LongCat-Video-Avatar..."
    huggingface-cli download meituan-longcat/LongCat-Video-Avatar \
        --local-dir "$LONGCAT_DIR/LongCat-Video-Avatar" \
        --resume-download
    log "LongCat-Video-Avatar downloaded ✓"
fi

# Download base model (some components needed)
if [ -d "$LONGCAT_DIR/LongCat-Video" ] && [ "$(find $LONGCAT_DIR/LongCat-Video -name '*.safetensors' -o -name '*.bin' 2>/dev/null | head -1)" ]; then
    log "LongCat-Video base weights already present — skipping"
else
    log "Downloading LongCat-Video base model..."
    huggingface-cli download meituan-longcat/LongCat-Video \
        --local-dir "$LONGCAT_DIR/LongCat-Video" \
        --resume-download
    log "LongCat-Video base downloaded ✓"
fi

# --- Step 4: Workflows ---
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 4/4 — Workflows"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

WORKFLOW_SRC="$WRAPPER_DIR/LongCat"
if [ -d "$WORKFLOW_SRC" ]; then
    WORKFLOW_DST="$COMFYUI_DIR/user/default/workflows/LongCat"
    mkdir -p "$WORKFLOW_DST"
    cp -r "$WORKFLOW_SRC"/* "$WORKFLOW_DST/" 2>/dev/null || true
    log "LongCat workflows copied to ComfyUI"
else
    warn "No workflow files in wrapper — check Kijai's repo for example workflows"
fi

# Convenience symlink
ln -sfn "$LONGCAT_DIR" "$COMFYUI_DIR/models/longcat"
log "Symlink: models/longcat → $LONGCAT_DIR"

# --- Done ---
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
MINUTES=$((ELAPSED / 60))
SECONDS_LEFT=$((ELAPSED % 60))

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "  ${GREEN}🐱 Setup complete!${NC} (${MINUTES}m ${SECONDS_LEFT}s)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Now restart ComfyUI (or it may auto-restart)."
echo ""
echo "  Model weights: $LONGCAT_DIR"
echo "  Wrapper: $WRAPPER_DIR"
echo ""
echo "  Tips:"
echo "    - Audio CFG: 3-5 for best lip sync"
echo "    - Max ~15s per clip (use continuation for longer)"
echo "    - Put 'talking' or 'speaking' in your prompts"
echo "    - The workflow should appear in ComfyUI's workflow browser"
echo ""
