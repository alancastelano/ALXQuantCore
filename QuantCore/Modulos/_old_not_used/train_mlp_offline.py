#!/usr/bin/env python3
"""
Offline training pipeline for EAQuant_IA_v1 MLP (15->12->3).

Flow:
  1. Read ia_miner CSV
  2. Extract 15 features + compute targets from trade outcomes
  3. Train MLP with Adam (same architecture as NeuralAgent.mqh)
  4. Save weights in CSV format compatible with LoadWeights()

Usage:
    python train_mlp_offline.py --input data/ia_miner --output data/weights_initial.csv
    python train_mlp_offline.py --input data/ia_miner --val-split 0.2 --epochs 500
"""

import argparse
import csv
import os
import sys

import numpy as np

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_PROJECT_ROOT = os.path.abspath(os.path.join(_SCRIPT_DIR, ".."))
sys.path.insert(0, _SCRIPT_DIR)
from features import (
    NN_INPUTS, NN_HIDDEN, NN_OUTPUTS,
    extract_features, normalize, compute_target,
)

DATA_DIR = os.path.join(_PROJECT_ROOT, "data")
DEFAULT_INPUT = os.path.join(DATA_DIR, "ia_miner")
DEFAULT_OUTPUT = os.path.join(DATA_DIR, "weights_initial.csv")


# --- MLP Model (same architecture as NeuralAgent.mqh) ---

def tanh(x):
    return np.tanh(x)


def tanh_deriv(a):
    return 1.0 - a ** 2


def sigmoid(x):
    return 1.0 / (1.0 + np.exp(-np.clip(x, -15, 15)))


def sigmoid_deriv(a):
    return a * (1.0 - a)


class MLP:
    """MLP 15->12->3 matching NeuralAgent.mqh exactly."""

    def __init__(self, lr=0.001, l2=0.0001):
        self.lr = lr
        self.l2 = l2

        scale1 = np.sqrt(2.0 / NN_INPUTS)
        scale2 = np.sqrt(2.0 / NN_HIDDEN)

        self.w1 = np.random.uniform(-1, 1, (NN_INPUTS, NN_HIDDEN)) * scale1
        self.b1 = np.zeros(NN_HIDDEN)
        self.w2 = np.random.uniform(-1, 1, (NN_HIDDEN, NN_OUTPUTS)) * scale2
        self.b2 = np.zeros(NN_OUTPUTS)

    def forward(self, x):
        x = np.asarray(x, dtype=np.float64)
        z1 = x @ self.w1 + self.b1
        a1 = tanh(z1)
        z2 = a1 @ self.w2 + self.b2
        y = np.empty(3, dtype=np.float64)
        y[0] = tanh(z2[0])
        y[1] = sigmoid(z2[1])
        y[2] = sigmoid(z2[2]) * 2.0
        return y, (z1, a1, z2)

    def predict(self, x):
        y, _ = self.forward(x)
        return y

    def backward(self, x, target, cache):
        x = np.asarray(x, dtype=np.float64)
        target = np.asarray(target, dtype=np.float64)
        z1, a1, z2 = cache

        a2 = np.empty(3, dtype=np.float64)
        a2[0] = tanh(z2[0])
        a2[1] = sigmoid(z2[1])
        a2[2] = sigmoid(z2[2]) * 2.0

        grad_w1 = np.zeros_like(self.w1)
        grad_b1 = np.zeros_like(self.b1)
        grad_w2 = np.zeros_like(self.w2)
        grad_b2 = np.zeros_like(self.b2)

        e0 = a2[0] - target[0]
        dz2_0 = 2.0 * e0 * (1.0 - a2[0] ** 2)

        e1 = a2[1] - target[1]
        dz2_1 = 2.0 * e1 * (1.0 - a2[1])
        # Using alternative gradient to be safe
        s_val = a2[1]
        dz2_1 = 2.0 * e1 * s_val * (1.0 - s_val)

        s = a2[2] / 2.0
        e2 = a2[2] - target[2]
        dz2_2 = 2.0 * e2 * 2.0 * s * (1.0 - s)

        dz2 = np.array([dz2_0, dz2_1, dz2_2])

        grad_b2 += dz2
        for j in range(NN_HIDDEN):
            grad_w2[j] += dz2 * a1[j]

        da1 = np.zeros(NN_HIDDEN)
        for j in range(NN_HIDDEN):
            da1[j] = (dz2[0] * self.w2[j, 0]
                      + dz2[1] * self.w2[j, 1]
                      + dz2[2] * self.w2[j, 2])

        dz1 = da1 * (1.0 - a1 ** 2)

        grad_b1 += dz1
        for i in range(NN_INPUTS):
            grad_w1[i] += dz1 * x[i]

        grad_w1 += self.l2 * self.w1
        grad_w2 += self.l2 * self.w2

        return grad_w1, grad_b1, grad_w2, grad_b2

    def compute_loss(self, y_pred, target):
        err = np.array(y_pred) - np.array(target)
        return float(np.mean(err ** 2))


class Trainer:
    """Adam optimizer for MLP."""

    def __init__(self, model, lr=0.001, beta1=0.9, beta2=0.999, eps=1e-8):
        self.model = model
        self.lr = lr
        self.beta1 = beta1
        self.beta2 = beta2
        self.eps = eps
        self.t = 0

        self.m_w1 = np.zeros_like(model.w1)
        self.m_b1 = np.zeros_like(model.b1)
        self.m_w2 = np.zeros_like(model.w2)
        self.m_b2 = np.zeros_like(model.b2)
        self.v_w1 = np.zeros_like(model.w1)
        self.v_b1 = np.zeros_like(model.b1)
        self.v_w2 = np.zeros_like(model.w2)
        self.v_b2 = np.zeros_like(model.b2)

    def step(self, grads):
        gw1, gb1, gw2, gb2 = grads
        self.t += 1

        for name, g, m, v in [
            ("w1", gw1, self.m_w1, self.v_w1),
            ("b1", gb1, self.m_b1, self.v_b1),
            ("w2", gw2, self.m_w2, self.v_w2),
            ("b2", gb2, self.m_b2, self.v_b2),
        ]:
            m[:] = self.beta1 * m + (1 - self.beta1) * g
            v[:] = self.beta2 * v + (1 - self.beta2) * (g ** 2)
            m_hat = m / (1 - self.beta1 ** self.t)
            v_hat = v / (1 - self.beta2 ** self.t)
            update = self.lr * m_hat / (np.sqrt(v_hat) + self.eps)

            if name == "w1":
                self.model.w1 -= update
            elif name == "b1":
                self.model.b1 -= update
            elif name == "w2":
                self.model.w2 -= update
            elif name == "b2":
                self.model.b2 -= update


# --- Data loading ---

def load_miner_csv(filepath):
    """Load ia_miner CSV (semicolon-delimited) into list of dicts."""
    rows = []
    with open(filepath, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f, delimiter=";")
        for row in reader:
            rows.append(row)
    return rows


def build_dataset(rows, max_samples=None):
    """Convert CSV rows to (X, y) pairs for training."""
    X, y = [], []
    if max_samples is not None:
        rows = rows[:max_samples]

    for row in rows:
        try:
            feats_raw = extract_features(row)
            feats_norm = normalize(feats_raw)
            target = compute_target(row)
            X.append(feats_norm)
            y.append(target)
        except (ValueError, KeyError) as e:
            continue

    return np.array(X, dtype=np.float64), np.array(y, dtype=np.float64)


# --- Weight export (compatible with NeuralAgent.mqh::LoadWeights) ---

def export_weights(model, filepath, comment=""):
    """Save weights in the CSV format expected by LoadWeights()."""
    os.makedirs(os.path.dirname(filepath), exist_ok=True)

    lines = []
    if comment:
        lines.append(f"# {comment},,\n")

    for i in range(NN_INPUTS):
        for j in range(NN_HIDDEN):
            lines.append(f"LAYER1_W,{i},{j},{model.w1[i,j]:.8f}\n")

    for j in range(NN_HIDDEN):
        lines.append(f"LAYER1_B,{j},,{model.b1[j]:.8f}\n")

    for j in range(NN_HIDDEN):
        for k in range(NN_OUTPUTS):
            lines.append(f"LAYER2_W,{j},{k},{model.w2[j,k]:.8f}\n")

    for k in range(NN_OUTPUTS):
        lines.append(f"LAYER2_B,{k},,{model.b2[k]:.8f}\n")

    with open(filepath, "w", encoding="ansi") as f:
        f.writelines(lines)

    total = NN_INPUTS * NN_HIDDEN + NN_HIDDEN + NN_HIDDEN * NN_OUTPUTS + NN_OUTPUTS
    print(f"  [OK] {filepath} — {total} parametros exportados")


# --- Train / eval split ---

def temporal_split(X, y, val_ratio=0.2):
    """Split by time (last val_ratio of samples go to validation)."""
    n = len(X)
    split = int(n * (1.0 - val_ratio))
    return X[:split], y[:split], X[split:], y[split:]


# --- Main ---

def main():
    p = argparse.ArgumentParser(description="Treina MLP offline para EAQuant_IA_v1")
    p.add_argument("--input", default=DEFAULT_INPUT, help="Caminho do ia_miner CSV")
    p.add_argument("--output", default=DEFAULT_OUTPUT, help="Onde salvar weights_initial.csv")
    p.add_argument("--epochs", type=int, default=300, help="Epocas de treino")
    p.add_argument("--lr", type=float, default=0.001, help="Learning rate (Adam)")
    p.add_argument("--l2", type=float, default=0.0001, help="L2 regularization")
    p.add_argument("--batch-size", type=int, default=32, help="Mini-batch size")
    p.add_argument("--val-split", type=float, default=0.2, help="Fracao de validacao temporal")
    p.add_argument("--max-samples", type=int, default=None, help="Limitar amostras (debug)")
    p.add_argument("--patience", type=int, default=30, help="Early stopping patience")
    p.add_argument("--seed", type=int, default=None, help="Seed numpy")
    args = p.parse_args()

    if args.seed is not None:
        np.random.seed(args.seed)

    print("=" * 60)
    print("EAQuant_IA_v1 — Treinamento Offline MLP 15->12->3")
    print("=" * 60)

    # --- Load ---
    print(f"\n[1] Carregando: {args.input}")
    if not os.path.isfile(args.input):
        print(f"  ERRO: Arquivo nao encontrado: {args.input}")
        print("  Rode o backtest com InpNeuralEnabled=false primeiro.")
        sys.exit(1)

    rows = load_miner_csv(args.input)
    print(f"  {len(rows)} trades carregados")

    X, y = build_dataset(rows, args.max_samples)
    print(f"  {len(X)} amostras validas (features + targets)")

    if len(X) < 50:
        print("  AVISO: Poucas amostras. O treino pode ser ineficaz.")

    # --- Split ---
    X_tr, y_tr, X_val, y_val = temporal_split(X, y, args.val_split)
    print(f"\n[2] Split: {len(X_tr)} treino / {len(X_val)} validacao")

    # --- Train ---
    print(f"\n[3] Treinando MLP {NN_INPUTS}->{NN_HIDDEN}->{NN_OUTPUTS}")
    print(f"    lr={args.lr} l2={args.l2} batch={args.batch_size} epochs={args.epochs}")

    model = MLP(lr=args.lr, l2=args.l2)
    optimizer = Trainer(model, lr=args.lr)

    best_val_loss = float("inf")
    best_weights = None
    patience_count = 0
    n = len(X_tr)

    for epoch in range(1, args.epochs + 1):
        perm = np.random.permutation(n)
        epoch_loss = 0.0
        batches = 0

        for start in range(0, n, args.batch_size):
            idx = perm[start:start + args.batch_size]
            batch_x = X_tr[idx]
            batch_y = y_tr[idx]

            grad_w1 = np.zeros_like(model.w1)
            grad_b1 = np.zeros_like(model.b1)
            grad_w2 = np.zeros_like(model.w2)
            grad_b2 = np.zeros_like(model.b2)

            for xi, yi in zip(batch_x, batch_y):
                _, cache = model.forward(xi)
                gw1, gb1, gw2, gb2 = model.backward(xi, yi, cache)
                grad_w1 += gw1
                grad_b1 += gb1
                grad_w2 += gw2
                grad_b2 += gb2

            bs = len(batch_x)
            optimizer.step((grad_w1 / bs, grad_b1 / bs,
                            grad_w2 / bs, grad_b2 / bs))

            loss = model.compute_loss(model.predict(xi), yi)
            epoch_loss += loss
            batches += 1

        avg_loss = epoch_loss / max(batches, 1)

        # Validation
        val_loss = 0.0
        for xi, yi in zip(X_val, y_val):
            yp = model.predict(xi)
            val_loss += model.compute_loss(yp, yi)
        val_loss /= max(len(X_val), 1)

        if epoch % 25 == 0 or epoch == 1:
            print(f"  epoca {epoch:4d} | train loss: {avg_loss:.6f} | val loss: {val_loss:.6f}")

        if val_loss < best_val_loss:
            best_val_loss = val_loss
            best_weights = (model.w1.copy(), model.b1.copy(),
                            model.w2.copy(), model.b2.copy())
            patience_count = 0
        else:
            patience_count += 1
            if patience_count >= args.patience:
                print(f"  Early stopping na epoca {epoch}")
                break

    # --- Restore best weights ---
    if best_weights is not None:
        model.w1, model.b1, model.w2, model.b2 = best_weights

    print(f"\n[4] Melhor loss validacao: {best_val_loss:.6f}")

    # --- Export ---
    print(f"\n[5] Exportando pesos para: {args.output}")
    comment = f"EAQuantIA_v1 offline train {len(X_tr)}samples val_loss={best_val_loss:.6f}"
    export_weights(model, args.output, comment)

    # --- Quick sanity ---
    print("\n[6] Sanity check — predicao media no dataset:")
    means = np.mean(y, axis=0)
    preds = np.array([model.predict(x) for x in X])
    pred_means = np.mean(preds, axis=0)
    print(f"  target medio:     dir={means[0]:.3f} conf={means[1]:.3f} size={means[2]:.3f}")
    print(f"  predicao media:   dir={pred_means[0]:.3f} conf={pred_means[1]:.3f} size={pred_means[2]:.3f}")

    print("\nConcluido! Copie o arquivo para o diretorio de dados e rode o EA.")


if __name__ == "__main__":
    main()
