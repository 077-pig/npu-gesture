"""Small synthetic checks; not a substitute for 200 epochs or board tests."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import numpy as np
import torch
from torch.utils.data import DataLoader, TensorDataset

import train_cnn_lif_v2 as v2
import verify_improved_fixed_point as quantization


def reference_forward(sequence, weights):
    """Functional CNN and LIF recurrence, independent of model.forward."""
    membrane = sequence.new_zeros((len(sequence), 11))
    counts = torch.zeros_like(membrane)
    for frame in sequence.unbind(dim=1):
        for name in ("conv1", "conv2", "conv3"):
            frame = torch.relu(torch.nn.functional.conv2d(
                frame, weights[name + ".weight"], weights[name + ".bias"], stride=2, padding=1))
        current = torch.nn.functional.linear(frame.mean(dim=(2, 3)),
                                             weights["classifier.weight"], weights["classifier.bias"])
        membrane = 0.5 * membrane + current
        spike = v2.SurrogateSpike.apply(membrane - 0.5)
        membrane = membrane - 0.5 * spike
        counts = counts + spike
    return counts


class TrainingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        torch.set_num_threads(2)

    def test_reference_config(self):
        reference = json.loads(v2.REFERENCE_REPORT.read_text(encoding="utf-8"))["config"]
        for key, value in v2.CONFIG.items():
            self.assertEqual(value, reference[key], key)
        self.assertNotIn("ema_start_epoch", v2.CONFIG)

    def test_original_checkpoint_and_forward_backward(self):
        checkpoint = torch.load(v2.REFERENCE_REPORT.with_name("cnn_lif_improved_best.pt"),
                                map_location="cpu", weights_only=True)
        model = v2.CNNLIF()
        model.load_state_dict(checkpoint["model_state_dict"], strict=True)
        weights = {key: value.clone().requires_grad_(True)
                   for key, value in checkpoint["model_state_dict"].items()}
        self.assertEqual(sum(p.numel() for p in model.parameters()), 24155)
        v2.set_seed(706)
        inputs = torch.rand(1, 16, 2, 64, 64)
        outputs = model(inputs)
        expected = reference_forward(inputs, weights)
        self.assertTrue(torch.equal(outputs, expected))
        loss = v2.loss_function(outputs, torch.tensor([3]))
        expected_loss = torch.nn.functional.cross_entropy(expected, torch.tensor([3]))
        loss.backward()
        expected_loss.backward()
        self.assertEqual(loss.item(), expected_loss.item())
        for name, parameter in model.named_parameters():
            torch.testing.assert_close(parameter.grad, weights[name].grad, rtol=1e-6, atol=1e-7, msg=name)
            self.assertTrue(torch.isfinite(parameter.grad).all())
        self.assertTrue(any(p.grad.abs().sum() > 0 for p in model.parameters()))
        values = torch.tensor([-1.0, 0.0, 1.0], requires_grad=True)
        spikes = v2.SurrogateSpike.apply(values)
        self.assertEqual(spikes.tolist(), [0.0, 1.0, 1.0])
        spikes.sum().backward()
        torch.testing.assert_close(values.grad, torch.tensor([0.25, 1.0, 0.25]))

    def test_augmentation_is_seeded_and_uses_zero_fill(self):
        sample = np.zeros((1, 16, 64, 64, 2), dtype=np.uint16)
        sample[0, :, 0, 0, 0] = 200
        sample[0, :, 28:35, 30:36, 1] = 7
        labels, indices = np.array([2]), np.array([0])
        actual = v2.GestureDataset(sample, labels, indices, True, 707)
        reference = v2.GestureDataset(sample, labels, indices, True, 707)
        for _ in range(10):
            self.assertTrue(torch.equal(actual[0][0], reference[0][0]))
        shifted = v2.translate_zero_fill(sample[0], 1, 1)
        self.assertEqual(shifted[:, 0].sum(), 0)
        self.assertEqual(shifted[:, :, 0].sum(), 0)
        np.testing.assert_array_equal(shifted[:, 1:, 1:, :], sample[0, :, :-1, :-1, :])
        plain = v2.GestureDataset(sample, labels, indices)[0][0]
        self.assertLessEqual(float(plain.max()), 1.0)

    def test_data_validation_and_subject_splits(self):
        # Broadcasted frames avoid allocating a 384 MB fixture.
        frames = np.broadcast_to(np.zeros((1, 16, 64, 64, 2), dtype=np.uint16), (1464, 16, 64, 64, 2))
        labels = np.zeros(1464, dtype=np.uint8)
        flags = np.array([0] * 1176 + [1] * 288, dtype=np.uint8)
        metadata = [{"sample_index": i, "label": 0,
                     "trial": f"user{(1 if i < 984 else 20 if i < 1176 else 24):02d}_test.aedat"}
                    for i in range(1464)]

        class FakeCache(dict):
            def __enter__(self):
                return self
            def __exit__(self, *args):
                return False

        with patch.object(Path, "is_file", return_value=True), patch.object(
                Path, "read_text", return_value=json.dumps(metadata)), patch.object(
                np, "load", return_value=FakeCache(frames=frames, labels=labels, splits=flags)):
            *_, groups = v2.load_data(Path("cache"), Path("metadata"))
            self.assertEqual(tuple(map(len, groups)), (984, 192, 288))
            flags[0] = 1
            with self.assertRaises(ValueError):
                v2.load_data(Path("cache"), Path("metadata"))

    def test_training_save_reload_determinism_and_output_protection(self):
        reports, states = [], []
        inputs = torch.rand(2, 16, 2, 64, 64)
        dataset = TensorDataset(inputs, torch.tensor([0, 1]), torch.tensor([0, 1]))
        with tempfile.TemporaryDirectory(prefix="npu_v2_test_") as directory:
            for run in range(2):
                v2.set_seed(706)
                model = v2.CNNLIF()
                loader = DataLoader(dataset, batch_size=2, shuffle=True)
                evaluation = DataLoader(dataset, batch_size=2)
                output = Path(directory) / str(run)
                config = dict(v2.CONFIG, max_epochs=1)
                report = v2.fit(model, loader, evaluation, evaluation, output, config,
                                {"synthetic_test": True}, torch.device("cpu"), evaluate_test=True)
                self.assertEqual(report["epochs_completed"], 1)
                self.assertTrue(report["official_test_evaluated"])
                self.assertFalse(report["board_verified"])
                checkpoint = torch.load(output / "cnn_lif_improved_best.pt", weights_only=True)
                v2.CNNLIF().load_state_dict(checkpoint["model_state_dict"], strict=True)
                states.append(checkpoint["model_state_dict"])
                reports.append(report)
                with self.assertRaises(FileExistsError):
                    v2.check_output_dir(output)
                modules = quantization.configure_modules("v2", Path(directory) / "quant", output / "cnn_lif_improved_best.pt")
                for module in modules:
                    self.assertEqual(module.FLOAT_MODEL_PATH, output / "cnn_lif_improved_best.pt")
                self.assertIs(modules[1].CNNLIF, v2.CNNLIF)
                self.assertIs(modules[3].CNNLIF, v2.CNNLIF)
                # Actual quantizer reads our checkpoint; verify all four layers.
                weights = modules[0].load_state_dict()
                self.assertEqual(set(weights), set(checkpoint["model_state_dict"]))
            self.assertEqual(reports[0]["history"], reports[1]["history"])
            for key in states[0]:
                self.assertTrue(torch.equal(states[0][key], states[1][key]))
        with self.assertRaises(ValueError):
            v2.check_output_dir(v2.REFERENCE_REPORT.parent)

    def test_test_loader_not_read_without_opt_in(self):
        class NeverRead:
            dataset = [None]
            def __iter__(self):
                raise AssertionError("Official test must not be read")

        data = TensorDataset(torch.zeros(1, 16, 2, 64, 64), torch.tensor([0]), torch.tensor([0]))
        loader = DataLoader(data)
        with tempfile.TemporaryDirectory(prefix="npu_v2_test_") as directory:
            report = v2.fit(v2.CNNLIF(), loader, loader, NeverRead(), Path(directory),
                            dict(v2.CONFIG, max_epochs=1), {}, torch.device("cpu"))
            self.assertFalse(report["official_test_evaluated"])
            self.assertIsNone(report["official_test_accuracy"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
