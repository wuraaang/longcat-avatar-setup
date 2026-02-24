# LongCat Avatar YouTube Pipeline

Pipeline complète pour générer des vidéos avatar lip-sync pour YouTube : TTS → Avatar → clips 5-10 sec.

Le workflow embarqué (`workflow_avatar_api.json`) inclut les fixes TCFG + FreSca pour supprimer les points blancs.

## Quick Start

```bash
# 1. Setup (modèles, deps, custom nodes)
bash setup.sh

# 2. Pipeline complète (TTS + Avatar + merge)
python pipeline.py \
    --text "Bienvenue sur ma chaîne YouTube !" \
    --image personnage.png \
    --output clip_01.mp4 \
    --ref-voice ma_voix.wav \
    --duration 5

# 3. Avec paramètres de génération personnalisés
python pipeline.py \
    --text "Hello" --image test.png \
    --steps 20 --shift 10 --block-swap 25 --raag-alpha 0.75

# 4. TTS seul
python tts.py "Bonjour, bienvenue sur ma chaîne" audio.wav
```

## Paramètres de génération

| Paramètre | Défaut | Description |
|-----------|--------|-------------|
| `--steps` | 15 | Nombre de pas de sampling |
| `--shift` | 8.0 | Shift du scheduler |
| `--block-swap` | 20 | Nombre de blocs à swapper (VRAM) |
| `--raag-alpha` | 0.5 | Alpha TCFG/RAAG (qualité vs vitesse) |

## Fichiers

| Fichier | Rôle |
|---------|------|
| `setup.sh` | Installation one-shot : deps, custom nodes, modèles (~21 Go) |
| `tts.py` | ChatterBox TTS : texte → .wav (avec voice cloning optionnel) |
| `pipeline.py` | Orchestration : texte + image → vidéo lip-sync avec audio |
| `workflow_avatar_api.json` | Workflow ComfyUI optimisé (API format, TCFG + FreSca) |
| `export_workflow.py` | Utilitaire : exporte le workflow courant depuis ComfyUI |

## Requis

- RunPod avec RTX 4090 (24 Go VRAM)
- ComfyUI installé dans `/workspace/runpod-slim/ComfyUI`
- ~50 Go d'espace disque pour les modèles

## Performance estimée (RTX 4090)

- Clip 5 sec (125 frames) : ~2-4 min
- Optimisations : fp8 + TeaCache + block swap + TCFG + FreSca

## Re-exporter le workflow

Si le workflow est modifié dans l'UI ComfyUI :

```bash
python export_workflow.py
```

Cela se connecte à ComfyUI, récupère le workflow courant, et régénère `workflow_avatar_api.json`.
