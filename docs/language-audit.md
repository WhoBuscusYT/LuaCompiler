# Lua-first source audit — 2026-10-23

Lua is the majority of original LuaCompiler code. After this audit's changes,
Lua accounts for **58.65% of all original code lines** and **59.97% of product
code lines**. No original C++ translation units were found. The native launcher
and platform bindings remain honestly classified as C.

These are source measurements, not performance claims or live GitHub language
statistics. The project directory was not a Git repository during the audit.
No repository was initialized there, and nothing was published.

## Method and scope

The before snapshot was frozen at `2026-10-23T22:07:12.914216Z`; the final source
snapshot at `2026-10-23T22:13:28.241791Z`. Each inventory records relative paths,
file sizes and SHA-256 hashes. These are audit snapshots, **not release
manifests**: the native executable was rebuilt after the source freeze, so
snapshot binary hashes must not be used to verify the final package. Source
hashes were checked again against the final tree. Source copies were counted with **cloc 2.10**,
using `--by-file --json --skip-uniqueness --timeout 0`. Identical source files are
counted at every shipped path. cloc separates code lines from comments and blank
lines; the tables below use its `code` counts. Full-file byte counts are reported
separately. [cloc methodology](https://github.com/AlDanial/cloc/blob/v2.10/README.md)

The same scope rules apply before and after:

- **Original product:** root compiler/installer/command sources, `runtime/lc/`,
  `native/launcher.c`, `native/graphics.c`, `native/ui.c`, native headers and
  `native/bootstrap.lua`.
- **Original support:** tests, examples, tools and native build scripts.
- **All original:** product plus support. Python and PowerShell count honestly
  alongside Lua, C, GLSL and the command wrapper.
- **Vendored:** `native/lua-5.4.9/`, `third_party/`, `runtime/moonvulkan/` and the
  reserved `native/third_party/` location.
- Build directories, Python caches, nested Git metadata, binaries, assets and
  prose documentation are excluded from source-code totals.

The external audit utilities were kept outside the project and are absent from
both original-code denominators. Added test code is visible in the support
scope; it cannot inflate the product-only result.

cloc reports C and C++ headers together as **C/C++ Header**, including `.h` and
`.hpp` files. This report preserves that category instead of arbitrarily
assigning every header to C or C++. C/C++ rows describe translation units.

## All original code: primary comparison

Every percentage in this table divides by **all original code lines**, including
other languages. Percentages may differ slightly when rounded.

| Language | Before code lines | Before share | After code lines | After share |
| --- | ---: | ---: | ---: | ---: |
| Lua | 2,860 | 58.65% | 2,895 | 58.65% |
| C | 1,326 | 27.19% | 1,313 | 26.60% |
| C++ | 0 | 0.00% | 0 | 0.00% |
| C/C++ Header | 5 | 0.10% | 5 | 0.10% |
| Other languages | 685 | 14.05% | 723 | 14.65% |
| **Total** | **4,876** | **100%** | **4,936** | **100%** |

Afterward, other languages comprise Python **580** lines, PowerShell **127**,
GLSL **13**, and DOS Batch **3**. No original native implementation was marked
vendored, generated, undetectable, or forced to Lua to obtain these results.

## Product-only code

Tests, examples and development tools are excluded from this table.

| Language | Before code lines | Before share | After code lines | After share |
| --- | ---: | ---: | ---: | ---: |
| Lua | 1,928 | 59.47% | 1,949 | 59.97% |
| C | 1,293 | 39.88% | 1,280 | 39.38% |
| C++ | 0 | 0.00% | 0 | 0.00% |
| C/C++ Header | 5 | 0.15% | 5 | 0.15% |
| Other languages | 16 | 0.49% | 16 | 0.49% |
| **Total** | **3,242** | **100%** | **3,250** | **100%** |

The product change is modest and real: module-search policy moved into
`native/bootstrap.lua`, while C retains validated bundle access, Lua loading and
native platform work. The C reduction is partly offset by additional native
validation. This audit did not reformat native files or add filler Lua to change
the ratio.

## Byte measurements and GitHub's language bar

GitHub Linguist calculates its language bar using **bytes**, not code-line
counts. It also applies language detection and excludes vendored, generated,
binary and documentation content. Therefore the local byte shares below are
useful context, but are **not an exact prediction of GitHub's result**.
[How Linguist works](https://github.com/github-linguist/linguist/blob/main/docs/how-linguist-works.md)

| Scope/language | Before bytes | Before share | After bytes | After share |
| --- | ---: | ---: | ---: | ---: |
| Product Lua | 102,147 | 63.31% | 103,098 | 63.66% |
| Product C | 58,558 | 36.29% | 58,214 | 35.94% |
| Product C++ | 0 | 0.00% | 0 | 0.00% |
| Product headers | 107 | 0.07% | 107 | 0.07% |
| Product other | 543 | 0.34% | 543 | 0.34% |
| **Product total** | **161,355** | **100%** | **161,962** | **100%** |
| All-original Lua | 158,042 | 59.28% | 159,888 | 58.54% |
| All-original C | 60,309 | 22.62% | 59,965 | 21.95% |
| All-original C++ | 0 | 0.00% | 0 | 0.00% |
| All-original headers | 107 | 0.04% | 107 | 0.04% |
| All-original other | 48,143 | 18.06% | 53,181 | 19.47% |
| **All-original total** | **266,601** | **100%** | **273,141** | **100%** |

The all-original Lua byte share **decreased** because regression tests and build
support also grew. This is reported rather than hidden. A ratio alone is not a
measure of architecture quality.

Ruby/GitHub Linguist was not available in this environment, so an actual
`github-linguist` repository analysis was **not** run. cloc and independent Git
attribute checks were executed; they are different tools with different jobs.

## Vendored source: separate and unchanged

All **2,496 vendored files** were compared by SHA-256 between snapshots. None
were added, removed or changed during this audit. This establishes equality to
the audit baseline, not a claim that every dependency is pristine upstream
source; existing documented portability patches predate this audit.

The measured vendor-source totals below are identical before and after.

| Language | Files | Bytes | Code lines | Code-line share |
| --- | ---: | ---: | ---: | ---: |
| Lua | 40 | 581,879 | 10,406 | 1.16% |
| C | 778 | 16,942,637 | 368,797 | 41.10% |
| C++ | 45 | 2,478,519 | 53,778 | 5.99% |
| C/C++ Header | 763 | 29,300,091 | 414,961 | 46.25% |
| Other measured languages | 267 | 2,351,090 | 49,266 | 5.49% |
| **Total** | **1,893** | **51,654,216** | **897,208** | **100%** |

| Dependency tree | Measured source bytes | Code lines |
| --- | ---: | ---: |
| `native/lua-5.4.9/` | 889,136 | 20,357 |
| `runtime/moonvulkan/` | 3,921 | 57 |
| `third_party/moonvulkan/` | 17,803,255 | 282,250 |
| `third_party/SDL/` | 32,957,904 | 594,544 |

The vendor tree also contains **13 source-like support files totaling 80,167
bytes** that cloc did not classify: SDL's Coccinelle migration script, two
templates, platform-named Makefiles and two MASM sources. They remain in the
hash inventory and are explicitly listed as `unclassified` in the raw metrics;
they are excluded from the vendor percentage denominator. Every original source
file was classified. Documentation, IDE metadata, binary assets and generated
build products are outside these measured source totals.

## Attribute and ignore verification

The four existing vendor prefixes remain `linguist-vendored`. Changes add
`linguist-generated` only to `native/build/**` and `examples/**/build/**`, and
ignore Python bytecode/cache files. Native `.c` files and the new original Lua
bootstrap have no language override or exclusion attribute.

An isolated temporary Git repository, outside the actual project, was used to
run `git check-attr` and `git check-ignore`. **3,008 real/probe paths passed**:
vendor files matched their expected attribute, original source had no explicit
Linguist exclusion/override, and build/cache artifacts matched the intended
rules. The before audit found one unignored Python cache; the new ignore rule
covers it. No original code was removed to make the percentage larger.
[Linguist attribute semantics](https://github.com/github-linguist/linguist/blob/main/docs/overrides.md)

The local MoonVulkan checkout contains nested Git metadata. That metadata is
excluded from source measurements and release packaging. A future repository
import should deliberately choose vendored files or a submodule; this audit
does not change that checkout or publish it.

## Reproduction and evidence

The audit evidence archive contains:

- `audit_metrics.py`: snapshots files and aggregates source scopes from cloc.
- `verify_attributes.py`: checks attributes in an isolated Git repository.
- Before/final file inventories with SHA-256, per-file CSVs and cloc JSON.
- Before/final language summaries and a vendor/source comparison report.
- Attribute-check reports and the cloc download URL/version/SHA-256.

The metrics script is Python because it is development analysis tooling; it was
not rewritten in Lua to improve the project's measured language mix. It adds no
application runtime dependency.

To repeat the measurement, create a fresh snapshot with `audit_metrics.py
snapshot`, run cloc on its `<label>-source` directory, then run `audit_metrics.py
measure` with the same label. Run cloc from the audit directory with relative
paths when using Git for Windows Perl, so its JSON paths remain portable. The
source selection and category rules are explicit in the script, and all
unclassified candidates are reported.

## Implementation decisions

The justified transfer is bundled module resolution and package search policy.
`native/bootstrap.lua` selects preload/file/directory-init search behavior and
disables implicit disk/DLL searches. It is embedded in the launcher template,
so default console builds do not need `Runtime.lcb` or a project bootstrap.
The bootstrap captures its standard-library helpers so application assignments
to globals do not break behavior that previously lived in C.

`native/launcher.c` retains a private loader that compiles directly from mapped,
validated bundle bytes. Module contents are not copied through `lcb.read`.
Bounds, SHA-256, Windows path conversion, argument conversion, entry setup and
native handle lifetimes remain native. Raw template probes now syntax-check the
embedded bootstrap before a rebuilt template can replace the previous one.

The Win32 menu bridge, window procedures, SDL event marshalling and Vulkan
bindings were retained. Their Lua wrappers already own callbacks, menu validation,
input state, game loops, scenes, cameras, assets and render orchestration. Moving
platform enum mappings or low-level handle operations would add interface churn
without a useful architectural improvement. No rendering hot-path algorithm
was moved for language statistics.

A separate correctness fix in `native/graphics.c` validates Lua's full integer
range before converting window dimensions to C integers. Large values that
previously wrapped into valid sizes are now rejected.

Changed source/configuration files: `native/bootstrap.lua`, `native/launcher.c`,
`native/build.ps1`, `native/graphics.c`, `tests/standalone.py`,
`tests/vulkan_failures.lua`, `.gitattributes`, `.gitignore`, `README.md`,
`native/README.md`, and this report. `Launcher.exe`, its checksum sidecar and
`SHA256SUMS` were rebuilt. The regenerated `Runtime.lcb` is byte-identical to
the baseline. No dependency source was changed.

## Executed validation

All existing test suites were executed. The final template passed the following
checks; the pure Lua/archive and native UI/GPU suites exercised the same unchanged
Lua sources and final native binding sources independently.

| Suite | Result |
| --- | --- |
| `tests/run.lua` | 254 checks passed; packaging, CLI, offline/update failures |
| `tests/recovery.lua` | Passed; failed rollback blocks builds and restores all 14 components |
| `tests/standalone.py` | 201 checks passed, zero skipped |
| `tests/runtime.lua` | 98 checks passed |
| `tests/engine.lua` | 164 checks passed; engine tests use a mock renderer |
| `tests/runtime_update.lua` | 119 checks passed in isolated installations |
| `tests/ui.lua` | 34 real Win32 UI checks passed |
| `tests/desktop.py` | 58 checks passed, including real Vulkan 2D/3D frames |
| `tests/vulkan_failures.lua` | 43 checks passed, including 33 added dimension guards |
| `tests/vulkan.lua` | Actual GPU rendering, resize and capture passed |
| `tests/vulkan_platform.lua` | Minimize, restore and blur checks passed |
| Isolated invalid-bootstrap native build | Failed as intended; old launcher and sidecar bytes preserved |

This is **971 counted checks**, plus the recovery, GPU smoke/platform and native
build-preservation scenarios. The final native sources compiled with MSVC
`/W4 /WX`, static Lua/SDL3/MoonVulkan and `/MT`. Dependency compilation reused
the already-built static SDL library; graphics and launcher bindings were rebuilt.

ConsoleDemo, NativeUI, Vulkan2D and Vulkan3D were rebuilt and each copied to an
isolated directory with only Windows System32 on PATH. All four validated and
exited successfully; the three desktop apps had the GUI subsystem, and ConsoleDemo
had the console subsystem. Their launcher bytes matched the final template,
apart from the intended PE subsystem field. GPU frame captures were inspected:
the 2D scene shows a checker texture and overlapping colored shapes, and the 3D
scene shows textured/lit cubes and a floor.

An already-running `examples/Vulkan2D/build/Vulkan2D.exe` was left alone.
Windows refused replacement, preserving that executable. The current example
was built and tested as `Vulkan2D-Audited.exe`; the new name avoids interrupting
the existing application.

The audit also measured 3,000 distinct embedded modules (about 1.5 MiB of source),
with two warmups and ten alternating samples per template. Median module CPU
time was **14.5 ms before, 17.0 ms after**; total process time was **41.49 ms
before, 43.05 ms after**. This small startup cost is disclosed rather than
claimed to be zero. The workload ran on this machine alongside test activity;
it is not a general benchmark or an FPS guarantee. Asset loading and rendering
implementation were not moved or copied to improve the language ratio.

Limitations: a clean Windows VM and other GPU vendors were not tested. The real
GPU runs used Intel Arc A380 driver `32.0.101.9034`. The Khronos Vulkan validation
layer is not installed; the explicit unavailable-layer error was tested, but a
validation-layer run was not possible. No live GitHub update, publication or
actual GitHub Linguist execution was performed. The nested MoonVulkan Git
metadata remains excluded from packaging; choose a deliberate vendor/submodule
strategy before importing this folder into a Git repository.
