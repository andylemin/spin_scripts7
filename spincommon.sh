# Helpers shared by the spin scripts; sourced after their settings (IPMITOOL, SMARTCTL,
# CAMCONTROL, DEVLIST_EXCLUDE, CPU_TEMP_SENSOR, LOG, LOG_CONSOLE).
# shellcheck disable=SC2034

# bc reads only a dot as the decimal point; keep printf's output in the same locale.
export LC_ALL=C

# Startup refusal. Before setup_logging the message goes to the console and is appended to LOG, so
# an unattended start that fails still leaves its reason in the log.
fail() {
   if [ "$LOGGING" == 1 ]; then
      echo "$*"
   else
      echo "$*" >&2
      [ -n "$LOG" ] && { echo "$*" >> "$LOG"; } 2> /dev/null
   fi
   exit 1
}

# stdout and stderr to LOG, plus the console when LOG_CONSOLE is 1. An unwritable LOG stops the
# script: the exec redirections below would fail quietly and run on without a log.
setup_logging() {
   : "${LOG:?LOG is not set in the settings}"
   [[ $LOG_CONSOLE =~ ^[01]$ ]] || fail "LOG_CONSOLE must be 0 or 1, not '$LOG_CONSOLE'; check the settings"
   ( : >> "$LOG" ) 2> /dev/null || fail "cannot write the log file $LOG; check LOG in the settings"
   if [ "$LOG_CONSOLE" = 1 ]; then
      exec > >(tee -i "$LOG") 2>&1
   else
      exec > "$LOG" 2>&1
   fi
   LOGGING=1
}

# The EXIT trap also runs on a fatal signal.
TMPFILE=$(mktemp "${TMPDIR:-/tmp}/spin.XXXXXX") || exit 1
SDR_CACHE=""
trap 'rm -f "$TMPFILE" ${SDR_CACHE:+"$SDR_CACHE"}' EXIT

# Named settings must be non-empty.
require_settings() {
   local v
   for v in "$@"; do
      [ -n "${!v}" ] || fail "$v is not set in the settings"
   done
}

# Named settings must exist; empty is allowed.
require_defined() {
   local v
   for v in "$@"; do
      [[ -v $v ]] || fail "$v is not set in the settings"
   done
}

# The first word of a tool setting is the command; IPMITOOL may carry remote options after it.
require_tools() {
   local v cmd
   for v in "$@"; do
      cmd=${!v%% *}
      command -v "$cmd" > /dev/null 2>&1 || fail "$v: $cmd not found; check the settings"
   done
}

# Named settings must be whole numbers from $1 to $2 without a leading zero (bash arithmetic reads
# 08 as an error and 050 as octal).
require_integers() {
   local min=$1 max=$2 v
   shift 2
   for v in "$@"; do
      if ! [[ ${!v} =~ ^(0|[1-9][0-9]{0,8})$ ]] || (( ${!v} < min || ${!v} > max )); then
         fail "$v must be a whole number from $min to $max with no leading zero, not '${!v}'; check the settings"
      fi
   done
}

# Named settings must be numbers of 0 or more; decimals allowed.
require_numbers() {
   local v
   for v in "$@"; do
      [[ ${!v} =~ ^[0-9]+(\.[0-9]+)?$ ]] || fail "$v must be a number, not '${!v}'; check the settings"
   done
}

# camcontrol devlist lines end in (pass#,[a]da#) or ([a]da#,pass#).
get_disk_name() {
   if [[ $LINE == *",p"* ]]; then
      DEVID=$(echo "$LINE" | awk -F '(' '{print $2}' | awk -F ',' '{print $1}')
   else
      DEVID=$(echo "$LINE" | awk -F ',' '{print $2}' | awk -F ')' '{print $1}')
   fi
}

# An empty list would leave the drive zone at its minimum for ever; stop instead.
build_devlist() {
   DEVLIST=$($CAMCONTROL devlist | sed "$DEVLIST_EXCLUDE")
   [ -n "$DEVLIST" ] || fail "No drives left from '$CAMCONTROL devlist' after DEVLIST_EXCLUDE; check the settings"
   DEVCOUNT=$(echo "$DEVLIST" | wc -l | tr -d ' ')
}

# STATUS: * spinning, _ standby, ? unknown. smartctl exits 2 for a standby drive and for one it
# cannot open; only standby prints "Device is in". Its error text is dropped: the ? cell marks it.
drive_status_temp() {
   local rc
   $SMARTCTL -a -n standby "/dev/$1" > "$TMPFILE" 2> /dev/null
   rc=$?
   TEMP=""
   if (( rc & 1 )); then
      STATUS="?"
   elif (( rc & 2 )); then
      if grep -q "^Device is in .* mode" "$TMPFILE"; then
         STATUS="_"
      else
         STATUS="?"
      fi
   else
      STATUS="*"
      TEMP=$(awk '$1 == 194 { t = $10 }
                  $1 == 190 { a = $10 }
                  /^Current Drive Temperature:/ { t = $4 }
                  END { print (t != "" ? t : a) }' "$TMPFILE")
      [[ $TEMP =~ ^[0-9]+$ ]] || TEMP=""
   fi
}

# smartctl exit bits above 1 report SMART problems.
drive_health_warning() {
   while read -r LINE; do
      get_disk_name
      $SMARTCTL -a -n standby "/dev/$DEVID" > "$TMPFILE"
      if [ $? -gt 2 ]; then
         printf "\n* WARNING - Drive %-4s has a record of past errors.\n" "$DEVID"
         printf "Use smartctl to check. NB; transient issues (Eg, a hot day) will report forever.\n"
      fi
   done <<< "$DEVLIST"
}

# ipmitool raw prints one hex byte with a leading space; anything else is a failed read.
ipmi_byte() {
   local raw=${1//[[:space:]]/}
   if [[ $raw =~ ^[0-9a-fA-F]{1,2}$ ]]; then
      echo $((0x$raw))
   else
      echo ""
   fi
}

# MODE and MODEt from the board; both empty, and status 1, when the read fails. The rows mark a
# failed read with ---, so ipmitool's error text is dropped rather than spliced into them.
read_mode() {
   MODE=$(ipmi_byte "$($IPMITOOL raw 0x30 0x45 0 2> /dev/null)")
   case $MODE in
      "") MODEt=""; return 1 ;;
      0) MODEt="Standard" ;;
      1) MODEt="Full" ;;
      2) MODEt="Optimal" ;;
      4) MODEt="HeavyIO" ;;
      *) MODEt="Mode$MODE" ;;
   esac
}

# Duty of zone $1 as reported by the board; empty when the read fails (the callers note it).
read_duty() {
   ipmi_byte "$($IPMITOOL raw 0x30 0x70 0x66 0 "$1" 2> /dev/null)"
}

# set_duty ZONE DUTY and set_mode MODE; echo -n drops the newline ipmitool prints after a set.
set_duty() {
   echo -n "$($IPMITOOL raw 0x30 0x70 0x66 1 "$1" "$2")"
}
set_mode() {
   echo -n "$($IPMITOOL raw 0x30 0x45 1 "$1")"
}

# FAN1..FAN5, FANA, FANB from one SDR walk: the integer at the start of the reading column, so
# 0 RPM is a reading and "no reading" is empty. A failed walk (its error text dropped, as for the
# mode and duty reads) leaves every fan empty. SDR stays global for the hooks.
read_fan_rpms() {
   local f
   SDR=$($IPMITOOL sdr 2> /dev/null)
   for f in FAN1 FAN2 FAN3 FAN4 FAN5 FANA FANB; do
      printf -v "$f" '%s' "$(printf '%s\n' "$SDR" |
         awk -F '|' -v f="$f" '$1 ~ "^" f " *$" { match($2, /[0-9]+/); print substr($2, RSTART, RLENGTH); exit }')"
   done
}

# With -S <dump> ipmitool reads a sensor by name without walking the repository.
init_sdr_cache() {
   SDR_CACHE=$(mktemp "${TMPDIR:-/tmp}/spin-sdr.XXXXXX") || return 1
   if ! $IPMITOOL sdr dump "$SDR_CACHE" > /dev/null 2>&1; then
      rm -f "$SDR_CACHE"
      SDR_CACHE=""
   fi
}

# RPM of fan $1 read by name; empty without a reading.
read_fan_rpm() {
   local line
   if [ -n "$SDR_CACHE" ]; then
      line=$($IPMITOOL -S "$SDR_CACHE" sensor reading "$1")
   else
      line=$($IPMITOOL sensor reading "$1")
   fi
   line=${line##*|}
   echo "${line//[[:space:]]/}"
}

# Empty CPU_TEMP_OIDS means no coretemp; get_cpu_temp then uses the IPMI sensor.
detect_cpu_temp_source() {
   local n ncpu
   CPU_TEMP_OIDS=()
   if sysctl -n dev.cpu.0.temperature > /dev/null 2>&1; then
      ncpu=$(sysctl -n hw.ncpu)
      for (( n = 0; n < ncpu; n++ )); do
         CPU_TEMP_OIDS+=("dev.cpu.$n.temperature")
      done
   fi
}

# Hottest core, or the IPMI sensor; empty unless an integer was read.
get_cpu_temp() {
   if [ ${#CPU_TEMP_OIDS[@]} -gt 0 ]; then
      CPU_TEMP=$(sysctl -n "${CPU_TEMP_OIDS[@]}" 2> /dev/null |
         awk -F. '$1 ~ /^[0-9]+$/ && (m == "" || $1 + 0 > m) { m = $1 + 0 } END { print m }')
   else
      CPU_TEMP=$($IPMITOOL sensor get "$CPU_TEMP_SENSOR" 2> /dev/null | awk '/Sensor Reading/ { print $4 }')
      CPU_TEMP=${CPU_TEMP%%.*}
   fi
   [[ $CPU_TEMP =~ ^[0-9]+$ ]] || CPU_TEMP=""
}

# $1 clamped to the range $2..$3.
constrain() {
   local v=$1
   (( v < $2 )) && v=$2
   (( v > $3 )) && v=$3
   echo "$v"
}

# True during the first $1 minutes after 00:00, 06:00, 12:00 and 18:00.
quarter_day_boundary() {
   (( 10#$(date +%H%M) % 600 < $1 ))
}

# Sleep until SECONDS reaches $1, at most $2 s: SECONDS follows the wall clock, so a clock step
# must not stall the loop.
sleep_until() {
   local w=$(( $1 - SECONDS ))
   (( w > $2 )) && w=$2
   (( w > 0 )) && sleep "$w"
   return 0
}

# Row prefix: the time and two spaces.
print_time() {
   printf '%s  ' "$(date "+%H:%M:%S")"
}
