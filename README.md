# Supermicro Fan Speed control script

All credit to Glorious1 @ truenas.com;

https://www.truenas.com/community/resources/fan-scripts-for-supermicro-boards-using-pid-logic.24/
https://www.truenas.com/community/resources/fan-scripts-for-supermicro-boards-using-pid-logic.24/updates

This is a fork of his original work, with additional fan headers added.

I also added an HDD temperature check script.

## Scripts

- spincheck.sh reads and logs temperature and fan data at a chosen interval, but does not control fans in any way. Works for both 1- and 2-zone motherboards.
- spintest.sh is a one-time utility that runs your fans through a range of duty cycles and logs resulting RPMs. Works for both 1- and 2-zone motherboards. The results can be used for some settings in spinpid2.sh.
- spinpid.sh controls fans for motherboards with one fan zone. It responds to both drive and CPU temperatures, depending on the greatest need. Logs lots of temperature and fan data.
- spinpid2.sh controls fans for motherboards with dual fan zones, peripheral and CPU/system. The zones can be reversed. Logs like spinpid.sh but with additional CPU log.
- spinpid.config / spinpid2.config; Example configuration files for spinpid.sh and spinpid2.sh respectively

- hdd-temp.sh; Get all ATA/SCSI/NVME drive temperatures


## Before using the fan control scripts:

Run spincheck.sh for a day or so. Look over the log to get a feel for your temperatures and fan duty cycles and RPMs while using the built-in control with the the fan mode you have set.

If you have dual fan zones, decide which zone will do what and connect fans to headers accordingly. For most boards, Supermicro says:

Zone 0, headers named with a number (e.g., FAN1, FAN2, etc.) --> CPU/System fans

Zone 1, headers named with a letter (e.g., FANA, FANB, etc.) --> Peripheral fans (presumably including drives).

Since zone 0 has more headers, and there are usually more peripheral fans than CPU fans, that seems backwards to some people (however it may make sense if you want diverse fans connected to the CPU zone and the peripheral fans are all the same kind). The script defaults to reversing this arrangement, setting ZONE_PER=0 and ZONE_CPU=1, but you can change settings to follow Supermicro's approach.

Make sure your fan thresholds are set properly based on manufacturer's specifications using Ericloewe's guide. The thresholds are assigned to headers, so if you've rearranged fan connections, you may need to reset them. You must have fan(s) connected to header FAN1, and for the dual-zone script, FANA.

If you have dual fan zones, run spintest.sh with no other fan control script running. See the resulting log.

Go through the settings (in separate .config file) of the respective script and carefully set them for your system.

When first using the scripts, watch the log (spinpid2.sh has a main log and a CPU log) to make sure there is not an obvious problem. If you get through a couple of full cycles and things are OK, they will likely stay OK.

NB; Make sure to set the Fan Mode to 'Full' using IPMI. The spinpid scripts will then reduce the Fan RPM. Other Fan Modes will interfere with the spinpid scripts

Please read the whole guide written by Glorious1;

https://www.truenas.com/community/resources/fan-scripts-for-supermicro-boards-using-pid-logic.24/


## Start at boot

Install `tmux` package

Add the following line to cron using 'crontab -e' (set your script location)

`@reboot tmux new-session -d -s fanscript '/<location of scripts>/spinscripts/spinpid2.sh'`


## My Fans are revving up and down?

Some Noctua Fan models, run slower than other models from Noctua and other vendors - at the same duty cycle, and stall around 300RPM.

Mixing models with different minimum speeds will mean you have to set the minimum RPM % based on the slowest fan.
For myself this meant MIN=25% to stop the fans stalling and revving continuoyusly.

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


