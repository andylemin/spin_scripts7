# Supermicro Fan Speed control script

All credit to Glorious1 @ truenas.com;

https://www.truenas.com/community/resources/fan-scripts-for-supermicro-boards-using-pid-logic.24/
https://www.truenas.com/community/resources/fan-scripts-for-supermicro-boards-using-pid-logic.24/updates

This is a fork of his original work, with additional fan headers added.

I also added an HDD temperature check script.

## Scripts

- spincheck.sh reads and logs temperature and fan data at a chosen interval, but does not control fans in any way. Works for both 1- and 2-zone motherboards.
- spintest.sh is a one-time utility that runs your fans through a range of duty cycles and logs resulting RPMs, then restores the previous duty and mode. Works for both 1- and 2-zone motherboards. The results can be used for some settings in spinpid2.config.
- spinpid.sh controls fans for motherboards with one fan zone. It responds to both drive and CPU temperatures, depending on the greatest need. Logs lots of temperature and fan data.
- spinpid2.sh controls fans for motherboards with dual fan zones, peripheral and CPU/system. The zones can be reversed. Logs like spinpid.sh, plus a per-CPU-cycle log when CPU_LOG_YES=1 in spinpid2.config.
- spinpid.config / spinpid2.config; the settings for spinpid.sh and spinpid2.sh respectively (data only; the scripts source them from their own directory)
- spincommon.sh; functions shared by the four scripts above. Keep it in the same directory as the scripts and their .config files.

- hdd-temp.sh; prints the temperature of every ATA, SCSI/SAS and NVMe disk without waking drives that are in standby


## Before using the fan control scripts:

Run spincheck.sh for a day or so. Look over the log to get a feel for your temperatures and fan duty cycles and RPMs while using the built-in control with the the fan mode you have set.

If you have dual fan zones, decide which zone will do what and connect fans to headers accordingly. For most boards, Supermicro says:

Zone 0, headers named with a number (e.g., FAN1, FAN2, etc.) --> CPU/System fans

Zone 1, headers named with a letter (e.g., FANA, FANB, etc.) --> Peripheral fans (presumably including drives).

Since zone 0 has more headers, and there are usually more peripheral fans than CPU fans, that seems backwards to some people (however it may make sense if you want diverse fans connected to the CPU zone and the peripheral fans are all the same kind). The script defaults to reversing this arrangement, setting ZONE_PER=0 and ZONE_CPU=1, but you can change settings to follow Supermicro's approach.

Make sure your fan thresholds are set properly based on manufacturer's specifications using Ericloewe's guide. The thresholds are assigned to headers, so if you've rearranged fan connections, you may need to reset them. You must have fan(s) connected to header FAN1, and for the dual-zone script, FANA.

If you have dual fan zones, run spintest.sh with no other fan control script running. See the resulting log.

Go through the settings (in separate .config file) of the respective script and carefully set them for your system. The scripts stop at startup and name any setting that is missing or any tool path that does not resolve, so after updating the scripts compare your .config with the shipped one and add the new keys.

When first using the scripts, watch the log (and, for spinpid2.sh, the CPU log if you set CPU_LOG_YES=1) to make sure there is not an obvious problem. If you get through a couple of full cycles and things are OK, they will likely stay OK.

NB; Make sure to set the Fan Mode to 'Full' using IPMI. The spinpid scripts will then reduce the Fan RPM. Other Fan Modes will interfere with the spinpid scripts

Please read the whole guide written by Glorious1;

https://www.truenas.com/community/resources/fan-scripts-for-supermicro-boards-using-pid-logic.24/


## Start at boot

Install `tmux` package

Add the following line to cron using 'crontab -e' (set your script location; the scripts are executable, or prefix the path with `bash`)

`@reboot tmux new-session -d -s fanscript '/<location of scripts>/spinscripts/spinpid2.sh'`


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


## My Fans are revving up and down?

Some Noctua Fan models, run slower than other models from Noctua and other vendors - at the same duty cycle, and stall around 300RPM.

Mixing models with different minimum speeds will mean you have to set the minimum duty (DUTY_PER_MIN / DUTY_CPU_MIN, or DUTY_MIN for one zone) based on the slowest fan.
For myself this meant 25% to stop the fans stalling and revving continuously.

You may also need to reduce the Supermicro RPM Assert thresholds to stop the motherboard Alerts, triggering the fans back to 100%
```
ipmitool sensor thresh FANA lower 100 200 300
ipmitool sensor thresh FANB lower 100 200 300
ipmitool sensor thresh FAN1 lower 100 200 300
ipmitool sensor thresh FAN2 lower 100 200 300
ipmitool sensor thresh FAN3 lower 100 200 300
ipmitool sensor thresh FAN4 lower 100 200 300
ipmitool sensor thresh FAN5 lower 100 200 300
```


