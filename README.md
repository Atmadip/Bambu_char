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

`source <install-prefix>/settings.sh` first (puts `eucalyptus` on `PATH`).
Targets (`--devices=`): `asap7-BC`, `asap7-TC`, `asap7-WC`, `nangate45`, `sky130hd`.

```bash
# Characterize one device/corner (full set). -o: out dir, -j: parallel jobs.
./etc/libtech/characterize_device.sh --devices=sky130hd -o char_sky130hd -j 8

# Resume an interrupted run (skips finished modules via <out>/.ladder_state).
./etc/libtech/characterize_device.sh --devices=sky130hd -o char_sky130hd -j 8 --restart

# Characterize only named components.
./etc/libtech/characterize_device.sh --devices=sky130hd -o char_sky130hd -j 8 --update=c1,c2
```

Flags: `-t <time>` per-module timeout (default `75m`); `--from-list=<file>` run a
prewritten work list; `LADDER_START_UTIL=<N>` start the util ladder at `<N>` (≤N rungs).

### Generate a correct module list — `eucalyptus --generate-list`

`characterize.py --list-only` mis-names non-scalar FUs (vectors, `MUX2_GATE`, FP).
Use `eucalyptus --generate-list`: bambu's own C++ enumerator, every name buildable.

```bash
SEED=etc/libtech/asic/sky130hd-seed.xml   # device-independent; any seed gives same names

# Dump every characterizable name (one per line). --list-library=<lib> narrows it.
eucalyptus --target-datafile="$SEED" --generate-list 2>/dev/null | sed -n 's/^FU_LIST //p' | sort -u > names.txt

# Wrap into a work list and run the backend.
awk -v s="$SEED" '{print "--target-datafile="s" --characterize="$0" --benchmark-name="$0" --configuration-name=sky130hd"}' names.txt > from_list.txt
python3 etc/scripts/characterize.py --from-list from_list.txt -o char_sky130hd -j 8
```

**Outputs:** `<out>/<device>.xml` (tech library bambu reads at HLS);
`<out>/.ladder_state/successful_utilizations.xml` (winning `CORE_UTILIZATION` per
module, reused on `--restart`).
