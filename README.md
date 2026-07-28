# quiver-yakitori

A lightweight experimental sandbox (Chicken Scheme + C23 + PyTorch) for
observing, empirically, how a 2x2 rotation register machine behaves under
reduced-precision (FP8 / BF16) quantization, and for harvesting small,
precisely-defined numeric constants from that behavior.

It is the fast, disposable counterpart to the sister project
[hatsu-yakitori](https://github.com/Yoshyhyrro/hatsu-yakitori), which carries
the Lean4 formalization. The division of labor is intentional:
quiver-yakitori makes **no formal claims**; it exists to generate cheap,
reproducible numerical evidence. Lean is only worth reaching for once
several independently-harvested constants from this project start
coinciding in a way that looks non-accidental.

## Working hypothesis (not yet proven)

The register node is the exact rotation matrix

$$
R_{17} = \begin{pmatrix} \cos\frac{2\pi}{17} & -\sin\frac{2\pi}{17} \\[4pt] \sin\frac{2\pi}{17} & \cos\frac{2\pi}{17} \end{pmatrix}
$$

Repeatedly multiplying by $R_{17}$ under full precision returns to the
identity after exactly 17 steps. The hypothesis this project is probing is:

> Under FP8/BF16 quantization, does the resulting trajectory get "pinned"
> to a discrete, 17-fold-periodic structure (informally: a "register
> machine crystal") in a way that is characteristic of the quantization
> grid itself, rather than being generic rounding noise?

This is a hypothesis to be stress-tested, not a conclusion. Anything below
that isn't in the "established" table is still open.

## What is actually established

Everything in this table has been independently reproduced (either across
machines, or across independent third-party implementations) as of this
writing.

| Finding | Where |
|---|---|
| The original `c23_to_fp8`/`c23_to_bf16` used truncation, not round-to-nearest-even; this caused ~4.5x larger error accumulation than a correct implementation | `src/c/quiver_c23.c`, fixed |
| Fixed (RNE) implementation matches PyTorch's `float8_e4m3fn` (ATen) and Google's independent `ml_dtypes.float8_e4m3fn` exactly, across the full 17-cycle trajectory | cross-checked, 3 independent implementations |
| Two composition orders — "shuffle" $Q(Q(A)Q(B))$ vs "stuffle" $Q(A@B)$ — diverge under FP8, and agree exactly under full precision | `observe-double-shuffle` in `src/scheme/quiver.scm` |
| For the current 17-cycle run (`mode='fp8'`, 20 steps): onset of divergence at step 3, exact agreement at 9/20 steps, max divergence 0.125, occurring as a 4-step plateau at steps 13-16 | `harvest-constants`, reproduced bit-for-bit across two independent machines |
| Max divergence (0.125) equals exactly 1 ULP of the E4M3 grid at magnitude ~1 — this follows directly from the format definition (3 mantissa bits), not from numerology | verified analytically + numerically |
| `quiver_c23.c`'s FP8 implementation silently matches the "with-Infinity" E4M3 variant (max finite value 240), **not** `float8_e4m3fn` (max 448) used elsewhere in this project. The two are indistinguishable within the 17-cycle's natural value range ($\lvert x\rvert \lesssim 1.125$) but diverge outside it (240 vs. 448 vs. Inf vs. NaN overflow policy) | boundary probe against `ml_dtypes.float8_e4m3` / `float8_e4m3fn`; not yet reconciled |

## What is NOT established (hypothesis / analogy only)

These terms have been used in discussion to describe the *shape* of what's
observed, but none of them have been backed by an actual construction or
proof within this project:

- **Newton-Okounkov polytope / rank explosion.** The Gram matrix of the
  quantized trajectory does lose its ideal rank-2 structure (eigenvalues
  leak away from `[8.5, 8.5, 0, ..., 0]`), which is real and measured. But
  no variety, line bundle, or valuation has been constructed, so "Newton-
  Okounkov body" is descriptive vocabulary here, not a formal identification.
- **$U_q(\mathfrak{sl}_2)$ / crystal basis limit.** No map has been
  constructed showing the FP8 rounding map satisfies the actual quantum
  group relations, or that round-to-nearest-even is a homomorphic image of
  Kashiwara crystal operators. Treat as an evocative analogy only.
- **Connection to hatsu-yakitori's `M24` / Galois-height objects.** As of
  hatsu-yakitori `v0.4.8`, the Lean formalization of these itself uses
  explicit placeholders (`M24` is implemented as the full symmetric group
  `S24`, not the Mathieu group; permutation cycle length is hardcoded to a
  constant `1`). Referencing these names does not currently import any
  additional rigor — the "full version" is, by its own admission, also
  simplified.

## Guardrails (so this doesn't drift)

1. Any claim stronger than "we observed X numerically, reproducibly, in
   implementation Y" needs either (a) an actual formal statement and proof,
   or (b) is explicitly labeled as hypothesis/analogy in code comments and
   docs — not stated as fact.
2. New comparison targets ("individuals") should be real, existing,
   independently-verifiable implementations (e.g. `ml_dtypes`, PyTorch
   ATen) rather than hand-built stand-ins for systems that can't actually
   be run and checked (e.g. nvfortran/CUDA in an environment with no GPU
   and no network access to NVIDIA's SDK).
3. `machine-epsilon` / `default-tolerance` are currently **vendored**
   (copied as literals into `src/scheme/quiver.scm`), not a live
   `chicken-install` dependency on hatsu-yakitori's `core` egg — that egg
   is not currently installable (invalid `.egg` structure, undeclared
   `srfi-1` dependency). Revisit once fixed upstream.
4. Every number quoted in a commit message, issue, or this README should
   be reproducible by running the corresponding Makefile target — no
   hand-transcribed or eyeballed figures.

## Build & test

```sh
make test-all      # builds the C23/Scheme bridge, builds the Python
                    # extension, and runs the full test suite
                    # (Scheme integration test + pytest)
```

Requires: `gcc-13`+, `cmake`, `chicken-bin`/`libchicken-dev` (+ the `srfi-4`
egg), Python 3.11+, `torch`, `numpy`, `pytest`.

## Layout

```
src/c/quiver_c23.c        C23 implementation of FP8 (E4M3) / BF16 quantization
src/scheme/quiver.scm     Chicken Scheme driver: register machine, shuffle/
                          stuffle divergence experiment, constant harvesting
python/quiver_sim.py      PyTorch (ATen) reference implementation
tests/test_quiver.py      pytest suite
```