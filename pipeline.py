#!/usr/bin/env python3
"""
LongCat Avatar Pipeline — End-to-end: text + image → lip-synced video.

Uses an embedded API-format workflow (workflow_avatar_api.json) with
TCFG + FreSca fixes pre-configured. No manual ComfyUI UI setup needed.

Usage:
    python pipeline.py \
        --text "Bienvenue sur ma chaîne YouTube !" \
        --image personnage.png \
        --output clip_01.mp4 \
        --ref-voice ma_voix.wav \
        --duration 5

    # Override generation parameters:
    python pipeline.py \
        --text "Hello" --image test.png \
        --steps 20 --shift 10 --block-swap 25 --raag-alpha 0.75
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path

import websocket
import urllib.request
import urllib.parse

# ── Config ───────────────────────────────────────────────────────────────────
COMFY_DIR = Path("/workspace/runpod-slim/ComfyUI")
COMFY_INPUT = COMFY_DIR / "input"
COMFY_TEMP = COMFY_DIR / "temp"
COMFY_OUTPUT = COMFY_DIR / "output"
SERVER_ADDRESS = "127.0.0.1:8188"
SCRIPT_DIR = Path(__file__).resolve().parent
WORKFLOW_PATH = SCRIPT_DIR / "workflow_avatar_api.json"
FPS = 25

# ── Key node IDs in the Avatar workflow ──────────────────────────────────────
NODE_IDS = {
    "load_image": "284",
    "load_audio": "125",
    "max_frames": "270",
    "trim_audio": "317",
    "model_loader": "122",
    "vae_loader": "129",
    "block_swap": "134",
    "lora_select": "138",
    "text_encode": "241",
    "scheduler": "325",
    "sampler_1": "324",
    "sampler_2": "327",
    "sampler_3": "456",
    "torch_compile": "177",
    "experimental_args": "472",
    "extra_args": "473",
    "image_resize": "281",
    "video_combine_1": "320",
    "video_combine_2": "386",
    "video_combine_3": "453",
}


# ── ComfyUI API helpers ─────────────────────────────────────────────────────

def is_comfyui_running() -> bool:
    try:
        urllib.request.urlopen(f"http://{SERVER_ADDRESS}/system_stats", timeout=3)
        return True
    except Exception:
        return False


def start_comfyui():
    """Start ComfyUI server in background."""
    print("Starting ComfyUI server...")
    env = os.environ.copy()
    env.pop("CLAUDECODE", None)
    proc = subprocess.Popen(
        [sys.executable, "main.py", "--listen", "0.0.0.0", "--port", "8188"],
        cwd=str(COMFY_DIR),
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    for i in range(120):
        time.sleep(1)
        if is_comfyui_running():
            print(f"ComfyUI ready (took {i+1}s)")
            return proc
    raise RuntimeError("ComfyUI failed to start after 120s")


def queue_prompt(prompt: dict, client_id: str) -> str:
    prompt_id = str(uuid.uuid4())
    p = {"prompt": prompt, "client_id": client_id, "prompt_id": prompt_id}
    data = json.dumps(p).encode("utf-8")
    req = urllib.request.Request(f"http://{SERVER_ADDRESS}/prompt", data=data)
    urllib.request.urlopen(req).read()
    return prompt_id


def get_history(prompt_id: str) -> dict:
    with urllib.request.urlopen(f"http://{SERVER_ADDRESS}/history/{prompt_id}") as r:
        return json.loads(r.read())


def wait_for_completion(ws, prompt_id: str):
    """Monitor websocket for completion, printing progress."""
    while True:
        out = ws.recv()
        if isinstance(out, str):
            msg = json.loads(out)
            msg_type = msg.get("type", "")
            data = msg.get("data", {})

            if msg_type == "progress":
                value = data.get("value", 0)
                max_val = data.get("max", 100)
                node = data.get("node", "?")
                pct = int(value / max_val * 100) if max_val else 0
                print(f"\r  Progress: {pct}% (node {node}, step {value}/{max_val})", end="", flush=True)

            elif msg_type == "executing":
                if data.get("node") is None and data.get("prompt_id") == prompt_id:
                    print("\n  Execution complete!")
                    return
                elif data.get("node"):
                    print(f"\n  Executing node {data['node']}...", end="", flush=True)

            elif msg_type == "execution_error":
                raise RuntimeError(f"ComfyUI execution error: {data}")


def get_output_files(prompt_id: str) -> list[dict]:
    """Get output video/image files from history."""
    history = get_history(prompt_id)
    if prompt_id not in history:
        return []

    outputs = []
    for node_id, node_output in history[prompt_id].get("outputs", {}).items():
        for key in ("gifs", "videos", "images"):
            if key in node_output:
                for item in node_output[key]:
                    outputs.append(item)
    return outputs


# ── Workflow preparation ─────────────────────────────────────────────────────

def load_workflow_api() -> dict:
    """Load the embedded API-format workflow."""
    if not WORKFLOW_PATH.exists():
        raise FileNotFoundError(
            f"Workflow not found: {WORKFLOW_PATH}\n"
            "Run 'python export_workflow.py' to regenerate it."
        )
    with open(WORKFLOW_PATH) as f:
        return json.load(f)


def configure_workflow(
    prompt: dict,
    image_file: str,
    audio_file: str,
    max_frames: int,
    steps: int = 15,
    shift: float = 8.0,
    block_swap: int = 20,
    raag_alpha: float = 0.5,
) -> dict:
    """Inject runtime parameters into the API workflow."""
    ids = NODE_IDS

    # Input image
    if ids["load_image"] in prompt:
        prompt[ids["load_image"]]["inputs"]["image"] = image_file

    # Input audio
    if ids["load_audio"] in prompt:
        prompt[ids["load_audio"]]["inputs"]["audio"] = audio_file

    # Max frames
    if ids["max_frames"] in prompt:
        prompt[ids["max_frames"]]["inputs"]["value"] = max_frames

    # Trim audio (start=0, full duration)
    if ids["trim_audio"] in prompt:
        prompt[ids["trim_audio"]]["inputs"]["start_index"] = 0

    # Scheduler: steps + shift
    if ids["scheduler"] in prompt:
        prompt[ids["scheduler"]]["inputs"]["steps"] = steps
        prompt[ids["scheduler"]]["inputs"]["shift"] = shift

    # Block swap
    if ids["block_swap"] in prompt:
        prompt[ids["block_swap"]]["inputs"]["blocks_to_swap"] = block_swap

    # TCFG + FreSca (experimental_args)
    if ids["experimental_args"] in prompt:
        prompt[ids["experimental_args"]]["inputs"]["raag_alpha"] = raag_alpha

    return prompt


# ── Main pipeline ────────────────────────────────────────────────────────────

def run_pipeline(
    text: str,
    image_path: str,
    output_path: str,
    ref_voice: str | None = None,
    duration: float = 5.0,
    skip_tts: bool = False,
    audio_path: str | None = None,
    steps: int = 15,
    shift: float = 8.0,
    block_swap: int = 20,
    raag_alpha: float = 0.5,
):
    print("=" * 60)
    print("  LongCat Avatar Pipeline")
    print(f"  steps={steps}  shift={shift}  block_swap={block_swap}  raag_alpha={raag_alpha}")
    print("=" * 60)

    # ── Step 1: TTS ──────────────────────────────────────────────────────
    if audio_path and Path(audio_path).exists():
        print(f"\n[1/5] Using provided audio: {audio_path}")
        wav_path = audio_path
    elif skip_tts:
        raise ValueError("--skip-tts requires --audio")
    else:
        print(f"\n[1/5] Generating TTS...")
        from tts import generate_tts
        wav_path = "/tmp/pipeline_tts.wav"
        _, audio_duration = generate_tts(text, wav_path, ref_voice)
        duration = audio_duration
        print(f"  Audio duration: {duration:.1f}s")

    # ── Step 2: Copy inputs to ComfyUI ───────────────────────────────────
    print(f"\n[2/5] Preparing ComfyUI inputs...")
    COMFY_INPUT.mkdir(parents=True, exist_ok=True)

    audio_dest = COMFY_INPUT / "pipeline_audio.wav"
    image_dest = COMFY_INPUT / "pipeline_image.png"

    if not wav_path.endswith(".wav"):
        subprocess.run(
            ["ffmpeg", "-y", "-i", wav_path, "-ar", "16000", "-ac", "1", str(audio_dest)],
            check=True, capture_output=True,
        )
    else:
        shutil.copy2(wav_path, audio_dest)

    shutil.copy2(image_path, image_dest)
    print(f"  Audio: {audio_dest}")
    print(f"  Image: {image_dest}")

    # Calculate frames
    max_frames = int(duration * FPS)
    max_frames = max(max_frames, 25)  # At least 1 second
    print(f"  Max frames: {max_frames} ({max_frames/FPS:.1f}s @ {FPS}fps)")

    # ── Step 3: Start ComfyUI ────────────────────────────────────────────
    print(f"\n[3/5] Connecting to ComfyUI...")
    comfy_proc = None
    if not is_comfyui_running():
        comfy_proc = start_comfyui()
    else:
        print("  ComfyUI already running")

    # ── Step 4: Submit workflow ───────────────────────────────────────────
    print(f"\n[4/5] Submitting workflow...")
    client_id = str(uuid.uuid4())

    prompt = load_workflow_api()
    prompt = configure_workflow(
        prompt,
        "pipeline_image.png",
        "pipeline_audio.wav",
        max_frames,
        steps=steps,
        shift=shift,
        block_swap=block_swap,
        raag_alpha=raag_alpha,
    )

    ws = websocket.WebSocket()
    ws.connect(f"ws://{SERVER_ADDRESS}/ws?clientId={client_id}")

    t0 = time.time()
    prompt_id = queue_prompt(prompt, client_id)
    print(f"  Prompt ID: {prompt_id}")
    print(f"  Waiting for generation...")

    wait_for_completion(ws, prompt_id)
    ws.close()
    gen_time = time.time() - t0
    print(f"  Generation took {gen_time:.0f}s ({gen_time/60:.1f}min)")

    # ── Step 5: Retrieve output + merge audio ────────────────────────────
    print(f"\n[5/5] Retrieving output...")
    outputs = get_output_files(prompt_id)

    video_output = None
    for out in outputs:
        fname = out.get("filename", "")
        if fname.endswith((".mp4", ".webm", ".gif")):
            subfolder = out.get("subfolder", "")
            folder_type = out.get("type", "temp")
            if folder_type == "temp":
                video_output = COMFY_TEMP / subfolder / fname
            elif folder_type == "output":
                video_output = COMFY_OUTPUT / subfolder / fname
            break

    if not video_output or not video_output.exists():
        for search_dir in [COMFY_TEMP, COMFY_OUTPUT]:
            videos = sorted(search_dir.glob("**/*.mp4"), key=lambda p: p.stat().st_mtime, reverse=True)
            if videos:
                video_output = videos[0]
                break

    if not video_output or not video_output.exists():
        raise RuntimeError("No video output found from ComfyUI")

    print(f"  Video: {video_output}")

    # Merge audio with video
    print(f"  Merging audio...")
    output_path = str(output_path)
    subprocess.run(
        [
            "ffmpeg", "-y",
            "-i", str(video_output),
            "-i", str(audio_dest),
            "-c:v", "copy",
            "-c:a", "aac",
            "-b:a", "192k",
            "-shortest",
            output_path,
        ],
        check=True,
        capture_output=True,
    )

    file_size = Path(output_path).stat().st_size / (1024 * 1024)
    print(f"\n{'=' * 60}")
    print(f"  Done! Output: {output_path} ({file_size:.1f} MB)")
    print(f"  Duration: ~{duration:.1f}s | Generation: {gen_time:.0f}s")
    print(f"{'=' * 60}")

    return output_path


def main():
    parser = argparse.ArgumentParser(description="LongCat Avatar Pipeline")
    parser.add_argument("--text", required=True, help="Text to speak")
    parser.add_argument("--image", required=True, help="Character image (PNG)")
    parser.add_argument("--output", default="output.mp4", help="Output video path")
    parser.add_argument("--ref-voice", default=None, help="Reference voice for cloning (~10s wav)")
    parser.add_argument("--duration", type=float, default=5.0, help="Target duration in seconds")
    parser.add_argument("--audio", default=None, help="Pre-generated audio (skip TTS)")
    parser.add_argument("--skip-tts", action="store_true", help="Skip TTS, use --audio instead")

    # Generation tuning parameters
    parser.add_argument("--steps", type=int, default=15, help="Sampling steps (default: 15)")
    parser.add_argument("--shift", type=float, default=8.0, help="Scheduler shift (default: 8.0)")
    parser.add_argument("--block-swap", type=int, default=20, help="Block swap count (default: 20)")
    parser.add_argument("--raag-alpha", type=float, default=0.5, help="TCFG RAAG alpha (default: 0.5)")

    args = parser.parse_args()

    if not Path(args.image).exists():
        print(f"Error: image not found: {args.image}")
        sys.exit(1)

    run_pipeline(
        text=args.text,
        image_path=args.image,
        output_path=args.output,
        ref_voice=args.ref_voice,
        duration=args.duration,
        skip_tts=args.skip_tts,
        audio_path=args.audio,
        steps=args.steps,
        shift=args.shift,
        block_swap=args.block_swap,
        raag_alpha=args.raag_alpha,
    )


if __name__ == "__main__":
    main()
