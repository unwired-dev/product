"""Export the frozen #829 candidates to Core ML and check them against the golden outputs."""

import argparse
import hashlib
import inspect
import json
import re
import shutil
import textwrap
import time
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
import transformers.models.deberta_v2.modeling_deberta_v2 as dv2
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.frontend.torch.ops import _get_inputs
from coremltools.converters.mil.frontend.torch.torch_op_registry import register_torch_op
from coremltools.converters.mil.mil import types
from coremltools.optimize.coreml import (
    OpLinearQuantizerConfig,
    OptimizationConfig,
    linear_quantize_weights,
)
from transformers import AutoModelForSequenceClassification

ROOT = Path(__file__).parent
BENCHMARK = ROOT.parent / "system-category-benchmark"
BUNDLE = json.loads((BENCHMARK / "custom" / "bundle-v1.json").read_text())
GOLDEN = json.loads((BENCHMARK / "custom" / "golden-v1.json").read_text())
LANGUAGES = {m["id"]: m["language"] for m in GOLDEN["messages"]}
SYSTEM_CATEGORIES = ["Orders", "Newsletters & Promotions", "Invites", "Flights", "People"]
MODELS = ROOT / "work" / "models"
RESULTS = ROOT / "results"
UNITS = ("CPU_ONLY", "CPU_AND_GPU", "CPU_AND_NE", "ALL")
# Largest absolute probability difference from the fp32 golden outputs that each export may show.
TOLERANCE = {"fp16": 0.02, "int8": 0.05}


# The tracer keeps DeBERTa's attention scale sqrt(int head size) as int32, which MIL sqrt rejects.
@register_torch_op(override=True)
def sqrt(context, node):
    x = _get_inputs(context, node, expected=1)[0]
    if x.dtype not in (types.fp16, types.fp32):
        x = mb.cast(x=x, dtype="fp32")
    context.add(mb.sqrt(x=x, name=node.name))


def patch_deberta() -> None:
    """Make the Hugging Face DeBERTa v2 graph traceable and finite in fp16."""
    source = inspect.getsource(dv2)
    # TorchScript helpers keep shape control flow that Core ML cannot type; trace their Python.
    for name in (
        "make_log_bucket_position",
        "c2p_dynamic_expand",
        "p2c_dynamic_expand",
        "pos_dynamic_expand",
        "scaled_size_sqrt",
        "build_rpos",
    ):
        found = re.search(
            rf"@torch\.jit\.script\n(def {name}\(.*?)(?=\n\n\n|\n@)", source, re.DOTALL
        )
        if not found:
            raise RuntimeError(f"transformers changed {name}; revisit the export patches")
        exec(found.group(1), dv2.__dict__)  # noqa: S102 -- re-defines library source, unscripted
    # fp32's minimum becomes -inf in fp16, so fully masked padding rows turn NaN and spread
    # through later layers; -1e4 stays finite and still gives masked keys zero probability.
    forward = textwrap.dedent(inspect.getsource(dv2.DisentangledSelfAttention.forward))
    if "torch.finfo(query_layer.dtype).min" not in forward:
        raise RuntimeError("transformers changed the attention mask fill; revisit the patch")
    scope: dict = {}
    patched = forward.replace("torch.finfo(query_layer.dtype).min", "-1e4")
    exec(patched, dv2.__dict__, scope)  # noqa: S102 -- re-defines library source with the fill
    dv2.DisentangledSelfAttention.forward = scope["forward"]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def size(path: Path) -> int:
    return sum(f.stat().st_size for f in path.rglob("*") if f.is_file())


def candidate(run: str) -> tuple[str, dict]:
    for mode in ("system", "custom"):
        for entry in BUNDLE[mode]:
            if entry["run"] == run:
                return mode, entry
    raise SystemExit(f"{run} is not in the frozen bundle")


class Logits(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, input_ids, attention_mask):
        return self.model(input_ids=input_ids, attention_mask=attention_mask).logits


def convert(weights: Path, length: int, shape_kind: str = "fixed") -> ct.models.MLModel:
    model = AutoModelForSequenceClassification.from_pretrained(
        weights, dtype=torch.float32, attn_implementation="eager"
    ).eval()
    example = torch.ones(1, length, dtype=torch.long)
    traced = torch.jit.trace(Logits(model).eval(), (example, example), strict=False)
    shape = (1, length)
    if shape_kind == "enumerated":
        shape = ct.EnumeratedShapes([(1, length // 2), (1, length)], default=(1, length))
    elif shape_kind == "flexible":
        shape = (1, ct.RangeDim(lower_bound=1, upper_bound=length, default=length))
    elif shape_kind != "fixed":
        raise ValueError(f"unsupported shape kind: {shape_kind}")
    return ct.convert(
        traced,
        inputs=[
            ct.TensorType("input_ids", shape=shape, dtype=np.int32),
            ct.TensorType("attention_mask", shape=shape, dtype=np.int32),
        ],
        outputs=[ct.TensorType("logits")],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS15,
    )


def quantization(model: ct.models.MLModel) -> dict:
    """Which constant weights the INT8 export stores quantized, by element count."""
    program = model._mil_program
    quantized, dense = {}, {}
    for op in program.functions["main"].operations:
        if op.op_type.startswith("constexpr_"):
            quantized[op.outputs[0].name] = int(np.prod(op.outputs[0].shape))
        elif op.op_type == "const" and op.outputs[0].val is not None:
            value = op.outputs[0].val
            # Quantized data and scales are consts too; count only weights used directly.
            direct = not all(c.op_type.startswith("constexpr_") for c in op.outputs[0].child_ops)
            if isinstance(value, np.ndarray) and value.size >= 2048 and direct:
                dense[op.outputs[0].name] = int(value.size)
    return {
        "quantized_tensors": len(quantized),
        "quantized_elements": sum(quantized.values()),
        "dense_tensors": sorted(dense),
        "dense_elements": sum(dense.values()),
        "word_embeddings_quantized": any("word_embeddings" in name for name in quantized),
    }


def golden_inputs(mode: str, entry: dict):
    run = next(r for r in GOLDEN[mode] if r["run"] == entry["run"])
    return run["outputs"]


def probabilities(mode: str, logits: np.ndarray, labels: dict) -> np.ndarray:
    logits = logits.astype(np.float64)
    if mode == "system":
        return 1 / (1 + np.exp(-logits))
    pair = logits[[labels["entailment"], labels["negative"]]]
    pair = np.exp(pair - pair.max())
    return np.array([pair[0] / pair.sum()])


def parity(mode: str, entry: dict, package: Path, labels: dict, unit: str) -> dict:
    model = ct.models.MLModel(str(package), compute_units=getattr(ct.ComputeUnit, unit))
    length = entry["max_length"]
    worst, changed, seconds = 0.0, [], []
    for output in golden_inputs(mode, entry):
        ids = np.zeros((1, length), np.int32)
        mask = np.zeros((1, length), np.int32)
        count = len(output["input_ids"])
        ids[0, :count] = output["input_ids"]
        mask[0, :count] = 1
        start = time.perf_counter()
        logits = model.predict({"input_ids": ids, "attention_mask": mask})["logits"][0]
        seconds.append(time.perf_counter() - start)
        got = probabilities(mode, logits, labels)
        if mode == "system":
            expected = np.array([output["probabilities"][c] for c in SYSTEM_CATEGORIES])
            thresholds = np.array([entry["thresholds"][c] for c in SYSTEM_CATEGORIES])
            decided = got >= thresholds
            decided[4] &= not decided[:4].any()
            categories = [c for c, d in zip(SYSTEM_CATEGORIES, decided) if d]
            if categories != output["categories"]:
                changed.append({"message": output["message"], "categories": categories})
        else:
            expected = np.array([output["entailment_probability"]])
            member = bool(got[0] >= entry["thresholds"][LANGUAGES[output["message"]]])
            if member != output["member"]:
                changed.append(
                    {"message": output["message"], "category": output["category"], "member": member}
                )
        if not np.isfinite(got).all():
            raise SystemExit(f"{package.name} on {unit} returned non-finite scores")
        worst = max(worst, float(np.abs(got - expected).max()))
    return {
        "max_abs_probability_difference": round(worst, 6),
        "decision_changes": changed,
        "python_predict_ms_median": round(1000 * float(np.median(seconds)), 1),
    }


def export(run: str, weights: Path) -> None:
    mode, entry = candidate(run)
    found = sha256_file(weights / "model.safetensors")
    if found != entry["weights_sha256"]:
        raise SystemExit(f"{run}: weights {found} differ from the frozen bundle")
    config = json.loads((weights / "config.json").read_text())
    labels = {
        "entailment": int(config["label2id"].get(entry.get("entailment_label"), -1)),
        "negative": int(config["label2id"].get(entry.get("negative_label"), -1)),
    }
    output = MODELS / run
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    patch_deberta()
    start = time.perf_counter()
    fp16 = convert(weights, entry["max_length"])
    convert_seconds = time.perf_counter() - start
    int8 = linear_quantize_weights(
        fp16,
        OptimizationConfig(
            global_config=OpLinearQuantizerConfig(
                mode="linear_symmetric", dtype="int8", granularity="per_channel"
            )
        ),
    )
    shutil.copy(weights / "tokenizer.json", output / "tokenizer.json")
    report = {
        "run": run,
        "mode": mode,
        "weights_sha256": found,
        "tolerance": TOLERANCE,
        "convert_seconds": round(convert_seconds, 1),
        "exports": {},
    }
    for precision, model in (("fp16", fp16), ("int8", int8)):
        package = output / f"{precision}.mlpackage"
        model.save(str(package))
        compiled = Path(ct.utils.compile_model(str(package), str(output / f"{precision}.mlmodelc")))
        archive = shutil.make_archive(str(output / precision), "zip", output, compiled.name)
        report["exports"][precision] = {
            "package_bytes": size(package),
            "compiled_bytes": size(compiled),
            "zipped_compiled_bytes": Path(archive).stat().st_size,
            "quantization": quantization(model) if precision == "int8" else None,
            "parity": {unit: parity(mode, entry, package, labels, unit) for unit in UNITS},
        }
        Path(archive).unlink()
        shutil.rmtree(package)
    manifest = {
        "run": run,
        "mode": mode,
        "max_length": entry["max_length"],
        "thresholds": entry["thresholds"],
        "labels": SYSTEM_CATEGORIES if mode == "system" else labels,
        "hypothesis": entry.get("hypothesis"),
        "description": entry.get("description"),
        "weights_sha256": found,
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    RESULTS.mkdir(exist_ok=True)
    (RESULTS / f"{run}.json").write_text(json.dumps(report, indent=2) + "\n")
    failures = [
        f"{precision} {unit}"
        for precision, result in report["exports"].items()
        for unit, check in result["parity"].items()
        if check["max_abs_probability_difference"] > TOLERANCE[precision]
    ]
    print(json.dumps(report, indent=2))
    if failures:
        raise SystemExit(f"{run}: outside tolerance on {', '.join(failures)}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run", help="a run name from custom/bundle-v1.json")
    parser.add_argument("weights", type=Path, help="directory holding that run's weights")
    arguments = parser.parse_args()
    export(arguments.run, arguments.weights)
