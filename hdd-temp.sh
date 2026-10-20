#!/usr/bin/env sh
# Print the temperature of every disk (ATA, SCSI/SAS, NVMe) without waking standby drives.

# nvd/nda units are numbered in nvmecontrol devlist namespace order; smartctl wants the
# controller device nvme<N>.
nvme_controller() {
   nvmecontrol devlist 2> /dev/null |
      awk -v n="$1" '/^ *nvme[0-9]+ns[0-9]+/ { if (k == n) { sub(/ns.*/, "", $1); print $1; exit } k++ }'
}

# ATA attribute 194 (190 as fallback), SCSI "Current Drive Temperature", NVMe "Temperature:".
parse_temp() {
   awk '$1 == 194 { t = $10 }
        $1 == 190 { a = $10 }
        /^Current Drive Temperature:/ { t = $4 }
        /^Temperature:/ { t = $2 }
        END { print (t != "" ? t : a) }' |
      grep -E '^[0-9]+$'
}

for drive in $(sysctl -n kern.disks | awk '{ for (i = NF; i != 0; i--) print $i }'); do
   case $drive in
      cd*)
         continue
         ;;
      nvd*|nda*)
         id=${drive#nvd}
         id=${id#nda}
         ctrl=$(nvme_controller "$id")
         if [ -z "$ctrl" ]; then
            echo "$drive ?"
            continue
         fi
         temp=$(smartctl -a "/dev/$ctrl" | parse_temp)
         ;;
      *)
         out=$(smartctl -a -n standby "/dev/$drive")
         rc=$?
         # exit 2: standby, or a device smartctl cannot open; only standby says "Device is in"
         if [ $((rc & 2)) -ne 0 ]; then
            case $out in
               *"Device is in "*" mode"*) echo "$drive standby" ;;
               *) echo "$drive ?" ;;
            esac
            continue
         fi
         temp=$(printf '%s\n' "$out" | parse_temp)
         ;;
   esac
   echo "$drive ${temp:-?}${temp:+C}"
done
