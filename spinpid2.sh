#!/usr/bin/env bash

# Fan control for Supermicro boards with two fan zones: a feedback loop (Glorious1's P and D terms,
# added to the previous duty) holds the mean drive temperature at a setpoint with the peripheral
# zone; the CPU zone follows the CPU temperature.
# Run as superuser; settings in spinpid2.config.
VERSION="2026-10-20"

DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
# shellcheck source=spinpid2.config
source "$DIR/spinpid2.config" || { echo "cannot read $DIR/spinpid2.config" >&2; exit 1; }
# shellcheck source=spincommon.sh
source "$DIR/spincommon.sh" || { echo "cannot read $DIR/spincommon.sh" >&2; exit 1; }

# Settings and the drive list are checked before the log opens; a refusal is shown on the console
# and appended to LOG.
require_settings IPMITOOL SMARTCTL CAMCONTROL CPU_LOG_YES CPU_LOG SP DRIVE_T Kp Kd \
   ZONE_CPU ZONE_PER DUTY_PER_MIN DUTY_PER_MAX DUTY_CPU_MIN DUTY_CPU_MAX \
   RPM_CPU_30 RPM_CPU_MAX RPM_PER_30 RPM_PER_MAX HOW_DUTY CPU_T CPU_REF CPU_SCALE
require_defined DEVLIST_EXCLUDE CPU_TEMP_SENSOR
require_tools IPMITOOL SMARTCTL CAMCONTROL
require_integers 0 1 ZONE_CPU ZONE_PER HOW_DUTY CPU_LOG_YES
[ "$ZONE_CPU" != "$ZONE_PER" ] || fail "ZONE_CPU and ZONE_PER must differ; check spinpid2.config"
require_integers 1 1440 DRIVE_T
require_integers 1 86400 CPU_T
(( CPU_T <= DRIVE_T * 60 )) || fail "CPU_T must not be longer than DRIVE_T minutes; check spinpid2.config"
require_integers 1 99999 RPM_CPU_30 RPM_CPU_MAX RPM_PER_30 RPM_PER_MAX
(( RPM_CPU_30 <= RPM_CPU_MAX && RPM_PER_30 <= RPM_PER_MAX )) || fail "RPM_*_30 must not be above RPM_*_MAX; check spinpid2.config"
require_integers 0 100 DUTY_PER_MIN DUTY_PER_MAX DUTY_CPU_MIN DUTY_CPU_MAX
(( DUTY_PER_MIN <= DUTY_PER_MAX && DUTY_CPU_MIN <= DUTY_CPU_MAX )) || fail "DUTY_*_MIN must not be above DUTY_*_MAX; check spinpid2.config"
require_integers 0 200 CPU_REF
require_integers 1 100 CPU_SCALE
require_numbers SP Kp Kd
if [ "$CPU_LOG_YES" == 1 ]; then
   ( : >> "$CPU_LOG" ) 2> /dev/null || fail "cannot write the CPU log $CPU_LOG; check CPU_LOG in spinpid2.config"
fi
build_devlist
setup_logging

# Column header; printed at start and in the first DRIVE_T minutes of each quarter day.
print_header() {
   DATE=$(date +"%A, %b %d")
   printf "\n%-*s %3s %16s %29s \n" "$(( DEVCOUNT * 5 + 42 ))" "$DATE" "CPU" "New_Fan%" "New_RPM__________________________________"
   echo -n "          "
   while read -r LINE ; do
      get_disk_name
      printf "%-5s" "$DEVID"
   done <<< "$DEVLIST"
   printf "%4s %5s %6s %6s %6s %3s %-7s %s %-4s %5s %5s %5s %5s %5s %5s %5s" "Tmax" "Tmean" "ERRc" "P" "D" "TEMP" "MODE" "CPU" "PER" "FANA" "FANB" "FAN1" "FAN2" "FAN3" "FAN4" "FAN5"
}

# Board duties (with HOW_DUTY=1), fan mode and fan RPMs; a failed duty read keeps the last value.
read_fan_data() {
   local d
   if [ "$HOW_DUTY" == 1 ]; then
      d=$(read_duty "$ZONE_CPU")
      if [ -n "$d" ]; then
         DUTY_CPU=$d
      elif [ -n "$DUTY_CPU" ]; then
         echo -n "[CPU duty read failed; keeping $DUTY_CPU] "
      fi
      d=$(read_duty "$ZONE_PER")
      if [ -n "$d" ]; then
         DUTY_PER=$d
      elif [ -n "$DUTY_PER" ]; then
         echo -n "[PER duty read failed; keeping $DUTY_PER] "
      fi
   fi
   read_mode
   read_fan_rpms
}

# CPU zone duty from the CPU temperature; also lets the PER zone fall while the drives are cool.
CPU_check_adjust() {
   NEXT_CPU=$(( NEXT_CPU + CPU_T ))
   get_cpu_temp
   DUTY_CPU_LAST=$DUTY_CPU
   if [ -n "$CPU_TEMP" ]; then
      DUTY_CPU=$(constrain $(( (CPU_TEMP - CPU_REF) * CPU_SCALE + DUTY_CPU_MIN )) "$DUTY_CPU_MIN" "$DUTY_CPU_MAX")
      CPU_TEMP_WARNED=0
   elif [ "$CPU_TEMP_WARNED" != 1 ]; then
      printf "\n%s\n" "CPU temperature unavailable; keeping CPU duty $DUTY_CPU"
      CPU_TEMP_WARNED=1
   fi
   adjust_fans "$ZONE_CPU" "$DUTY_CPU" "$DUTY_CPU_LAST"

   # Drives more than 1 C below the setpoint and PD < 0: step the PER duty down by PD each CPU cycle.
   if [[ -n $Tmean && PD -lt 0 && $(bc <<< "$Tmean < ($SP-1)") == 1 ]]; then
      DUTY_PER_LAST=$DUTY_PER
      DUTY_PER=$(constrain $(( DUTY_PER + PD )) "$DUTY_PER_MIN" "$DUTY_PER_MAX")
      adjust_fans "$ZONE_PER" "$DUTY_PER" "$DUTY_PER_LAST"
   fi

   sleep_until "$NEXT_CPU" "$CPU_T"

   if [ "$CPU_LOG_YES" == 1 ]; then
      print_interim_CPU >> "$CPU_LOG"
   fi
   # Config hook; may read CPU_TEMP, DUTY_CPU, DUTY_PER, FAN*.
   declare -f -F Post_CPU_check_adjust > /dev/null && Post_CPU_check_adjust
}

# Drive row, PD terms and the PER zone duty. With no temperature at all the duty is the minimum when
# every drive sleeps, but is kept when any drive is awake without one: it may be hot.
DRIVES_check_adjust() {
   local now dt unread=0
   Tmax=0; Tsum=0
   i=0
   while read -r LINE ; do
      get_disk_name
      drive_status_temp "$DEVID"
      if [ -n "$TEMP" ]; then
         Tsum=$(( Tsum + TEMP ))
         (( TEMP > Tmax )) && Tmax=$TEMP
         i=$(( i + 1 ))
      elif [ "$STATUS" != "_" ]; then
         unread=$(( unread + 1 ))
      fi
      printf "%s%-2s  " "$STATUS" "${TEMP:---}"
   done <<< "$DEVLIST"

   DUTY_PER_LAST=$DUTY_PER
   now=$SECONDS
   if [ "$i" -eq 0 ]; then
      Tmean=""; Tmax=""; P=""; D=""; ERRc=""; PD=0
      if (( unread == 0 )); then
         DUTY_PER=$DUTY_PER_MIN
         BLIND_NOTED=0
      elif [ "$BLIND_NOTED" != 1 ]; then
         printf "[no drive temperature; keeping PER duty %s] " "$DUTY_PER"
         BLIND_NOTED=1
      fi
   else
      BLIND_NOTED=0
      Tmean=$(bc <<< "scale=2; $Tsum / $i")
      ERRp=$ERRc
      ERRc=$(bc <<< "scale=2; ($Tmean - $SP) / 1")
      P=$(bc <<< "scale=3; ($Kp * $ERRc) / 1")
      # No earlier error on the first check or after a check with no drive temperature. The measured
      # interval is dropped for the nominal one when a clock step makes it implausible; a BMC reset (up to about
      # four minutes) stays within the bound.
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

      DUTY_PER=$(constrain $(( DUTY_PER_LAST + PD )) "$DUTY_PER_MIN" "$DUTY_PER_MAX")
   fi
   LAST_CHECK=$now

   adjust_fans "$ZONE_PER" "$DUTY_PER" "$DUTY_PER_LAST"

   printf "^%-3s %5s" "${Tmax:---}" "${Tmean:----}"
}

# $1 zone, $2 duty, $3 last duty; sends when they differ or on the first call.
adjust_fans() {
   local zone=$1 duty=$2 last=$3
   if [[ $duty -ne $last ]] || [[ $FIRST_TIME -eq 1 ]]; then
      set_duty "$zone" "$duty"
   fi
   FIRST_TIME=0
   if [ "$zone" == "$ZONE_CPU" ]; then
      DUTY_CPU_SET=$duty
   else
      DUTY_PER_SET=$duty
   fi
}

# One CPU-log line: time, reference fan RPM, CPU temperature, CPU duty.
print_interim_CPU() {
   local rpm
   rpm=$(read_fan_rpm "$RPM_CPU")
   printf "%s%7s %5s %5d \n" "$(print_time)" "${rpm:----}" "${CPU_TEMP:----}" "$DUTY_CPU"
}

# $1 zone name, $2 reference fan, $3 requested duty, $4 minimum duty, $5 fast limit at the minimum,
# $6 slow limit at 95 %+. True for a mismatch to escalate; END_$1 records the end that failed (MIN
# or MAX) and PASSED_$1 whether the last reading followed the duty. A fan without a reading is noted
# once and not checked. An end held after a BMC reset (HELDMIN_$1, HELDMAX_$1) is not escalated
# again until the fan has followed the duty at that end; the other end is tested on its own.
zone_mismatch() {
   local rpm=${!2} noread=NOREAD_$1 end="" held
   if [ -z "$rpm" ]; then
      [ "${!noread}" == 1 ] || printf "\n%s\n" "No RPM reading for $2; $1 zone not checked"
      printf -v "$noread" 1
      return 1
   fi
   printf -v "$noread" 0
   if [[ ${3} -ge 95 && rpm -lt ${6} ]]; then
      end=MAX
   elif [[ ${3} -le ${4} && rpm -gt ${5} ]]; then
      end=MIN
   fi
   if [ -n "$end" ]; then
      printf -v "END_$1" '%s' "$end"
      printf -v "PASSED_$1" 0
      held=HELD${end}_$1
      [ "${!held}" == 1 ] && return 1
      printf "\n%s\n" "Mismatch between $1 duty and RPM: duty $3, $2 $rpm RPM (limits: below $6 at 95 %+, above $5 at $4 %)"
      return 0
   fi
   printf -v "PASSED_$1" 1
   [[ ${3} -ge 95 ]] && printf -v "HELDMAX_$1" 0
   [[ ${3} -le ${4} ]] && printf -v "HELDMIN_$1" 0
   return 1
}

# A reference fan running fast at the minimum duty or slow at 95 %+ is a mismatch; the duty
# compared is the one last requested.
mismatch_test() {
   MISMATCH=0; MISMATCH_CPU=0; MISMATCH_PER=0
   if zone_mismatch CPU "$RPM_CPU" "$DUTY_CPU_SET" "$DUTY_CPU_MIN" "$RPM_CPU_LOW" "$RPM_CPU_MAX"; then
      MISMATCH=1; MISMATCH_CPU=1
   fi
   if zone_mismatch PER "$RPM_PER" "$DUTY_PER_SET" "$DUTY_PER_MIN" "$RPM_PER_LOW" "$RPM_PER_MAX"; then
      MISMATCH=1; MISMATCH_PER=1
   fi
}

# $1 zone name, $2 reference fan, $3 1 when this zone's mismatch led to the reset. After the
# escalation a zone still mismatched, or one that led to the reset and has not been seen following
# the duty since, is held at the end that failed (see zone_mismatch), so the reset is not repeated
# every drive cycle.
hold_mismatch() {
   local mismatch=MISMATCH_$1 passed=PASSED_$1 end=END_$1
   if [ "${!mismatch}" == 1 ]; then
      printf -v "HELD${!end}_$1" 1
      printf "%s\n" "$1 mismatch persists after the BMC reset; not escalated again until $2 follows the duty. Check RPM_$1_30, RPM_$1_MAX and the BMC fan thresholds."
   elif [ "$3" == 1 ] && [ "${!passed}" != 1 ]; then
      printf -v "HELD${!end}_$1" 1
      printf "%s\n" "$1 mismatch not seen cleared after the BMC reset ($2 has no reading); not escalated again until $2 follows the duty."
   fi
}

# With HOW_DUTY=1 read_fan_data has replaced DUTY_* with the board's value; restore the request.
force_set_fans() {
   if [ "$MISMATCH_CPU" == 1 ]; then
      FIRST_TIME=1
      DUTY_CPU=$DUTY_CPU_SET
      adjust_fans "$ZONE_CPU" "$DUTY_CPU" "$DUTY_CPU_LAST"
      echo "Re-sending CPU duty $DUTY_CPU_SET"
      sleep 5
   fi
   if [ "$MISMATCH_PER" == 1 ]; then
      FIRST_TIME=1
      DUTY_PER=$DUTY_PER_SET
      adjust_fans "$ZONE_PER" "$DUTY_PER" "$DUTY_PER_LAST"
      echo "Re-sending PER duty $DUTY_PER_SET"
      sleep 5
   fi
}

# The reset puts both zones at the BMC default; the caller re-sends both requested duties. A BMC
# still booting after 120 s is polled for up to another 120 s before Full mode is set.
reset_bmc() {
   local i=0
   print_time
   echo -n "Resetting BMC after second attempt failed to fix mismatch -- "
   $IPMITOOL bmc reset cold
   sleep 120
   until read_mode 2> /dev/null || (( i++ >= 12 )); do
      sleep 10
   done
   set_mode 1
   sleep 1
   read_mode
   read_fan_rpms
}

#####################################################
# SETUP
#####################################################
printf "\n****** SETTINGS ******\n"
printf "CPU zone %s; Peripheral zone %s\n" "$ZONE_CPU" "$ZONE_PER"
printf "CPU fans min/max duty cycle: %s/%s\n" "$DUTY_CPU_MIN" "$DUTY_CPU_MAX"
printf "PER fans min/max duty cycle: %s/%s\n" "$DUTY_PER_MIN" "$DUTY_PER_MAX"
printf "CPU fans - measured RPMs at 30%% and 100%% duty cycle: %s/%s\n" "$RPM_CPU_30" "$RPM_CPU_MAX"
printf "PER fans - measured RPMs at 30%% and 100%% duty cycle: %s/%s\n" "$RPM_PER_30" "$RPM_PER_MAX"

# Slow: below 80 % of the RPM at 100 % duty. Fast: above 120 % of the RPM at the minimum duty,
# interpolated between the 30 % and 100 % readings for minima above 30 %; below that fans sit near
# their floor, so the 30 % reading is used.
M=$(( DUTY_CPU_MIN > 30 ? DUTY_CPU_MIN : 30 ))
RPM_CPU_LOW=$(( (RPM_CPU_30 * 70 + (RPM_CPU_MAX - RPM_CPU_30) * (M - 30)) * 12 / 700 ))
M=$(( DUTY_PER_MIN > 30 ? DUTY_PER_MIN : 30 ))
RPM_PER_LOW=$(( (RPM_PER_30 * 70 + (RPM_PER_MAX - RPM_PER_30) * (M - 30)) * 12 / 700 ))
unset M
RPM_CPU_MAX=$(( RPM_CPU_MAX * 8 / 10 ))
RPM_PER_MAX=$(( RPM_PER_MAX * 8 / 10 ))
printf "CPU fan mismatch: below %s RPM at 95%%+ duty, above %s RPM at %s%% duty\n" "$RPM_CPU_MAX" "$RPM_CPU_LOW" "$DUTY_CPU_MIN"
printf "PER fan mismatch: below %s RPM at 95%%+ duty, above %s RPM at %s%% duty\n" "$RPM_PER_MAX" "$RPM_PER_LOW" "$DUTY_PER_MIN"

printf "Drive temperature setpoint (C): %s\n" "$SP"
printf "Kp=%s, Kd=%s\n" "$Kp" "$Kd"
printf "Drive check interval (main cycle; minutes): %s\n" "$DRIVE_T"
printf "CPU check interval (seconds): %s\n" "$CPU_T"
printf "CPU reference temperature (C): %s\n" "$CPU_REF"
printf "CPU scalar: %s\n" "$CPU_SCALE"

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

# Reference fan per zone, read through ${!RPM_CPU} / ${!RPM_PER}.
if [[ ZONE_PER -eq 0 ]]; then
   RPM_PER=FAN1
   RPM_CPU=FANA
else
   RPM_PER=FANA
   RPM_CPU=FAN1
fi

read_fan_data

# Full mode keeps the BMC from changing the duty; it needs a moment before the next command.
if [[ MODE -ne 1 ]]; then
   set_mode 1
   sleep 1
fi

# Both zones start at a duty this script has sent, so the mismatch test compares a request: 50 %
# when the board's duty is unknown (HOW_DUTY=0) or the fans run fast, else the board's duty clamped.
[[ ${!RPM_PER} -ge RPM_PER_MAX || -z ${DUTY_PER+x} ]] && DUTY_PER=50
DUTY_PER=$(constrain "$DUTY_PER" "$DUTY_PER_MIN" "$DUTY_PER_MAX")
set_duty "$ZONE_PER" "$DUTY_PER"
sleep 1
[[ ${!RPM_CPU} -ge RPM_CPU_MAX || -z ${DUTY_CPU+x} ]] && DUTY_CPU=50
DUTY_CPU=$(constrain "$DUTY_CPU" "$DUTY_CPU_MIN" "$DUTY_CPU_MAX")
set_duty "$ZONE_CPU" "$DUTY_CPU"
sleep 1
DUTY_CPU_SET=$DUTY_CPU
DUTY_PER_SET=$DUTY_PER

drive_health_warning

printf "\n%s \n" "Key to drive status symbols:  * spinning (*-- without a temperature);  _ standby;  ? not readable"
printf "%0s %s \n" "Version" "$VERSION"
print_header

get_cpu_temp

if [ "$CPU_LOG_YES" == 1 ] ; then
   init_sdr_cache
   printf "%s \n%s \n%17s %5s %5s \n" "$DATE" "Printed every CPU cycle" "$RPM_CPU" "Temp" "Duty" > "$CPU_LOG"
fi

###########################################
# Main loop: drives every DRIVE_T minutes, CPU every CPU_T seconds in between
###########################################
while true ; do
   quarter_day_boundary "$DRIVE_T" && print_header

   echo
   print_time

   DRIVES_check_adjust

   # let the fans settle on the new duty before reading them
   sleep 5
   read_fan_data

   printf "%7s %6s %6.6s %4s %-7s %3d %3d %5s %5s %5s %5s %5s %5s %5s" "${ERRc:----}" "${P:----}" "${D:----}" "${CPU_TEMP:----}" "${MODEt:----}" "$DUTY_CPU" "$DUTY_PER" "${FANA:----}" "${FANB:----}" "${FAN1:----}" "${FAN2:----}" "${FAN3:----}" "${FAN4:----}" "${FAN5:----}"
   # Config hook; may read Tmean, Tmax, ERRc, P, D, PD, DUTY_PER, DUTY_CPU, CPU_TEMP, FAN*, SDR as logged in this row.
   declare -f -F Post_DRIVES_check_adjust > /dev/null && Post_DRIVES_check_adjust

   # A BMC running in its own fan mode (back late from a reset, or restarted) is put back in Full
   # mode with both duties re-sent before the test.
   if [[ -n $MODE && MODE -ne 1 ]]; then
      printf "\n%s\n" "Fan mode is $MODEt; restoring Full mode"
      set_mode 1
      sleep 1
      MISMATCH_CPU=1; MISMATCH_PER=1
      force_set_fans
      read_fan_data
   fi

   # Two re-sends of a mismatched duty; if the second fails, a BMC reset with both zones re-sent,
   # then a last re-send. The zones that caused the reset, and whether each was seen following the
   # duty afterwards, are recorded for hold_mismatch.
   ATTEMPTS=0; RESET_CPU=0; RESET_PER=0
   mismatch_test
   while [ "$MISMATCH" == 1 ]; do
      force_set_fans
      ATTEMPTS=$(( ATTEMPTS + 1 ))
      read_fan_data
      mismatch_test
      if [ "$ATTEMPTS" == 2 ] && [ "$MISMATCH" == 1 ]; then
         RESET_CPU=$MISMATCH_CPU; RESET_PER=$MISMATCH_PER
         # shellcheck disable=SC2034  # set by zone_mismatch and read in hold_mismatch by name
         PASSED_CPU=0 PASSED_PER=0
         reset_bmc
         MISMATCH_CPU=1; MISMATCH_PER=1
         force_set_fans
         read_fan_data
         mismatch_test
      fi
      [ "$ATTEMPTS" == 3 ] && break
   done
   hold_mismatch CPU "$RPM_CPU" "$RESET_CPU"
   hold_mismatch PER "$RPM_PER" "$RESET_PER"

   NEXT_CPU=$SECONDS
   i=0
   while [ "$i" -lt "$CPU_LOOPS" ]; do
      CPU_check_adjust
      i=$(( i + 1 ))
   done
done

# The fan RPMs in a row are read 5 s after the new PER duty was applied. Drive status uses
# joeschmuck's smartctl method (exit 0 spinning, 2 standby), which also works on an HBA:
# https://forums.freenas.org/index.php?threads/how-to-find-out-if-a-drive-is-spinning-down-properly.2068/#post-28451
