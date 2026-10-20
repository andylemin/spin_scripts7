#!/usr/bin/env bash

# Log drive temperatures, fan RPMs, duty cycles and the fan mode at a fixed interval without
# controlling anything; one or two fan zones. Run as superuser.
VERSION="2026-10-17"

#################  SETTINGS  ################

LOG=/var/log/spincheck.log
# 1: log file and console; 0: log file only.
LOG_CONSOLE=1

# Whole minutes between checks; asked for when run from a terminal.
T=5

# Setpoint (C) used for the ERRc column only.
SP=33.57

# Add " -H <host> -U <user> -P <password>" inside the quotes to drive a remote BMC.
IPMITOOL="/usr/local/bin/ipmitool"
SMARTCTL="/usr/local/sbin/smartctl"
CAMCONTROL="/sbin/camcontrol"

# camcontrol devlist lines matching these sed patterns are not drives to report (SSDs, enclosures, cards).
DEVLIST_EXCLUDE='/KINGSTON/d;/ADATA/d;/SanDisk/d;/OCZ/d;/LSI/d;/EXP/d;/INTEL/d;/TDKMedia/d;/SSD/d;/VMware/d;/Enclosure/d;/Card/d;/Flash/d'

# IPMI sensor used when coretemp (dev.cpu.N.temperature) is unavailable.
CPU_TEMP_SENSOR="CPU Temp"

#############################################

DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
# shellcheck source=spincommon.sh
source "$DIR/spincommon.sh" || { echo "cannot read $DIR/spincommon.sh" >&2; exit 1; }

if [ -t 0 ]; then
   read -r -p "How many whole minutes do you want between spin checks? [$T] " ANSWER
   [ -n "$ANSWER" ] && T=$ANSWER
fi
if [[ ! $T =~ ^[1-9][0-9]*$ ]]; then
   echo "The interval must be a whole number of minutes above 0, not '$T'" >&2
   exit 1
fi
setup_logging
require_settings IPMITOOL SMARTCTL CAMCONTROL SP
require_defined DEVLIST_EXCLUDE CPU_TEMP_SENSOR
require_tools IPMITOOL SMARTCTL CAMCONTROL

# Column header; printed at start and in the first T minutes of each quarter day.
print_header() {
   DATE=$(date +"%A, %b %d")
   printf "\n%s \n" "$DATE"
   echo -n "          "
   while read -r LINE ; do
      get_disk_name
      printf "%-5s" "$DEVID"
   done <<< "$DEVLIST"
   printf "%4s %5s %5s %3s %5s %5s %5s %5s %5s %5s %5s %5s %5s %-7s" "Tmax" "Tmean" "ERRc" "CPU" "FAN1" "FAN2" "FAN3" "FAN4" "FAN5" "FANA" "FANB" "Fan%0" "Fan%1" "MODE"
}

detect_cpu_temp_source
build_devlist

printf "\n%s\n%s\n%s\n" "NOTE ABOUT DUTY CYCLE (Fan%0 and Fan%1):" \
"Some boards apparently report incorrect duty cycle, and can" \
"report duty cycle for zone 1 when that zone does not exist."

drive_health_warning

printf "\n%s %36s %s \n" "Key to drive status symbols:  * spinning;  _ standby;  ? unknown" "Version" "$VERSION"
print_header

###########################################
# Main loop: one row every T minutes
###########################################
while true ; do
   quarter_day_boundary "$T" && print_header

   echo
   print_time
   Tmax=0; Tsum=0
   i=0
   while read -r LINE ; do
      get_disk_name
      drive_status_temp "$DEVID"
      if [ -n "$TEMP" ]; then
         Tsum=$(( Tsum + TEMP ))
         (( TEMP > Tmax )) && Tmax=$TEMP
         i=$(( i + 1 ))
      fi
      printf "%s%-2s  " "$STATUS" "${TEMP:---}"
   done <<< "$DEVLIST"

   if [ "$i" -eq 0 ]; then
      Tmean=""; Tmax=""; ERRc=""
   else
      Tmean=$(bc <<< "scale=3; $Tsum / $i")
      ERRc=$(bc <<< "scale=2; $Tmean - $SP")
      Tmean=$(printf %0.2f "$Tmean")
      ERRc=$(printf %0.2f "$ERRc")
   fi

   DUTY0=$(read_duty 0)
   DUTY1=$(read_duty 1)
   read_mode
   read_fan_rpms
   get_cpu_temp

   printf "^%-3s %5s" "${Tmax:---}" "${Tmean:----}"
   printf "%6s %3s %5s %5s %5s %5s %5s %5s %5s %5s %5s %-7s" "${ERRc:----}" "${CPU_TEMP:----}" "${FAN1:----}" "${FAN2:----}" "${FAN3:----}" "${FAN4:----}" "${FAN5:----}" "${FANA:----}" "${FANB:----}" "${DUTY0:----}" "${DUTY1:----}" "$MODEt"

   sleep $(( T * 60 ))
done

# Drive status uses joeschmuck's smartctl method (exit 0 spinning, 2 standby), which also works
# on an HBA: https://forums.freenas.org/index.php?threads/how-to-find-out-if-a-drive-is-spinning-down-properly.2068/#post-28451
