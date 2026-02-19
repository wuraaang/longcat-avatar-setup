# 🐱 LongCat Avatar Setup

One-shot install script for **LongCat-Video-Avatar** on RunPod / GPUhub.

Assumes you're using the **official ComfyUI template** (ComfyUI already installed).  
This script only adds what's needed: Kijai's wrapper + model weights.

## Usage

### RunPod (official ComfyUI template)
```bash
cd /workspace
git clone https://github.com/wuraaang/longcat-avatar-setup.git
cd longcat-avatar-setup
bash setup-runpod.sh
```

### GPUhub (Asia/China VPS)
```bash
git clone https://github.com/wuraaang/longcat-avatar-setup.git
cd longcat-avatar-setup
bash setup-gpuhub.sh
```

## What it installs
- **Kijai WanVideoWrapper** (longcat_avatar branch) → ComfyUI custom node
- **LongCat-Video-Avatar** model weights from HuggingFace (~30GB)
- **LongCat-Video** base model weights (~25GB)
- Audio deps (librosa, soundfile, ffmpeg)
- Example workflows (if available in wrapper)

## Requirements
- **RunPod ComfyUI template** or any setup with ComfyUI at `/workspace/ComfyUI`
- NVIDIA GPU with **24GB+ VRAM** (RTX 4090/5090)
- ~60GB free disk space
- CUDA 12.4+

## Tips
- Audio CFG 3-5 for best lip sync
- Max ~15s per generation (use video continuation for longer clips)
- Include "talking" or "speaking" in your prompts for natural lip movement
- GPUhub script auto-uses Chinese mirrors (hf-mirror.com, PyPI Tsinghua)
