#!/bin/bash
set -euo pipefail

# ============================================================
# 🐱 LongCat Avatar — RunPod Setup (FAST)
# For use with RunPod comfyui-base (runpod-slim) template
#
# Downloads only what's needed for single-avatar talking head:
#   - avatar_single (~63GB) — NOT avatar_multi
#   - Base model VAE + text encoder (~18GB)
#   - Audio models (~1.5GB)
#
# Uses aria2c x16 parallel connections for speed.
# Lesson from bebop: resolve HF redirects first, then aria2c.
# ============================================================

echo "🐱 LongCat Avatar Setup (FAST) — Starting..."
START_TIME=$(date +%s)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARIA2_CONNECTIONS=16

# --- Colors ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
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
    log "User override: $COMFYUI_DIR"
elif [ -d "/workspace/runpod-slim/ComfyUI" ]; then
    COMFYUI_DIR="/workspace/runpod-slim/ComfyUI"
elif [ -d "/workspace/madapps/ComfyUI" ]; then
    COMFYUI_DIR="/workspace/madapps/ComfyUI"
elif [ -d "/workspace/ComfyUI" ]; then
    COMFYUI_DIR="/workspace/ComfyUI"
elif [ -d "/root/ComfyUI" ]; then
    COMFYUI_DIR="/root/ComfyUI"
else
    err "ComfyUI not found! Set COMFYUI_DIR manually."
fi

# Verify running process matches (lesson from bebop)
COMFYUI_PID=$(pgrep -f "main.py.*--listen" 2>/dev/null | head -1 || true)
if [ -n "$COMFYUI_PID" ]; then
    RUNNING_CWD=$(readlink -f /proc/$COMFYUI_PID/cwd 2>/dev/null || true)
    if [ -n "$RUNNING_CWD" ] && [ "$RUNNING_CWD" != "$COMFYUI_DIR" ]; then
        warn "Running ComfyUI at $RUNNING_CWD — switching!"
        COMFYUI_DIR="$RUNNING_CWD"
    fi
fi

CUSTOM_NODES_DIR="$COMFYUI_DIR/custom_nodes"
MODELS_DIR="$COMFYUI_DIR/models"
HF_MIRROR="${HF_MIRROR:-https://huggingface.co}"
log "ComfyUI: $COMFYUI_DIR"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Step 1 — Dependencies + aria2c
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 1/5 — Dependencies"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

apt-get update -qq 2>/dev/null && apt-get install -y -qq ffmpeg libsndfile1 aria2 > /dev/null 2>&1 || warn "apt skipped"
pip install librosa soundfile einops -q 2>&1 | tail -1 || true
python3 -c "import librosa; import soundfile" 2>/dev/null || err "librosa/soundfile import failed"
command -v aria2c &>/dev/null || err "aria2c not installed"
log "All deps ready (aria2c + audio + ffmpeg)"

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
    if git branch -r 2>/dev/null | grep -q "origin/longcat_avatar"; then
        git checkout longcat_avatar 2>/dev/null || git checkout -b longcat_avatar origin/longcat_avatar
        git pull origin longcat_avatar 2>/dev/null
        log "WanVideoWrapper → longcat_avatar branch"
    else
        git checkout main 2>/dev/null; git pull 2>/dev/null
        warn "longcat_avatar branch not found — using main"
    fi
else
    if git clone -b longcat_avatar https://github.com/kijai/ComfyUI-WanVideoWrapper.git "$WRAPPER_DIR" 2>/dev/null; then
        log "WanVideoWrapper cloned (longcat_avatar)"
    else
        git clone https://github.com/kijai/ComfyUI-WanVideoWrapper.git "$WRAPPER_DIR"
        warn "Cloned main branch"
    fi
fi

cd "$WRAPPER_DIR"
[ -f requirements.txt ] && pip install -r requirements.txt -q 2>&1 | tail -1 || true
log "WanVideoWrapper ready"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Step 3 — Download models (FAST)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 3/5 — Model weights (aria2c x${ARIA2_CONNECTIONS})"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

LONGCAT_DIR="$MODELS_DIR/LongCat"
mkdir -p "$LONGCAT_DIR"

# Fast download function: resolve HF redirect then aria2c x16
# Lesson from bebop: aria2c chokes on redirects, resolve with curl first
fast_download() {
    local url="$1"
    local dest_dir="$2"
    local filename="$3"
    local dest_path="${dest_dir}/${filename}"
    local min_size="${4:-1000000}"  # minimum expected size in bytes

    if [ -f "$dest_path" ] && [ "$(stat -c%s "$dest_path" 2>/dev/null || echo 0)" -gt "$min_size" ]; then
        log "Already downloaded: $filename — skip"
        return 0
    fi

    mkdir -p "$dest_dir"

    # Resolve redirect (lesson from bebop: HF/CivitAI redirects break aria2c)
    local direct_url
    direct_url=$(curl -sI -L -o /dev/null -w '%{url_effective}' "$url" 2>/dev/null)
    [ -z "$direct_url" ] && direct_url="$url"

    if aria2c -x "${ARIA2_CONNECTIONS}" -s "${ARIA2_CONNECTIONS}" \
        --max-connection-per-server="${ARIA2_CONNECTIONS}" \
        --min-split-size=5M \
        --file-allocation=none \
        --console-log-level=warn \
        --summary-interval=10 \
        -d "$dest_dir" -o "$filename" \
        "$direct_url" 2>&1; then

        # Verify file size (lesson from bebop: truncated downloads)
        local actual_size=$(stat -c%s "$dest_path" 2>/dev/null || echo 0)
        if [ "$actual_size" -lt "$min_size" ]; then
            warn "$filename is only $(numfmt --to=iec $actual_size) — possibly truncated!"
            rm -f "$dest_path"
            return 1
        fi
        log "$filename ✓ ($(numfmt --to=iec $actual_size))"
    else
        err "Download failed: $filename"
    fi
}

# Helper to build HF download URL
HF_BASE="${HF_MIRROR}/meituan-longcat"

echo ""
echo "  📦 LongCat-Video-Avatar — avatar_single (~63GB, 6 shards)"
echo ""

AVATAR_DIR="$LONGCAT_DIR/LongCat-Video-Avatar/avatar_single"
mkdir -p "$AVATAR_DIR"

# Download the 6 shards in parallel (background jobs)
for i in $(seq 1 6); do
    padded=$(printf "%05d" $i)
    fname="diffusion_pytorch_model-${padded}-of-00006.safetensors"
    fast_download \
        "${HF_BASE}/LongCat-Video-Avatar/resolve/main/avatar_single/${fname}" \
        "$AVATAR_DIR" \
        "$fname" \
        "1000000000" &  # min 1GB
done

# Also download config + other small files in parallel
for f in config.json model_index.json; do
    fast_download \
        "${HF_BASE}/LongCat-Video-Avatar/resolve/main/avatar_single/${f}" \
        "$AVATAR_DIR" \
        "$f" \
        "100" &
done

# Download audio models
echo ""
echo "  📦 Audio models (~1.5GB)"
echo ""

AUDIO_DIR="$LONGCAT_DIR/LongCat-Video-Avatar/chinese-wav2vec2-base"
mkdir -p "$AUDIO_DIR"
fast_download "${HF_BASE}/LongCat-Video-Avatar/resolve/main/chinese-wav2vec2-base/chinese-wav2vec2-base-fairseq-ckpt.pt" "$AUDIO_DIR" "chinese-wav2vec2-base-fairseq-ckpt.pt" "500000000" &
fast_download "${HF_BASE}/LongCat-Video-Avatar/resolve/main/chinese-wav2vec2-base/pytorch_model.bin" "$AUDIO_DIR" "pytorch_model.bin" "100000000" &

# Config files from root
for f in chinese-wav2vec2-base/config.json chinese-wav2vec2-base/preprocessor_config.json; do
    bname=$(basename "$f")
    fast_download "${HF_BASE}/LongCat-Video-Avatar/resolve/main/$f" "$AUDIO_DIR" "$bname" "100" &
done

# Vocal separator
VOCAL_DIR="$LONGCAT_DIR/LongCat-Video-Avatar/vocal_separator"
mkdir -p "$VOCAL_DIR"
fast_download "${HF_BASE}/LongCat-Video-Avatar/resolve/main/vocal_separator/Kim_Vocal_2.onnx" "$VOCAL_DIR" "Kim_Vocal_2.onnx" "10000000" &

echo ""
echo "  ⏳ Waiting for avatar_single + audio downloads..."
wait
log "Avatar model downloads complete"

echo ""
echo "  📦 Base model — VAE + text encoder (~18GB)"
echo ""

# VAE (needed for decode)
VAE_DIR="$LONGCAT_DIR/LongCat-Video/vae"
mkdir -p "$VAE_DIR"
fast_download "${HF_BASE}/LongCat-Video/resolve/main/vae/diffusion_pytorch_model.safetensors" "$VAE_DIR" "diffusion_pytorch_model.safetensors" "100000000" &
fast_download "${HF_BASE}/LongCat-Video/resolve/main/vae/config.json" "$VAE_DIR" "config.json" "100" &

# Text encoder (5 shards)
TE_DIR="$LONGCAT_DIR/LongCat-Video/text_encoder"
mkdir -p "$TE_DIR"
for i in $(seq 1 5); do
    padded=$(printf "%05d" $i)
    fname="model-${padded}-of-00005.safetensors"
    fast_download \
        "${HF_BASE}/LongCat-Video/resolve/main/text_encoder/${fname}" \
        "$TE_DIR" \
        "$fname" \
        "1000000000" &
done

# Text encoder config files
for f in config.json model.safetensors.index.json; do
    fast_download "${HF_BASE}/LongCat-Video/resolve/main/text_encoder/$f" "$TE_DIR" "$f" "100" &
done

# Tokenizer
TOK_DIR="$LONGCAT_DIR/LongCat-Video/tokenizer"
mkdir -p "$TOK_DIR"
for f in spiece.model tokenizer.json tokenizer_config.json; do
    fast_download "${HF_BASE}/LongCat-Video/resolve/main/tokenizer/$f" "$TOK_DIR" "$f" "100" &
done

echo ""
echo "  ⏳ Waiting for base model downloads..."
wait
log "Base model downloads complete"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Step 4 — Workflows
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 4/5 — Workflows"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

WORKFLOW_SRC="$WRAPPER_DIR/LongCat"
if [ -d "$WORKFLOW_SRC" ]; then
    WORKFLOW_DST="$COMFYUI_DIR/user/default/workflows/LongCat"
    mkdir -p "$WORKFLOW_DST"
    cp -r "$WORKFLOW_SRC"/* "$WORKFLOW_DST/" 2>/dev/null || true
    log "LongCat workflows copied"
else
    warn "No workflows in wrapper — load manually from Kijai's repo"
fi

[ -d "$SCRIPT_DIR/workflows" ] && cp "$SCRIPT_DIR"/workflows/*.json "$COMFYUI_DIR/user/default/workflows/" 2>/dev/null && log "Local workflows copied" || true

ln -sfn "$LONGCAT_DIR" "$COMFYUI_DIR/models/longcat"
log "Symlink: models/longcat"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Step 5 — Validation
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 5/5 — Validation"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

ERRORS=0

# Wrapper check
[ -d "$WRAPPER_DIR" ] && ([ -f "$WRAPPER_DIR/__init__.py" ] || [ -f "$WRAPPER_DIR/nodes.py" ]) && \
    log "WanVideoWrapper: OK ✓" || { warn "WanVideoWrapper: structure issue!"; ERRORS=$((ERRORS+1)); }

# Avatar single shards (should be 6 files, each >5GB)
AVATAR_COUNT=$(find "$AVATAR_DIR" -name '*.safetensors' -size +5G 2>/dev/null | wc -l)
[ "$AVATAR_COUNT" -eq 6 ] && \
    log "Avatar single: $AVATAR_COUNT/6 shards ✓ ($(du -sh "$AVATAR_DIR" 2>/dev/null | cut -f1))" || \
    { warn "Avatar single: only $AVATAR_COUNT/6 shards >5GB!"; ERRORS=$((ERRORS+1)); }

# Text encoder (should be 5 files)
TE_COUNT=$(find "$TE_DIR" -name '*.safetensors' -size +1G 2>/dev/null | wc -l)
[ "$TE_COUNT" -eq 5 ] && \
    log "Text encoder: $TE_COUNT/5 shards ✓" || \
    { warn "Text encoder: only $TE_COUNT/5 shards!"; ERRORS=$((ERRORS+1)); }

# VAE
[ -f "$VAE_DIR/diffusion_pytorch_model.safetensors" ] && \
    log "VAE: OK ✓" || { warn "VAE: missing!"; ERRORS=$((ERRORS+1)); }

# Audio
[ -f "$AUDIO_DIR/chinese-wav2vec2-base-fairseq-ckpt.pt" ] && \
    log "Audio model: OK ✓" || { warn "Audio model: missing!"; ERRORS=$((ERRORS+1)); }

# Python + ffmpeg
python3 -c "import librosa; import soundfile" 2>/dev/null && log "Python deps: OK ✓" || { warn "Python deps!"; ERRORS=$((ERRORS+1)); }
command -v ffmpeg &>/dev/null && log "ffmpeg: OK ✓" || { warn "ffmpeg missing!"; ERRORS=$((ERRORS+1)); }

# Disk
AVAIL=$(df -BG "$MODELS_DIR" | awk 'NR==2{print $4}' | tr -d 'G')
[ "$AVAIL" -lt 5 ] && warn "Low disk: ${AVAIL}GB free!"

# --- Done ---
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
MINUTES=$((ELAPSED / 60))
SECS=$((ELAPSED % 60))

TOTAL_SIZE=$(du -sh "$LONGCAT_DIR" 2>/dev/null | cut -f1)

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$ERRORS" -eq 0 ]; then
    echo -e "  ${GREEN}🐱 Setup complete! All checks passed.${NC} (${MINUTES}m ${SECS}s)"
else
    echo -e "  ${YELLOW}🐱 Setup done with $ERRORS warning(s).${NC} (${MINUTES}m ${SECS}s)"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Downloaded: $TOTAL_SIZE"
echo "  ComfyUI   : $COMFYUI_DIR"
echo "  Weights   : $LONGCAT_DIR"
echo ""
echo "  → Restart ComfyUI, then load a LongCat Avatar workflow."
echo ""
echo "  Tips:"
echo "    - Audio CFG 3-5 for best lip sync"
echo "    - Max ~15s per clip"
echo "    - Put 'talking' or 'speaking' in prompts"
echo ""
