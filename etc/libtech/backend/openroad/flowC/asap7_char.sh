#!/usr/bin/env bash
# PDK plugin: asap7 (process corners BC / TC / WC).
#
# Sourced by the characterization launch.sh. Context (dynamic scope from
# run_orfs_backend): TECHNODE, CHAR_CORNER, PLATFORM, WORK_DIR, DESIGN_NAME,
# FLOW_VARIANT, config_mk, run_orfs_make_cmd, and the ladder_*/config_* helpers.
#
# IMPORTANT: asap7's Liberty time unit is 1ps. The SDC clock period is written in
# PICOSECONDS, and timing slacks come back in ps -> converted to ns for the XML.
# This is PDK-owned on purpose -- nothing here is shared/generalized.

# --- corner ---------------------------------------------------------------
# Forward the Bambu device speed_grade (BC/TC/WC) to the ORFS CORNER variable
# (asap7/config.mk defaults to "CORNER ?= BC"; without this TC/WC silently use BC).
pdk_corner_env() {
   case "${CHAR_CORNER}" in
      BC|TC|WC) echo "CORNER=${CHAR_CORNER}" ;;
      *)        : ;;
   esac
}

# --- config.mk policy -----------------------------------------------------
# Drop cell-pad + FP_CORE_SPACE, PLACE_DENSITY_LB_ADDON=0.20, keep PLACE_DENSITY
# at the device default (0.60), and start the ladder at CORE_UTILIZATION=85.
pdk_config_mk_extra() {
   ladder_config_common "$1" 0.60 0.20 85
}

# --- escalation ladder ----------------------------------------------------
# CORE_UTILIZATION 85 -> 10 (step -5).
pdk_run_flow() {
   run_core_util_ladder 85 80 75 70 65 60 55 50 45 40 35 30 25 20 15 10
}

# --- SDC (constraints.sdc) ------------------------------------------------
# asap7 Liberty unit = ps, so write the clock period using bambu's ps value
# (target@period_ps). OpenROAD applies it as picoseconds (correct).
pdk_write_sdc() {
   local sdc="$1" period clk ext
   period="$(bambu_results /application/target@period_ps)"          # picoseconds
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
# slack/fallback math uses ps->ns because asap7 ORFS slacks are in picoseconds.
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
ws    = num(["finish__timing__setup__ws", "finish__timing__setup__wns"])  # asap7: PICOSECONDS
SENT = 1.0e30
delay = slack = freq = None
if fmax and fmax > 0.0:
    delay = 1.0e9 / fmax              # fmax in Hz -> period in ns (unit-safe)
    freq  = fmax / 1.0e6             # MHz
    slack = required_ns - delay
elif ws is not None and abs(ws) < SENT:
    ws_ns = ws / 1000.0             # asap7 ps -> ns
    delay = required_ns - ws_ns
    slack = ws_ns
    freq  = 1000.0 / delay if delay else 0.0
if None in (area, power, delay, slack, freq):
    sys.stderr.write("ERROR: missing ORFS metrics for backend XML (asap7)\n"); sys.exit(1)
out.parent.mkdir(parents=True, exist_ok=True)
root = ET.Element("application")
ET.SubElement(root, "resources", AREA=f"{area:g}", BRAMS="0", DRAMS="0",
              CLOCK_SLACK=f"{slack:g}", DSPS="0", FREQUENCY=f"{freq:g}",
              PERIOD=f"{delay:g}", REGISTERS="0", POWER=f"{power:g}",
              DELAY=f"{delay:g}", SLACK=f"{slack:g}")
ET.ElementTree(root).write(out, encoding="utf-8", xml_declaration=True)
PY
}
