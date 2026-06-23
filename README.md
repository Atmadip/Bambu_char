# Bambu_char — Multi-PDK Device Characterization for PandA-bambu

This is [PandA-bambu](https://github.com/ferrandi/PandA-bambu) extended with a
multi-PDK device-characterization backend driven by
[OpenROAD-flow-scripts](https://github.com/The-OpenROAD-Project/OpenROAD-flow-scripts).
It characterizes bambu's functional units (operators, memories) on real ASIC
PDKs — **asap7** (BC/TC/WC corners), **nangate45**, **sky130hd** — and emits the
technology library bambu consumes during HLS.

Clone recursively (pulls the ORFS submodule and bambu's own submodules):

```bash
git clone --recursive https://github.com/Atmadip/Bambu_char.git
# or, if already cloned:
git submodule update --init --recursive
```

---

## Step 1 — Install bambu

Build and install PandA-bambu the usual way; this also builds `eucalyptus`, the
characterization driver. Follow the upstream instructions:
**[PandA-bambu README →](https://github.com/ferrandi/PandA-bambu#how-to-build-panda)**

After installing, put the tools on your `PATH`:

```bash
source <install-prefix>/settings.sh   # provides `bambu` and `eucalyptus`
```

---

## Step 2 — Build the ORFS Docker image

The backend runs OpenROAD + Yosys inside a Docker image tagged
`orfs_bambu:latest`. ORFS is vendored as a submodule at
`external/OpenROAD-flow-scripts` (pinned to a known-good commit). Build it and
tag the result (see the
[OpenROAD-flow-scripts repo](https://github.com/The-OpenROAD-Project/OpenROAD-flow-scripts)
for prerequisites):

```bash
cd external/OpenROAD-flow-scripts
./build_openroad.sh --threads <N>
docker tag \
  "$(docker images --format '{{.Repository}}:{{.Tag}}' \
       | grep '^openroad/flow-ubuntu22.04-builder:' | head -1)" \
  orfs_bambu:latest
```

---

## Step 3 — Run characterization

Entry point: **`etc/libtech/characterize_device.sh`** — it wraps
`etc/scripts/characterize.py`, auto-collecting the `C_*_IPs.xml` technology
libraries. You pick the target with `--devices`, the output dir with `-o`, and
parallelism with `-j`. (Make sure `eucalyptus` is on `PATH` — see Step 1.)

**Target devices / corners** (`--devices=`):

| `--devices` | PDK / corner             |
| ----------- | ------------------------ |
| `asap7-BC`  | asap7, best-case (fast)  |
| `asap7-TC`  | asap7, typical           |
| `asap7-WC`  | asap7, worst-case (slow) |
| `nangate45` | nangate45 (single corner)|
| `sky130hd`  | sky130hd                 |

**Run one device/corner:**

```bash
./etc/libtech/characterize_device.sh --devices=asap7-TC -o char_asap7_TC -j 8
```

**Resume an interrupted run** (picks up per-module ladder checkpoints under
`<out>/.ladder_state`, does not redo finished modules):

```bash
./etc/libtech/characterize_device.sh --devices=asap7-TC -o char_asap7_TC -j 8 --restart
```

**Run all three asap7 corners in parallel** (separate terminals + output dirs):

```bash
./etc/libtech/characterize_device.sh --devices=asap7-BC -o char_asap7_BC -j 8
./etc/libtech/characterize_device.sh --devices=asap7-TC -o char_asap7_TC -j 8
./etc/libtech/characterize_device.sh --devices=asap7-WC -o char_asap7_WC -j 8
```

**Options:**

| Option | Meaning |
| ------ | ------- |
| `--devices=<dev>` | Target device/corner (see table). Selects `<dev>-seed.xml`. |
| `-o <dir>` | Output directory — use one per device/corner. |
| `-j <N>` | Parallel jobs. Each job launches an `orfs_bambu` container, so keep `N` well below your core count (P&R is CPU-heavy). |
| `--restart` | Resume from where a previous run stopped. First run must omit it (and the output dir must not already exist). |
| `-t <time>` | Per-module timeout (default `75m`). |
| `--update=<c1,c2,...>` | Characterize only the named components instead of the full set. |
| `--list-only=<file>` | Only generate the work list, then exit. **Note:** this is the Python enumerator and mis-names non-scalar FUs — prefer `eucalyptus --generate-list` (below). |
| `--from-list=<file>` | Run from a previously generated work list. |

### Generate the module list with `eucalyptus --generate-list`

`characterize.py`'s `--list-only` enumerates names in Python and **mis-names
non-scalar FUs** (vectors, `MUX2_GATE`, floating-point): it ignores each FU's
`portsize_parameters` and port structure, so it emits names like
`vec_mul_node_FU_1_1_1` or `MUX2_GATE_0_1_1` that fail characterization with
*"<name> is not in any technology library."*

Use **`eucalyptus --generate-list`** instead. It runs bambu's own C++ enumerator
(`FunctionalUnitStep::AnalyzeFu` — the same code the characterizer uses), so
every emitted name is guaranteed buildable (correct lane-pair vectors, the MUX
`sel` port, FP only at 32/64, etc.). It prints one `FU_LIST <template>-<instance>`
line per component and runs **no backend**:

```bash
source <install-prefix>/settings.sh   # eucalyptus needs BAMBU_HLS in the env
eucalyptus --target-datafile=etc/libtech/asic/sky130hd-seed.xml --generate-list \
    2>/dev/null | sed -n 's/^FU_LIST //p' | sort -u > names.txt
```

The list is device-independent (any `*-seed.xml` yields the same names), so pass
whichever seed you will characterize against. Optional `--list-library=<name>`
restricts the dump to a single library (default: all).

Wrap the names into `--from-list` lines and run the backend as usual:

```bash
SEED=etc/libtech/asic/sky130hd-seed.xml
eucalyptus --target-datafile="$SEED" --generate-list 2>/dev/null \
  | sed -n 's/^FU_LIST //p' | sort -u \
  | awk -v s="$SEED" '{print "--target-datafile="s" --characterize="$0" --benchmark-name="$0" --configuration-name=sky130hd"}' \
  > from_list.txt
python3 etc/scripts/characterize.py --from-list from_list.txt -o char_sky130hd -j 8
```

**Outputs:**

- `<out>/<device>.xml` — the technology library bambu reads during HLS.
- `<out>/.ladder_state/successful_utilizations.xml` — the `CORE_UTILIZATION`
  the escalation ladder succeeded at, per module (reused on `--restart`).
- Pre-characterized asap7 BC/TC/WC caches ship under
  `etc/libtech/backend/openroad/flowC/characterization_results/`.

### How the PDK/corner flow works

`etc/libtech/backend/openroad/flowC/launch.sh` detects the `PLATFORM`, forwards
the process corner (BC/TC/WC → ORFS `CORNER`), and runs a resumable
`CORE_UTILIZATION` escalation ladder: it lowers utilization on routing/placement
congestion and stops (resumably) on any other error. Per-PDK policy and ladder
bounds live in the plugins sourced by `launch.sh`:
`etc/libtech/backend/openroad/flowC/{asap7,nangate45,sky130hd}_char.sh`.

The ladder's **starting utilization** can be overridden per-run with the
`LADDER_START_UTIL` environment variable — it filters the ladder to rungs `<=`
the given value, so the run begins at that utilization and steps down from there.
This is handy for re-running known-hard modules whose winning utilization band is
already known (e.g. `LADDER_START_UTIL=35` for 64-bit dividers), without changing
the plugin's default ladder.
