"""Reproduce one non-fixed FP16 shape path without changing the fixed exports."""

import argparse
import hashlib
import importlib.metadata
import json
import platform
import signal
import subprocess
import sys
import tempfile
import time
from datetime import UTC, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def predict(weights: Path, length: int, shape: str, output: Path) -> None:
    sys.path.insert(0, str(ROOT))
    import export

    export.patch_deberta()
    print("converting", flush=True)
    model = export.convert(weights, length, shape)
    model.save(str(output / "probe.mlpackage"))
    print("converted; loading CPU_ONLY", flush=True)
    model = export.ct.models.MLModel(
        str(output / "probe.mlpackage"), compute_units=export.ct.ComputeUnit.CPU_ONLY
    )
    for count in (length // 2, length):
        print(f"predicting [1, {count}]", flush=True)
        inputs = export.np.ones((1, count), dtype=export.np.int32)
        logits = model.predict({"input_ids": inputs, "attention_mask": inputs})["logits"]
        if not export.np.isfinite(logits).all():
            raise RuntimeError(f"non-finite logits at length {count}")
        print(json.dumps({"length": count, "finite": True}), flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run", help="a run name from custom/bundle-v1.json")
    parser.add_argument("weights", type=Path)
    parser.add_argument("--shape", choices=("enumerated", "flexible"), required=True)
    parser.add_argument("--timeout", type=int, default=300, help="worker timeout in seconds")
    parser.add_argument("--worker-output", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    bundle = json.loads(
        (ROOT.parent / "system-category-benchmark/custom/bundle-v1.json").read_text()
    )
    entries = [entry for mode in ("system", "custom") for entry in bundle[mode]]
    entry = next((entry for entry in entries if entry["run"] == args.run), None)
    if entry is None or args.timeout <= 0:
        parser.error("choose a frozen run and a positive timeout")
    if args.worker_output is not None:
        predict(args.weights, entry["max_length"], args.shape, args.worker_output)
        return
    with (args.weights / "model.safetensors").open("rb") as file:
        digest = hashlib.file_digest(file, "sha256").hexdigest()
    if digest != entry["weights_sha256"]:
        parser.error("weights SHA-256 differs from the frozen bundle")
    (ROOT / "work").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="shape-", dir=ROOT / "work") as temporary:
        command = [
            sys.executable,
            str(Path(__file__).resolve()),
            args.run,
            str(args.weights.resolve()),
            "--shape",
            args.shape,
            "--worker-output",
            temporary,
        ]
        started = time.perf_counter()
        timed_out = False
        try:
            process = subprocess.run(
                command, check=False, capture_output=True, timeout=args.timeout
            )
            code, stdout, stderr = process.returncode, process.stdout, process.stderr
        except subprocess.TimeoutExpired as error:
            timed_out = True
            code, stdout, stderr = None, error.stdout or b"", error.stderr or b""
        report = {
            "recorded_at": datetime.now(UTC).isoformat(),
            "run": args.run,
            "shape": args.shape,
            "prediction_lengths": [entry["max_length"] // 2, entry["max_length"]],
            "compute_units": "CPU_ONLY",
            "weights_sha256": digest,
            "host": platform.platform(),
            "python": platform.python_version(),
            "versions": {
                package: importlib.metadata.version(package)
                for package in ("coremltools", "torch", "transformers", "numpy")
            },
            "command": [sys.executable, *sys.argv],
            "worker_command": command,
            "timeout_seconds": args.timeout,
            "elapsed_seconds": round(time.perf_counter() - started, 1),
            "timed_out": timed_out,
            "exit_code": code,
            "signal": signal.Signals(-code).name if code is not None and code < 0 else None,
            "stdout": stdout.decode(errors="replace"),
            "stderr_tail": stderr.decode(errors="replace")[-12000:],
        }
    result = ROOT / "results" / f"shape-{args.run}-{args.shape}.json"
    result.parent.mkdir(exist_ok=True)
    result.write_text(json.dumps(report, indent=2) + "\n")
    print(result)
    print(f"exit={code}, signal={report['signal']}, timed_out={timed_out}")
    if timed_out or code != 0:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
