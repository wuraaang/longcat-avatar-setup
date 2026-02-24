#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# LongCat Avatar YouTube Pipeline — One-Shot Setup
# Usage: bash setup.sh
#
# Installs everything needed: deps, custom nodes, models, optimizations.
# Designed for RunPod with RTX 4090 (24 Go VRAM).
# ============================================================================

COMFY="/workspace/runpod-slim/ComfyUI"
MODELS="$COMFY/models"
CUSTOM="$COMFY/custom_nodes"
HF="https://huggingface.co"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }

# ── 1. Nettoyage espace disque ──────────────────────────────────────────────
echo "═══ 1/9  Nettoyage espace disque ═══"
if [ -d /root/models/LongCat ]; then
    SIZE=$(du -sh /root/models/LongCat 2>/dev/null | cut -f1)
    echo "Suppression de /root/models/LongCat ($SIZE)..."
    rm -rf /root/models/LongCat
    ok "Espace libéré: $SIZE"
else
    ok "Rien à nettoyer"
fi

# ── 2. Dépendances système ──────────────────────────────────────────────────
echo ""
echo "═══ 2/9  Vérification dépendances système ═══"
for cmd in aria2c ffmpeg python3; do
    if command -v "$cmd" &>/dev/null; then
        ok "$cmd trouvé: $(command -v $cmd)"
    else
        fail "$cmd manquant — installation requise"
        exit 1
    fi
done

# ── 3. Dépendances Python ───────────────────────────────────────────────────
echo ""
echo "═══ 3/9  Installation dépendances Python ═══"
pip install -q \
    gguf ftfy accelerate diffusers peft protobuf pyloudnorm \
    librosa soundfile onnxruntime scipy \
    rotary-embedding-torch einops imageio-ffmpeg opencv-python \
    chatterbox-tts \
    websocket-client
ok "Dépendances Python de base installées"

# ── 4. Optimisations: SageAttention + triton + torch.compile ────────────────
echo ""
echo "═══ 4/9  Installation optimisations (SageAttention, triton) ═══"

# SageAttention2 — accélération attention 1.5-2x
# Nécessite triton pour fonctionner
pip install -q triton 2>/dev/null && ok "triton installé" || warn "triton non disponible"
pip install -q sageattention 2>/dev/null && ok "SageAttention installé" || warn "SageAttention non disponible, fallback sdpa"

# torch.compile — accélération 10-20% via compilation inductor
# Déjà inclus dans PyTorch >= 2.0, on vérifie juste
python3 -c "import torch; assert hasattr(torch, 'compile'); print(f'torch.compile OK (PyTorch {torch.__version__})')" 2>/dev/null \
    && ok "torch.compile disponible" \
    || warn "torch.compile non disponible (PyTorch < 2.0)"

# NVFP4 — quantification avancée (nécessite CUDA 12.8+ et PyTorch récent)
python3 -c "
import torch
major, minor = torch.cuda.get_device_capability()
if major >= 8:
    print(f'GPU compute capability {major}.{minor} — compatible FP8/FP4')
else:
    print(f'GPU compute capability {major}.{minor} — FP8 seulement')
" 2>/dev/null && ok "Vérification GPU OK" || warn "Impossible de vérifier le GPU"

# ── 5. Custom Nodes ─────────────────────────────────────────────────────────
echo ""
echo "═══ 5/9  Vérification custom nodes ═══"

declare -A NODES=(
    ["ComfyUI-WanVideoWrapper"]="https://github.com/kijai/ComfyUI-WanVideoWrapper.git|longcat_avatar"
    ["ComfyUI-VideoHelperSuite"]="https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git|main"
    ["ComfyUI-MelBandRoFormer"]="https://github.com/kijai/ComfyUI-MelBandRoFormer.git|main"
    ["ComfyUI-KJNodes"]="https://github.com/kijai/ComfyUI-KJNodes.git|main"
    ["comfy-pilot"]="https://github.com/yuvraj108c/comfy-pilot.git|main"
)

for node in "${!NODES[@]}"; do
    IFS='|' read -r url branch <<< "${NODES[$node]}"
    if [ -d "$CUSTOM/$node" ]; then
        ok "$node déjà installé"
        # Vérifier la branche
        CURRENT=$(cd "$CUSTOM/$node" && git branch --show-current 2>/dev/null || echo "unknown")
        if [ "$CURRENT" != "$branch" ]; then
            warn "$node: branche $CURRENT, checkout $branch..."
            (cd "$CUSTOM/$node" && git fetch origin && git checkout "$branch" && git pull origin "$branch") 2>&1 | tail -1
        fi
    else
        echo "Installation de $node (branche $branch)..."
        git clone -b "$branch" "$url" "$CUSTOM/$node" 2>&1 | tail -1
        ok "$node installé"
    fi
    # Installer les requirements si présents
    if [ -f "$CUSTOM/$node/requirements.txt" ]; then
        pip install -q -r "$CUSTOM/$node/requirements.txt" 2>/dev/null || true
    fi
done

# ── 6. Créer répertoires modèles ────────────────────────────────────────────
echo ""
echo "═══ 6/9  Création répertoires modèles ═══"
mkdir -p "$MODELS/diffusion_models/LongCat"
mkdir -p "$MODELS/wav2vec2"
mkdir -p "$MODELS/clip_vision"
mkdir -p "$COMFY/user/default/workflows/LongCat"
ok "Répertoires créés"

# ── 7. Téléchargement modèles ───────────────────────────────────────────────
echo ""
echo "═══ 7/9  Téléchargement modèles ═══"

download() {
    local url="$1" dest="$2" name="$3"
    if [ -f "$dest" ]; then
        ok "$name déjà présent ($(du -h "$dest" | cut -f1))"
        return 0
    fi
    echo "Téléchargement $name..."
    mkdir -p "$(dirname "$dest")"
    aria2c -x 16 -s 16 -k 1M --console-log-level=warn -o "$dest" "$url"
    if [ -f "$dest" ]; then
        ok "$name téléchargé ($(du -h "$dest" | cut -f1))"
    else
        fail "$name — échec du téléchargement"
        return 1
    fi
}

# Modèles déjà présents (vérification seulement)
echo "── Vérification modèles existants ──"
for f in \
    "$MODELS/text_encoders/umt5-xxl-enc-bf16.safetensors" \
    "$MODELS/vae/wanvideo/Wan2_1_VAE_bf16.safetensors" \
    "$MODELS/diffusion_models/WanVideo/LongCat_TI2V_comfy_fp8_e4m3fn_scaled_KJ.safetensors" \
    "$MODELS/loras/WanVideo/LongCat_distill_lora_alpha64_bf16.safetensors"; do
    if [ -f "$f" ]; then
        ok "$(basename "$f") présent"
    else
        warn "$(basename "$f") manquant — requis pour I2V"
    fi
done

# Nouveaux modèles à télécharger
echo ""
echo "── Téléchargement nouveaux modèles (~21.7 Go) ──"

download \
    "$HF/Kijai/LongCat-Video_comfy/resolve/main/Avatar/LongCat-Avatar-single_fp8_e4m3fn_scaled_mixed_KJ.safetensors" \
    "$MODELS/diffusion_models/LongCat/LongCat-Avatar-single_fp8_e4m3fn_scaled_mixed_KJ.safetensors" \
    "Avatar fp8 (16.9 Go)"

download \
    "$HF/Kijai/LongCat-Video_comfy/resolve/main/LongCat_refinement_lora_rank128_bf16.safetensors" \
    "$MODELS/loras/LongCat_refinement_lora_rank128_bf16.safetensors" \
    "LoRA rank128 (2.47 Go)"

download \
    "$HF/Kijai/wav2vec2_safetensors/resolve/main/wav2vec2-chinese-base_fp16.safetensors" \
    "$MODELS/wav2vec2/wav2vec2-chinese-base_fp16.safetensors" \
    "wav2vec2 (190 Mo)"

download \
    "$HF/Kijai/MelBandRoFormer_comfy/resolve/main/MelBandRoformer_fp32.safetensors" \
    "$MODELS/diffusion_models/MelBandRoformer_fp32.safetensors" \
    "MelBandRoFormer (913 Mo)"

download \
    "$HF/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors" \
    "$MODELS/clip_vision/clip_vision_h.safetensors" \
    "CLIP Vision H (1.26 Go)"

# ── 8. Symlink LoRA + Copie workflow optimisé ────────────────────────────────
echo ""
echo "═══ 8/9  Symlinks et workflow ═══"

# Symlink pour compatibilité noms anciens
if [ -f "$MODELS/loras/LongCat_refinement_lora_rank128_bf16.safetensors" ]; then
    ln -sf "$MODELS/loras/LongCat_refinement_lora_rank128_bf16.safetensors" \
           "$MODELS/loras/LongCat_distill_lora_rank128_bf16.safetensors"
    ok "Symlink LoRA créé"
fi

# Copie workflow optimisé (API format, avec TCFG + FreSca)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/workflow_avatar_api.json" ]; then
    cp "$SCRIPT_DIR/workflow_avatar_api.json" \
       "$COMFY/user/default/workflows/LongCat/workflow_avatar_api.json"
    ok "Workflow API optimisé copié"
else
    fail "workflow_avatar_api.json manquant dans le repo"
fi

# ── 9. Vérification finale ──────────────────────────────────────────────────
echo ""
echo "═══ 9/9  Vérification finale ═══"
MISSING=0
declare -A REQUIRED_FILES=(
    ["Text encoder"]="$MODELS/text_encoders/umt5-xxl-enc-bf16.safetensors"
    ["VAE"]="$MODELS/vae/wanvideo/Wan2_1_VAE_bf16.safetensors"
    ["I2V fp8"]="$MODELS/diffusion_models/WanVideo/LongCat_TI2V_comfy_fp8_e4m3fn_scaled_KJ.safetensors"
    ["LoRA alpha64"]="$MODELS/loras/WanVideo/LongCat_distill_lora_alpha64_bf16.safetensors"
    ["Avatar fp8"]="$MODELS/diffusion_models/LongCat/LongCat-Avatar-single_fp8_e4m3fn_scaled_mixed_KJ.safetensors"
    ["LoRA rank128"]="$MODELS/loras/LongCat_refinement_lora_rank128_bf16.safetensors"
    ["wav2vec2"]="$MODELS/wav2vec2/wav2vec2-chinese-base_fp16.safetensors"
    ["MelBandRoFormer"]="$MODELS/diffusion_models/MelBandRoformer_fp32.safetensors"
    ["CLIP Vision H"]="$MODELS/clip_vision/clip_vision_h.safetensors"
    ["Workflow API"]="$COMFY/user/default/workflows/LongCat/workflow_avatar_api.json"
)

for name in "${!REQUIRED_FILES[@]}"; do
    if [ -f "${REQUIRED_FILES[$name]}" ]; then
        ok "$name"
    else
        fail "$name — MANQUANT: ${REQUIRED_FILES[$name]}"
        MISSING=$((MISSING + 1))
    fi
done

# Résumé optimisations
echo ""
echo "── Optimisations disponibles ──"
python3 -c "
try:
    import sageattention
    print('\033[0;32m[OK]\033[0m SageAttention2 — sélectionner \"sageattn\" dans WanVideo Model Loader')
except ImportError:
    print('\033[1;33m[WARN]\033[0m SageAttention non installé — attention mode: sdpa (par défaut)')
" 2>/dev/null || true

python3 -c "
import torch
if hasattr(torch, 'compile'):
    print('\033[0;32m[OK]\033[0m torch.compile — utiliser le node TorchCompileModel (backend: inductor)')
else:
    print('\033[1;33m[WARN]\033[0m torch.compile non disponible')
" 2>/dev/null || true

echo ""
if [ $MISSING -eq 0 ]; then
    echo -e "${GREEN}══════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Setup terminé ! Tous les modèles OK.   ${NC}"
    echo -e "${GREEN}══════════════════════════════════════════${NC}"
    echo ""
    echo "Prochaine étape:"
    echo "  python pipeline.py --text \"Bonjour !\" --image personnage.png --output clip.mp4"
else
    echo -e "${RED}══════════════════════════════════════════${NC}"
    echo -e "${RED}  $MISSING modèle(s) manquant(s)          ${NC}"
    echo -e "${RED}══════════════════════════════════════════${NC}"
    exit 1
fi
