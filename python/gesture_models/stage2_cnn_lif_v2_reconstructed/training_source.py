from __future__ import annotations

"""Reconstructed V2 training entry, not a recovered historical source file.

The saved V2 report supplies the architecture, split and hyperparameters.
Optimizer/selection/augmentation implementation follows the retained training
code. This does not promise identical historical weights or board accuracy.
No EMA, auxiliary current loss, pretrained initialization or test-based selection.
"""

import argparse
import hashlib
import json
import os
import platform
import random
from pathlib import Path

import numpy as np
import torch
from torch import nn
from torch.utils.data import DataLoader, Dataset


PROJECT_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_DATA = Path(__file__).resolve().parents[4] / "data" / "DVS128Gesture"
DEFAULT_OUTPUT = PROJECT_ROOT / "gesture_models" / "stage2_cnn_lif_v2_reconstructed"
REFERENCE_REPORT = PROJECT_ROOT / "gesture_models" / "stage2_cnn_lif_improved_v2" / "cnn_lif_improved_report.json"
CONFIG = {
    "seed": 706, "batch_size": 8, "max_epochs": 200,
    "learning_rate": 0.001, "weight_decay": 0.0001,
    "label_smoothing": 0.0, "dropout": 0.0,
    "gradient_clip_norm": None, "use_scheduler": False,
    "early_stopping_patience": 200,
    "leak": 0.5, "threshold": 0.5,
    "translation_pixels": 2, "translation_probability": 0.5,
    "time_shift_bins": 1, "time_shift_probability": 0.0,
    "event_dropout_probability": 0.0,
    "count_scale_min": 1.0, "count_scale_max": 1.0,
}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def set_seed(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(seed)
    torch.backends.cudnn.benchmark = False
    torch.backends.cudnn.deterministic = True
    # Retained training code uses these cuDNN flags, not a new strict algorithm
    # policy. Reproducibility across devices/PyTorch versions is not guaranteed.


class SurrogateSpike(torch.autograd.Function):
    @staticmethod
    def forward(ctx, value):
        ctx.save_for_backward(value)
        return (value >= 0).to(value.dtype)

    @staticmethod
    def backward(ctx, gradient):
        (value,) = ctx.saved_tensors
        surrogate_gradient = 1.0 / (1.0 + value.abs()).pow(2)
        return gradient * surrogate_gradient


class CNNLIF(nn.Module):
    """Same eight state_dict keys and forward recurrence as the saved V2."""

    def __init__(self, class_count=11, leak=0.5, threshold=0.5):
        super().__init__()
        self.conv1 = nn.Conv2d(2, 16, 3, stride=2, padding=1, bias=True)
        self.conv2 = nn.Conv2d(16, 32, 3, stride=2, padding=1, bias=True)
        self.conv3 = nn.Conv2d(32, 64, 3, stride=2, padding=1, bias=True)
        self.classifier = nn.Linear(64, class_count, bias=True)
        self.class_count, self.leak, self.threshold = class_count, leak, threshold

    def encode_one_frame(self, frame):
        frame = torch.relu(self.conv1(frame))
        frame = torch.relu(self.conv2(frame))
        frame = torch.relu(self.conv3(frame))
        return frame.mean(dim=(2, 3))

    def forward(self, sequence):
        if sequence.ndim != 5 or tuple(sequence.shape[1:]) != (16, 2, 64, 64):
            raise ValueError(f"输入必须是[B,16,2,64,64]，实际为{tuple(sequence.shape)}")
        membrane = sequence.new_zeros((len(sequence), self.class_count))
        counts = torch.zeros_like(membrane)
        for time_index in range(16):
            current = self.classifier(self.encode_one_frame(sequence[:, time_index]))
            membrane = self.leak * membrane + current
            spike = SurrogateSpike.apply(membrane - self.threshold)
            membrane = membrane - spike * self.threshold
            counts = counts + spike
        return counts


def translate_zero_fill(sample, shift_y, shift_x):
    result = np.zeros_like(sample)
    height, width = sample.shape[1:3]
    sy0, sy1 = max(0, -shift_y), height - max(0, shift_y)
    sx0, sx1 = max(0, -shift_x), width - max(0, shift_x)
    ty0, ty1 = max(0, shift_y), height - max(0, -shift_y)
    tx0, tx1 = max(0, shift_x), width - max(0, -shift_x)
    result[:, ty0:ty1, tx0:tx1, :] = sample[:, sy0:sy1, sx0:sx1, :]
    return result


class GestureDataset(Dataset):
    def __init__(self, frames, labels, indices, augment=False, seed=707):
        self.frames, self.labels, self.indices = frames, labels, indices
        self.augment = augment
        self.rng = np.random.default_rng(seed)

    def __len__(self):
        return len(self.indices)

    def __getitem__(self, position):
        index = int(self.indices[position])
        sample = self.frames[index]
        if self.augment:
            sample = sample.copy()
            if self.rng.random() < CONFIG["translation_probability"]:
                limit = CONFIG["translation_pixels"]
                dy = int(self.rng.integers(-limit, limit + 1))
                dx = int(self.rng.integers(-limit, limit + 1))
                sample = translate_zero_fill(sample, dy, dx)
            # Preserve the retained augmentation implementation's RNG calls for
            # disabled time-shift and unity scaling; do not silently reorder RNG.
            self.rng.random()
            scale = float(self.rng.uniform(1.0, 1.0))
            sample = sample.astype(np.float32) * scale
        sample = np.minimum(sample, 127).astype(np.float32) / 127.0
        sample = np.ascontiguousarray(sample.transpose(0, 3, 1, 2))
        return torch.from_numpy(sample), int(self.labels[index]), index


def load_data(cache_path, metadata_path):
    for path in (cache_path, metadata_path):
        if not path.is_file():
            raise FileNotFoundError(f"缺少数据文件：{path}；请先生成缓存或指定--cache/--metadata")
    with np.load(cache_path, allow_pickle=False) as data:
        frames, labels, flags = (data[key] for key in ("frames", "labels", "splits"))
    metadata = json.loads(metadata_path.read_text(encoding="utf-8-sig"))
    if frames.shape != (1464, 16, 64, 64, 2) or frames.dtype != np.uint16:
        raise ValueError("frames必须为uint16，形状为[1464,16,64,64,2]")
    if labels.shape != (1464,) or flags.shape != (1464,) or len(metadata) != 1464:
        raise ValueError("标签、划分或元数据数量错误")
    if not np.issubdtype(labels.dtype, np.integer) or np.any((labels < 0) | (labels > 10)):
        raise ValueError("标签必须是0到10之间的整数")
    groups = [[], [], []]
    for index, item in enumerate(metadata):
        user = Path(item["trial"]).stem.split("_")[0]
        if not user.startswith("user") or not user[4:].isdigit():
            raise ValueError(f"非法受试者名称：{user}")
        subject = int(user[4:])
        if not 1 <= subject <= 29:
            raise ValueError(f"非法受试者编号：{subject}")
        group = 0 if subject <= 19 else (1 if subject <= 23 else 2)
        if flags[index] != int(group == 2):
            raise ValueError(f"样本{index}的受试者与官方划分不一致")
        if item["sample_index"] != index or item["label"] != int(labels[index]):
            raise ValueError(f"样本{index}的元数据编号或标签与缓存不一致")
        groups[group].append(index)
    if tuple(map(len, groups)) != (984, 192, 288):
        raise ValueError(f"训练/验证/测试数量错误：{tuple(map(len, groups))}")
    return frames, labels, metadata, groups


def loss_function(outputs, labels):
    # Same explicit log-softmax loss as retained V2-derived code, smoothing=0.
    log_prob = torch.log_softmax(outputs, dim=1)
    negative_log_likelihood = -log_prob.gather(1, labels.unsqueeze(1)).squeeze(1)
    smooth_loss = -log_prob.mean(dim=1)
    return (negative_log_likelihood + 0.0 * smooth_loss).mean()


def run_epoch(model, loader, device, optimizer=None):
    model.train(optimizer is not None)
    total_loss, count, correct = 0.0, 0, 0
    result = {"labels": [], "predictions": [], "sample_indices": []}
    with torch.set_grad_enabled(optimizer is not None):
        for inputs, labels, indices in loader:
            inputs, labels = inputs.to(device), labels.to(device)
            if optimizer is not None:
                optimizer.zero_grad()
            outputs = model(inputs)
            loss = loss_function(outputs, labels)
            if not torch.isfinite(loss):
                raise FloatingPointError("损失不是有限值，停止训练")
            if optimizer is not None:
                loss.backward()
                for parameter in model.parameters():
                    if parameter.grad is not None and not torch.isfinite(parameter.grad).all():
                        raise FloatingPointError("梯度不是有限值，停止训练")
                optimizer.step()
            predictions = outputs.detach().argmax(dim=1)
            count += len(labels)
            correct += int((predictions == labels).sum().item())
            total_loss += loss.detach().item() * len(labels)
            result["labels"].extend(labels.cpu().tolist())
            result["predictions"].extend(predictions.cpu().tolist())
            result["sample_indices"].extend(indices.tolist())
    if count == 0:
        raise ValueError("数据集不能为空")
    return dict(result, loss=total_loss / count, accuracy=correct / count, correct=correct)


def check_output_dir(output):
    output = output.resolve()
    protected = [PROJECT_ROOT, PROJECT_ROOT / "gesture_tools", PROJECT_ROOT / "data",
                 PROJECT_ROOT / "gesture_models" / "stage2_cnn_lif_improved_v2"]
    for path in protected:
        if output == path or (path != PROJECT_ROOT and path in output.parents):
            raise ValueError(f"不能写入源码、数据或原V2模型目录：{output}")
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        raise FileExistsError(f"输出目录已存在且非空，不会覆盖：{output}；请换一个--output-dir")


def write_json(path, data):
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")


def fit(model, train_loader, validation_loader, test_loader, output, config, provenance, device,
        evaluate_test=False):
    check_output_dir(output)
    output.mkdir(parents=True, exist_ok=True)
    source = Path(__file__)
    (output / "training_source.py").write_text(source.read_text(encoding="utf-8"), encoding="utf-8")
    write_json(output / "training_config.json", config)
    write_json(output / "run_environment.json", provenance)
    optimizer = torch.optim.AdamW(model.parameters(), lr=config["learning_rate"],
                                  weight_decay=config["weight_decay"])
    best_accuracy, best_loss, best_epoch = -1.0, float("inf"), 0
    history = []
    for epoch in range(1, config["max_epochs"] + 1):
        train = run_epoch(model, train_loader, device, optimizer)
        validation = run_epoch(model, validation_loader, device)
        row = {"epoch": epoch, "learning_rate": optimizer.param_groups[0]["lr"],
               "train_loss": train["loss"], "train_accuracy": train["accuracy"],
               "validation_loss": validation["loss"], "validation_accuracy": validation["accuracy"]}
        history.append(row)
        with (output / "training_history.jsonl").open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(row) + "\n")
        print(f"epoch={epoch}/{config['max_epochs']} train={train['accuracy']:.4f} "
              f"validation={validation['accuracy']:.4f} loss={validation['loss']:.6f}", flush=True)
        if (validation["accuracy"], -validation["loss"]) > (best_accuracy, -best_loss):
            best_accuracy, best_loss, best_epoch = validation["accuracy"], validation["loss"], epoch
            torch.save({"model_state_dict": {k: v.detach().cpu() for k, v in model.state_dict().items()},
                        "epoch": epoch, "validation_accuracy": best_accuracy,
                        "validation_loss": best_loss, "config": config,
                        "source_reconstructed": True, "fpga_parameter_structure_compatible": True},
                       output / "cnn_lif_improved_best.pt")
        if epoch - best_epoch >= config["early_stopping_patience"]:
            break
    checkpoint = torch.load(output / "cnn_lif_improved_best.pt", map_location=device, weights_only=True)
    model.load_state_dict(checkpoint["model_state_dict"], strict=True)
    report = {"model": "cnn_lif_v2_reconstructed", "source_reconstructed": True,
              "config": config, "provenance": provenance,
              "inference_architecture_changed": False, "fpga_parameter_structure_compatible": True,
              "train_subjects": "user01-user19", "validation_subjects": "user20-user23",
              "test_subjects": "user24-user29",
              "train_count": len(train_loader.dataset), "validation_count": len(validation_loader.dataset),
              "test_count": len(test_loader.dataset), "epochs_completed": len(history),
              "best_epoch": best_epoch, "best_validation_accuracy": best_accuracy,
              "best_validation_loss": best_loss, "official_test_evaluated": evaluate_test,
              "official_test_accuracy": None, "board_verified": False, "history": history}
    if evaluate_test:
        # Test is evaluated only once, after validation-based model selection.
        test = run_epoch(model, test_loader, device)
        matrix = np.zeros((11, 11), dtype=np.int64)
        np.add.at(matrix, (test["labels"], test["predictions"]), 1)
        report.update(official_test_accuracy=test["accuracy"], official_test_correct=test["correct"],
                      test_labels=test["labels"], test_predictions=test["predictions"],
                      test_sample_indices=test["sample_indices"],
                      confusion_matrix_rows_true_columns_predicted=matrix.tolist())
    write_json(output / "cnn_lif_improved_report.json", report)
    print(f"模型：{output / 'cnn_lif_improved_best.pt'}")
    print(f"报告：{output / 'cnn_lif_improved_report.json'}")
    if evaluate_test:
        print(f"本次浮点测试准确率：{report['official_test_accuracy']:.2%}；不是FPGA准确率")
    return report


def parse_arguments():
    parser = argparse.ArgumentParser(description="按保留V2报告重建的独立训练入口，不保证历史权重逐位一致")
    parser.add_argument("--cache", type=Path, default=DEFAULT_DATA / "frames_t16_uint16.npz")
    parser.add_argument("--metadata", type=Path, default=DEFAULT_DATA / "frames_t16_uint16.json")
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--max-epochs", type=int, default=200)
    parser.add_argument("--device", choices=("auto", "cpu", "cuda"), default="auto")
    parser.add_argument("--threads", type=int, default=None, help="可选CPU线程数")
    parser.add_argument("--evaluate-test", action="store_true", help="选好模型后额外评估官方测试集")
    parser.add_argument("--smoke-test", action="store_true", help="真实缓存前向、反向检查，不训练保存模型")
    return parser.parse_args()


def main():
    args = parse_arguments()
    if args.max_epochs <= 0 or (args.threads is not None and args.threads <= 0):
        raise ValueError("训练轮数和线程数必须为正整数")
    if args.device == "cuda" and not torch.cuda.is_available():
        raise ValueError("指定了cuda，但当前PyTorch无法使用CUDA")
    if args.threads is not None:
        torch.set_num_threads(args.threads)
    device = torch.device("cuda" if args.device == "auto" and torch.cuda.is_available()
                          else ("cpu" if args.device == "auto" else args.device))
    output = args.output_dir.resolve()
    if not args.smoke_test:
        check_output_dir(output)
    frames, labels, metadata, groups = load_data(args.cache, args.metadata)
    set_seed(CONFIG["seed"])
    datasets = [GestureDataset(frames, labels, indices, augment=(i == 0), seed=707 + i)
                for i, indices in enumerate(groups)]
    model = CNNLIF(leak=CONFIG["leak"], threshold=CONFIG["threshold"]).to(device)
    if args.smoke_test:
        inputs, label, _ = datasets[0][0]
        loss = loss_function(model(inputs.unsqueeze(0).to(device)), torch.tensor([label], device=device))
        loss.backward()
        if not torch.isfinite(loss) or not any(p.grad is not None and p.grad.abs().sum() > 0
                                             for p in model.parameters()):
            raise RuntimeError("前向或反向检查失败")
        print("SMOKE_TEST_PASS：真实缓存前向和反向通过；没有保存模型，也没有评估测试集")
        return
    loaders = [DataLoader(ds, batch_size=CONFIG["batch_size"], shuffle=(i == 0), num_workers=0)
               for i, ds in enumerate(datasets)]
    config = dict(CONFIG, max_epochs=args.max_epochs, experiment="v2_reconstructed_no_ema",
                  optimizer="AdamW", source_reconstructed=True)
    provenance = {"python": platform.python_version(), "numpy": str(np.__version__),
                  "torch": str(torch.__version__), "device": str(device), "platform": platform.platform(),
                  "cuda": torch.version.cuda, "cudnn": torch.backends.cudnn.version(),
                  "cpu_threads": torch.get_num_threads(), "script_sha256": sha256_file(Path(__file__)),
                  "inputs": {Path(os.path.relpath(p.resolve(), PROJECT_ROOT.parents[1])).as_posix(): sha256_file(p) for p in (args.cache, args.metadata)},
                  "reference_report_sha256": sha256_file(REFERENCE_REPORT) if REFERENCE_REPORT.is_file() else None,
                  "historical_source_recovered": False, "historical_weight_equality_guaranteed": False}
    print("训练V2重建版：无EMA、无辅助损失、无预训练权重；只用验证集选择模型", flush=True)
    print("划分：984训练 / 192验证 / 288测试；本次不会自动部署到FPGA", flush=True)
    fit(model, *loaders, output, config, provenance, device, args.evaluate_test)


if __name__ == "__main__":
    main()
