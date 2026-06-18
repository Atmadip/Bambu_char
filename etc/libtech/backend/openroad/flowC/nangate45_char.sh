#!/usr/bin/env bash
# PDK plugin: nangate45 (single typical corner; no CORNER selection in ORFS).
#
# Sourced by the characterization launch.sh. Same config/ladder pattern as asap7,
# with nangate45-specific values.

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
