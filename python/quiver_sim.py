# tests/test_quiver.py
import pytest
from python.quiver_sim import detect_17_cycle

def test_simulation_fp8_runs():
    """Verify that FP8 simulation finishes without raising unexpected exceptions."""
    try:
        result = detect_17_cycle(mode='fp8', max_steps=10)
        assert result is not None
    except Exception as exc:
        pytest.fail(f"FP8 simulation failed with exception: {exc}")

def test_simulation_bf16_runs():
    """Verify that BF16 simulation finishes without raising unexpected exceptions."""
    try:
        result = detect_17_cycle(mode='bf16', max_steps=10)
        assert result is not None
    except Exception as exc:
        pytest.fail(f"BF16 simulation failed with exception: {exc}")