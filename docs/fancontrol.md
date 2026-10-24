# Thorch Fan Curve Quick Guide

Thorch controls the Thor fan with `thorch-fancontrol`. The service reads
temperatures from thermal sysfs sensors, chooses a PWM value from the configured
profile, and writes that value to the fan PWM sysfs node.

When multiple thermal sensors are readable, Thorch follows the hottest selected
sensor by default. This reacts more like Android thermal policy than a broad
sensor average, where idle or cooler zones can hide a hot CPU/GPU spot.

For a quieter or more aggressive curve, switch between the built-in profiles:

```bash
sudo thorch-hardwarectl set fan-profile quiet
```

`thorch-hardwarectl` writes `THORCH_FAN_PROFILE` into `/etc/thorch/hardware.conf`
and restarts the service for you. The available profiles are:

- `auto` and `moderate`: balanced default. Both select the same curve.
- `quiet`: later fan ramp, lower noise.
- `aggressive`: earlier fan ramp.
- `custom`: user-defined temperature thresholds and PWM speeds.

## Custom Curve

Persistent settings live in `/etc/thorch/hardware.conf`, the same file that
carries the CPU governor, RGB and fan defaults. Temperatures are in
millidegrees Celsius, so `65000` means 65 C. PWM speeds are integers from
`0` to `255`.

Set the profile through the tool, then add the curve values to the file:

```bash
sudo thorch-hardwarectl set fan-profile custom
sudo nano /etc/thorch/hardware.conf
```

`thorch-hardwarectl` only manages the profile and the sensor mode. The
threshold and speed keys have to be written by hand. Append them at the end of
the file rather than uncommenting the sample block, and do not append
`THORCH_FAN_PROFILE` itself. The config is sourced top to bottom, so a second
copy of that key at the end would win forever while the tool kept rewriting
the first one.

Example custom curve, as appended to the end of `hardware.conf`:

```bash
THORCH_FAN_POLL_SECONDS=3
THORCH_FAN_SENSOR_MODE=max

THORCH_FAN_T1=50000
THORCH_FAN_T2=55000
THORCH_FAN_T3=60000
THORCH_FAN_T4=65000
THORCH_FAN_T5=70000
THORCH_FAN_T6=75000
THORCH_FAN_MAX_TEMP=80000

THORCH_FAN_SPEED1=51
THORCH_FAN_SPEED2=77
THORCH_FAN_SPEED3=102
THORCH_FAN_SPEED4=119
THORCH_FAN_SPEED5=153
THORCH_FAN_SPEED6=204
THORCH_FAN_MAX_SPEED=255
```

`THORCH_FAN_T1` through `THORCH_FAN_T6` and `THORCH_FAN_MAX_TEMP` are the
thresholds, and `THORCH_FAN_SPEED1` through `THORCH_FAN_SPEED6` plus
`THORCH_FAN_MAX_SPEED` are the PWM values they select. The commented sample
block shipped in `hardware.conf` lists only the thresholds, so the speed keys
are easy to miss. Any key you leave unset keeps the built-in default, which is
`51`, `77`, `102`, `119`, `153`, `204` and `255` at the thresholds `55000`
through `85000`.

Then restart the service:

```bash
sudo systemctl restart thorch-fancontrol.service
sudo thorch-fancontrol status
```

The fan uses the first speed whose threshold has been crossed. For example,
with the custom curve above:

- At or below 50 C, the target PWM is `0`.
- Above 50 C, the target PWM is `51`.
- Above 60 C, the target PWM is `102`.
- Above 80 C, the target PWM is `255`.

Thresholds must increase from `THORCH_FAN_T1` through
`THORCH_FAN_MAX_TEMP`. Speeds may stay flat or increase, but values outside
`0..255` are rejected.

## Testing

Check the detected PWM path, selected sensors, current control temperature, and
target PWM:

```bash
sudo thorch-fancontrol status
```

Apply the current curve once without leaving a daemon running:

```bash
sudo systemctl stop thorch-fancontrol.service
sudo thorch-fancontrol once
```

Start the normal boot service again:

```bash
sudo systemctl enable --now thorch-fancontrol.service
```

Follow service logs while tuning:

```bash
journalctl -fu thorch-fancontrol.service
```

## Sensor And PWM Overrides

Most users should leave hardware paths empty so Thorch can autodetect them. For
bring-up or debugging, the config can pin paths explicitly:

```bash
THORCH_FAN_PWM_PATH=/sys/class/hwmon/hwmon0/pwm1
THORCH_FAN_TEMP_SENSORS="/sys/devices/virtual/thermal/thermal_zone0/temp /sys/devices/virtual/thermal/thermal_zone1/temp"
```

`THORCH_FAN_TEMP_SENSORS` is a space-separated list. When more than one sensor
is configured, `THORCH_FAN_SENSOR_MODE=max` uses the hottest readable value
before selecting the fan speed. Set `THORCH_FAN_SENSOR_MODE=average` to restore
the quieter ROCKNIX-style broad sensor average.

Left unset, autodetection takes every thermal zone except `pm8550`,
`pm8550b`, `pm8550ve` and `battery`. On the Thor that is 37 zones, and it
includes the modem, cdsp, camera, aoss, video and memory blocks. Those
satellites power-gate, and a zone sampled while it is transitioning can report a
spurious high value. Under `max` a single such reading is enough to drive the
fan to full power at a real temperature of 58 C.

Pinning the list to the CPU, cluster and GPU zones shrinks the spike surface
but does not eliminate it. The thermal-zone interface itself returns garbage
for some sensors: on the Thor, `gpuss-2`, `cdsp1`, `pm8550` and `battery`
disagreed with the hwmon interface by 16-30 C for the same physical sensor,
and spikes persisted from within the pinned set (91.9-93.5 C readings with
zero kernel throttle events, proving artifacts, since a real 93.5 C would trip
the 90 C CPU throttle). The durable fix is a jump cap in the script: reject
any reading that moves more than about 15 C from the previous poll and keep
the last bucket. Real silicon cannot move that far in one 3-second poll.
`thorch-fancontrol status` prints a `temperature_source` line naming whichever
sensor produced the reading, so a surviving spike can be traced to one zone.

## Config file location

`thorch-fancontrol` resolves its config as `THORCH_FAN_CONFIG`, then
`THORCH_HARDWARE_CONFIG`, then `/etc/thorch/hardware.conf`. The shipped unit
sets neither variable, so the default is the path above.

`/etc/thorch/fancontrol.conf` is a legacy location. `thorch-hardwarectl` lists
it alongside `hw-defaults.conf` and `rgb.conf` as a file to retire, and nothing
reads it. A fan curve written there has no effect. Set `THORCH_FAN_CONFIG` in
the unit's `Environment=` if you need a separate file, and remember the config
is sourced as shell, so the last assignment of a repeated key wins.

## Safety Notes

Lower-noise curves also mean higher temperatures. Keep a terminal open with
`thorch-fancontrol status` or `journalctl -fu thorch-fancontrol.service` while
tuning, and avoid disabling the service for normal use.

If a custom curve fails validation, `thorch-fancontrol` exits without applying
it. Fix the curve keys in `/etc/thorch/hardware.conf`, then restart the
service.
