# Needle 3 engine (Cactus Compute)

`Needle.xcframework` is the iOS device and simulator static library and C header of Needle 3, taken
unmodified from https://huggingface.co/Cactus-Compute/needle3 at commit
`b274efcb211a9eef48c9a88da4b43bd569696a39` (`ios-arm64/` and `ios-sim-arm64/`), Apache-2.0 (see `LICENSE`).
The app reaches `needle.h` through `FoldForm/FoldForm-Bridging-Header.h` (a module map here would clash with Moonshine's).

| File | SHA-256 |
| --- | --- |
| `ios-arm64/libneedle.a` | `236aae1ab238d815217a59c5ba4ce513a2b60aba10356499893dfdbbf6b4341b` |
| `ios-sim-arm64/libneedle.a` | `02f0e6ab33ccc0addc0997f66fb5c8490d023d87516d65dd256031e097004c2c` |

The weights (`needle3.cact`, 35 MB, SHA-256 `c9d915eca282ed42d1a09b143b592adb4cc6744ffe2d294adf5cfc5548170c38`)
are not in the repository. The app downloads them once, on first use of voice control, and checks that hash.
