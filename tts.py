#!/usr/bin/env python3
"""
ChatterBox TTS — Standalone text-to-speech for LongCat Avatar pipeline.

Usage:
    python tts.py "Bonjour, bienvenue sur ma chaîne" output.wav
    python tts.py "Hello world" output.wav --ref ma_voix.wav
"""

import argparse
import sys
import time
from pathlib import Path

import torch
import torchaudio


def generate_tts(text: str, output_path: str, ref_audio: str | None = None, exaggeration: float = 0.5, cfg_weight: float = 0.5):
    """Generate speech from text using ChatterBox Turbo."""
    from chatterbox.tts import ChatterboxTTS

    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"Loading ChatterBox model on {device}...")
    t0 = time.time()
    model = ChatterboxTTS.from_pretrained(device=device)
    print(f"Model loaded in {time.time() - t0:.1f}s")

    # Generate audio
    print(f"Generating speech: \"{text[:80]}{'...' if len(text) > 80 else ''}\"")
    t0 = time.time()

    if ref_audio and Path(ref_audio).exists():
        print(f"Voice cloning from: {ref_audio}")
        wav = model.generate(
            text,
            audio_prompt_path=ref_audio,
            exaggeration=exaggeration,
            cfg_weight=cfg_weight,
        )
    else:
        if ref_audio:
            print(f"Warning: ref audio '{ref_audio}' not found, using default voice")
        wav = model.generate(text, exaggeration=exaggeration, cfg_weight=cfg_weight)

    duration = wav.shape[-1] / model.sr
    print(f"Generated {duration:.1f}s of audio in {time.time() - t0:.1f}s")

    # Save
    torchaudio.save(output_path, wav.cpu(), model.sr)
    print(f"Saved: {output_path}")

    # Free VRAM
    del model
    torch.cuda.empty_cache()

    return output_path, duration


def main():
    parser = argparse.ArgumentParser(description="ChatterBox TTS — text to speech")
    parser.add_argument("text", help="Text to synthesize")
    parser.add_argument("output", help="Output .wav file path")
    parser.add_argument("--ref", default=None, help="Reference audio for voice cloning (~10s sample)")
    parser.add_argument("--exaggeration", type=float, default=0.5, help="Voice exaggeration (0-1, default 0.5)")
    parser.add_argument("--cfg-weight", type=float, default=0.5, help="CFG weight (0-1, default 0.5)")
    args = parser.parse_args()

    if not args.output.endswith(".wav"):
        args.output += ".wav"

    generate_tts(args.text, args.output, args.ref, args.exaggeration, args.cfg_weight)


if __name__ == "__main__":
    main()
