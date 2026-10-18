# Supermicro fan control scripts

Fan control for Supermicro boards running FreeBSD / TrueNAS CORE: the mean drive temperature is held at a setpoint with a PD controller, and the CPU fans follow the CPU temperature.

All credit for the design goes to Glorious1 @ truenas.com:

- https://www.truenas.com/community/resources/fan-scripts-for-supermicro-boards-using-pid-logic.24/
- https://www.truenas.com/community/resources/fan-scripts-for-supermicro-boards-using-pid-logic.24/updates

This fork adds support for boards with seven fan headers (FAN1-FAN5, FANA, FANB), moves the code the scripts share into one helper file, validates every reading from the BMC and from smartctl before acting on it, and adds a drive temperature report. Please read Glorious1's guide for the background.

## Scripts

| File | Purpose |
|------|---------|
| `spinpid2.sh` | Controller for boards with two fan zones (CPU/system and peripheral). Settings in `spinpid2.config`. |
| `spinpid.sh` | Controller for boards with one fan zone; the zone runs at the higher of the drive and CPU demands. Settings in `spinpid.config`. |
| `spincheck.sh` | Logs temperatures, fan RPMs, duty cycles and the fan mode at a fixed interval without controlling anything. Settings at the top of the script. |
| `spintest.sh` | Steps both zones from 100 % duty down to 20 % and logs every fan's RPM at each step, then restores the previous duty and mode. Settings at the top of the script. |
| `spincommon.sh` | Functions shared by the four scripts above. It is sourced, not run. |
| `hdd-temp.sh` | Prints the temperature of every ATA, SCSI/SAS and NVMe disk without waking drives that are in standby. |

## Requirements

- FreeBSD 13 or 14 (TrueNAS CORE) with `bash` from ports at `/usr/local/bin/bash`.
- `ipmitool` (ports) with access to the board's BMC, `smartctl` from smartmontools, and `camcontrol` from the base system. `hdd-temp.sh` also uses `nvmecontrol`.
- Root privileges.
- A fan on header FAN1 and, for the dual-zone controller, on FANA: these are the reference fans whose RPM is checked against the duty.

## Installation

1. Copy all the files into one directory, for example `/root/spinscripts`. The scripts find `spincommon.sh` and their `.config` next to themselves.
2. The scripts are executable in the repository; run `chmod +x *.sh` if a copy lost the bits.
3. Edit the `.config` file of the controller you will use (see Settings). A script stops at startup and names any setting that is missing, any tool path that does not resolve and any value that is out of range.

## Before using the fan control scripts

1. Run `spincheck.sh` for a day or so and look over its log to get a feel for your temperatures, duty cycles and RPMs under the BMC's own control.
2. With two fan zones, decide which zone does what and connect the fans accordingly. Supermicro's convention is zone 0 for the numbered headers (FAN1, FAN2, ...) as CPU/system fans and zone 1 for the lettered headers (FANA, FANB) as peripheral fans. Zone 0 has more headers and there are usually more drive fans than CPU fans, so the shipped settings reverse this: `ZONE_PER=0`, `ZONE_CPU=1`. Either way FAN1 and FANA must be populated.
3. Set the BMC's fan thresholds to the fans' specifications (Ericloewe's guide on the TrueNAS forum). Thresholds belong to headers, so re-check them after moving fans. See "My fans are revving up and down?" below.
4. Run `spintest.sh` with no controller running. Its log gives each fan's RPM at every duty step; the controllers need the reference fans' RPM at 30 % and at 100 % (`RPM_*_30`, `RPM_*_MAX`) and the stall point of your slowest fan decides the minimum duty.
5. Go through the settings and set them for your system.
6. When first using a controller, watch its log (and the CPU log if you enable it) for a couple of full cycles.

The controllers switch the BMC to Full fan mode at startup so the BMC does not change the duty behind them. When a controller is stopped, the fans keep the duty it last set.

## Settings

Shared by both controllers (`spinpid.config` and `spinpid2.config`):

| Setting | Meaning |
|---------|---------|
| `IPMITOOL`, `SMARTCTL`, `CAMCONTROL` | Tool paths. `IPMITOOL` may carry remote options inside the quotes, e.g. `"/usr/local/bin/ipmitool -H host -U user -P password"`, when the script runs in a VM. |
| `LOG`, `LOG_CONSOLE` | Log file (truncated at every start) and whether output also goes to the console (1) or only to the file (0). |
| `DEVLIST_EXCLUDE` | sed script applied to `camcontrol devlist`; lines it deletes are not drives to control (SSDs, enclosures, cards). Empty means control every device listed. |
| `SP` | Setpoint: the mean drive temperature (C) to hold. |
| `DRIVE_T` | Whole minutes between drive checks. |
| `Kp`, `Kd` | Proportional and derivative constants of the drive PD controller (see Tuning). |
| `HOW_DUTY` | 1: read the current duty from the board each cycle. 0: assume the duty is what the script last set, for boards that report the duty incorrectly. |
| `CPU_T` | Whole seconds between CPU checks (at most `DRIVE_T` minutes). |
| `CPU_REF`, `CPU_SCALE` | At and below `CPU_REF` (C) the CPU demand is the minimum duty; each degree above adds `CPU_SCALE` duty points. Integers. |
| `CPU_TEMP_SENSOR` | IPMI sensor read when coretemp (`dev.cpu.N.temperature`) is unavailable, e.g. in a VM. Dual-socket boards name theirs `CPU1 Temp` and `CPU2 Temp`. |

Only in `spinpid2.config`:

| Setting | Meaning |
|---------|---------|
| `ZONE_CPU`, `ZONE_PER` | Which zone (0 or 1) holds the CPU fans and which the peripheral (drive) fans. |
| `DUTY_PER_MIN`, `DUTY_PER_MAX`, `DUTY_CPU_MIN`, `DUTY_CPU_MAX` | Duty limits (%) per zone. |
| `RPM_CPU_30`, `RPM_CPU_MAX`, `RPM_PER_30`, `RPM_PER_MAX` | RPM of the reference fans (FANA or FAN1) at 30 % and 100 % duty, from `spintest.sh`. |
| `CPU_LOG_YES`, `CPU_LOG` | 1 writes a line per CPU cycle to `CPU_LOG` (reference CPU fan RPM, CPU temperature, CPU duty). It grows fast; turn it off after tuning. |
| `Post_DRIVES_check_adjust`, `Post_CPU_check_adjust` | Optional functions defined in the config and run after each drive and CPU check, for example to feed Grafana. The variables they may read are listed above their calls in `spinpid2.sh`. |

Only in `spinpid.config`: `DUTY_MIN` and `DUTY_MAX`, the duty limits of the single zone.

`spincheck.sh` keeps its settings at the top of the file (`LOG`, `LOG_CONSOLE`, `T` minutes between checks, `SP` for the ERRc column, tool paths, `DEVLIST_EXCLUDE`, `CPU_TEMP_SENSOR`). It asks for the interval when run from a terminal and uses `T` otherwise. `spintest.sh` keeps `LOG`, `LOG_CONSOLE`, `IPMITOOL`, `DUTY_START` and `DUTY_STOP` (the sweep runs down in steps of 10 and always measures `DUTY_STOP`).

## How the controllers work

- Every `DRIVE_T` minutes each drive is polled with `smartctl -n standby`, so sleeping drives are not woken; spinning drives contribute to the mean temperature. The PD terms give the new drive-zone duty, within the configured limits. D is 0 on the first check and after a check with every drive in standby, and it uses the measured interval between checks.
- Every `CPU_T` seconds the CPU demand is set from the hottest core (or the IPMI sensor). While the drives are at least 1 C below the setpoint and the drive correction is negative, the drive zone also steps down by that correction between drive checks.
- A failed duty read keeps the last duty and logs a note; an unreadable CPU temperature keeps the CPU duty and is logged once.
- After each drive check `spinpid2.sh` compares the duty it requested with the reference fans' RPM: a fan running fast at the minimum duty, or slow at 95 % and above, is a mismatch. The duty is re-sent up to twice; if the mismatch persists the BMC is cold-reset, Full mode is restored and both zones are re-sent. The thresholds are printed in the settings banner at startup. A fan without an RPM reading is not checked.

## Start at boot

Install the `tmux` package and add this line with `crontab -e`, with your directory:

`@reboot tmux new-session -d -s fanscript '/root/spinscripts/spinpid2.sh'`

Attach with `tmux attach -t fanscript` to watch the console output; the log file has the same content. Stop the controller with `kill` or by killing the tmux session; it removes its scratch files on exit.

## Logs

Drive status symbols: `*` spinning with its temperature, `_` standby, `?` unknown (no reply or no temperature).

`spinpid2.sh` main log, one row per drive check: time, one cell per drive, `Tmax`, `Tmean`, `ERRc` (Tmean - SP), `P`, `D`, CPU temperature, fan mode, the new CPU and PER duties, and the RPM of FANA, FANB, FAN1-FAN5 read 5 s after the new duty was applied. `---` marks a value that is unavailable. Mismatch handling, duty-read failures and BMC resets are logged between rows.

`spinpid.sh` main log: time, drive cells, `Tmax`, `Tmean`, `ERRc`, `P`, `D`, CPU temperature, which demand set the duty (`Drives` or `CPU`), previous/new duty, fan mode, FAN1 RPM, then every interim duty set during the following CPU cycles.

`spincheck.sh` log: time, drive cells, `Tmax`, `Tmean`, `ERRc`, CPU temperature, RPM of FAN1-FAN5, FANA and FANB, the duty reported for zones 0 and 1, fan mode. Some boards report the duty incorrectly, and report a duty for zone 1 even when the board has one zone.

The column header is repeated at startup and in the first interval after 00:00, 06:00, 12:00 and 18:00.

## Tuning

PID tuning advice on the internet generally does not work well in this application.

- First run spincheck.sh and get familiar with your temperature and fan variations without any intervention.
- Choose a setpoint (SP) that is an actual observed Tmean, given the number of drives you have. It should be the Tmean associated with the Tmax that you want.
- Start with Kp low. Find the lowest ERRc (which is Tmean - setpoint) in the output other than 0 (don't worry about sign +/-). Set Kp to 0.5 / ERRc, rounded up to an integer. With a lowest ERRc of 0.14, 0.5 / 0.14 is 3.6, and Kp = 4 is adequate. Higher Kp gives a more aggressive response to error, but may overshoot the setpoint and oscillate. Kd offsets that, but raising both makes things unstable and harder to tune.
- Set Kd at about Kp*10.
- Get Tmean within ~0.3 degree of SP before starting the script. Run for a few hours. If Tmean oscillates (best to graph it), reduce Kd. If there is no oscillation but the response is too slow, raise Kd.
- Stop the script, let Tmean drift at least 1 C off SP, and restart. If Tmean overshoots and oscillates, reduce Kd.
- If you have problems, examine P and D in the log and see which is messing you up.

For reference, duty cycle, its hex value as sent to the BMC, and the RPM of the original author's fans (RPM varies by fan and is only reported by the scripts):

| Percent | Hex | RPM |
|---------|-----|-----|
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

## My fans are revving up and down?

Some Noctua fan models run slower than other models from Noctua and other vendors at the same duty cycle, and stall around 300 RPM.

Mixing models with different minimum speeds means the minimum duty (`DUTY_PER_MIN` / `DUTY_CPU_MIN`, or `DUTY_MIN` for one zone) has to suit the slowest fan. For myself this meant 25 % to stop the fans stalling and revving continuously.

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

`hdd-temp.sh` prints one line per disk from `kern.disks`: the device name and its temperature (`ada0 40C`), `standby` for a drive that is asleep (it is not woken), or `?` when the device cannot be read. NVMe devices (`nvd*`, `nda*`) are read through their controller, mapped with `nvmecontrol devlist`.

## Upgrading from an older checkout

The `.config` files are plain settings now; the logging redirection and the hook descriptions moved into the scripts. Compare your `.config` with the shipped one and add the new keys (`SMARTCTL`, `CAMCONTROL`, `LOG_CONSOLE`, `DEVLIST_EXCLUDE`, `CPU_TEMP_SENSOR`; `HOW_DUTY` and `DUTY_MAX` in `spinpid.config`). Copy `spincommon.sh` alongside the scripts. A script that finds a setting missing stops at startup and names it.

## Changes since the fork

Upstream on GitHub stopped at Glorious1's 2018 upload; his later releases were published on the TrueNAS forum resource, the last being 2020-08-20. The scripts print their version (a date) at startup.

### 2026-10-17

Shared code and startup checks

- New `spincommon.sh`, sourced by the four bash scripts: drive status and temperature, IPMI reads, fan RPMs, CPU temperature, logging, clamping, paced sleeps. The `.config` files are settings only; the scripts set up logging themselves.
- A script stops at startup and names any missing setting, any tool path that does not resolve, an empty drive list, zones outside 0/1, an interval of 0 or a CPU interval longer than the drive interval, and RPM settings that are not positive or in the wrong order.
- Replies from `ipmitool raw` are accepted only when they are one byte; drive temperatures only when they are integers; CPU temperatures only when they are integers.

spinpid2.sh

- A failed duty read keeps the last duty instead of turning an empty reply into 0 % and forcing it onto the fans.
- The duty/RPM mismatch test compares the duty the script requested against the configured minimum (it could never fire at the shipped minimum before), uses a fast-fan reference derived from the measured 30 % and 100 % readings, skips a fan without a reading instead of treating it as stalled, and after a BMC reset restores Full mode and re-sends both requested duties rather than the BMC's own values.
- An unreadable CPU temperature (no coretemp and no `CPU Temp` sensor, as on dual-socket boards) keeps the current duty and is logged once instead of driving the CPU fans to the minimum. The sensor name is a setting.
- A spinning drive without a parsable temperature no longer drags the mean down; attribute 190 (Airflow_Temperature_Cel) is accepted.
- D is 0 on the first check and after a check with every drive in standby (no more startup spike), and divides by the measured interval; the CPU loop is paced to its deadline so forks and the CPU log no longer stretch the drive interval.
- The CPU log shows the CPU duty (it showed the drive zone's duty whenever the drive-lowering branch ran) and reads its one sensor through an SDR cache instead of walking the whole repository every cycle.
- Standby and unknown drives print `_--` and `?--` instead of `_0`; the bc parse errors logged every CPU cycle while all drives slept are gone; the 7-header columns are consistent across header, rows and reads.

spinpid.sh

- Writes a log file again (the shipped config had none), gains `HOW_DUTY` and `DUTY_MAX`, keeps its duty on a failed read, writes 50 % on a start outside Full mode, and shares the temperature, derivative and pacing fixes above.

spincheck.sh and spintest.sh

- spincheck has a settings block, a default interval when no terminal is attached (it used to spin with errors under cron), FAN5/FANA/FANB columns and no division by zero when every drive sleeps.
- spintest starts only on `y` (Enter, EOF and multi-word answers used to start the sweep), restores both duties and the fan mode afterwards, shows FANB/FAN5, and takes its sweep bounds from settings that are honoured exactly.

hdd-temp.sh

- Uses `smartctl -n standby` so sleeping drives are not woken, parses ATA, SAS and NVMe output correctly (SAS printed a bare `C`), maps NVMe devices through `nvmecontrol devlist`, and reports `standby` or `?`.

Documentation and repository

- README rewritten for the current scripts: settings reference, log layout, controller behaviour, tuning, upgrade notes. The controllers are executable in the repository; the configs are not.

### 2023-05-13

- Merged Glorious1's forum releases up to 2020-08-20 (configuration files, `HOW_DUTY`, the mismatch test and BMC reset escalation, SAS drives, VM support, the IPMI CPU temperature fallback, user hooks).
- Added FANB and FAN5 to spinpid2.sh for boards with seven fan headers.
- Fixed the BMC reset escalation, whose attempt counter was compared as a literal string and never reached the reset.
- Applied shellcheck fixes, added the example configuration files, this README and `hdd-temp.sh`.
