#!/usr/bin/env sh
drives=$(sysctl -n kern.disks | awk '{for (i=NF; i!=0 ; i--) print $i }')

for drive in $drives
do
    case "$drive" in
        *"nvd"*)
            id=$(echo $drive | tr -d -c 0-9)
            temp1=$(smartctl -a /dev/nvme"${id}" | grep "Temperature Sensor 1" | awk '{print $4 "C"}')
            temp2=$(smartctl -a /dev/nvme"${id}" | grep "Temperature Sensor 2" | awk '{print $4 "C"}')
            echo "$drive" "$temp1" "$temp2"
            ;;
        *)
            temp=$(smartctl -a /dev/"${drive}" | awk '/Temperature/{print $0}' | awk '{print $10 "C"}')
            echo "$drive" "$temp"
            ;;
    esac
done

