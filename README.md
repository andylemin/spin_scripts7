# Supermicro fan control scripts

Fan control for Supermicro boards running FreeBSD / TrueNAS CORE. A feedback loop holds the mean drive temperature at a setpoint, and the CPU fans follow the CPU temperature.

All credit for the design goes to Glorious1 @ truenas.com:

- https://www.truenas.com/community/resources/fan-scripts-for-supermicro-boards-using-pid-logic.24/
- https://www.truenas.com/community/resources/fan-scripts-for-supermicro-boards-using-pid-logic.24/updates

This fork adds support for boards with seven fan headers (FAN1-FAN5, FANA, FANB) and moves the code the scripts share into one helper file. It also validates every reading from the BMC and smartctl before acting on it, and adds a drive temperature report. Please read Glorious1's guide for the background.

## Scripts

| File | Purpose | Settings |
|------|---------|----------|
| `spinpid2.sh` | Controller for boards with two fan zones (CPU and drive). | `spinpid2.config` |
| `spinpid.sh` | Controller for boards with one fan zone, which runs at the higher of the drive and CPU demands. | `spinpid.config` |
| `spincheck.sh` | Logs temperatures, fan RPMs, duty cycles, and the fan mode at a fixed interval without controlling anything. | Top of the script |
| `spintest.sh` | Steps both zones from 100 % to 20 % duty, logs every fan's RPM per step, and restores the previous mode and duties. | Top of the script |
| `spincommon.sh` | Functions shared by the four scripts above. It is sourced, not run. | |
| `hdd-temp.sh` | Prints the temperature of every ATA, SCSI/SAS, and NVMe disk without waking drives that are in standby. | |

`spintest.sh` does not start unless it can read the mode and the zone 0 duty.

## Requirements

- FreeBSD 13 or later (TrueNAS CORE) with `bash` 5 from ports on the PATH. The bash scripts start with `#!/usr/bin/env bash`.
- `ipmitool` (ports) with access to the board's BMC, `smartctl` from smartmontools, and `camcontrol` from the base system. `hdd-temp.sh` also uses `nvmecontrol`.
- Root privileges.
- A fan on header FAN1 and, for the dual-zone controller, on FANA. `spinpid2.sh` uses them as reference fans: it checks their RPM against the duty it set. `spinpid.sh` reports FAN1's RPM and checks nothing.

## Installation

1. Copy all the files into one directory, for example `/root/spinscripts`. The scripts find `spincommon.sh` and their `.config` next to themselves.
2. The scripts you run are executable in the repository. Run `chmod +x *.sh` if copying dropped the execute bits.
3. Edit the `.config` file of the controller you will use (see Settings).

A script checks its settings and the drive list before it opens the log. A failed check stops it, with the reason shown on the console and appended to the log file. The reason names any missing setting, any tool path that does not resolve, an empty drive list, and any value that is out of range. Write whole numbers without a leading zero. A missing or unwritable log also stops it but can only be reported on the console.

## Before using the fan control scripts

1. Run `spincheck.sh` for a day or so and read its log to learn your temperatures, duty cycles, and RPMs under the BMC's control.
2. With two fan zones, decide which zone does what and connect the fans accordingly. The settings and logs call the drive zone `PER`, for peripheral. Supermicro's convention is zone 0 for the numbered headers (FAN1, FAN2, ...) as CPU/system fans and zone 1 for the lettered headers (FANA, FANB) as peripheral fans. Zone 0 has more headers and there are usually more drive fans than CPU fans, so the shipped settings reverse this: `ZONE_PER=0`, `ZONE_CPU=1`. Either way FAN1 and FANA must be populated.
3. Set the BMC's fan thresholds to the fans' specifications (Ericloewe's guide on the TrueNAS forum). Thresholds belong to headers, so re-check them after moving fans (see "My fans are revving up and down?" below).
4. Run `spintest.sh` with no controller running. Its log gives each fan's RPM at every duty step. `spinpid2.sh` needs the reference fans' RPM at 30 % and at 100 % (`RPM_*_30`, `RPM_*_MAX`). The stall point of your slowest fan decides the minimum duty for either controller.
5. Review the settings and set them for your system.
6. When first using a controller, watch its log (and the CPU log if you enable it) for a couple of full cycles.

At startup the controllers switch the BMC to Full fan mode, so the BMC does not change the duty behind them. When you stop a controller, the fans keep the duty it last set.

## Settings

Shared by both controllers (`spinpid.config` and `spinpid2.config`):

| Setting | Meaning |
|---------|---------|
| `IPMITOOL`, `SMARTCTL`, `CAMCONTROL` | Tool paths. `IPMITOOL` may carry remote options inside the quotes when the script runs in a VM, for example `"/usr/local/bin/ipmitool -H host -U user -P password"`. |
| `LOG`, `LOG_CONSOLE` | Log file (truncated at every start) and whether output also reaches the console (1) or only the file (0). |
| `DEVLIST_EXCLUDE` | sed script applied to `camcontrol devlist`. Deleted lines are not drives to control (SSDs, enclosures, cards). Empty means control every device listed. |
| `SP` | Setpoint: the mean drive temperature (C) to hold. |
| `DRIVE_T` | Whole minutes between drive checks. |
| `Kp`, `Kd` | Drive controller gains: each check adds `Kp` × the error plus `Kd` × the error's change per minute to the duty (see Tuning). |
| `HOW_DUTY` | 1: read the board's duty each cycle. 0: assume the duty the script last set, for boards that misreport it. |
| `CPU_T` | Whole seconds between CPU checks (at most `DRIVE_T` minutes). |
| `CPU_REF`, `CPU_SCALE` | At and below `CPU_REF` (C) the CPU demand is the minimum duty. Each degree above adds `CPU_SCALE` duty points. Integers. |
| `CPU_TEMP_SENSOR` | IPMI sensor read when coretemp (`dev.cpu.N.temperature`) is unavailable, for example in a VM. Dual-socket boards name theirs `CPU1 Temp` and `CPU2 Temp`. |

Only in `spinpid2.config`:

| Setting | Meaning |
|---------|---------|
| `ZONE_CPU`, `ZONE_PER` | Which zone (0 or 1) is the CPU zone and which the drive zone. |
| `DUTY_PER_MIN`, `DUTY_PER_MAX`, `DUTY_CPU_MIN`, `DUTY_CPU_MAX` | Duty limits (%) per zone. |
| `RPM_CPU_30`, `RPM_CPU_MAX`, `RPM_PER_30`, `RPM_PER_MAX` | RPM of the reference fans (FANA or FAN1) at 30 % and 100 % duty, from `spintest.sh`. |
| `CPU_LOG_YES`, `CPU_LOG` | 1 logs reference CPU fan RPM, CPU temperature, and CPU duty to `CPU_LOG` each CPU cycle. Grows fast: disable after tuning. |
| `Post_DRIVES_check_adjust`, `Post_CPU_check_adjust` | Optional functions defined in the config and run after each drive row and CPU check, for example to feed Grafana. The variables they may read are listed in the config and above their calls in `spinpid2.sh`. |

Only in `spinpid.config`: `DUTY_MIN` and `DUTY_MAX`, the duty limits of the single zone.

`spincheck.sh` keeps its settings at the top of the file: `LOG`, `LOG_CONSOLE`, `T` minutes between checks, `SP` for the ERRc column, tool paths, `DEVLIST_EXCLUDE`, `CPU_TEMP_SENSOR`. It asks for the interval when run from a terminal and uses `T` otherwise. `spintest.sh` keeps `LOG`, `LOG_CONSOLE`, `IPMITOOL`, `DUTY_START`, and `DUTY_STOP`. Its sweep runs down in steps of 10 and always measures `DUTY_STOP`.

## How the controllers work

For `spinpid.sh`, read "drive zone" below as its drive demand: the single zone runs at the higher of the drive and CPU demands.

- Every `DRIVE_T` minutes the controller polls each drive with `smartctl -n standby`, so sleeping drives are not woken. Spinning drives contribute to the mean temperature. Each check adds P = `Kp` × ERRc and D = `Kd` × the change in ERRc per minute to the previous drive-zone duty, within the configured limits (see Tuning). D is 0 on the first check and after a check with no drive temperature, and it uses the measured interval between checks.
- With every drive in standby, the drive zone runs at its minimum duty. When no drive reports a temperature while any is awake, the drives may be hot, so the drive demand is left as it was. The row notes this once per episode.
- Every `CPU_T` seconds the controller sets the CPU demand from the hottest core (or the IPMI sensor). While the drives are over 1 C below the setpoint and the drive correction is negative, each CPU check lowers the drive zone by it.
- A failed duty read keeps the last duty and logs a note. An unreadable CPU temperature keeps the CPU duty and is logged once.

`spinpid2.sh` also watches the fans after each drive check:

- It compares the duty it requested with the reference fans' RPM. A fan running fast at the minimum duty, or slow at 95 % and above, is a mismatch. The settings banner prints the thresholds at startup. A fan without an RPM reading is not checked, and the log notes this once.
- It re-sends a mismatched duty up to twice. If the mismatch persists, it cold-resets the BMC and gives it up to four minutes to answer. It then restores Full mode, re-sends both duties, and re-sends the mismatched duty a last time.
- A mismatch that survives the reset is logged once. It is not escalated again until that fan follows the duty at the end that failed: the minimum, or 95 % and above. Each end is held separately, so a fan that fails at both ends gets one reset per end. A wrong RPM setting therefore cannot reset the BMC every cycle. A zone whose mismatch led to the reset, and that has not been seen following the duty since, is held the same way.
- If a drive check finds the BMC running in its own fan mode, it restores Full mode and re-sends both duties.

## Start at boot

Install the `tmux` package and add this line with `crontab -e`, using your directory:

`@reboot tmux new-session -d -s fanscript '/root/spinscripts/spinpid2.sh'`

Attach with `tmux attach -t fanscript` to watch the console output, the same content as the log file. Stop the controller with `kill` or by killing the tmux session. The controller removes its scratch files on exit.

The scripts find `bash` through the PATH. cron's PATH includes `/usr/local/bin`. rc(8) runs `/etc/rc.local`, rc.d scripts, and TrueNAS init scripts with a PATH that has no `/usr/local/bin`, so a start from there needs the interpreter spelled out: `/usr/local/bin/bash /root/spinscripts/spinpid2.sh`.

## Logs

Drive status symbols: `*` spinning with its temperature (`*--` when it reports none), `_` standby, `?` not readable. `?` covers no reply, or a reply that is neither a reading nor standby.

`spinpid2.sh` main log, one row per drive check: time, one cell per drive, `Tmax`, `Tmean`, `ERRc` (Tmean − SP), `P`, `D`, CPU temperature, fan mode, and the new CPU and PER duties. Then the RPM of FANA, FANB, FAN1-FAN5, read 5 s after the new drive-zone duty is applied. `---` marks a value that was not available: not read, or not computed because no drive reported a temperature. Mismatch handling, fan-mode restores, and BMC resets are logged between rows. A failed duty read, or a check with no drive temperature, is noted inside the row, or between rows during mismatch handling.

`spinpid.sh` main log: time, drive cells, `Tmax`, `Tmean`, `ERRc`, `P`, `D`, CPU temperature, which demand set the duty (`Drives` or `CPU`), previous/new duty, fan mode, and FAN1 RPM. Then every interim duty set during the following CPU cycles.

`spincheck.sh` log: time, drive cells, `Tmax`, `Tmean`, `ERRc`, CPU temperature, RPM of FAN1-FAN5, FANA and FANB, the duty reported for zones 0 and 1, fan mode. Some boards report the duty incorrectly, and report a duty for zone 1 even when the board has one zone.

The column header is printed at startup and repeated in the first interval after 00:00, 06:00, 12:00, and 18:00.

## Tuning

Every `DRIVE_T` minutes the drive controller adds a correction to the previous duty. The correction is P = `Kp` × ERRc, where ERRc = Tmean − SP, plus D = `Kd` × the change in ERRc since the last check, per minute. Because the correction adds to the previous duty, P accumulates from check to check. It is the integral action of the loop, and `Kp` sets how quickly a persistent error is worked off.

D answers a change in Tmean at once: it is the proportional action. Its effective gain is `Kd` × 60 / the interval in seconds, which is `Kd` / 5 at the default 5 minutes (300 s). With the shipped settings that is 8 duty points per degree. Glorious1 named the terms after the formulas that compute them. As a loop it is a PI controller, and the duty limits give it its anti-windup.

The correction is rounded to a whole duty point, so a steady error smaller than 0.5 / `Kp` (0.125 C with `Kp` = 4) changes nothing; while the error is changing, D adds to the correction. This rounding deadband keeps the fans from hunting around the setpoint. Drives respond over tens of minutes, so generic PID recipes transfer poorly. Glorious1's procedure below is what works in practice.

1. Run `spincheck.sh` to learn your temperature and fan variations under the BMC's control.
2. Choose a setpoint (`SP`) that is an observed Tmean: the Tmean that goes with the Tmax you want, given the number of drives you have.
3. Start with `Kp` low. Find the smallest ERRc other than 0 in the output, ignoring the sign, and set `Kp` to 0.5 / ERRc rounded up to a whole number. With a smallest ERRc of 0.14, 0.5 / 0.14 is 3.6, so `Kp` = 4. That smallest error then moves the duty by one point per check, and anything smaller stays inside the rounding deadband. A higher `Kp` works a persistent error off faster but overshoots the setpoint and oscillates sooner.
4. Set `Kd` to about 10 × `Kp`, so D answers a change in Tmean immediately, before P accumulates.
5. Get Tmean within about 0.3 C of `SP` before starting the controller, then run it for a few hours. If Tmean oscillates (graph it), reduce `Kd`. Both gains add to the loop gain, so lowering `Kp` also calms it, at the cost of a slower return to the setpoint. If Tmean does not oscillate but responds too slowly, raise `Kd`.
6. Stop the controller, let Tmean drift at least 1 C off `SP`, and restart. If Tmean overshoots and oscillates, reduce `Kd`.
7. When in doubt, read the P and D columns in the log to see which term is driving the duty.

For reference, duty cycle, its hex value as sent to the BMC, and the RPM of the original author's fans:

| Duty (%) | Hex | RPM |
|----------|-----|-----|
| 10 | A | 300 |
| 20 | 14 | 400 |
| 30 | 1E | 500 |
| 40 | 28 | 600/700 |
| 50 | 32 | 800 |
| 60 | 3C | 900 |
| 70 | 46 | 1000/1100 |
| 80 | 50 | 1100/1200 |
| 90 | 5A | 1200/1300 |
| 100 | 64 | 1300 |

RPM varies by fan; the scripts set the duty and only read the RPM.

## My fans are revving up and down?

Some Noctua fan models run slower than other models from Noctua and other vendors at the same duty cycle, and stall around 300 RPM.

Mixing models with different minimum speeds means the minimum duty (`DUTY_PER_MIN` / `DUTY_CPU_MIN`, or `DUTY_MIN` for one zone) has to suit the slowest fan. For me this meant 25 % to stop the fans stalling and revving continuously.

You may also need to lower the BMC's RPM assert thresholds, otherwise a sensor alert drives the fans back to 100 %:

```
ipmitool sensor thresh FANA lower 100 200 300
ipmitool sensor thresh FANB lower 100 200 300
ipmitool sensor thresh FAN1 lower 100 200 300
ipmitool sensor thresh FAN2 lower 100 200 300
ipmitool sensor thresh FAN3 lower 100 200 300
ipmitool sensor thresh FAN4 lower 100 200 300
ipmitool sensor thresh FAN5 lower 100 200 300
```

## Drive temperatures

`hdd-temp.sh` prints one line per disk from `kern.disks`: the device name and its temperature (`ada0 40C`), or `standby` for a drive that is asleep (it is not woken). A device that cannot be read or reports no temperature shows `?`. NVMe devices (`nvd*`, `nda*`) are read through their controller, mapped with `nvmecontrol devlist`, and show its composite temperature. `cd*` devices are skipped.

## Upgrading from an older checkout

The `.config` files are plain settings now. The logging redirection moved into the scripts. Compare your `.config` with the shipped one and add the new keys: `SMARTCTL`, `CAMCONTROL`, `LOG_CONSOLE`, `DEVLIST_EXCLUDE`, `CPU_TEMP_SENSOR`, plus `LOG`, `HOW_DUTY`, and `DUTY_MAX` in `spinpid.config`. Copy `spincommon.sh` alongside the scripts. A script that finds a setting missing stops at startup and names it.

Hooks may read only the variables listed in `spinpid2.config`. The globals `DUTY`, `ZONE`, `DUTY_LAST`, `RPM`, `TIME`, `CPU_TEMP_SYSCTL`, and `CORES` of older releases are gone.

## Changes since the fork

Upstream on GitHub stopped at Glorious1's 2018 upload. He published his later releases on the TrueNAS forum resource, the last on 2020-08-20. The scripts print their version (a date) at startup.

### 2026-10-20

- The bash scripts start with `#!/usr/bin/env bash`, so they run wherever bash is on the PATH instead of requiring `/usr/local/bin/bash`. Starts from rc(8) need the full path to bash (see Start at boot).
- A mismatch that survives the BMC reset no longer causes a cold reset every drive cycle. It is logged once and not escalated again until the fan follows the duty at the end that failed, each end held separately. A zone whose mismatch led to the reset, and that was not seen following the duty afterwards, is held the same way.
- A reference fan without a reading is noted once rather than every cycle.
- After a reset the BMC is given up to a further 120 s to answer before Full mode is restored.
- A BMC found running in its own fan mode at a drive check is put back in Full mode with both duties re-sent.
- When no drive reports a temperature while any is awake, the drive demand is left as it was instead of dropping to the minimum. Unreadable drives may be hot. The row notes this once per episode. Every drive in standby still means the minimum.
- The scripts run in the C locale, so a comma-decimal locale no longer breaks the duty arithmetic. Day and month names in the headers are English.
- A log file that cannot be written stops the script at startup, as does an unwritable CPU log when it is enabled.
- Every whole-number setting is range-checked and must be written without a leading zero: intervals, zones, duty limits, RPM references, `HOW_DUTY`, `CPU_LOG_YES`, `LOG_CONSOLE`, `CPU_REF`, `CPU_SCALE`. `SP`, `Kp`, and `Kd` must be numbers.
- The checks and the drive list run before the log opens. A refusal is shown on the console and, unless the log itself is the problem, appended to the log whatever `LOG_CONSOLE` says.
- Fan RPMs are taken from the reading column, so 0 RPM counts as a reading.
- A failed fan-mode, RPM, or smartctl read shows `---` or `?`, and the tool's error text is no longer spliced into the row. A failed duty read keeps the last duty, noted in the row. spincheck notes once each raw command that stops answering.
- spinpid.sh waits 5 s and re-reads before completing its first row.
- Both zones start at a duty within the limits that the script has sent (two writes at startup).
- spintest restores the mode before the duties and does not start unless it can read the mode and the zone 0 duty.
- The drive hook runs after the row is logged and sees that row's fan RPMs.
- `hdd-temp.sh` prints `?` for a device that answers without a temperature.
- README: the validation and reference-fan claims, the status key, and the 1 C step rule match the code. So do the all-standby duty, where duty-read notes appear, and the upgrade key list. The drive controller is described as what it is: an incremental loop. Its P term accumulates (integral action), and its D term answers the change in error (proportional action). The tuning section explains the gains in those terms.

### 2026-10-17

Shared code and startup checks

- New `spincommon.sh`, sourced by the four bash scripts: drive status and temperature, IPMI reads, fan RPMs, CPU temperature, logging, clamping, paced sleeps. The `.config` files are settings only. The scripts set up logging themselves.
- A script stops at startup and names:
  - a missing setting
  - a tool path that does not resolve
  - an empty drive list
  - zones outside 0/1
  - an interval of 0, or a CPU interval longer than the drive interval
  - RPM settings that are not positive or in the wrong order
- Replies from `ipmitool raw` are accepted only when they are one byte, and drive and CPU temperatures only when they are integers.

spinpid2.sh

- A failed duty read keeps the last duty instead of turning an empty reply into 0 % and forcing it onto the fans.
- The duty/RPM mismatch test compares the duty the script requested against the configured minimum. Before, it could never fire at the shipped minimum. It uses a fast-fan reference derived from the measured 30 % and 100 % readings. A fan without a reading is skipped instead of being treated as stalled. After a BMC reset the test restores Full mode and re-sends both requested duties rather than the BMC's values.
- An unreadable CPU temperature keeps the current duty and is logged once instead of driving the CPU fans to the minimum. That happens with no coretemp and no `CPU Temp` sensor, as on dual-socket boards. The sensor name is a setting.
- A spinning drive without a parsable temperature no longer drags the mean down. Attribute 190 (Airflow_Temperature_Cel) is accepted.
- D is 0 on the first check and after a check with every drive in standby (no more startup spike). It divides by the measured interval. The CPU loop is paced to its deadline, so forks and the CPU log no longer stretch the drive interval.
- The CPU log shows the CPU duty. It showed the drive zone's duty whenever the drive-lowering branch ran. It reads its one sensor through an SDR cache instead of walking the repository every cycle.
- Standby and unknown drives print `_--` and `?--` instead of `_0`. The bc parse errors logged every CPU cycle while all drives slept are gone. The 7-header columns are consistent across header, rows, and reads.
- Hooks may read the variables listed in `spinpid2.config`. The globals `DUTY`, `ZONE`, `DUTY_LAST`, `RPM`, `TIME`, `CPU_TEMP_SYSCTL`, and `CORES` of the previous release no longer exist.

spinpid.sh

- Writes a log file again (the shipped config had none), gains `HOW_DUTY` and `DUTY_MAX`, and keeps its duty on a failed read. Writes 50 % on a start outside Full mode and shares the temperature, derivative, and pacing fixes above.

spincheck.sh and spintest.sh

- spincheck has a settings block, FAN5/FANA/FANB columns, no division by zero when every drive sleeps, and a default interval when no terminal is attached. It used to spin with errors under cron.
- spintest starts only on `y`. Enter, EOF, and multi-word answers used to start the sweep. It restores both duties and the fan mode afterwards, shows FANB/FAN5, and takes its sweep bounds from settings that are honoured exactly.

hdd-temp.sh

- Uses `smartctl -n standby` so sleeping drives are not woken. Parses ATA, SAS, and NVMe output correctly (SAS printed a bare `C`). Maps NVMe devices through `nvmecontrol devlist` and prints their composite temperature as one value instead of two. Skips `cd*` devices and reports `standby` or `?`.

Documentation and repository

- README rewritten for the current scripts: settings reference, log layout, controller behaviour, tuning, upgrade notes. The controllers are executable in the repository. The configs are not.

### 2023-05-13

- Merged Glorious1's forum releases up to 2020-08-20. They added configuration files, `HOW_DUTY`, the mismatch test and BMC reset escalation, SAS drives, VM support, the IPMI CPU temperature fallback, and user hooks.
- Added FANB and FAN5 to spinpid2.sh for boards with seven fan headers.
- Fixed the BMC reset escalation, whose attempt counter was compared as a literal string and never reached the reset.
- Applied shellcheck fixes, added the example configuration files, this README, and `hdd-temp.sh`.
