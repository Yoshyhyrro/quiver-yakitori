import torch
import numpy as np


def detect_17_cycle(mode='fp8', max_steps=35, verbose=True):
    """Iteratively multiply a 2x2 rotation matrix (theta = 2*pi/17) by
    itself under a given precision mode, and return the resulting
    RegState trajectory (the [0, 0] entry at every step).

    Parameters
    ----------
    mode : {'fp8', 'bf16', anything else}
        Quantization applied to the accumulator after each matmul.
        Anything other than 'fp8'/'bf16' runs unquantized float32.
    max_steps : int
        Number of multiplications to perform.
    verbose : bool
        If True, print each step (kept for CLI/manual runs). Tests
        should pass verbose=False to keep output clean.

    Returns
    -------
    list[float]
        length == max_steps, trajectory[k] == current[0, 0] before the
        (k+1)-th multiplication.
    """
    theta = 2.0 * np.pi / 17.0
    cos_t = np.cos(theta)
    sin_t = np.sin(theta)

    # High-precision base rotation node
    m_init = torch.tensor([
        [cos_t, -sin_t],
        [sin_t,  cos_t]
    ], dtype=torch.float32)

    current = m_init.clone()
    trajectory = []

    if verbose:
        print(f"=== Driving 17-cycle Register Machine (Emergence via {mode.upper()}) ===")

    for step in range(max_steps):
        reg_state = current[0, 0].item()
        trajectory.append(reg_state)
        if verbose:
            print(f"Step {step:2d}: RegState = {reg_state:.4f}")

        # Mixed precision matmul: quantized state x high-precision node
        res = torch.matmul(current, m_init)

        if mode == 'bf16':
            # PyTorch native bfloat16 uses Round-to-Nearest-Even
            current = res.to(torch.bfloat16).to(torch.float32)
        elif mode == 'fp8':
            try:
                current = res.to(torch.float8_e4m3fn).to(torch.float32)
            except (RuntimeError, AttributeError):
                if verbose:
                    print("[Warning] Native FP8 not supported, falling back to FP16")
                current = res.to(torch.float16).to(torch.float32)
        else:
            current = res  # float32, no quantization

    if verbose:
        print("Simulation finished")

    return trajectory


if __name__ == "__main__":
    detect_17_cycle(mode='fp8', max_steps=35)