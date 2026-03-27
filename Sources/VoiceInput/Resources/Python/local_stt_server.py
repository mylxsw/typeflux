#!/usr/bin/env python3
import argparse
import json
import os
import sys
import tempfile
from pathlib import Path


def parse_args():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    def add_shared(p):
        p.add_argument("--model", required=True, choices=["whisperLocal", "senseVoiceSmall", "qwen3ASR"])
        p.add_argument("--model-id", required=True)
        p.add_argument("--source", default="auto", choices=["auto", "modelScope", "huggingFace"])
        p.add_argument("--cache-dir", required=True)

    prepare = subparsers.add_parser("prepare")
    add_shared(prepare)

    serve = subparsers.add_parser("serve")
    add_shared(serve)
    serve.add_argument("--host", default="127.0.0.1")
    serve.add_argument("--port", type=int, default=55123)
    return parser.parse_args()


def _download_from_modelscope(repo_id, target_dir):
    from modelscope import snapshot_download

    return snapshot_download(repo_id, local_dir=str(target_dir))


def _download_from_huggingface(repo_id, target_dir):
    from huggingface_hub import snapshot_download

    snapshot_download(
        repo_id=repo_id,
        local_dir=str(target_dir),
        resume_download=True,
    )
    return str(target_dir)


def _retry_download(download_fn, label, attempts=3):
    last_error = None
    for attempt in range(1, attempts + 1):
        try:
            return download_fn()
        except Exception as exc:
            last_error = exc
            if attempt == attempts:
                raise RuntimeError(f"{label} failed after {attempts} attempts: {exc}") from exc
    raise last_error


def download_snapshot(repo_id, cache_dir, source):
    target_dir = Path(cache_dir) / repo_id.replace("/", "--")
    if target_dir.exists():
        resolved_source = "huggingFace" if (target_dir / ".cache" / "huggingface").exists() else "modelScope"
        return str(target_dir), resolved_source

    target_dir.parent.mkdir(parents=True, exist_ok=True)

    sources = ["modelScope", "huggingFace"] if source == "auto" else [source]
    errors = []

    for current_source in sources:
        try:
            if current_source == "modelScope":
                path = _retry_download(lambda: _download_from_modelscope(repo_id, target_dir), "ModelScope download")
            else:
                path = _retry_download(lambda: _download_from_huggingface(repo_id, target_dir), "Hugging Face download")
            return path, current_source
        except Exception as exc:
            errors.append(str(exc))

    raise RuntimeError(" / ".join(errors))


def prepare_whisper(model_id, cache_dir):
    import whisper

    whisper.load_model(model_id, download_root=cache_dir)
    return {"model_path": str(Path(cache_dir) / f"{model_id}.pt"), "source": "huggingFace"}


def prepare_sensevoice(model_id, cache_dir, source):
    model_path, used_source = download_snapshot(model_id, cache_dir, source)
    return {"model_path": model_path, "source": used_source}


def prepare_qwen(model_id, cache_dir, source):
    model_path, used_source = download_snapshot(model_id, cache_dir, source)
    return {"model_path": model_path, "source": used_source}


def prepare_runtime(model_name, model_id, cache_dir, source):
    if model_name == "whisperLocal":
        return prepare_whisper(model_id, cache_dir)
    if model_name == "senseVoiceSmall":
        return prepare_sensevoice(model_id, cache_dir, source)
    if model_name == "qwen3ASR":
        return prepare_qwen(model_id, cache_dir, source)
    raise ValueError(f"Unsupported model: {model_name}")


def load_runtime(model_name, model_id, cache_dir, source):
    prepared = prepare_runtime(model_name, model_id, cache_dir, source)

    if model_name == "whisperLocal":
        import imageio_ffmpeg
        import whisper

        ffmpeg_exe = imageio_ffmpeg.get_ffmpeg_exe()
        os.environ["PATH"] = f"{Path(ffmpeg_exe).parent}:{os.environ.get('PATH', '')}"

        device = "cpu"
        try:
            import torch

            if torch.backends.mps.is_available():
                device = "mps"
        except Exception:
            pass

        model = whisper.load_model(model_id, download_root=cache_dir, device=device)
        return {"type": model_name, "model": model, "meta": prepared}

    if model_name == "senseVoiceSmall":
        from funasr import AutoModel
        from funasr.utils.postprocess_utils import rich_transcription_postprocess

        device = "cpu"
        try:
            import torch

            if torch.backends.mps.is_available():
                device = "mps"
        except Exception:
            pass

        model = AutoModel(
            model=prepared["model_path"],
            trust_remote_code=True,
            vad_model="fsmn-vad",
            vad_kwargs={"max_single_segment_time": 30_000},
            device=device,
        )
        return {
            "type": model_name,
            "model": model,
            "postprocess": rich_transcription_postprocess,
            "meta": prepared,
        }

    if model_name == "qwen3ASR":
        import torch
        from qwen_asr import Qwen3ASRModel

        dtype = torch.float32
        model = Qwen3ASRModel.from_pretrained(
            prepared["model_path"],
            dtype=dtype,
            device_map="cpu",
            max_new_tokens=256,
        )
        return {"type": model_name, "model": model, "meta": prepared}

    raise ValueError(f"Unsupported model: {model_name}")


def transcribe(runtime, audio_path, prompt=None):
    if runtime["type"] == "whisperLocal":
        transcribe_options = {}
        if prompt:
            transcribe_options["initial_prompt"] = prompt
        result = runtime["model"].transcribe(audio_path, **transcribe_options)
        return result.get("text", "").strip()

    if runtime["type"] == "senseVoiceSmall":
        result = runtime["model"].generate(
            input=audio_path,
            cache={},
            language="auto",
            use_itn=True,
            batch_size_s=0,
        )
        text = result[0].get("text", "") if result else ""
        return runtime["postprocess"](text).strip()

    if runtime["type"] == "qwen3ASR":
        result = runtime["model"].transcribe(audio=audio_path, language=None)
        if not result:
            return ""
        return getattr(result[0], "text", "").strip()

    raise ValueError(f"Unsupported runtime type: {runtime['type']}")


def run_prepare(args):
    payload = prepare_runtime(args.model, args.model_id, args.cache_dir, args.source)
    print(json.dumps({"ready": True, **payload}))


def run_server(args):
    from fastapi import FastAPI, File, Form, HTTPException, UploadFile
    from fastapi.responses import JSONResponse
    import uvicorn

    runtime = load_runtime(args.model, args.model_id, args.cache_dir, args.source)
    app = FastAPI()

    @app.get("/health")
    async def health():
        return {
            "ready": True,
            "provider": args.model,
            "model": args.model_id,
            "source": args.source,
        }

    @app.post("/v1/audio/transcriptions")
    async def create_transcription(
        file: UploadFile = File(...),
        model: str = Form(...),
        provider: str = Form(None),
        prompt: str = Form(None),
    ):
        suffix = Path(file.filename or "audio.wav").suffix or ".wav"
        with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
            tmp.write(await file.read())
            tmp_path = tmp.name

        try:
            text = transcribe(runtime, tmp_path, prompt=prompt)
            return JSONResponse({"text": text, "model": model, "provider": provider or args.model, "prompt": prompt})
        except Exception as exc:
            raise HTTPException(status_code=500, detail=str(exc)) from exc
        finally:
            try:
                os.remove(tmp_path)
            except OSError:
                pass

    uvicorn.run(app, host=args.host, port=args.port, log_level="warning")


def main():
    args = parse_args()
    try:
        if args.command == "prepare":
            run_prepare(args)
        elif args.command == "serve":
            run_server(args)
        else:
            raise ValueError(f"Unsupported command: {args.command}")
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        raise


if __name__ == "__main__":
    main()
