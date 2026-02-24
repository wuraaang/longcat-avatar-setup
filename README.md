# LongCat Avatar YouTube Pipeline

Pipeline complète pour générer des vidéos avatar lip-sync pour YouTube : **TTS → Avatar → clips 5-10 sec**.

Le workflow embarqué (`workflow_avatar_api.json`) inclut les fixes **TCFG + FreSca** pour supprimer les points blancs.

---

## One-Shot Setup (RunPod)

```bash
# Cloner le repo et tout installer en une commande
git clone https://github.com/wuraaang/longcat-avatar-setup.git
cd longcat-avatar-setup
bash setup.sh
```

Le script `setup.sh` fait tout automatiquement :
1. Libère l'espace disque (supprime les anciens modèles LongCat)
2. Vérifie les dépendances système (aria2c, ffmpeg, python3)
3. Installe les dépendances Python
4. Installe les **optimisations** (SageAttention2, triton, vérifie torch.compile)
5. Clone/met à jour les custom nodes ComfyUI
6. Crée les répertoires modèles
7. Télécharge ~21.7 Go de modèles (avec reprise automatique)
8. Configure les symlinks et copie le workflow
9. Vérifie que tout est en place

---

## Quick Start

```bash
# Pipeline complète (TTS + Avatar + merge audio)
python pipeline.py \
    --text "Bienvenue sur ma chaîne YouTube !" \
    --image personnage.png \
    --output clip_01.mp4 \
    --ref-voice ma_voix.wav \
    --duration 5

# Avec paramètres de génération personnalisés
python pipeline.py \
    --text "Hello" --image test.png \
    --steps 20 --shift 10 --block-swap 25 --raag-alpha 0.75

# TTS seul
python tts.py "Bonjour, bienvenue sur ma chaîne" audio.wav
```

---

## Modèles requis (~21.7 Go téléchargés par setup.sh)

| Modèle | Taille | Destination |
|--------|--------|-------------|
| LongCat-Avatar-single fp8 | 16.9 Go | `models/diffusion_models/LongCat/` |
| LongCat refinement LoRA rank128 | 2.47 Go | `models/loras/` |
| wav2vec2 chinese base fp16 | 190 Mo | `models/wav2vec2/` |
| MelBandRoFormer fp32 | 913 Mo | `models/diffusion_models/` |
| CLIP Vision H | 1.26 Go | `models/clip_vision/` |

**Modèles pré-existants** (déjà installés sur le pod RunPod) :
- `umt5-xxl-enc-bf16.safetensors` (text encoder)
- `Wan2_1_VAE_bf16.safetensors` (VAE)
- `LongCat_TI2V_comfy_fp8_e4m3fn_scaled_KJ.safetensors` (I2V)
- `LongCat_distill_lora_alpha64_bf16.safetensors` (LoRA I2V)

---

## Optimisations de vitesse

### Actives par défaut (dans le workflow)

| Optimisation | Effet | Détails |
|-------------|-------|---------|
| **FP8** | ~2x vs bf16 | Réduit VRAM, qualité quasi-identique |
| **TeaCache** | 1.6-2.3x | Accélération génération tokens (threshold 0.25-0.28) |
| **Block Swap 20** | Gestion VRAM | Permet de tourner sur 24 Go |
| **TCFG + FreSca** | Qualité | Supprime les artefacts (points blancs) |

### Nouvelles optimisations (installées par setup.sh)

#### SageAttention2 (gain: 1.5-2x)

Installé automatiquement par `setup.sh`. Pour l'activer :

1. Dans ComfyUI, ouvrir le **WanVideo Model Loader** node
2. Changer `attention_mode` de `sdpa` → `sageattn`
3. C'est tout !

> Si l'installation échoue (certaines configs CUDA), le fallback `sdpa` fonctionne très bien.

#### torch.compile (gain: 10-20%)

Déjà disponible dans PyTorch >= 2.0. Pour l'activer :

1. Ajouter un node **TorchCompileModel** ou **WanVideoTorchCompileSettings** dans le workflow
2. Backend recommandé : `inductor`
3. La première exécution est plus lente (compilation), les suivantes sont accélérées

#### NVFP4 (expérimental)

Quantification plus agressive que FP8. Nécessite :
- CUDA 12.8+
- GPU compute capability >= 8.0 (RTX 3090/4090)
- ComfyUI version récente

### Gains cumulés estimés

| Configuration | Vitesse clip 5s (125 frames) |
|--------------|------------------------------|
| Base (fp8 + TeaCache) | ~3-4 min |
| + SageAttention2 | ~2 min |
| + torch.compile | ~1.5-2 min |

---

## Paramètres de génération

| Paramètre | Défaut | Description |
|-----------|--------|-------------|
| `--steps` | 15 | Nombre de pas de sampling |
| `--shift` | 8.0 | Shift du scheduler |
| `--block-swap` | 20 | Nombre de blocs à swapper (VRAM) |
| `--raag-alpha` | 0.5 | Alpha TCFG/RAAG (qualité vs vitesse) |
| `--duration` | 5.0 | Durée cible en secondes |
| `--ref-voice` | - | Fichier .wav de référence pour voice cloning (~10s) |

---

## Fichiers du repo

| Fichier | Rôle |
|---------|------|
| `setup.sh` | Installation one-shot : deps, optimisations, custom nodes, modèles (~21 Go) |
| `tts.py` | ChatterBox TTS : texte → .wav (avec voice cloning optionnel) |
| `pipeline.py` | Orchestration : texte + image → vidéo lip-sync avec audio |
| `workflow_avatar_api.json` | Workflow ComfyUI optimisé (API format, TCFG + FreSca) |
| `export_workflow.py` | Utilitaire : exporte le workflow courant depuis ComfyUI |

---

## Custom Nodes installés

| Node | Branche | Usage |
|------|---------|-------|
| [ComfyUI-WanVideoWrapper](https://github.com/kijai/ComfyUI-WanVideoWrapper) | `longcat_avatar` | Chargement modèle WanVideo + Avatar |
| [ComfyUI-VideoHelperSuite](https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite) | `main` | Export vidéo |
| [ComfyUI-MelBandRoFormer](https://github.com/kijai/ComfyUI-MelBandRoFormer) | `main` | Séparation audio |
| [ComfyUI-KJNodes](https://github.com/kijai/ComfyUI-KJNodes) | `main` | Nodes utilitaires Kijai |
| [comfy-pilot](https://github.com/yuvraj108c/comfy-pilot) | `main` | Monitoring |

---

## Prérequis

- RunPod avec **RTX 4090** (24 Go VRAM)
- ComfyUI installé dans `/workspace/runpod-slim/ComfyUI`
- ~50 Go d'espace disque pour les modèles

## Performance estimée (RTX 4090)

- Clip 5 sec (125 frames) : **~2-4 min** (selon optimisations activées)
- Optimisations : fp8 + TeaCache + block swap + TCFG + FreSca + SageAttention2

---

## Re-exporter le workflow

Si le workflow est modifié dans l'UI ComfyUI :

```bash
python export_workflow.py
```

Cela se connecte à ComfyUI, récupère le workflow courant, et régénère `workflow_avatar_api.json`.

---

## Troubleshooting

**SageAttention ne s'installe pas ?**
→ Normal sur certaines configs. Le mode `sdpa` (défaut) fonctionne très bien.

**torch.compile : première exécution très lente ?**
→ C'est normal, la compilation est cachée pour les exécutions suivantes.

**Modèle manquant après setup ?**
→ Relancer `bash setup.sh` — les téléchargements reprennent là où ils se sont arrêtés (aria2c).

**Points blancs dans la vidéo ?**
→ Le workflow inclut déjà TCFG + FreSca. Vérifier que `raag_alpha` est entre 0.3 et 0.75.
