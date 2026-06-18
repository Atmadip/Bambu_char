#!/usr/bin/env bash
# PDK plugin: asap7 (process corners BC / TC / WC).
#
# Sourced by the characterization launch.sh. Context (dynamic scope from
# run_orfs_backend): TECHNODE, CHAR_CORNER, PLATFORM, WORK_DIR, DESIGN_NAME,
# FLOW_VARIANT, config_mk, run_orfs_make_cmd, and the ladder_*/config_* helpers.

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
