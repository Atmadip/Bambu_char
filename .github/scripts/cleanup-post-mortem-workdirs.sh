#!/usr/bin/env bash
set -u

found=0
for path in out_*
do
   if [[ -d "${path}" ]]; then
      printf 'Removing post-mortem workdir %s\n' "${path}"
      rm -rf -- "${path}"
      found=1
   fi
done

if [[ "${found}" -eq 0 ]]; then
   echo "No post-mortem workdirs to remove."
fi
