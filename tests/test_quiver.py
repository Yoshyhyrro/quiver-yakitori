import pytest
from python.quiver_sim import detect_17_cycle


def test_simulation_fp8_runs():
    """The FP8 simulation should complete without exceptions and return a
    trajectory with the expected number of steps."""
    result = detect_17_cycle(mode='fp8', max_steps=10, verbose=False)
    assert len(result) == 10


def test_simulation_bf16_runs():
    """The BF16 simulation should complete without exceptions."""
    result = detect_17_cycle(mode='bf16', max_steps=10, verbose=False)
    assert len(result) == 10


def test_float32_returns_to_identity_after_17_steps():
    """`current` starts at m_init = R(theta), so trajectory[k] = cos((k+1)*theta).
    Without quantization (float32), the trajectory should therefore satisfy:
      trajectory[16] = cos(17*theta) = cos(2*pi) = 1.0  (true 17-cycle closure point)
      trajectory[17] = cos(18*theta) = cos(theta) = trajectory[0]  (periodicity)
    This is the baseline check confirming the "true" 17-cycle.
    """
    trajectory = detect_17_cycle(mode='float32', max_steps=18, verbose=False)
    assert trajectory[16] == pytest.approx(1.0, abs=1e-4)
    assert trajectory[17] == pytest.approx(trajectory[0], abs=1e-4)


def test_fp8_degrades_periodicity():
    """FP8 quantization accumulates rounding error at every step.

    Note: comparing only trajectory[16] against float32's 1.0 is misleading,
    because the FP8 trajectory happens to round to exactly 1.0 at that same
    step too (verified empirically: diff == 0.0 at step 16), which would
    make it look like periodicity is preserved. However, the neighboring
    steps (15, 17, 18, ...) show steadily growing error, so the match at
    step 16 is coincidental saturation, not genuine periodicity. This test
    therefore evaluates the deviation from the float32 baseline across the
    whole trajectory, and checks that the error grows over time rather than
    relying on a single index.
    """
    fp8_traj = detect_17_cycle(mode='fp8', max_steps=20, verbose=False)
    f32_traj = detect_17_cycle(mode='float32', max_steps=20, verbose=False)

    diffs = [abs(a - b) for a, b in zip(fp8_traj, f32_traj)]

    # Error should be non-trivial and should grow as steps progress,
    # confirming that quantization error accumulates and drifts away
    # from the true periodic behavior over time.
    assert max(diffs) > 0.05, (
        "FP8 trajectory unexpectedly tracked float32 closely; "
        "verify whether native fp8 casting behavior has changed."
    )
    assert diffs[-1] > diffs[len(diffs) // 2], (
        "Expected FP8 quantization error to grow over time, but it did not."
    )