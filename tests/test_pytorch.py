import torch
import numpy as np

def detect_17_cycle(mode='fp8', max_steps=35):
    # Setup for the initial Jordan quiver (High Precision)
    theta = 2.0 * np.pi / 17.0
    cos_t = np.cos(theta)
    sin_t = np.sin(theta)
    
    # Initial node (Float32) - This acts as our high-precision transformation matrix
    m_init = torch.tensor([
        [cos_t, -sin_t],
        [sin_t,  cos_t]
    ], dtype=torch.float32)
    
    # Start with the unquantized initial state
    current = m_init.clone()
    
    print(f"=== Driving 17-cycle Register Machine (Emergence via {mode.upper()}) ===")
    
    for step in range(max_steps):
        # Plot the top-left element as the register output value (indicator)
        reg_state = current[0, 0].item()
        print(f"Step {step:2d}: RegState = {reg_state:.4f}")
        
        # Mixed Precision MatMul: Quantized State (current) x High-Precision Node (m_init)
        res = torch.matmul(current, m_init)
        
        # Quantize the accumulator (State Update)
        if mode == 'bf16':
            # PyTorch native bfloat16 uses Round-to-Nearest (RNE)
            current = res.to(torch.bfloat16).to(torch.float32)
            
        elif mode == 'fp8':
            try:
                # float8_e4m3fn is available in PyTorch 2.1+
                current = res.to(torch.float8_e4m3fn).to(torch.float32)
            except (RuntimeError, AttributeError):
                # Fallback if hardware/PyTorch version does not support native FP8 casting
                print("[Warning] Native FP8 not supported, falling back to FP16")
                current = res.to(torch.float16).to(torch.float32)
                
        else:
            current = res # Float32 (No quantization, will slowly drift due to f32 limits)

# Run the simulation
detect_17_cycle(mode='fp8', max_steps=35)