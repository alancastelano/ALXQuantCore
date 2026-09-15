#!/usr/bin/env python3
"""
Gera pesos iniciais para EAQuant_IA_v1 (MLP 15->12->3).
Formato CSV compatível com NeuralAgent.mqh (LoadWeights via kernel32).

Uso:
    python gerar_pesos_ia.py                      # pesos aleatorios (Xavier)
    python gerar_pesos_ia.py --seed 42             # reproducible
    python gerar_pesos_ia.py --output pesos.csv    # nome customizado
"""

import argparse
import os
import numpy as np

NN_INPUTS = 15
NN_HIDDEN = 12
NN_OUTPUTS = 3

DATA_DIR = "C:\\ALXQuant\\data"
DEFAULT_OUTPUT = "weights_initial.csv"


def xavier_init(rows, cols, rng):
    scale = np.sqrt(2.0 / rows)
    return rng.uniform(-1, 1, (rows, cols)) * scale


def gerar_pesos(seed=None):
    rng = np.random.default_rng(seed)

    w1 = xavier_init(NN_INPUTS, NN_HIDDEN, rng)
    b1 = np.zeros(NN_HIDDEN)
    w2 = xavier_init(NN_HIDDEN, NN_OUTPUTS, rng)
    b2 = np.zeros(NN_OUTPUTS)

    return w1, b1, w2, b2


def salvar_csv(w1, b1, w2, b2, filepath, comment=""):
    os.makedirs(os.path.dirname(filepath), exist_ok=True)

    lines = []
    if comment:
        lines.append(f"# {comment},,\n")

    for i in range(NN_INPUTS):
        for j in range(NN_HIDDEN):
            lines.append(f"LAYER1_W,{i},{j},{w1[i,j]:.8f}\n")

    for j in range(NN_HIDDEN):
        lines.append(f"LAYER1_B,{j},,{b1[j]:.8f}\n")

    for j in range(NN_HIDDEN):
        for k in range(NN_OUTPUTS):
            lines.append(f"LAYER2_W,{j},{k},{w2[j,k]:.8f}\n")

    for k in range(NN_OUTPUTS):
        lines.append(f"LAYER2_B,{k},,{b2[k]:.8f}\n")

    with open(filepath, "w", encoding="ansi") as f:
        f.writelines(lines)

    print(f"[OK] {filepath} — {NN_INPUTS*NN_HIDDEN + NN_HIDDEN + NN_HIDDEN*NN_OUTPUTS + NN_OUTPUTS} parametros")


def main():
    parser = argparse.ArgumentParser(description="Gera pesos iniciais para EAQuant_IA_v1")
    parser.add_argument("--seed", type=int, default=None, help="Seed numpy (opcional)")
    parser.add_argument("--output", type=str, default=DEFAULT_OUTPUT, help="Nome do arquivo CSV")
    parser.add_argument("--comment", type=str, default="EAQuantIA_v1 initial weights", help="Comentario no topo")
    args = parser.parse_args()

    filepath = os.path.join(DATA_DIR, args.output)
    w1, b1, w2, b2 = gerar_pesos(args.seed)
    salvar_csv(w1, b1, w2, b2, filepath, args.comment)


if __name__ == "__main__":
    main()
