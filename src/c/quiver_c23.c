#include <stdint.h>
#include <stdbool.h>
#include <math.h>

// C23 constexpr for bitmasks
constexpr uint32_t SIGN_MASK     = 0x80000000u;
constexpr uint32_t EXP_MASK      = 0x7F800000u;
constexpr uint32_t MANTISSA_MASK = 0x007FFFFFu;
constexpr uint32_t BF16_MASK     = 0xFFFF0000u;
constexpr uint32_t FP8_MANT_MASK = 0x00700000u; // E4M3 keeps top 3 bits of mantissa

typedef union {
    float f;
    uint32_t i;
} float_bits;

// BF16: 1 sign, 8 exponent, 7 mantissa
// Hardware-like quantization via simple truncation
float c23_to_bf16(float f) {
    float_bits fb = { .f = f };
    fb.i &= BF16_MASK;
    return fb.f;
}

// FP8 (E4M3 mode): 1 sign, 4 exponent, 3 mantissa
float c23_to_fp8(float f) {
    float_bits fb = { .f = f };
    uint32_t sign = fb.i & SIGN_MASK;
    
    // Quick exit for zero to avoid exponent underflow calculation
    if (f == 0.0f) return f;

    int32_t exponent = ((fb.i & EXP_MASK) >> 23) - 127;
    uint32_t mantissa = fb.i & MANTISSA_MASK;

    // FP8 E4M3 valid exponent range is -6 to 7
    if (exponent < -6) {
        // Underflow: Return +/- 0.0f preserving the sign bit 
        // (Crucial for rotation matrix phase tracking)
        float_bits zero_fb = { .i = sign };
        return zero_fb.f;
    }
    
    if (exponent > 7) {
        // Overflow: Saturate to max FP8 value 
        // (E4M3 format does not standardly support infinity, it clips)
        exponent = 7;
        mantissa = FP8_MANT_MASK; 
    }

    // Reconstruct the 32-bit float with FP8 quantized constraints
    fb.i = sign | ((uint32_t)(exponent + 127) << 23) | (mantissa & FP8_MANT_MASK);
    return fb.f;
}