#!/usr/bin/env bash
# Quick best-effort summary of an ILA capture CSV: for the key ReckOn probes,
# report whether each stayed FLAT or CHANGED during the window (and the values).
# For the full waveform, open the matching .ila file in the Vivado GUI.
#
# Usage: summarize.sh <capture.csv>
set -uo pipefail
CSV="${1:?usage: summarize.sh <capture.csv>}"
[ -f "$CSV" ] || { echo "no such file: $CSV"; exit 1; }

echo "== ILA capture summary: $CSV =="
awk -F',' '
function trim(s){ gsub(/^[ \t"]+|[ \t"]+$/,"",s); return s }
NR==1 {
  for (i=1;i<=NF;i++){ name[i]=trim($i) }
  ncol=NF
  # probes of interest (substring match on header)
  split("TIME_TICK RAM_ADDR CS BATCH_DONE EPOCH_DONE new_batch_fsm SPI_CYCLES_PER_TICK N_SAMPLES BATCH_SIZE N_EPOCHS",keys," ")
  next
}
{
  for (i=1;i<=ncol;i++){
    v=trim($i)
    if (v=="") continue
    if (v ~ /^(HEX|BIN|OCT|DEC|UNSIGNED|SIGNED|RADIX|ASCII)$/) continue   # skip radix row
    if (!( (i SUBSEP v) in seen)){ seen[i SUBSEP v]=1; nval[i]++; if(nval[i]<=8){ vals[i]=vals[i] (vals[i]==""?"":" ") v } }
    rows++
  }
}
END{
  for (k in keys){
    pat=keys[k]; found=0
    for (i=1;i<=ncol;i++){
      if (index(name[i],pat)>0){
        found=1
        if (nval[i]<=1)  printf "  %-24s FLAT   = %s\n", name[i], vals[i]
        else             printf "  %-24s CHANGED (%d vals): %s%s\n", name[i], nval[i], vals[i], (nval[i]>8?" ...":"")
      }
    }
  }
}
' "$CSV"

echo "  (samples: $(($(wc -l < "$CSV")-1)))"
echo "  -> apri il .ila corrispondente in Vivado per la waveform completa."
