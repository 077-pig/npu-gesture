from __future__ import annotations

"""改进模型定点验证入口。

这个入口复用工程中已有的四个脚本：
量化权重 -> 激活校准 -> 量化偏置 -> 288个测试样本定点验证。

默认不覆盖任何已有目录。v2和v4分别写入独立目录，避免把旧基线
的量化参数、缩放系数和验证报告混在一起。
"""

import argparse
import hashlib
import importlib.util
import json
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
QUANT_SOURCE_DIR = PROJECT_ROOT / "gesture_models" / "stage2_quantized"
MODEL_DIRS = {
    # 当前game目录中保留的V2权重目录
    "v2": PROJECT_ROOT / "gesture_models" / "stage2_cnn_lif_v2_reconstructed",
    "v4": PROJECT_ROOT / "gesture_models" / "stage2_cnn_lif_improved_v4",
}


def load_module(module_name: str, path: Path):
    """按文件路径加载旧脚本，但不触发它的main入口。"""

    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise ImportError(f"无法加载脚本：{path}")

    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


def configure_modules(model_key: str, output_dir: Path, model_file: Path | None = None) -> list[object]:
    """加载并重定向四个已有脚本的输入、输出路径。"""

    model_dir = MODEL_DIRS[model_key]
    model_path = model_file or (model_dir / "cnn_lif_improved_best.pt")
    if not model_path.exists():
        raise FileNotFoundError(f"找不到{model_key}最佳模型：{model_path}")

    source_files = {
        "quantize": QUANT_SOURCE_DIR / "quantize_cnn_lif.py",
        "calibrate": QUANT_SOURCE_DIR / "calibrate_activations.py",
        "bias": QUANT_SOURCE_DIR / "quantize_biases.py",
        "verify": PROJECT_ROOT / "gesture_tools" / "verify_fixed_point.py",
    }
    for path in source_files.values():
        if not path.exists():
            raise FileNotFoundError(f"找不到已有流程脚本：{path}")

    # 先加载校准和量化脚本，分别覆盖它们原来指向基线的路径。
    quantize = load_module(f"quantize_{model_key}", source_files["quantize"])
    calibrate = load_module(f"calibrate_{model_key}", source_files["calibrate"])
    bias = load_module(f"bias_{model_key}", source_files["bias"])
    verify = load_module(f"verify_{model_key}", source_files["verify"])

    # 量化权重脚本
    quantize.FLOAT_MODEL_PATH = model_path
    quantize.OUTPUT_DIR = output_dir
    quantize.OUTPUT_NPZ = output_dir / "cnn_lif_int8_parameters.npz"
    quantize.OUTPUT_JSON = output_dir / "cnn_lif_int8_parameters.json"

    # 激活校准脚本
    calibrate.FLOAT_MODEL_PATH = model_path
    calibrate.OUTPUT_PATH = output_dir / "activation_calibration.json"

    # INT32偏置脚本读取本轮权重和激活报告，并写入本轮目录
    bias.FLOAT_MODEL_PATH = model_path
    bias.WEIGHT_REPORT_PATH = output_dir / "cnn_lif_int8_parameters.json"
    bias.ACTIVATION_REPORT_PATH = output_dir / "activation_calibration.json"
    bias.OUTPUT_DIR = output_dir
    bias.OUTPUT_NPZ = output_dir / "cnn_lif_int32_biases.npz"
    bias.OUTPUT_JSON = output_dir / "cnn_lif_int32_biases.json"

    # 定点验证脚本读取本轮所有参数，输出本轮报告和黄金数据
    verify.FLOAT_MODEL_PATH = model_path
    verify.WEIGHT_REPORT_PATH = output_dir / "cnn_lif_int8_parameters.json"
    verify.WEIGHT_NPZ_PATH = output_dir / "cnn_lif_int8_parameters.npz"
    verify.BIAS_REPORT_PATH = output_dir / "cnn_lif_int32_biases.json"
    verify.BIAS_NPZ_PATH = output_dir / "cnn_lif_int32_biases.npz"
    verify.ACTIVATION_REPORT_PATH = output_dir / "activation_calibration.json"
    verify.OUTPUT_PATH = output_dir / "fixed_point_report.json"
    verify.TRACE_OUTPUT_PATH = output_dir / "golden_trace_sample0.npz"
    verify.TRACE_META_PATH = output_dir / "golden_trace_sample0.json"

    return [quantize, calibrate, bias, verify]


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="验证改进CNN+LIF模型的电脑定点准确率"
    )
    parser.add_argument(
        "--model",
        choices=sorted(MODEL_DIRS),
        required=True,
        help="选择要验证的改进模型：v2或v4",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=None,
        help="可选的独立输出目录；默认按模型自动命名",
    )
    parser.add_argument(
        "--model-file",
        type=Path,
        help="可选的新训练权重PT；不替换原V2模型，须同时指定新的--output-dir",
    )
    parser.add_argument("--cache", type=Path, help="可选的事件帧NPZ路径")
    parser.add_argument("--metadata", type=Path, help="可选的事件帧元数据JSON路径")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="只检查文件和路径，不进行量化、校准或评估，不写输出",
    )
    return parser.parse_args()


def main() -> None:
    arguments = parse_arguments()
    if arguments.model_file is not None:
        arguments.model_file = arguments.model_file.resolve()
        if arguments.output_dir is None:
            raise ValueError("使用--model-file时必须指定新的--output-dir，避免混入原V2量化结果")
    output_dir = arguments.output_dir
    if output_dir is None:
        output_dir = PROJECT_ROOT / "gesture_models" / (
            f"stage2_quantized_improved_{arguments.model}"
        )
    elif not output_dir.is_absolute():
        output_dir = PROJECT_ROOT / output_dir

    output_dir = output_dir.resolve()
    if arguments.model_file is not None and (
        output_dir == arguments.model_file.parent or arguments.model_file.parent in output_dir.parents
    ):
        raise ValueError("量化输出不能放进输入权重目录")
    protected_dirs = [QUANT_SOURCE_DIR, *MODEL_DIRS.values(),
                      PROJECT_ROOT / "gesture_models" / "stage2_cnn_lif",
                      PROJECT_ROOT / "data", PROJECT_ROOT / "gesture_tools",
                      PROJECT_ROOT / "gesture_generated", PROJECT_ROOT / "vivado",
                      PROJECT_ROOT / "G_RTL"]
    for protected in protected_dirs:
        protected = protected.resolve()
        if output_dir == protected or protected in output_dir.parents:
            raise ValueError(f"不能向原模型、源码或工程数据目录写入量化输出：{output_dir}")
    if output_dir.exists() and not output_dir.is_dir():
        raise ValueError(f"输出路径不是目录：{output_dir}")
    if output_dir.exists() and any(output_dir.iterdir()):
        raise FileExistsError(
            f"输出目录已有文件，为保护实验记录拒绝覆盖：{output_dir}\n"
            "如需重新生成，请换一个目录。"
        )

    scripts = configure_modules(arguments.model, output_dir, arguments.model_file)
    quantize, calibrate, bias, verify = scripts
    for module in (calibrate, verify):
        if arguments.cache is not None:
            module.CACHE_PATH = arguments.cache.resolve()
        if arguments.metadata is not None:
            module.METADATA_PATH = arguments.metadata.resolve()

    for path in (calibrate.CACHE_PATH, calibrate.METADATA_PATH):
        if not path.exists():
            raise FileNotFoundError(f"缺少数据文件：{path}")

    print(f"模型：{arguments.model}")
    print(f"浮点模型：{quantize.FLOAT_MODEL_PATH}")
    print(f"定点输出目录：{output_dir}")
    print("说明：复用旧流程的电脑定点仿真，尚不是RTL逐位一致或板端结果")
    if arguments.dry_run:
        print("DRY_RUN_PASS：路径检查通过；没有量化、校准、评估或写入结果")
        return
    print("第1/4步：量化INT8权重")
    quantize.main()
    print("第2/4步：校准激活范围")
    calibrate.main()
    print("第3/4步：量化INT32偏置")
    bias.main()
    print("第4/4步：评估288个测试样本")
    verify.main()
    report = json.loads(verify.OUTPUT_PATH.read_text(encoding="utf-8"))
    report["model_version"] = arguments.model
    report["source_model"] = str(verify.FLOAT_MODEL_PATH)
    report["source_model_sha256"] = hashlib.sha256(
        verify.FLOAT_MODEL_PATH.read_bytes()
    ).hexdigest()
    report["evaluation_method"] = "legacy_fixed_point_simulation"
    report["rtl_bit_exact_verified"] = False
    report["board_verified"] = False
    report["float_correct"] = sum(
        r["float_prediction"] == r["label"] for r in report["records"]
    )
    report["fixed_correct"] = sum(
        r["fixed_prediction"] == r["label"] for r in report["records"]
    )
    verify.OUTPUT_PATH.write_text(
        json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8"
    )
    print("定点验证流程完成")
    print(f"浮点准确率：{report['float_accuracy']:.2%}")
    print(f"定点准确率：{report['fixed_accuracy']:.2%}")
    print(f"预测不一致数：{report['prediction_mismatch_count']}")
    print(f"报告：{output_dir / 'fixed_point_report.json'}")


if __name__ == "__main__":
    main()
