#!/usr/bin/env bash

# Step both fan zones from DUTY_START down to DUTY_STOP, logging every fan's RPM at each step, to
# find the RPM/duty relation and stall point of each fan. Run as superuser with no fan control
# script running.
VERSION="2026-10-17"

#################  SETTINGS  ################

LOG=/var/log/spintest.log
# 1: log file and console; 0: log file only.
LOG_CONSOLE=1

# Add " -H <host> -U <user> -P <password>" inside the quotes to drive a remote BMC.
IPMITOOL="/usr/local/bin/ipmitool"

# Duty cycle (%) sweep, from DUTY_START down to DUTY_STOP in steps of 10. Fans may stall near
# the bottom; raise DUTY_STOP if yours do.
DUTY_START=100
DUTY_STOP=20

#############################################

DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
# shellcheck source=spincommon.sh
source "$DIR/spincommon.sh" || { echo "cannot read $DIR/spincommon.sh" >&2; exit 1; }
setup_logging
require_settings IPMITOOL DUTY_START DUTY_STOP
require_tools IPMITOOL
if [[ ! $DUTY_START =~ ^[0-9]+$ || ! $DUTY_STOP =~ ^[0-9]+$ || $DUTY_START -gt 100 || $DUTY_STOP -gt $DUTY_START || $DUTY_STOP -lt 10 ]]; then
   echo "DUTY_START and DUTY_STOP must be whole numbers with 100 >= DUTY_START >= DUTY_STOP >= 10"
   exit 1
fi

# Table header with a timestamp; printed before and after the confirmation.
print_header() {
   echo
   date +"%A, %b %d, %H:%M:%S"
   printf "%44s %41s \n" "___Duty%___" "Curr_RPM_________________________________"
   printf "%28s %9s %5s %5s %5s %5s %5s %5s %5s %5s \n" "MODE" "Zone0" "Zone1" "FANA" "FANB" "FAN1" "FAN2" "FAN3" "FAN4" "FAN5"
}

# Duties of both zones, fan mode and fan RPMs; a failed read leaves the value empty.
read_fan_data() {
   DUTY_0=$(read_duty 0)
   DUTY_1=$(read_duty 1)
   read_mode
   read_fan_rpms
}

# One table row labelled COND: mode, both duties, the seven fan RPMs.
print_line() {
   printf "%-23s %-8s %5s %5s %5s %5s %5s %5s %5s %5s %5s \n" "$COND" "$MODEt" "${DUTY_0:----}" "${DUTY_1:----}" "${FANA:----}" "${FANB:----}" "${FAN1:----}" "${FAN2:----}" "${FAN3:----}" "${FAN4:----}" "${FAN5:----}"
}

#####################################################
# Main section
#####################################################
read_fan_data
MODEorig=$MODE
DUTY_0orig=$DUTY_0
DUTY_1orig=$DUTY_1

echo
echo "Script to determine fan RPMs associated with varying duty cycles (version $VERSION)."
echo "Duty will be varied from $DUTY_START% down to $DUTY_STOP% in steps of 10, ending at $DUTY_STOP%"
echo "(DUTY_START and DUTY_STOP in the settings at the top of the script)."
echo "After setting duty, we wait 5 seconds for equilibration before reading the fans."
echo "There should be no fan control scripts running."
echo "At very high and especially low fan speeds, the BMC may take over and change the duty:"
echo "ignore it, or adjust the fan thresholds before testing."
echo "Logging to $LOG."

print_header
COND="Conditions before test"
print_line

echo
echo "Are you ready to begin? (y/n)"
if ! read -r START || [ "$START" != "y" ]; then
   echo "Not started."
   exit
fi

print_header

# Full mode keeps the BMC from changing the duty; it needs a moment before the next command.
set_mode 1
sleep 1

# The last step is clamped so DUTY_STOP itself is measured.
i=$DUTY_START
while :; do
   set_duty 0 "$i"
   sleep 1
   set_duty 1 "$i"
   sleep 5
   read_fan_data
   COND="Duty cycle $i%"
   print_line
   (( i <= DUTY_STOP )) && break
   i=$(( i - 10 ))
   (( i < DUTY_STOP )) && i=$DUTY_STOP
done

# Restore the pre-test duties and mode.
if [ -n "$DUTY_0orig" ]; then
   set_duty 0 "$DUTY_0orig"
   sleep 1
fi
if [ -n "$DUTY_1orig" ]; then
   set_duty 1 "$DUTY_1orig"
   sleep 1
fi
set_mode "${MODEorig:-1}"
sleep 5
read_fan_data
COND="After test (restored)"
print_line
