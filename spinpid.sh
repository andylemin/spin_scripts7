#!/usr/bin/env bash

# Fan control for Supermicro boards with one fan zone: the zone runs at the higher of the drive
# demand (a PD controller holding the mean drive temperature at a setpoint) and the CPU demand.
# Run as superuser; settings in spinpid.config.
VERSION="2026-10-17"

DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
# shellcheck source=spinpid.config
source "$DIR/spinpid.config" || { echo "cannot read $DIR/spinpid.config" >&2; exit 1; }
# shellcheck source=spincommon.sh
source "$DIR/spincommon.sh" || { echo "cannot read $DIR/spincommon.sh" >&2; exit 1; }
setup_logging

require_settings IPMITOOL SMARTCTL CAMCONTROL SP DRIVE_T Kp Kd DUTY_MIN DUTY_MAX \
   HOW_DUTY CPU_T CPU_REF CPU_SCALE
require_defined DEVLIST_EXCLUDE CPU_TEMP_SENSOR
require_tools IPMITOOL SMARTCTL CAMCONTROL
if [[ ! $DRIVE_T =~ ^[1-9][0-9]*$ || ! $CPU_T =~ ^[1-9][0-9]*$ ]] || (( CPU_T > DRIVE_T * 60 )); then
   echo "DRIVE_T and CPU_T must be whole numbers above 0 with CPU_T no longer than DRIVE_T minutes; check spinpid.config"
   exit 1
fi

# Column header; printed at start and in the first DRIVE_T minutes of each quarter day.
print_header() {
   DATE=$(date +"%A, %b %d")
   printf "\n%-*s %-8s %21s \n" "$(( DEVCOUNT * 5 + 51 ))" "$DATE" "Fan %" "Interim"
   echo -n "          "
   while read -r LINE ; do
      get_disk_name
      printf "%-5s" "$DEVID"
   done <<< "$DEVLIST"
   printf "%4s %5s %5s %6s %6s %3s %s %4s %-8s %4s %s" "Tmax" "Tmean" "ERRc" "P" "D" "CPU" "Driver" "Prev/New" "MODE" "RPM" "Adjustments"
}

# Board duty (with HOW_DUTY=1), fan mode and FAN1 RPM; a failed duty read keeps the last value.
read_fan_data() {
   local d
   if [ "$HOW_DUTY" == 1 ]; then
      d=$(read_duty 0)
      if [ -n "$d" ]; then
         DUTY_CURR=$d
      elif [ -n "$DUTY_CURR" ]; then
         echo -n "[duty read failed; keeping $DUTY_CURR] "
      fi
   fi
   read_mode
   read_fan_rpms
   RPM=$FAN1
}

# CPU demand from the CPU temperature; the zone gets the higher of CPU and drive demand. While the
# drives are at least 1 C below the setpoint with PD < 0, the drive demand steps down by PD per cycle.
CPU_check_adjust() {
   local new prev
   NEXT_CPU=$(( NEXT_CPU + CPU_T ))
   get_cpu_temp
   if [ -n "$CPU_TEMP" ]; then
      DUTY_CPU=$(constrain $(( (CPU_TEMP - CPU_REF) * CPU_SCALE + DUTY_MIN )) "$DUTY_MIN" "$DUTY_MAX")
      CPU_TEMP_WARNED=0
   elif [ "$CPU_TEMP_WARNED" != 1 ]; then
      printf "\n%s\n" "CPU temperature unavailable; keeping CPU demand ${DUTY_CPU:-$DUTY_MIN}"
      CPU_TEMP_WARNED=1
   fi
   : "${DUTY_CPU:=$DUTY_MIN}"

   if [[ $FIRST_TIME -eq 1 ]]; then return; fi

   prev=$DUTY_CURR
   if [[ -n $Tmean && PD -lt 0 && $(bc <<< "$Tmean < ($SP-1)") == 1 ]]; then
      DUTY_DRIVE=$(constrain $(( DUTY_CURR + PD )) "$DUTY_MIN" "$DUTY_MAX")
   fi
   new=$DUTY_CPU
   (( DUTY_DRIVE > DUTY_CPU )) && new=$DUTY_DRIVE
   adjust_fans "$new"
   if [[ $prev -ne $DUTY_CURR ]]; then
      printf "%d " "$DUTY_CURR"
   fi

   sleep_until "$NEXT_CPU" "$CPU_T"
}

# Drive row and PD terms; the drive demand is applied when it is at least the CPU demand.
DRIVES_check_adjust() {
   local now dt
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

   now=$SECONDS
   if [ "$i" -eq 0 ]; then
      Tmean=""; Tmax=""; P=""; D=""; ERRc=""; PD=0
      DUTY_DRIVE=$DUTY_MIN
   else
      Tmean=$(bc <<< "scale=2; $Tsum / $i")
      ERRp=$ERRc
      ERRc=$(bc <<< "scale=3; ($Tmean - $SP) / 1")
      P=$(bc <<< "scale=3; ($Kp * $ERRc) / 1")
      # No earlier error on the first check or after an all-standby check. The measured interval is
      # dropped for the nominal one when a clock step makes it implausible.
      if [ -z "$ERRp" ]; then
         D=0
      else
         dt=$(( now - LAST_CHECK ))
         (( dt < 1 || dt > DRIVE_T * 60 + 600 )) && dt=$(( DRIVE_T * 60 ))
         D=$(bc <<< "scale=4; $Kd * ($ERRc - $ERRp) * 60 / $dt")
      fi
      PD=$(bc <<< "$P + $D")

      Tmean=$(printf %0.2f "$Tmean")
      ERRc=$(printf %0.2f "$ERRc")
      P=$(printf %0.2f "$P")
      D=$(printf %0.2f "$D")
      PD=$(printf %0.f "$PD")

      DUTY_DRIVE=$(constrain $(( DUTY_CURR + PD )) "$DUTY_MIN" "$DUTY_MAX")
   fi
   LAST_CHECK=$now

   if [[ $DUTY_DRIVE -ge $DUTY_CPU ]]; then
      adjust_fans "$DUTY_DRIVE"
      DRIVER="Drives"
   else
      DRIVER="CPU"
   fi

   printf "^%-3s %5s" "${Tmax:---}" "${Tmean:----}"
}

# Send duty $1 when it differs from the current duty, and record it.
adjust_fans() {
   if [[ $1 -ne $DUTY_CURR ]]; then
      set_duty 0 "$1"
      DUTY_CURR=$1
   fi
}

#####################################################
# SETUP
#####################################################
printf "\n****** SETTINGS ******\n"
printf "Drive temperature setpoint (C): %s\n" "$SP"
printf "Kp=%s, Kd=%s\n" "$Kp" "$Kd"
printf "Drive check interval (main cycle; minutes): %s\n" "$DRIVE_T"
printf "CPU check interval (seconds): %s\n" "$CPU_T"
printf "CPU reference temperature (C): %s\n" "$CPU_REF"
printf "CPU scalar: %s\n" "$CPU_SCALE"
printf "Fan min/max duty cycle: %s/%s\n" "$DUTY_MIN" "$DUTY_MAX"

if [ "$HOW_DUTY" == 1 ] ; then
   printf "Reading fan duty from board \n"
else
   printf "Assuming fan duty as set \n"
fi

detect_cpu_temp_source
if [ ${#CPU_TEMP_OIDS[@]} -gt 0 ]; then
   printf "Getting CPU temperatures via sysctl \n"
else
   printf "Getting CPU temperature via ipmitool sensor \"%s\" (sysctl not available) \n" "$CPU_TEMP_SENSOR"
fi

CPU_LOOPS=$(( DRIVE_T * 60 / CPU_T ))
FIRST_TIME=1
ERRc=""
LAST_CHECK=$SECONDS

build_devlist

read_fan_data

# Full mode keeps the BMC from changing the duty; it needs a moment before the next command.
# A duty read under another mode is the BMC's own: start at 50 % then too.
if [[ MODE -ne 1 ]]; then
   set_mode 1
   sleep 1
   DUTY_CURR=""
fi
if [ -z "$DUTY_CURR" ]; then
   DUTY_CURR=$(constrain 50 "$DUTY_MIN" "$DUTY_MAX")
   set_duty 0 "$DUTY_CURR"
   sleep 1
fi
DUTY_DRIVE=$DUTY_CURR

drive_health_warning

printf "\n%s %51s %s \n" "Key to drive status symbols:  * spinning;  _ standby;  ? unknown" "Version" "$VERSION"
print_header
CPU_check_adjust

###########################################
# Main loop: drives every DRIVE_T minutes, CPU every CPU_T seconds in between
###########################################
while true ; do
   quarter_day_boundary "$DRIVE_T" && print_header

   DUTY_PREV=$DUTY_CURR
   DRIVES_check_adjust

   printf "%6s %6s %6.6s %3s %-6s %2d/%-5d " "${ERRc:----}" "${P:----}" "${D:----}" "${CPU_TEMP:----}" "$DRIVER" "$DUTY_PREV" "$DUTY_CURR"

   if [[ $FIRST_TIME -eq 0 ]]; then
      # let the fan settle on the new duty before reading it
      sleep 5
      read_fan_data
   fi
   FIRST_TIME=0

   printf "%-8s %4s " "$MODEt" "${RPM:----}"

   NEXT_CPU=$SECONDS
   i=0
   while [ "$i" -lt "$CPU_LOOPS" ]; do
      CPU_check_adjust
      i=$(( i + 1 ))
   done
done

# The interim duties after a row are those set during its CPU cycles. Drive status uses
# joeschmuck's smartctl method (exit 0 spinning, 2 standby), which also works on an HBA:
# https://forums.freenas.org/index.php?threads/how-to-find-out-if-a-drive-is-spinning-down-properly.2068/#post-28451
