# LongCat Avatar YouTube Pipeline

Pipeline complète pour générer des vidéos avatar lip-sync pour YouTube : TTS → Avatar → clips 5-10 sec.

## Quick Start

```bash
# 1. Setup (modèles, deps, custom nodes)
bash setup.sh

# 2. Générer de la parole
python tts.py "Bonjour, bienvenue sur ma chaîne" audio.wav

# 3. Pipeline complète (TTS + Avatar + merge)
python pipeline.py \
    --text "Bienvenue sur ma chaîne YouTube !" \
    --image personnage.png \
    --output clip_01.mp4 \
    --ref-voice ma_voix.wav \
    --duration 5
```

## Fichiers

| Fichier | Rôle |
|---------|------|
| `setup.sh` | Installation one-shot : deps, custom nodes, modèles (~21 Go) |
| `tts.py` | ChatterBox TTS : texte → .wav (avec voice cloning optionnel) |
| `pipeline.py` | Orchestration : texte + image → vidéo lip-sync avec audio |

## Requis

- RunPod avec RTX 4090 (24 Go VRAM)
- ComfyUI installé dans `/workspace/runpod-slim/ComfyUI`
- ~50 Go d'espace disque pour les modèles

## Performance estimée (RTX 4090)

- Clip 5 sec (125 frames) : ~2-4 min
- Optimisations : fp8 + TeaCache + block swap
