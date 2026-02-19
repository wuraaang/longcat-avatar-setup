#!/bin/bash
set -euo pipefail

# ============================================================
# 🐱 LongCat Avatar — RunPod Setup
# For use with RunPod comfyui-base (runpod-slim) template
# 
# Lessons applied from bebop-studio-workspace:
#   - Auto-detect correct ComfyUI path (runpod-slim first!)
#   - Verify running ComfyUI process matches our path
#   - Don't use aria2c for HF downloads (403 on redirects)
#   - Validate install at the end (don't just clone and pray)
#   - Use absolute paths everywhere (no dirname $0 fragility)
# ============================================================

echo "🐱 LongCat Avatar Setup — Starting..."
START_TIME=$(date +%s)

# --- Resolve script dir (absolute, not relative) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Step 0 — Detect ComfyUI
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 0/5 — Detecting ComfyUI"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ -n "${COMFYUI_DIR:-}" ]; then
    log "Using user override: $COMFYUI_DIR"
elif [ -d "/workspace/runpod-slim/ComfyUI" ]; then
    COMFYUI_DIR="/workspace/runpod-slim/ComfyUI" # RunPod official (comfyui-base)
elif [ -d "/workspace/madapps/ComfyUI" ]; then
    COMFYUI_DIR="/workspace/madapps/ComfyUI"     # RunPod legacy template
elif [ -d "/workspace/ComfyUI" ]; then
    COMFYUI_DIR="/workspace/ComfyUI"             # Community templates
elif [ -d "/root/ComfyUI" ]; then
    COMFYUI_DIR="/root/ComfyUI"                  # GPUhub / manual install
else
    err "ComfyUI not found! Set COMFYUI_DIR manually:\n  COMFYUI_DIR=/path/to/ComfyUI bash setup-runpod.sh"
fi

# Lesson from bebop: verify the RUNNING ComfyUI matches our detected path
COMFYUI_PID=$(pgrep -f "main.py.*--listen" 2>/dev/null | head -1 || true)
if [ -n "$COMFYUI_PID" ]; then
    RUNNING_CWD=$(readlink -f /proc/$COMFYUI_PID/cwd 2>/dev/null || true)
    if [ -n "$RUNNING_CWD" ] && [ "$RUNNING_CWD" != "$COMFYUI_DIR" ]; then
        warn "Running ComfyUI is at $RUNNING_CWD but we detected $COMFYUI_DIR"
        warn "Switching to running instance path!"
        COMFYUI_DIR="$RUNNING_CWD"
    fi
fi

CUSTOM_NODES_DIR="$COMFYUI_DIR/custom_nodes"
MODELS_DIR="$COMFYUI_DIR/models"
HF_MIRROR="${HF_MIRROR:-}"

log "ComfyUI path: $COMFYUI_DIR"
[ -n "$COMFYUI_PID" ] && log "ComfyUI running (PID: $COMFYUI_PID)" || warn "ComfyUI not running — you'll need to start it after setup"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Step 1 — Dependencies
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 1/5 — Extra dependencies"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# System deps
apt-get update -qq 2>/dev/null && apt-get install -y -qq ffmpeg libsndfile1 > /dev/null 2>&1 || warn "apt install skipped (may already be present)"

# Python deps — pin versions to avoid conflicts with existing ComfyUI env
pip install librosa soundfile "huggingface_hub[cli]" -q 2>&1 | tail -1 || true

# Verify critical deps actually imported
python3 -c "import librosa; import soundfile" 2>/dev/null || err "Failed to import librosa/soundfile — Python env issue"
log "Audio & HF dependencies installed"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Step 2 — Kijai WanVideoWrapper
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 2/5 — Kijai WanVideoWrapper"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

WRAPPER_DIR="$CUSTOM_NODES_DIR/ComfyUI-WanVideoWrapper"

if [ -d "$WRAPPER_DIR" ]; then
    cd "$WRAPPER_DIR"
    git fetch origin 2>/dev/null
    # Check if longcat_avatar branch exists remotely
    if git branch -r 2>/dev/null | grep -q "origin/longcat_avatar"; then
        git checkout longcat_avatar 2>/dev/null || git checkout -b longcat_avatar origin/longcat_avatar
        git pull origin longcat_avatar 2>/dev/null
        log "WanVideoWrapper switched to longcat_avatar branch"
    else
        warn "longcat_avatar branch not found — it may have been merged into main"
        git checkout main 2>/dev/null || true
        git pull 2>/dev/null
        log "WanVideoWrapper updated (main branch)"
    fi
else
    # Try longcat_avatar branch first, fallback to main
    if git clone -b longcat_avatar https://github.com/kijai/ComfyUI-WanVideoWrapper.git "$WRAPPER_DIR" 2>/dev/null; then
        log "WanVideoWrapper cloned (longcat_avatar branch)"
    else
        git clone https://github.com/kijai/ComfyUI-WanVideoWrapper.git "$WRAPPER_DIR"
        warn "Cloned main branch (longcat_avatar may be merged)"
    fi
fi

cd "$WRAPPER_DIR"
if [ -f requirements.txt ]; then
    pip install -r requirements.txt -q 2>&1 | tail -1 || true
    log "Wrapper requirements installed"
else
    warn "No requirements.txt in wrapper"
fi

# Extra deps that Kijai's wrapper sometimes needs
pip install einops -q 2>/dev/null || true

log "WanVideoWrapper ready"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Step 3 — Model weights
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 3/5 — Model weights"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ☕ This downloads ~55GB. Go grab a coffee..."
echo ""

LONGCAT_DIR="$MODELS_DIR/LongCat"
mkdir -p "$LONGCAT_DIR"

# Set HF mirror if specified (for China/Asia)
if [ -n "$HF_MIRROR" ]; then
    export HF_ENDPOINT="$HF_MIRROR"
    log "Using HuggingFace mirror: $HF_MIRROR"
fi

# --- Download Avatar model ---
download_hf_model() {
    local repo="$1"
    local dest="$2"
    local label="$3"

    if [ -d "$dest" ] && [ "$(find "$dest" -name '*.safetensors' -o -name '*.bin' -o -name '*.pt' 2>/dev/null | head -1)" ]; then
        log "$label weights already present — skipping"
        return 0
    fi

    log "Downloading $label..."
    mkdir -p "$dest"

    # huggingface-cli handles auth, resume, and retries properly
    # (unlike aria2c which chokes on HF redirects — lesson from bebop)
    if huggingface-cli download "$repo" --local-dir "$dest" --resume-download 2>&1; then
        # Verify we actually got model files (not just README/config)
        if [ "$(find "$dest" -name '*.safetensors' -o -name '*.bin' -o -name '*.pt' 2>/dev/null | wc -l)" -gt 0 ]; then
            log "$label downloaded ✓ ($(du -sh "$dest" | cut -f1))"
        else
            err "$label download completed but no model files found! Check HuggingFace repo."
        fi
    else
        err "$label download failed! Check your network connection."
    fi
}

download_hf_model "meituan-longcat/LongCat-Video-Avatar" "$LONGCAT_DIR/LongCat-Video-Avatar" "LongCat-Video-Avatar"
download_hf_model "meituan-longcat/LongCat-Video" "$LONGCAT_DIR/LongCat-Video" "LongCat-Video (base)"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Step 4 — Workflows
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 4/5 — Workflows & Symlinks"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Copy workflows from wrapper if available
WORKFLOW_SRC="$WRAPPER_DIR/LongCat"
if [ -d "$WORKFLOW_SRC" ]; then
    WORKFLOW_DST="$COMFYUI_DIR/user/default/workflows/LongCat"
    mkdir -p "$WORKFLOW_DST"
    cp -r "$WORKFLOW_SRC"/* "$WORKFLOW_DST/" 2>/dev/null || true
    log "LongCat workflows copied to ComfyUI"
else
    warn "No workflow files in wrapper — check Kijai's repo for example workflows"
fi

# Copy any workflows from this repo (absolute path, not relative)
if [ -d "$SCRIPT_DIR/workflows" ]; then
    WORKFLOW_DST="$COMFYUI_DIR/user/default/workflows/LongCat"
    mkdir -p "$WORKFLOW_DST"
    cp -v "$SCRIPT_DIR"/workflows/*.json "$WORKFLOW_DST/" 2>/dev/null && \
        log "Local workflows copied" || true
fi

# Convenience symlink
ln -sfn "$LONGCAT_DIR" "$COMFYUI_DIR/models/longcat"
log "Symlink: models/longcat → $LONGCAT_DIR"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Step 5 — Validation
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 5/5 — Validation"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

ERRORS=0

# Check wrapper is in correct location
if [ -d "$WRAPPER_DIR" ] && [ -f "$WRAPPER_DIR/__init__.py" ] || [ -f "$WRAPPER_DIR/nodes.py" ]; then
    log "WanVideoWrapper: installed ✓"
else
    warn "WanVideoWrapper: missing __init__.py or nodes.py — may not load!"
    ERRORS=$((ERRORS + 1))
fi

# Check model weights exist
AVATAR_FILES=$(find "$LONGCAT_DIR/LongCat-Video-Avatar" -name '*.safetensors' -o -name '*.bin' -o -name '*.pt' 2>/dev/null | wc -l)
BASE_FILES=$(find "$LONGCAT_DIR/LongCat-Video" -name '*.safetensors' -o -name '*.bin' -o -name '*.pt' 2>/dev/null | wc -l)
if [ "$AVATAR_FILES" -gt 0 ]; then
    log "LongCat-Video-Avatar weights: $AVATAR_FILES files ✓"
else
    warn "LongCat-Video-Avatar: no model files found!"
    ERRORS=$((ERRORS + 1))
fi
if [ "$BASE_FILES" -gt 0 ]; then
    log "LongCat-Video base weights: $BASE_FILES files ✓"
else
    warn "LongCat-Video base: no model files found!"
    ERRORS=$((ERRORS + 1))
fi

# Check Python imports
if python3 -c "import librosa; import soundfile" 2>/dev/null; then
    log "Python audio deps: OK ✓"
else
    warn "Python audio deps: import failed!"
    ERRORS=$((ERRORS + 1))
fi

# Check ffmpeg
if command -v ffmpeg &>/dev/null; then
    log "ffmpeg: installed ✓"
else
    warn "ffmpeg: not found!"
    ERRORS=$((ERRORS + 1))
fi

# Disk space check
AVAILABLE_GB=$(df -BG "$MODELS_DIR" | awk 'NR==2 {print $4}' | tr -d 'G')
if [ "$AVAILABLE_GB" -lt 5 ]; then
    warn "Low disk space: ${AVAILABLE_GB}GB remaining!"
fi

# --- Done ---
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
MINUTES=$((ELAPSED / 60))
SECONDS_LEFT=$((ELAPSED % 60))

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$ERRORS" -eq 0 ]; then
    echo -e "  ${GREEN}🐱 Setup complete! All checks passed.${NC} (${MINUTES}m ${SECONDS_LEFT}s)"
else
    echo -e "  ${YELLOW}🐱 Setup complete with $ERRORS warning(s).${NC} (${MINUTES}m ${SECONDS_LEFT}s)"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  ComfyUI path : $COMFYUI_DIR"
echo "  Model weights: $LONGCAT_DIR"
echo "  Wrapper      : $WRAPPER_DIR"
echo ""
echo "  Next: Restart ComfyUI, then load a LongCat workflow."
echo ""
echo "  Tips:"
echo "    - Audio CFG: 3-5 for best lip sync"
echo "    - Max ~15s per clip (use continuation for longer)"
echo "    - Put 'talking' or 'speaking' in your prompts"
echo ""
