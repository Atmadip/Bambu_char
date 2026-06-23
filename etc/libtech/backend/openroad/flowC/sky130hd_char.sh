#!/usr/bin/env bash
# PDK plugin: sky130hd (SkyWater 130 nm high-density).
#
# Sourced by the characterization launch.sh. Like nangate45, ORFS ships sky130hd
# with a single (typical) corner -> no CORNER forwarding. Memory is synthesized
# generically (no SRAM macros wired in), so this mirrors the nangate45 policy.
#
# IMPORTANT: sky130hd's Liberty time unit is 1ns. The SDC clock period is written
# in NANOSECONDS, and ORFS timing slacks come back in ns. This is PDK-owned on
# purpose -- nothing here is shared/generalized.

# sky130hd has a single corner -> nothing to forward.
pdk_corner_env() { :; }

# --- config.mk policy -----------------------------------------------------
# By default use sky130hd's own config.mk defaults; CORE_UTILIZATION is the only
# knob, driven by the ladder below.
#
# Optional fixed-die override (env CHAR_FIXED_DIE_UM=<um>): set an absolute
# DIE_AREA/CORE_AREA so ORFS sizes the die by coordinates instead of utilization.
# Needed for very small (e.g. 1-bit) cells whose util-driven die is too narrow
# for the PDN strap grid (needs ~29um core width); lowering util cannot help once
# the die hits its minimum size. Unset = unchanged (util ladder owns sizing).
pdk_config_mk_extra() {
   local cfg="$1"
   if [[ -n "${CHAR_FIXED_DIE_UM:-}" ]]; then
      local die="${CHAR_FIXED_DIE_UM}" m=4 hi
      hi=$(( die - m ))
      config_set_var "$cfg" DIE_AREA  "0 0 ${die} ${die}"
      config_set_var "$cfg" CORE_AREA "${m} ${m} ${hi} ${hi}"
      # DIE_AREA/CORE_AREA and CORE_UTILIZATION are mutually exclusive in ORFS
      # floorplan init -> strip any CORE_UTILIZATION (e.g. from the device seed).
      sed -i -E '/^[[:space:]]*export[[:space:]]+CORE_UTILIZATION[[:space:]]*=/d' "$cfg"
      echo "[char] CHAR_FIXED_DIE_UM=${die} -> DIE_AREA=0 0 ${die} ${die}, CORE_AREA=${m} ${m} ${hi} ${hi} (fixed die; ladder bypassed; CORE_UTILIZATION stripped)"
   fi
}

# --- escalation ladder ----------------------------------------------------
# CORE_UTILIZATION 70 -> 2 (step -5, plus low 5/2 rungs for tiny cells).
# With CHAR_FIXED_DIE_UM set, the die is fixed by coordinates -> skip the ladder
# and run the flow once.
pdk_run_flow() {
   if [[ -n "${CHAR_FIXED_DIE_UM:-}" ]]; then
      run_orfs_make_cmd
      return $?
   fi
   run_core_util_ladder 70 65 60 55 50 45 40 35 30 25 20 15 10 5 2
}

# --- SDC (constraints.sdc) ------------------------------------------------
# sky130hd Liberty unit = ns, so write the clock period using bambu's ns value
# (target@period). OpenROAD applies it as nanoseconds (correct). bambu's intended
# characterization target is 10 ps == 0.01 ns -> aggressive clock, as designed.
pdk_write_sdc() {
   local sdc="$1" period clk ext
   period="$(bambu_results /application/target@period)"             # nanoseconds
   clk="$(bambu_results /application/top_module@clock_name)"
   if $(bambu_results /application/top_module@combinational); then
      echo "set_max_delay ${period} -from [all_inputs] -to [all_outputs]" > "${sdc}"
   else
      echo "create_clock ${clk} -period ${period}" > "${sdc}"
   fi
   ext="$(bambu_results /application/target@sdc_ext_file)"
   [[ -n "${ext}" ]] && echo "source ${ext}" >> "${sdc}"
}

# --- delay / area read-back -----------------------------------------------
# Delay comes from fmax (Hz, OpenSTA-internal seconds -> unit-safe). The
# slack/fallback math uses ns directly because sky130hd ORFS slacks are in ns.
pdk_extract_metrics() {
   local meta="$1" out="$2" period_ps
   period_ps="$(bambu_results /application/target@period_ps)"       # ALWAYS picoseconds (10)
   python3 - "${meta}" "${out}" "${period_ps}" <<'PY'
import json, re, sys, pathlib, xml.etree.ElementTree as ET
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
out  = pathlib.Path(sys.argv[2])
required_ns = float(sys.argv[3]) / 1000.0   # ps -> ns (10 ps characterization target)
def num(keys):
    for k in keys:
        v = data.get(k)
        if isinstance(v, (int, float)): return float(v)
        if isinstance(v, str):
            m = re.search(r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?", v)
            if m: return float(m.group(0))
    return None
area  = num(["finish__design__instance__area", "finish__design__instance__area__stdcell"])
power = num(["finish__power__total", "finish__power__internal__total"])
fmax  = num(["finish__timing__fmax", "placeopt__timing__fmax", "globalroute__timing__fmax",
             "detailedplace__timing__fmax", "cts__timing__fmax"])
ws    = num(["finish__timing__setup__ws", "finish__timing__setup__wns"])  # sky130hd: NANOSECONDS
SENT = 1.0e30
delay = slack = freq = None
if fmax and fmax > 0.0:
    delay = 1.0e9 / fmax              # fmax in Hz -> period in ns (unit-safe)
    freq  = fmax / 1.0e6             # MHz
    slack = required_ns - delay
elif ws is not None and abs(ws) < SENT:
    ws_ns = ws                       # sky130hd slacks already in ns
    delay = required_ns - ws_ns
    slack = ws_ns
    freq  = 1000.0 / delay if delay else 0.0
if None in (area, power, delay, slack, freq):
    sys.stderr.write("ERROR: missing ORFS metrics for backend XML (sky130hd)\n"); sys.exit(1)
out.parent.mkdir(parents=True, exist_ok=True)
root = ET.Element("application")
ET.SubElement(root, "resources", AREA=f"{area:g}", BRAMS="0", DRAMS="0",
              CLOCK_SLACK=f"{slack:g}", DSPS="0", FREQUENCY=f"{freq:g}",
              PERIOD=f"{delay:g}", REGISTERS="0", POWER=f"{power:g}",
              DELAY=f"{delay:g}", SLACK=f"{slack:g}")
ET.ElementTree(root).write(out, encoding="utf-8", xml_declaration=True)
PY
}
