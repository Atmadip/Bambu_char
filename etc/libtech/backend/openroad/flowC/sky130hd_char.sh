#!/usr/bin/env bash
# PDK plugin: sky130hd.
#
# Sourced by the characterization launch.sh. sky130hd ships a single (typical)
# corner in ORFS, so there is no CORNER forwarding yet. This file exists so the
# dispatch resolves "${PLATFORM}_char.sh" for sky130hd and is ready to host
# PDK-specific config.mk tuning (and, later, the escalation ladder).

pdk_corner_env()      { :; }   # sky130hd: single corner -> nothing to forward yet
pdk_config_mk_extra() { :; }
