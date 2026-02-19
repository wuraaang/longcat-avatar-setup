#!/bin/bash
set -euo pipefail

# ============================================================
# 🐱 LongCat Avatar — RunPod One-Shot Setup
# Tested on: RunPod RTX 4090/5090, PyTorch 2.6+, CUDA 12.4
# ============================================================

echo "🐱 LongCat Avatar Setup — Starting..."
START_TIME=$(date +%s)

# --- Config ---
COMFYUI_DIR="${COMFYUI_DIR:-/workspace/ComfyUI}"
MODELS_DIR="$COMFYUI_DIR/models"
CUSTOM_NODES_DIR="$COMFYUI_DIR/custom_nodes"
HF_MIRROR="${HF_MIRROR:-}" # Leave empty for default HuggingFace

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# --- Step 1: System deps ---
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 1/6 — System dependencies"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

apt-get update -qq && apt-get install -y -qq git git-lfs ffmpeg libsndfile1 > /dev/null 2>&1
git lfs install --skip-smudge > /dev/null 2>&1
log "System deps installed"

# --- Step 2: Install/Update ComfyUI ---
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 2/6 — ComfyUI"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ -d "$COMFYUI_DIR" ]; then
    log "ComfyUI already exists at $COMFYUI_DIR"
    cd "$COMFYUI_DIR" && git pull --ff-only 2>/dev/null || warn "Could not update ComfyUI (not critical)"
else
    git clone https://github.com/comfyanonymous/ComfyUI.git "$COMFYUI_DIR"
    log "ComfyUI cloned"
fi

cd "$COMFYUI_DIR"
pip install -r requirements.txt -q
log "ComfyUI requirements installed"

# --- Step 3: Install ComfyUI Manager ---
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 3/6 — ComfyUI Manager"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

mkdir -p "$CUSTOM_NODES_DIR"

if [ -d "$CUSTOM_NODES_DIR/ComfyUI-Manager" ]; then
    log "ComfyUI Manager already installed"
else
    git clone https://github.com/ltdrdata/ComfyUI-Manager.git "$CUSTOM_NODES_DIR/ComfyUI-Manager"
    log "ComfyUI Manager installed"
fi

# --- Step 4: Install Kijai WanVideoWrapper (longcat_avatar branch) ---
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 4/6 — Kijai WanVideoWrapper"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

WRAPPER_DIR="$CUSTOM_NODES_DIR/ComfyUI-WanVideoWrapper"

if [ -d "$WRAPPER_DIR" ]; then
    cd "$WRAPPER_DIR"
    git fetch origin
    git checkout longcat_avatar 2>/dev/null || git checkout -b longcat_avatar origin/longcat_avatar
    git pull origin longcat_avatar
    log "WanVideoWrapper updated to longcat_avatar branch"
else
    git clone -b longcat_avatar https://github.com/kijai/ComfyUI-WanVideoWrapper.git "$WRAPPER_DIR"
    log "WanVideoWrapper cloned (longcat_avatar branch)"
fi

cd "$WRAPPER_DIR"
pip install -r requirements.txt -q 2>/dev/null || warn "No requirements.txt in wrapper (may be fine)"

# Install extra deps for LongCat Avatar
pip install librosa soundfile -q
log "Audio dependencies installed"

# --- Step 5: Download LongCat-Video-Avatar model weights ---
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 5/6 — Model weights (~30GB)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

pip install "huggingface_hub[cli]" -q

LONGCAT_WEIGHTS_DIR="$MODELS_DIR/LongCat"
mkdir -p "$LONGCAT_WEIGHTS_DIR"

# Set HF mirror if specified
if [ -n "$HF_MIRROR" ]; then
    export HF_ENDPOINT="$HF_MIRROR"
    log "Using HuggingFace mirror: $HF_MIRROR"
fi

# Download Avatar model
if [ -d "$LONGCAT_WEIGHTS_DIR/LongCat-Video-Avatar" ] && [ "$(ls -A $LONGCAT_WEIGHTS_DIR/LongCat-Video-Avatar 2>/dev/null)" ]; then
    log "LongCat-Video-Avatar weights already present"
else
    log "Downloading LongCat-Video-Avatar weights... (this will take a while)"
    huggingface-cli download meituan-longcat/LongCat-Video-Avatar \
        --local-dir "$LONGCAT_WEIGHTS_DIR/LongCat-Video-Avatar" \
        --resume-download
    log "LongCat-Video-Avatar weights downloaded"
fi

# Download base LongCat-Video model (needed for some components)
if [ -d "$LONGCAT_WEIGHTS_DIR/LongCat-Video" ] && [ "$(ls -A $LONGCAT_WEIGHTS_DIR/LongCat-Video 2>/dev/null)" ]; then
    log "LongCat-Video base weights already present"
else
    log "Downloading LongCat-Video base weights..."
    huggingface-cli download meituan-longcat/LongCat-Video \
        --local-dir "$LONGCAT_WEIGHTS_DIR/LongCat-Video" \
        --resume-download
    log "LongCat-Video base weights downloaded"
fi

# --- Step 6: Copy workflow & Create symlinks ---
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 6/6 — Workflow & Symlinks"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Copy example workflow if available in the wrapper
WORKFLOW_SRC="$WRAPPER_DIR/LongCat"
WORKFLOW_DST="$COMFYUI_DIR/user/default/workflows"
mkdir -p "$WORKFLOW_DST"

if [ -d "$WORKFLOW_SRC" ]; then
    cp -r "$WORKFLOW_SRC"/* "$WORKFLOW_DST/" 2>/dev/null || true
    log "LongCat workflows copied"
else
    warn "No workflow files found in wrapper — you may need to load them manually"
fi

# Create convenience symlink
ln -sfn "$LONGCAT_WEIGHTS_DIR" "$COMFYUI_DIR/models/longcat"
log "Symlink created: models/longcat → $LONGCAT_WEIGHTS_DIR"

# --- Done ---
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
MINUTES=$((ELAPSED / 60))
SECONDS=$((ELAPSED % 60))

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "  ${GREEN}🐱 Setup complete!${NC} (${MINUTES}m ${SECONDS}s)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  To launch ComfyUI:"
echo "    cd $COMFYUI_DIR"
echo "    python main.py --listen 0.0.0.0 --port 8188"
echo ""
echo "  Model weights: $LONGCAT_WEIGHTS_DIR"
echo "  Wrapper: $WRAPPER_DIR (branch: longcat_avatar)"
echo ""
echo "  Tips:"
echo "    - Audio CFG: 3-5 for best lip sync"
echo "    - Max 15s per gen (use video continuation for longer)"
echo "    - Include 'talking' or 'speaking' in prompts"
echo ""
