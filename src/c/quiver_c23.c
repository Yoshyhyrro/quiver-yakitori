#include <stdint.h>
#include <stdbool.h>
#include <math.h>

// C23 constexpr for bitmasks
constexpr uint32_t SIGN_MASK       = 0x80000000u;
constexpr uint32_t EXP_MASK        = 0x7F800000u;
constexpr uint32_t MANTISSA_MASK   = 0x007FFFFFu;
constexpr uint32_t BF16_MASK       = 0xFFFF0000u;
constexpr uint32_t BF16_ROUND_BIAS = 0x00007FFFu; // half-ULP bias for bf16 round-to-nearest
constexpr uint32_t FP8_MANT_MASK   = 0x00700000u; // E4M3 keeps top 3 bits of mantissa (bits 20-22)
constexpr uint32_t FP8_ROUND_BIT   = 0x00080000u; // first discarded bit (bit 19)
constexpr uint32_t FP8_STICKY_MASK = 0x0007FFFFu; // remaining discarded bits (bits 0-18)
constexpr uint32_t FP8_ULP         = 0x00100000u; // 1 ULP at the kept mantissa's LSB (bit 20)
constexpr uint32_t FP8_MANT_CARRY  = 0x00800000u; // carry-out of the 3-bit mantissa field

typedef union {
    float f;
    uint32_t i;
} float_bits;

// BF16: 1 sign, 8 exponent, 7 mantissa
// Round-to-nearest-even, matching standard hardware/ML-framework bf16
// conversion: add a half-ULP bias (adjusted by the kept LSB for ties-to-even),
// then truncate. The bias addition naturally propagates any mantissa carry
// into the exponent field via plain integer addition, exactly as IEEE-754
// rounding requires.
float c23_to_bf16(float f) {
    float_bits fb = { .f = f };

    // Preserve NaNs: truncating a NaN's mantissa to zero would turn it into
    // +/-Infinity, which round-to-nearest-even must never do.
    if ((fb.i & EXP_MASK) == EXP_MASK && (fb.i & MANTISSA_MASK) != 0) {
        fb.i |= 0x00400000u; // force the top kept mantissa bit on to stay NaN
        fb.i &= BF16_MASK;
        return fb.f;
    }

    uint32_t kept_lsb = (fb.i >> 16) & 1u;
    uint32_t rounding_bias = BF16_ROUND_BIAS + kept_lsb; // ties-to-even
    fb.i += rounding_bias;
    fb.i &= BF16_MASK;
    return fb.f;
}

// FP8 (E4M3 mode): 1 sign, 4 exponent, 3 mantissa
// Round-to-nearest-even on the 3 kept mantissa bits, with explicit handling
// of mantissa carry-out (which bumps the exponent by one) and saturation at
// the representable range boundaries.
float c23_to_fp8(float f) {
    float_bits fb = { .f = f };
    uint32_t sign = fb.i & SIGN_MASK;

    // Quick exit for zero to avoid exponent underflow calculation
    if (f == 0.0f) return f;

    int32_t exponent = ((fb.i & EXP_MASK) >> 23) - 127;
    uint32_t mantissa = fb.i & MANTISSA_MASK;

    // Round the discarded 20 low mantissa bits to nearest, ties-to-even
    uint32_t round_bit = mantissa & FP8_ROUND_BIT;
    uint32_t sticky     = mantissa & FP8_STICKY_MASK;
    uint32_t kept        = mantissa & FP8_MANT_MASK;

    bool round_up;
    if (round_bit == 0) {
        round_up = false;                  // strictly below halfway: round down
    } else if (sticky != 0) {
        round_up = true;                   // strictly above halfway: round up
    } else {
        round_up = (kept & FP8_ULP) != 0;  // exactly halfway: round to even
    }

    if (round_up) {
        kept += FP8_ULP;
        if (kept & FP8_MANT_CARRY) {
            // Mantissa overflowed (111 -> 1000): normalize by bumping the
            // exponent and resetting the mantissa back to zero.
            kept = 0;
            exponent += 1;
        }
    }
    mantissa = kept;

    // FP8 E4M3 valid exponent range is -6 to 7. This check happens AFTER
    // rounding, since rounding can itself push a value across a boundary
    // (e.g. the largest subnormal-range value rounding up into range -6).
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