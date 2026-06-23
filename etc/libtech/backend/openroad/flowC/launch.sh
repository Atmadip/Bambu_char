#!/usr/bin/env bash
SWD="$(dirname "$(readlink -e "$0")")"
OUT_LVL="$(bambu_results /application@verbosity)"
ORFS_DEFAULT_PINNED_DIGEST="a2bb042b6ea0811b4a63b6be41dcac5dc49e72f8"
ORFS_REQUIRED_DIGEST="${OPENROAD_ORFS_PINNED_DIGEST:-${ORFS_DEFAULT_PINNED_DIGEST}}"
ORFS_REPO_URL="https://github.com/The-OpenROAD-Project/OpenROAD-flow-scripts.git"
ORFS_DEFAULT_MODULES_TO_KEEP_AND_RETIME="mul_node_FU widen_mul_node_FU ui_widen_mul_node_FU ui_mul_node_FU"

detect_host_cores()
{
   nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1
}

resolve_num_cores()
{
   : "${ENABLE_PARALLEL:=$(bambu_results /application/backend@parallel)}"
   export ENABLE_PARALLEL

   if [[ -z "${NUM_CORES:-}" ]]; then
      if [[ "${ENABLE_PARALLEL}" =~ ^[0-9]+$ ]]; then
         if [[ "${ENABLE_PARALLEL}" -gt 1 ]]; then
            NUM_CORES="${ENABLE_PARALLEL}"
         else
            NUM_CORES=1
         fi
      elif [[ "${ENABLE_PARALLEL}" == "true" || "${ENABLE_PARALLEL}" == "TRUE" ]]; then
         NUM_CORES="$(detect_host_cores)"
      else
         NUM_CORES=1
      fi
   fi
   export NUM_CORES
}

append_asap7_fakeram_assets_config()
{
   local config_mk="$1"

   case "${PLATFORM}" in
      asap7|asap7-*)
         cat >> "${config_mk}" <<'EOF'
export ADDITIONAL_LEFS         = $(PLATFORM_DIR)/lef/fakeram7_64x25.lef \
                                 $(PLATFORM_DIR)/lef/fakeram7_64x28.lef \
                                 $(PLATFORM_DIR)/lef/fakeram7_256x32.lef \
                                 $(PLATFORM_DIR)/lef/fakeram7_128x64.lef \
                                 $(PLATFORM_DIR)/lef/fakeram7_64x256.lef \
                                 $(PLATFORM_DIR)/lef/fakeram7_256x256.lef
export ADDITIONAL_LIBS         = $(PLATFORM_DIR)/lib/NLDM/fakeram7_64x25.lib \
                                 $(PLATFORM_DIR)/lib/NLDM/fakeram7_64x28.lib \
                                 $(PLATFORM_DIR)/lib/NLDM/fakeram7_256x32.lib \
                                 $(PLATFORM_DIR)/lib/NLDM/fakeram7_128x64.lib \
                                 $(PLATFORM_DIR)/lib/NLDM/fakeram7_64x256.lib \
                                 $(PLATFORM_DIR)/lib/NLDM/fakeram7_256x256.lib
EOF
         ;;
   esac
}

validate_orfs_pinned_digest()
{
   local orfs_dir="$1"
   local current_digest=""
   local dirty_status=""
   local tree_state="clean"

   if [[ ! "${ORFS_REQUIRED_DIGEST}" =~ ^[0-9a-fA-F]{40}$ ]]; then
      cat >&2 <<EOF
ERROR: invalid ORFS digest in OPENROAD_ORFS_PINNED_DIGEST.
Current value: ${ORFS_REQUIRED_DIGEST}
Please set OPENROAD_ORFS_PINNED_DIGEST to a full 40-hex git commit digest.
EOF
      exit 1
   fi

   if ! command -v git >/dev/null 2>&1; then
      cat >&2 <<EOF
ERROR: git is required to validate the pinned OpenROAD-flow-scripts digest.
Please install git and retry.
Required ORFS digest: ${ORFS_REQUIRED_DIGEST}
EOF
      exit 1
   fi

   if [[ ! -d "${orfs_dir}/.git" ]]; then
      cat >&2 <<EOF
ERROR: '${orfs_dir}' is not a git clone of OpenROAD-flow-scripts.
Bambu requires a git clone to validate the pinned ORFS digest.
Required ORFS digest: ${ORFS_REQUIRED_DIGEST}

Recovery (recommended):
  git clone --no-checkout --depth 1 ${ORFS_REPO_URL} /path/to/OpenROAD-flow-scripts
  git -C /path/to/OpenROAD-flow-scripts fetch --depth 1 origin ${ORFS_REQUIRED_DIGEST}
  git -C /path/to/OpenROAD-flow-scripts checkout --detach ${ORFS_REQUIRED_DIGEST}
  export OPENROAD_FLOW_DATA_INSTALLDIR=/path/to/OpenROAD-flow-scripts
EOF
      exit 1
   fi

   current_digest="$(git -C "${orfs_dir}" rev-parse HEAD 2>/dev/null || true)"
   if [[ -z "${current_digest}" ]]; then
      cat >&2 <<EOF
ERROR: unable to read ORFS git digest from '${orfs_dir}'.
Please verify that OPENROAD_FLOW_DATA_INSTALLDIR points to a valid ORFS git clone.
Required ORFS digest: ${ORFS_REQUIRED_DIGEST}
EOF
      exit 1
   fi

   dirty_status="$(git -C "${orfs_dir}" status --porcelain --untracked-files=no 2>/dev/null || true)"
   if [[ -n "${dirty_status}" ]]; then
      tree_state="dirty"
   fi

   if [[ "${current_digest}" != "${ORFS_REQUIRED_DIGEST}" || "${tree_state}" != "clean" ]]; then
      cat >&2 <<EOF
ERROR: OpenROAD-flow-scripts digest validation failed.
Expected ORFS digest: ${ORFS_REQUIRED_DIGEST}
Found ORFS digest:    ${current_digest}
Working tree state:   ${tree_state}

Please use the exact pinned ORFS revision and a clean tracked-file tree.

Recovery from an existing clone:
  git -C "${orfs_dir}" fetch --depth 1 origin ${ORFS_REQUIRED_DIGEST}
  git -C "${orfs_dir}" checkout --detach ${ORFS_REQUIRED_DIGEST}
  git -C "${orfs_dir}" reset --hard ${ORFS_REQUIRED_DIGEST}

Recovery from scratch:
  git clone --no-checkout --depth 1 ${ORFS_REPO_URL} /path/to/OpenROAD-flow-scripts
  git -C /path/to/OpenROAD-flow-scripts fetch --depth 1 origin ${ORFS_REQUIRED_DIGEST}
  git -C /path/to/OpenROAD-flow-scripts checkout --detach ${ORFS_REQUIRED_DIGEST}
  export OPENROAD_FLOW_DATA_INSTALLDIR=/path/to/OpenROAD-flow-scripts
EOF
      exit 1
   fi
}

is_simple_orfs_module_list()
{
   local raw="$1"
   local token=""

   if [[ -z "${raw}" ]]; then
      return 1
   fi

   for token in ${raw}; do
      if [[ "${token}" == -* ]]; then
         return 1
      fi
      if [[ ! "${token}" =~ ^[[:alnum:]_.$\\]+$ ]]; then
         return 1
      fi
   done

   return 0
}

resolve_orfs_module_names()
{
   local rtlil_file="$1"
   local optional_keep="$2"
   local required_keep="$3"
   local optional_retime="$4"
   local required_retime="$5"

   python3 - "${rtlil_file}" "${optional_keep}" "${required_keep}" "${optional_retime}" "${required_retime}" <<'PY'
import pathlib
import sys

rtlil_path = pathlib.Path(sys.argv[1])
optional_keep = sys.argv[2].split()
required_keep = sys.argv[3].split()
optional_retime = sys.argv[4].split()
required_retime = sys.argv[5].split()

if not rtlil_path.is_file():
   raise SystemExit(f"ERROR: canonicalized RTLIL not found: {rtlil_path}")

module_names = []
seen = set()
for line in rtlil_path.read_text(encoding="utf-8").splitlines():
   if not line.startswith("module "):
      continue
   tokens = line.split()
   if len(tokens) < 2:
      continue
   name = tokens[1]
   if name not in seen:
      seen.add(name)
      module_names.append(name)

def resolve_module_names(requested_name: str, *, required: bool) -> list[str]:
   if requested_name in seen:
      return [requested_name]

   escaped_name = "\\" + requested_name
   if escaped_name in seen:
      return [escaped_name]

   suffix = "\\" + requested_name
   matches = [module_name for module_name in module_names if module_name.endswith(suffix)]
   if matches:
      return matches
   if required:
      raise SystemExit(
         f"ERROR: unable to resolve ORFS module name '{requested_name}' in {rtlil_path}."
      )
   return []

keep_modules = []
seen_keep = set()
for requested_name, required in [(name, False) for name in optional_keep] + [(name, True) for name in required_keep]:
   for resolved in resolve_module_names(requested_name, required=required):
      if resolved not in seen_keep:
         seen_keep.add(resolved)
         keep_modules.append(resolved)

retime_modules = []
seen_retime = set()
for requested_name, required in [(name, False) for name in optional_retime] + [(name, True) for name in required_retime]:
   for resolved in resolve_module_names(requested_name, required=required):
      if resolved not in seen_retime:
         seen_retime.add(resolved)
         retime_modules.append(resolved)

# Tcl list parsing in 'foreach module $::env(SYNTH_KEEP_MODULES)' consumes one
# backslash level, so preserve RTLIL escaped identifiers by doubling '\'.
keep_value = " ".join(module_name.replace("\\", "\\\\") for module_name in keep_modules)
retime_value = " ".join(module_name.replace("\\", "\\\\") for module_name in retime_modules)

sys.stdout.write(keep_value)
sys.stdout.write("\0")
sys.stdout.write(retime_value)
PY
}

create_custom_orfs_synth_script()
{
   local source_synth_script="$1"
   local destination_synth_script="$2"

   # Exit status:
   #   0 -> a known retime block was rewritten into the per-module form (custom script written)
   #   2 -> no known retime block found (caller should skip the SYNTH_SCRIPT override and
   #        rely on the ORFS-native SYNTH_RETIME_MODULES handling)
   python3 - "${source_synth_script}" "${destination_synth_script}" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])

if not source.is_file():
   raise SystemExit(f"ERROR: ORFS synth.tcl not found: {source}")

text = source.read_text(encoding="utf-8")

# Per-module retiming (bambu intent): retime each selected module independently.
new = """if { [env_var_exists_and_non_empty SYNTH_RETIME_MODULES] } {\n  foreach module $::env(SYNTH_RETIME_MODULES) {\n    select -module $module\n    opt -fast -full\n    memory_map\n    opt -full\n    techmap\n    abc -dff -script $::env(SCRIPTS_DIR)/abc_retime.script\n    select -clear\n  }\n}\n"""

# Known upstream retime blocks across ORFS revisions:
#   - newer ORFS: list-expanding "select {*}$::env(...)"
#   - older ORFS (bambu pinned digest): single-arg "select $::env(...)"
candidates = [
   """if { [env_var_exists_and_non_empty SYNTH_RETIME_MODULES] } {\n  select {*}$::env(SYNTH_RETIME_MODULES)\n  opt -fast -full\n  memory_map\n  opt -full\n  techmap\n  abc -dff -script $::env(SCRIPTS_DIR)/abc_retime.script\n  select -clear\n}\n""",
   """if { [env_var_exists_and_non_empty SYNTH_RETIME_MODULES] } {\n  select $::env(SYNTH_RETIME_MODULES)\n  opt -fast -full\n  memory_map\n  opt -full\n  techmap\n  abc -dff -script $::env(SCRIPTS_DIR)/abc_retime.script\n  select -clear\n}\n""",
]

if new in text:
   # synth.tcl already performs per-module retiming; no override needed.
   raise SystemExit(2)

for old in candidates:
   if old in text:
      destination.parent.mkdir(parents=True, exist_ok=True)
      destination.write_text(text.replace(old, new, 1), encoding="utf-8")
      raise SystemExit(0)

# Unknown synth.tcl layout: do not abort the flow; fall back to native handling.
sys.stderr.write("WARNING: ORFS synth.tcl retime block not recognized; "
                 "skipping custom synth script.\n")
raise SystemExit(2)
PY
}

# ===========================================================================
# Characterization escalation-ladder helpers (used by PDK plugins' pdk_run_flow).
# They rely on WORK_DIR / PLATFORM / DESIGN_NAME / FLOW_VARIANT / CHAR_CORNER being
# set by run_orfs_backend (visible by dynamic scope when called from pdk_run_flow).
# ===========================================================================

# Stable, resumable checkpoint path for this (platform, corner, design).
# characterize.py defaults BAMBU_CHAR_LADDER_STATE_DIR to <char_output>/.ladder_state;
# fall back to an in-workdir path (no cross-run resume) for ad-hoc/direct runs.
ladder_state_file()
{
   local base="${BAMBU_CHAR_LADDER_STATE_DIR:-${WORK_DIR}/.ladder_state}"
   echo "${base}/${PLATFORM}/${CHAR_CORNER:-none}/${DESIGN_NAME}.rung"
}

# Set CORE_UTILIZATION in a config.mk ($1=config.mk, $2=value).
ladder_set_core_util()
{
   local cfg="$1" util="$2"
   if grep -qE '^export CORE_UTILIZATION' "$cfg" 2>/dev/null; then
      sed -i -E "s|^(export CORE_UTILIZATION[[:space:]]*=).*|\\1 ${util}|" "$cfg"
   else
      echo "export CORE_UTILIZATION       = ${util}" >> "$cfg"
   fi
}

ladder_design_log_dir()
{
   echo "${WORK_DIR}/logs/${PLATFORM}/${DESIGN_NAME}/${FLOW_VARIANT:-base}"
}

# True (0) iff the last flow attempt failed because the design does not fit at this
# utilization (lowering CORE_UTILIZATION / enlarging the core would relieve it).
#
# For a single-FU characterization, every failure between floorplan and routing is
# a "doesn't fit" condition -- placement density (FLW-0024), detailed-placement
# legalization at place OR CTS (DPL-003x), global-route congestion (GRT-0116),
# IO overflow (PPL-0024), GPL divergence, etc. So we escalate on ANY failure whose
# furthest stage is floorplan(2_)/place(3_)/cts(4_)/route(5_), rather than trying
# to enumerate ORFS error codes. Only synthesis (1_) and finish (6_) failures are
# NOT utilization-fixable -> the ladder stops there (resumable).
ladder_flow_congested()
{
   local ld; ld="$(ladder_design_log_dir)"
   [[ -d "$ld" ]] || return 1
   local last_stage
   last_stage="$(ls "$ld"/[0-9]_*.log 2>/dev/null | sed -E 's#.*/([0-9]+)_.*#\1#' | sort -n | tail -1)"
   case "$last_stage" in
      2|3|4|5) return 0 ;;
   esac
   return 1
}

# Remove this design's ORFS outputs so the next rung re-runs from scratch.
ladder_clean_design()
{
   local v="${FLOW_VARIANT:-base}" sub
   for sub in results logs reports objects; do
      rm -rf "${WORK_DIR}/${sub}/${PLATFORM}/${DESIGN_NAME}/${v}" 2>/dev/null || true
   done
}

# Record the CORE_UTILIZATION at which this (platform, corner, module) succeeded
# into a shared lookup XML, so future runs can skip the ladder. flock-protected
# because parallel mantis jobs write concurrently. ($1 = winning CORE_UTILIZATION)
record_successful_util()
{
   local util="$1"
   local base="${BAMBU_CHAR_LADDER_STATE_DIR:-${WORK_DIR}/.ladder_state}"
   mkdir -p "$base" 2>/dev/null || return 0
   local xml="${base}/successful_utilizations.xml"
   (
      flock 9
      python3 - "$xml" "${PLATFORM}" "${CHAR_CORNER:-none}" "${DESIGN_NAME}" "$util" <<'PY'
import os, sys, xml.etree.ElementTree as ET
path, platform, corner, name, util = sys.argv[1:6]
root = None
if os.path.exists(path) and os.path.getsize(path) > 0:
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError:
        root = None
if root is None or root.tag != "successful_utilizations":
    root = ET.Element("successful_utilizations")
entry = None
for m in root.findall("module"):
    if (m.get("platform"), m.get("corner"), m.get("name")) == (platform, corner, name):
        entry = m
        break
if entry is None:
    entry = ET.SubElement(root, "module")
    entry.set("platform", platform)
    entry.set("corner", corner)
    entry.set("name", name)
entry.set("core_utilization", util)
# Human-readable lookup table: stable order, one <module> per line.
root[:] = sorted(root, key=lambda m: ((m.get("platform") or ""), (m.get("corner") or ""), (m.get("name") or "")))
ET.indent(root, space="  ")
ET.ElementTree(root).write(path, encoding="utf-8", xml_declaration=True)
with open(path, "a", encoding="utf-8") as fh:
    fh.write("\n")
PY
   ) 9>"${xml}.lock"
}

# Set-or-append "export VAR = value" in a config.mk ($1=config.mk $2=VAR $3=value).
config_set_var()
{
   local cfg="$1" var="$2" val="$3"
   if grep -qE "^export ${var}[[:space:]]*=" "$cfg" 2>/dev/null; then
      sed -i -E "s|^(export ${var}[[:space:]]*=).*|\\1 ${val}|" "$cfg"
   else
      echo "export ${var} = ${val}" >> "$cfg"
   fi
}

# Common characterization config.mk policy shared by PDK plugins:
# drop cell-pad + FP_CORE_SPACE, set the density addon + density, and seed the
# starting CORE_UTILIZATION (the ladder owns it thereafter).
#   $1=config.mk  $2=PLACE_DENSITY  $3=PLACE_DENSITY_LB_ADDON  $4=start CORE_UTILIZATION
ladder_config_common()
{
   local cfg="$1" density="$2" addon="$3" start_util="$4"
   sed -i -E '/^export CELL_PAD_IN_SITES_(GLOBAL|DETAIL)_PLACEMENT/d; /^export FP_CORE_SPACE/d' "$cfg"
   config_set_var "$cfg" PLACE_DENSITY_LB_ADDON "$addon"
   config_set_var "$cfg" PLACE_DENSITY          "$density"
   ladder_set_core_util "$cfg" "$start_util"
}

# Shared CORE_UTILIZATION escalation ladder. Pass rungs high->low as args
# (last = floor). Escalate (next rung) only on GRT/PPL congestion; stop on any
# other failure. Checkpoints the current rung for resume; clears it on success.
run_core_util_ladder()
{
   local -a rungs=("$@")
   # Optional override (env): start the ladder at the first rung <= LADDER_START_UTIL,
   # skipping higher rungs. Scopes a per-run starting utilization without changing the
   # plugin's default ladder. Useful for re-running known-hard modules whose winning
   # utilization band is already known.
   if [[ -n "${LADDER_START_UTIL:-}" ]]; then
      local -a _filtered=() _r
      for _r in "${rungs[@]}"; do
         [[ "$_r" -le "${LADDER_START_UTIL}" ]] && _filtered+=("$_r")
      done
      if [[ ${#_filtered[@]} -gt 0 ]]; then
         rungs=("${_filtered[@]}")
         echo "[char] LADDER_START_UTIL=${LADDER_START_UTIL} -> ladder starts at CORE_UTILIZATION=${rungs[0]}"
      fi
   fi
   local floor="${rungs[$((${#rungs[@]}-1))]}"
   local state resume_at="" started=0 util
   state="$(ladder_state_file)"
   [[ -f "$state" ]] && resume_at="$(cat "$state" 2>/dev/null)"
   [[ -n "$resume_at" ]] && echo "[char] resuming ${DESIGN_NAME} from CORE_UTILIZATION=${resume_at}"
   for util in "${rungs[@]}"; do
      if [[ -n "$resume_at" && "$started" -eq 0 && "$util" -gt "$resume_at" ]]; then
         continue
      fi
      started=1
      mkdir -p "$(dirname "$state")" && echo "$util" > "$state"
      ladder_clean_design
      ladder_set_core_util "$config_mk" "$util"
      echo "[char] CORE_UTILIZATION=${util} (platform=${PLATFORM} corner=${CHAR_CORNER:-none} design=${DESIGN_NAME})"
      if run_orfs_make_cmd; then
         rm -f "$state"
         LADDER_WON_UTIL="$util"   # recorded later, ONLY if the full flow (metadata+extract) succeeds
         return 0
      fi
      if ladder_flow_congested; then
         if [[ "$util" -le "$floor" ]]; then
            echo "[char] congestion persists at floor CORE_UTILIZATION=${floor} -> giving up" >&2
            return 1
         fi
         echo "[char] congestion at CORE_UTILIZATION=${util} -> lowering by 5" >&2
         continue
      fi
      echo "[char] non-congestion failure at CORE_UTILIZATION=${util} -> stopping (resume from ${util})" >&2
      return 1
   done
   return 1
}

run_orfs_backend()
{
   WORK_DIR="${CURR_WORKDIR:-$(pwd)}"

   # ===========================================================================
   # Characterization PDK dispatch.
   #   * Default the ORFS image to the locally-built one so multi-job runs never
   #     silently fall back to the old pinned image.
   #   * Detect the technology node (ORFS platform) and process corner, then
   #     source the per-PDK plugin "<technode>_char.sh" (sitting next to this
   #     script, copied in by BackendWrapper). The plugin may override the pdk_*
   #     hooks below. Escalation logic is intentionally NOT here yet.
   # ===========================================================================
   : "${OR_IMAGE:=orfs_bambu:latest}"
   export OR_IMAGE
   local TECHNODE="${PLATFORM:-$(bambu_results /application/target@model)}"
   local CHAR_CORNER="$(bambu_results /application/target@speed_grade)"

   # Default (base) hooks -- a PDK plugin may override any of these.
   pdk_corner_env()      { :; }                  # echo "CORNER=<x>" lines to forward to ORFS
   pdk_config_mk_extra() { :; }                  # rewrite/append config.mk lines; $1 = config.mk
   pdk_run_flow()        { run_orfs_make_cmd; }   # run the ORFS flow; default = single attempt
   pdk_write_sdc()       { echo "ERROR: PDK plugin for ${TECHNODE} must define pdk_write_sdc()" >&2; exit 1; }
   pdk_extract_metrics() { echo "ERROR: PDK plugin for ${TECHNODE} must define pdk_extract_metrics()" >&2; exit 1; }

   local pdk_plugin="${SWD}/${TECHNODE}_char.sh"
   if [[ -f "${pdk_plugin}" ]]; then
      echo "[char] technode=${TECHNODE} corner=${CHAR_CORNER:-none} plugin=$(basename "${pdk_plugin}")"
      # shellcheck source=/dev/null
      source "${pdk_plugin}"
   else
      echo "[char] technode=${TECHNODE} corner=${CHAR_CORNER:-none} (no PDK plugin; base flow)"
   fi

   # SDC is PDK-owned: the clock period must be in the platform Liberty time
   # unit (ps for asap7, ns for nangate45/sky130hd). Plugin defines pdk_write_sdc.
   export SDC_FILE="${SWD}/constraints.sdc"
   pdk_write_sdc "${SDC_FILE}"

   WORK_DIR_CONTAINER="${OPENROAD_DOCKER_WORK_DIR_CONTAINER:-/work}"
   if [[ "${WORK_DIR_CONTAINER}" == "/" ]]; then
      echo "ERROR: OPENROAD_DOCKER_WORK_DIR_CONTAINER cannot be '/'." >&2
      echo "Use an absolute path such as /work or /tmp/openroad-work." >&2
      exit 1
   fi
   WORK_DIR_CONTAINER="${WORK_DIR_CONTAINER%/}"
   if [[ -z "${WORK_DIR_CONTAINER}" || "${WORK_DIR_CONTAINER}" != /* ]]; then
      cat >&2 <<EOF
ERROR: OPENROAD_DOCKER_WORK_DIR_CONTAINER must be an absolute path.
Current value: ${OPENROAD_DOCKER_WORK_DIR_CONTAINER:-${WORK_DIR_CONTAINER}}

Please set OPENROAD_DOCKER_WORK_DIR_CONTAINER to an absolute container path.
Examples:
  export OPENROAD_DOCKER_WORK_DIR_CONTAINER=/work
  export OPENROAD_DOCKER_WORK_DIR_CONTAINER=/tmp/openroad-work
EOF
      exit 1
   fi
   local use_docker="${OPENROAD_USE_DOCKER:-1}"
   local orfs_mode="image"

   if [[ -n "${OPENROAD_FLOW_DATA_INSTALLDIR:-}" ]]; then
      orfs_mode="repo"
      if [[ "${OPENROAD_FLOW_DATA_INSTALLDIR}" != /* ]]; then
         cat >&2 <<EOF
ERROR: OPENROAD_FLOW_DATA_INSTALLDIR must be an absolute path.
Current value: ${OPENROAD_FLOW_DATA_INSTALLDIR}

Please set OPENROAD_FLOW_DATA_INSTALLDIR to an absolute directory path.
Example:
  export OPENROAD_FLOW_DATA_INSTALLDIR=/path/to/OpenROAD-flow-scripts

If you currently have a relative path, convert it to absolute first, e.g.:
  export OPENROAD_FLOW_DATA_INSTALLDIR="\$(realpath "${OPENROAD_FLOW_DATA_INSTALLDIR}")"
EOF
         exit 1
      fi
      if [[ ! -d "${OPENROAD_FLOW_DATA_INSTALLDIR}" ]]; then
         echo "ERROR: OPENROAD_FLOW_DATA_INSTALLDIR is not a directory: ${OPENROAD_FLOW_DATA_INSTALLDIR}" >&2
         exit 1
      fi
      if [[ ! -d "${OPENROAD_FLOW_DATA_INSTALLDIR}/flow" ]]; then
         echo "ERROR: '${OPENROAD_FLOW_DATA_INSTALLDIR}/flow' not found." >&2
         exit 1
      fi
      validate_orfs_pinned_digest "${OPENROAD_FLOW_DATA_INSTALLDIR}"
   elif [[ "${use_docker}" -eq 0 ]]; then
      cat >&2 <<'EOF'
ERROR: OPENROAD_FLOW_DATA_INSTALLDIR is required when OPENROAD_USE_DOCKER=0.
Non-docker mode needs a local clone of OpenROAD-flow-scripts.

Set OPENROAD_FLOW_DATA_INSTALLDIR to the directory containing a clone of:
  https://github.com/The-OpenROAD-Project/OpenROAD-flow-scripts.git
EOF
      exit 1
   fi

   local verilog_files_host=""
   local verilog_files_container=""
   local source_file=""
   for source_file in ${VERILOG_FILES}; do
      local abs_source="${source_file}"
      if [[ "${abs_source}" != /* ]]; then
         abs_source="${WORK_DIR}/${abs_source}"
      fi
      verilog_files_host+="${abs_source} "
      if [[ "${abs_source}" == "${WORK_DIR}"* ]]; then
         verilog_files_container+="${WORK_DIR_CONTAINER}${abs_source#"${WORK_DIR}"} "
      else
         verilog_files_container+="${abs_source} "
      fi
   done

   local config_verilog_files="${verilog_files_host}"
   local config_sdc_file="${SDC_FILE}"
   if [[ "${use_docker}" -eq 1 ]]; then
      config_verilog_files="${verilog_files_container}"
      if [[ "${SDC_FILE}" == "${WORK_DIR}"* ]]; then
         config_sdc_file="${WORK_DIR_CONTAINER}${SDC_FILE#"${WORK_DIR}"}"
      fi
   fi

   local use_fixed_floorplan=0
   if [[ -n "${DIE_AREA:-}" || -n "${CORE_AREA:-}" ]]; then
      if [[ -z "${DIE_AREA:-}" || -z "${CORE_AREA:-}" ]]; then
         echo "ERROR: DIE_AREA and CORE_AREA must be set together when using fixed floorplan." >&2
         echo "Set both DIE_AREA and CORE_AREA, or unset both and use CORE_UTILIZATION." >&2
         exit 1
      fi
      use_fixed_floorplan=1
      # Force fixed floorplan path by disabling utilization-based initialization.
      unset CORE_UTILIZATION
   fi

   local config_mk="${WORK_DIR}/config.mk"
   local config_mk_container="${config_mk}"
   if [[ "${config_mk}" == "${WORK_DIR}"* ]]; then
      config_mk_container="${WORK_DIR_CONTAINER}${config_mk#"${WORK_DIR}"}"
   fi
   cat > "${config_mk}" <<EOF
export PLATFORM               = ${PLATFORM}
export DESIGN_NAME            = ${DESIGN_NAME}
export VERILOG_FILES          = ${config_verilog_files}
export SDC_FILE               = ${config_sdc_file}
export SKIP_LAST_GASP ?= ${SKIP_LAST_GASP:-1}
export SYNTH_MEMORY_MAX_BITS = ${SYNTH_MEMORY_MAX_BITS:-4194304}
export LEC_CHECK              = 0
EOF
   if [[ "${use_fixed_floorplan}" -eq 1 ]]; then
      echo "export DIE_AREA               = ${DIE_AREA}" >> "${config_mk}"
      echo "export CORE_AREA              = ${CORE_AREA}" >> "${config_mk}"
   else
      if [[ -z "${CORE_UTILIZATION:-}" ]]; then
         echo "ERROR: CORE_UTILIZATION is not set." >&2
         echo "Set CORE_UTILIZATION for auto floorplan, or set both DIE_AREA and CORE_AREA for fixed floorplan." >&2
         exit 1
      fi
      local core_utilization="${CORE_UTILIZATION}"
      core_utilization="$(echo "${core_utilization}" | sed -E "s/^[[:space:]]+//; s/[[:space:]]+$//; s/^\"(.*)\"$/\\1/; s/^'(.*)'$/\\1/")"
      if [[ -z "${core_utilization}" ]]; then
         echo "ERROR: CORE_UTILIZATION resolves to an empty value after quote trimming." >&2
         echo "Provide a numeric value, e.g. CORE_UTILIZATION=10" >&2
         exit 1
      fi
      echo "export CORE_UTILIZATION       = ${core_utilization}" >> "${config_mk}"
   fi
   if [[ -n "${FP_CORE_SPACE:-}" ]]; then
      echo "export FP_CORE_SPACE          = ${FP_CORE_SPACE}" >> "${config_mk}"
   fi
   if [[ -n "${CELL_PAD_IN_SITES_GLOBAL_PLACEMENT:-}" ]]; then
      echo "export CELL_PAD_IN_SITES_GLOBAL_PLACEMENT = ${CELL_PAD_IN_SITES_GLOBAL_PLACEMENT}" >> "${config_mk}"
   fi
   if [[ -n "${CELL_PAD_IN_SITES_DETAIL_PLACEMENT:-}" ]]; then
      echo "export CELL_PAD_IN_SITES_DETAIL_PLACEMENT = ${CELL_PAD_IN_SITES_DETAIL_PLACEMENT}" >> "${config_mk}"
   fi
   if [[ -n "${PLACE_DENSITY_LB_ADDON:-}" ]]; then
      echo "export PLACE_DENSITY_LB_ADDON = ${PLACE_DENSITY_LB_ADDON}" >> "${config_mk}"
   fi
   if [[ -n "${PLACE_DENSITY:-}" ]]; then
      echo "export PLACE_DENSITY          = ${PLACE_DENSITY}" >> "${config_mk}"
   fi
   append_asap7_fakeram_assets_config "${config_mk}"
   pdk_config_mk_extra "${config_mk}"

   local flow_makefile=""
   local docker_image="${OR_IMAGE:-openroad/orfs:v3.0-4639-ga2bb042b6}"
   local flow_variant="${FLOW_VARIANT:-base}"
   local results_dir_host="${WORK_DIR}/results/${PLATFORM}/${DESIGN_NAME}/${flow_variant}"
   local canonicalize_target_host="${results_dir_host}/1_1_yosys_canonicalize.rtlil"
   local canonicalize_target="${canonicalize_target_host}"
   local user_requested_keep_modules="${SYNTH_KEEP_MODULES:-}"
   local user_requested_retime_modules="${SYNTH_RETIME_MODULES:-}"
   local requested_keep_modules="${user_requested_keep_modules}"
   local requested_retime_modules="${user_requested_retime_modules}"
   local resolved_keep_modules="${requested_keep_modules}"
   local resolved_retime_modules="${requested_retime_modules}"
   local default_keep_modules_to_resolve=""
   local default_retime_modules_to_resolve=""
   local keep_to_resolve=""
   local retime_to_resolve=""
   local resolve_keep_modules=0
   local resolve_retime_modules=0
   local custom_synth_script_host="${WORK_DIR}/orfs_scripts/synth_multi_retime.tcl"
   local custom_synth_script="${custom_synth_script_host}"
   local source_synth_script_host=""

   if [[ "${orfs_mode}" == "repo" ]]; then
      flow_makefile="${OPENROAD_FLOW_DATA_INSTALLDIR}/flow/Makefile"
      source_synth_script_host="${OPENROAD_FLOW_DATA_INSTALLDIR}/flow/scripts/synth.tcl"
   else
      flow_makefile="/OpenROAD-flow-scripts/flow/Makefile"
   fi

   if [[ "${use_docker}" -eq 1 ]]; then
      canonicalize_target="${WORK_DIR_CONTAINER}${canonicalize_target_host#"${WORK_DIR}"}"
      custom_synth_script="${WORK_DIR_CONTAINER}${custom_synth_script_host#"${WORK_DIR}"}"
   fi

   run_orfs_make_cmd()
   {
      local -a make_targets=("$@")
      if [[ "${use_docker}" -eq 1 ]]; then
         local -a docker_args=(
            "--rm"
            -e FLOW_HOME=/OpenROAD-flow-scripts/flow/
            -e "NUM_CORES=${NUM_CORES}"
            -e "WORK_HOME=${WORK_DIR_CONTAINER}"
            -e "DESIGN_CONFIG=${config_mk_container}"
            -w "/OpenROAD-flow-scripts/flow"
            -v "${WORK_DIR}:${WORK_DIR_CONTAINER}:Z"
         )
         if [[ "${orfs_mode}" == "repo" ]]; then
            docker_args+=(-v "${OPENROAD_FLOW_DATA_INSTALLDIR}/flow:/OpenROAD-flow-scripts/flow:Z")
         fi
         local userns_remap
         userns_remap="$(docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -i userns || true)"
         if [[ -n "${userns_remap}" ]]; then
            echo "WARNING: Docker User Namespaces enabled on this machine, make sure mapped users have permissions to read/write the output directory."
         else
            docker_args+=(-u "$(id -u):$(id -g)")
         fi
         local env_assignment=""
         for env_assignment in "${orfs_extra_env_vars[@]}"; do
            docker_args+=(-e "${env_assignment}")
         done
         local make_cmd="make -f /OpenROAD-flow-scripts/flow/Makefile"
         local make_target=""
         for make_target in "${make_targets[@]}"; do
            printf -v make_cmd '%s %q' "${make_cmd}" "${make_target}"
         done
         docker run "${docker_args[@]}" "${docker_image}" \
            bash -lc "set -e; if [[ -f ../env.sh ]]; then . ../env.sh; elif [[ -f ../setup-env.sh ]]; then . ../setup-env.sh; fi; ${make_cmd}"
      else
         local -a host_make_cmd=(
            make
            "NUM_CORES=${NUM_CORES}"
            "WORK_HOME=${WORK_DIR}"
            "DESIGN_CONFIG=${config_mk}"
            -f "${flow_makefile}"
         )
         if [[ ${#make_targets[@]} -ne 0 ]]; then
            host_make_cmd+=("${make_targets[@]}")
         fi
         (
            set -e
            cd "$(dirname "${flow_makefile}")"
            if [[ -f ../env.sh ]]; then
               . ../env.sh
            elif [[ -f ../setup-env.sh ]]; then
               . ../setup-env.sh
            fi
            env "${orfs_extra_env_vars[@]}" "${host_make_cmd[@]}"
         )
      fi
   }

   local -a orfs_extra_env_vars=()

   # Forward the process corner chosen by the PDK plugin (e.g. CORNER=TC for asap7).
   # Without this, ORFS uses its platform default (asap7: CORNER ?= BC) and every
   # corner would characterize with identical BC libraries.
   local _pdk_env_line
   while IFS= read -r _pdk_env_line; do
      [[ -n "${_pdk_env_line}" ]] && orfs_extra_env_vars+=("${_pdk_env_line}")
   done < <(pdk_corner_env)

   local simple_user_keep_modules=0
   local simple_user_retime_modules=0
   if is_simple_orfs_module_list "${user_requested_keep_modules}"; then
      simple_user_keep_modules=1
   fi
   if is_simple_orfs_module_list "${user_requested_retime_modules}"; then
      simple_user_retime_modules=1
   fi

   if [[ -z "${user_requested_keep_modules}" || "${simple_user_keep_modules}" -eq 1 ]]; then
      default_keep_modules_to_resolve="${ORFS_DEFAULT_MODULES_TO_KEEP_AND_RETIME}"
      requested_keep_modules="${default_keep_modules_to_resolve}${user_requested_keep_modules:+ ${user_requested_keep_modules}}"
      resolved_keep_modules="${requested_keep_modules}"
   fi
   if [[ -z "${user_requested_retime_modules}" || "${simple_user_retime_modules}" -eq 1 ]]; then
      default_retime_modules_to_resolve="${ORFS_DEFAULT_MODULES_TO_KEEP_AND_RETIME}"
      requested_retime_modules="${default_retime_modules_to_resolve}${user_requested_retime_modules:+ ${user_requested_retime_modules}}"
      resolved_retime_modules="${requested_retime_modules}"
   fi

   if is_simple_orfs_module_list "${requested_keep_modules}"; then
      resolve_keep_modules=1
      if [[ -n "${user_requested_keep_modules}" ]]; then
         keep_to_resolve="${user_requested_keep_modules}"
      fi
   fi
   if is_simple_orfs_module_list "${requested_retime_modules}"; then
      resolve_retime_modules=1
      if [[ -n "${user_requested_retime_modules}" ]]; then
         retime_to_resolve="${user_requested_retime_modules}"
      fi
   fi

   if [[ "${resolve_keep_modules}" -eq 1 || "${resolve_retime_modules}" -eq 1 ]]; then
      run_orfs_make_cmd "${canonicalize_target}"
      local -a resolved_module_vars=()
      mapfile -d '' -t resolved_module_vars < <(
         resolve_orfs_module_names "${canonicalize_target_host}" "${default_keep_modules_to_resolve}" \
            "${keep_to_resolve}" "${default_retime_modules_to_resolve}" "${retime_to_resolve}"
      )
      if [[ "${resolve_keep_modules}" -eq 1 ]]; then
         resolved_keep_modules="${resolved_module_vars[0]}"
         echo "Resolved SYNTH_KEEP_MODULES to elaborated Yosys modules: ${resolved_keep_modules}"
      fi
      if [[ "${resolve_retime_modules}" -eq 1 ]]; then
         resolved_retime_modules="${resolved_module_vars[1]}"
         echo "Resolved SYNTH_RETIME_MODULES to elaborated Yosys modules: ${resolved_retime_modules}"
      fi
   fi

   if [[ -n "${resolved_keep_modules}" ]]; then
      orfs_extra_env_vars+=("SYNTH_KEEP_MODULES=${resolved_keep_modules}")
   fi
   if [[ -n "${resolved_retime_modules}" ]]; then
      orfs_extra_env_vars+=("SYNTH_RETIME_MODULES=${resolved_retime_modules}")
      if [[ -z "${source_synth_script_host}" ]]; then
         source_synth_script_host="${WORK_DIR}/orfs_scripts/original_synth.tcl"
         mkdir -p "$(dirname "${source_synth_script_host}")"
         docker run --rm "${docker_image}" \
            bash -lc 'cat /OpenROAD-flow-scripts/flow/scripts/synth.tcl' > "${source_synth_script_host}"
      fi
      if create_custom_orfs_synth_script "${source_synth_script_host}" "${custom_synth_script_host}"; then
         orfs_extra_env_vars+=("SYNTH_SCRIPT=${custom_synth_script}")
      else
         echo "INFO: using native ORFS SYNTH_RETIME_MODULES handling (no custom synth script)." >&2
      fi
   fi

   if ! pdk_run_flow; then
      echo "ERROR: characterization backend flow failed for ${DESIGN_NAME} (platform=${PLATFORM} corner=${CHAR_CORNER:-none})." >&2
      exit 1
   fi
   if ! run_orfs_make_cmd metadata-generate; then
      echo "ERROR: metadata generation failed for ${DESIGN_NAME} (platform=${PLATFORM} corner=${CHAR_CORNER:-none})." >&2
      exit 1
   fi

   local metadata_json="${WORK_DIR}/reports/${PLATFORM}/${DESIGN_NAME}/${FLOW_VARIANT}/metadata.json"
   local out_xml="${SWD}/$(bambu_results /application/backend@bambu_results)"
   # Delay/area read-back is PDK-owned: timing values follow the platform Liberty unit.
   if ! pdk_extract_metrics "${metadata_json}" "${out_xml}"; then
      echo "ERROR: metric extraction failed for ${DESIGN_NAME} (platform=${PLATFORM} corner=${CHAR_CORNER:-none})." >&2
      exit 1
   fi

   # Full success (P&R ladder + metadata + extraction). Only NOW record the winning
   # CORE_UTILIZATION into the lookup table, so failed modules never get cached.
   [[ -n "${LADDER_WON_UTIL:-}" ]] && record_successful_util "${LADDER_WON_UTIL}"
}

export DESIGN_NAME="$(bambu_results /application/top_module@name)"
: "${DESIGN_NICKNAME:=${DESIGN_NAME}}"
export DESIGN_NICKNAME
# (SDC + delay read-back moved into run_orfs_backend as PDK-owned hooks.)

WORK_DIR="${CURR_WORKDIR:-$(pwd)}"
export VERILOG_FILES=""
for src in $(bambu_results /application/outputs/file); do
   if [[ "${src}" = /* ]]; then
      VERILOG_FILES+="${src} "
   else
      VERILOG_FILES+="${WORK_DIR}/${src} "
   fi
done
: "${FLOW_VARIANT:=base}"
export FLOW_VARIANT

resolve_num_cores
run_orfs_backend
exit 0
