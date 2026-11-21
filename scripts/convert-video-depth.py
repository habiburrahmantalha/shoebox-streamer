"""Build-only conversion. The installed app uses Core ML and needs no Python."""
import gc
import json
import pathlib
import shutil
import subprocess
import sys
import types

import coremltools as ct
import numpy as np
import torch

root = pathlib.Path(__file__).resolve().parents[1]
cache = root / ".macos-cache"
sys.path.insert(0, str(cache / "video-depth-anything"))
from video_depth_anything.video_depth import VideoDepthAnything

torch.set_num_threads(4)
model = VideoDepthAnything(encoder="vits", features=64, out_channels=[48, 96, 192, 384]).eval()
model.load_state_dict(torch.load(cache / "video_depth_anything_vits.pth", map_location="cpu", weights_only=True), strict=True)
sample = torch.zeros(1, 32, 3, 392, 700)
# Fixed-resolution positional interpolation is constant. Bake the exact original
# bicubic result, rather than approximating an unsupported Core ML operation.
with torch.no_grad():
    position = model.pretrained.interpolate_pos_encoding(torch.zeros(1, 28 * 50 + 1, 384), 392, 700).detach()
model.pretrained.register_buffer("shoebox_position", position)
model.pretrained.interpolate_pos_encoding = types.MethodType(lambda self, x, w, h: self.shoebox_position, model.pretrained)
print("Tracing Video Depth Anything Small, 32-frame windows, 700×392…", flush=True)
with torch.inference_mode():
    traced = torch.jit.trace(model, sample, check_trace=False)
converted = ct.convert(traced, convert_to="mlprogram",
    inputs=[ct.TensorType(name="frames", shape=sample.shape, dtype=np.float32)],
    outputs=[ct.TensorType(name="depth", dtype=np.float32)], compute_precision=ct.precision.FLOAT16,
    minimum_deployment_target=ct.target.macOS13, skip_model_load=True)
converted.author = "ByteDance; Shoebox Core ML conversion"
converted.license = "Apache-2.0"
converted.short_description = "Video Depth Anything Small: 32-frame temporal windows, 700×392, raw relative inverse depth."
temporary = cache / "VideoDepthAnythingSmall32-building.mlpackage"
shutil.rmtree(temporary, ignore_errors=True)
converted.save(str(temporary))
compiled_root = cache / "video-depth-verification"
compiled_root.mkdir(exist_ok=True)
subprocess.run(["/usr/bin/xcrun", "coremlcompiler", "compile", str(temporary), str(compiled_root)], check=True)

# Check an actual image sequence against the original PyTorch network before shipping.
y, x = np.mgrid[0:392, 0:700]
image = np.stack([x / 699, y / 391, np.full_like(x, .4, dtype=np.float32)]).astype(np.float32)
image = (image - np.array([.485, .456, .406], np.float32)[:, None, None]) / np.array([.229, .224, .225], np.float32)[:, None, None]
frames = np.tile(image, (1, 32, 1, 1, 1))
with torch.inference_mode():
    reference = model(torch.from_numpy(frames)).numpy()
del traced, model, converted
gc.collect()
native = ct.models.CompiledMLModel(str(compiled_root / "VideoDepthAnythingSmall32-building.mlmodelc"), compute_units=ct.ComputeUnit.CPU_AND_GPU)
actual = native.predict({"frames": frames})["depth"]
relative_error = float(np.mean(np.abs(actual - reference)) / max(np.mean(np.abs(reference)), 1e-6))
if not np.isfinite(actual).all() or relative_error > .02:
    raise RuntimeError(f"Core ML conversion validation failed: relative error {relative_error}")
package = cache / "VideoDepthAnythingSmall32.mlpackage"
shutil.rmtree(package, ignore_errors=True)
temporary.rename(package)
(cache / "video-depth-export.json").write_text(json.dumps({
    "model": "vda-small-32-700x392-25687536-v1", "relative_error": relative_error,
    "source": "4f5ae23172ba60fd7bc11ef671cca678842c7072",
    "checkpoint_sha256": "13379300b739e659f076a59d52e9801bd8d38c541a7e71f73bbca4dcfb013609",
}))
print(f"Validated native video-depth export: relative error {relative_error:.6f}", flush=True)
