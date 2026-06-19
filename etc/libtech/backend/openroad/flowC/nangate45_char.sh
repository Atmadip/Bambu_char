#!/usr/bin/env bash
# PDK plugin: nangate45 (single typical corner; no CORNER selection in ORFS).
#
# Sourced by the characterization launch.sh. Same config/ladder pattern as asap7,
# with nangate45-specific values.
#
# IMPORTANT: nangate45's Liberty time unit is 1ns. The SDC clock period is written
# in NANOSECONDS, and ORFS timing slacks come back in ns. This is PDK-owned on
# purpose -- nothing here is shared/generalized.

# nangate45 has no process-corner variants -> nothing to forward.
pdk_corner_env() { :; }

# --- config.mk policy -----------------------------------------------------
# Drop cell-pad + FP_CORE_SPACE, PLACE_DENSITY_LB_ADDON=0.20, PLACE_DENSITY=0.40,
# and start the ladder at CORE_UTILIZATION=70.
pdk_config_mk_extra() {
   ladder_config_common "$1" 0.40 0.20 70
}

# --- escalation ladder ----------------------------------------------------
# CORE_UTILIZATION 70 (max) -> 10 (step -5).
pdk_run_flow() {
   run_core_util_ladder 70 65 60 55 50 45 40 35 30 25 20 15 10
}

# --- SDC (constraints.sdc) ------------------------------------------------
# nangate45 Liberty unit = ns, so write the clock period using bambu's ns value
# (target@period). OpenROAD applies it as nanoseconds (correct).
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
# slack/fallback math uses ns directly because nangate45 ORFS slacks are in ns.
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
ws    = num(["finish__timing__setup__ws", "finish__timing__setup__wns"])  # nangate45: NANOSECONDS
SENT = 1.0e30
delay = slack = freq = None
if fmax and fmax > 0.0:
    delay = 1.0e9 / fmax              # fmax in Hz -> period in ns (unit-safe)
    freq  = fmax / 1.0e6             # MHz
    slack = required_ns - delay
elif ws is not None and abs(ws) < SENT:
    ws_ns = ws                       # nangate45 slacks already in ns
    delay = required_ns - ws_ns
    slack = ws_ns
    freq  = 1000.0 / delay if delay else 0.0
if None in (area, power, delay, slack, freq):
    sys.stderr.write("ERROR: missing ORFS metrics for backend XML (nangate45)\n"); sys.exit(1)
out.parent.mkdir(parents=True, exist_ok=True)
root = ET.Element("application")
ET.SubElement(root, "resources", AREA=f"{area:g}", BRAMS="0", DRAMS="0",
              CLOCK_SLACK=f"{slack:g}", DSPS="0", FREQUENCY=f"{freq:g}",
              PERIOD=f"{delay:g}", REGISTERS="0", POWER=f"{power:g}",
              DELAY=f"{delay:g}", SLACK=f"{slack:g}")
ET.ElementTree(root).write(out, encoding="utf-8", xml_declaration=True)
PY
}
