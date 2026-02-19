# 🐱 LongCat Avatar Setup

One-shot install script for LongCat-Video-Avatar on RunPod / GPUhub.

**What it does:**
- Installs ComfyUI (latest)
- Installs Kijai's WanVideoWrapper (longcat_avatar branch)
- Downloads LongCat-Video-Avatar model weights from HuggingFace
- Sets up all dependencies
- Launches ComfyUI ready to go

## Usage

### RunPod
```bash
git clone https://github.com/wuraaang/longcat-avatar-setup.git
cd longcat-avatar-setup
bash setup-runpod.sh
```

### GPUhub (China/Asia VPS)
```bash
git clone https://github.com/wuraaang/longcat-avatar-setup.git
cd longcat-avatar-setup
bash setup-gpuhub.sh
```

## Requirements
- NVIDIA GPU with **24GB+ VRAM** (RTX 4090/5090 recommended)
- CUDA 12.4+
- ~50GB disk space (model weights ~30GB)

## Notes
- GPUhub script uses HuggingFace mirror (hf-mirror.com) for China-accessible downloads
- 15 second generation limit per clip (use video continuation for longer)
- Audio CFG 3-5 for best lip sync
