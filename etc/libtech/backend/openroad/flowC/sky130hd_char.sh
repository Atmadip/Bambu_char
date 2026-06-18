#!/usr/bin/env bash
# PDK plugin: sky130hd (SkyWater 130 nm high-density).
#
# Sourced by the characterization launch.sh. Like nangate45, ORFS ships sky130hd
# with a single (typical) corner -> no CORNER forwarding. Memory is synthesized
# generically (no SRAM macros wired in), so this mirrors the nangate45 policy.

# sky130hd has a single corner -> nothing to forward.
pdk_corner_env() { :; }

# --- config.mk policy -----------------------------------------------------
# Keep it simple: use sky130hd's own config.mk defaults (PLACE_DENSITY, addon,
# margins, PDN, etc.). The only knob we drive is CORE_UTILIZATION, via the
# ladder below. So there is nothing extra to inject here.
pdk_config_mk_extra() { :; }

# --- escalation ladder ----------------------------------------------------
# CORE_UTILIZATION 70 -> 10 (step -5).
pdk_run_flow() {
   run_core_util_ladder 70 65 60 55 50 45 40 35 30 25 20 15 10
}
