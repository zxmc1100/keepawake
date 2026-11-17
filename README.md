# KeepAwake

Menu bar app (no Dock icon) that keeps a Mac **running with the lid closed**, on battery, with
the display off and the screen locked. It can stay on until you turn it off, or only while a
chosen window or app is open.

It also shows what your charger is giving the Mac (for example `30W (20V × 1.5A)`) and warns you
when a charger is bad for it: too weak, 5V-only, unstable or delivering the wrong voltage.

## Install

Requires macOS 13 or later and Xcode or the Command Line Tools. There's no prebuilt download, so
you build it yourself:

```sh
git clone https://github.com/zxmc1100/keepawake.git
cd keepawake
./install.sh
```

Builds, runs the checks, installs to `/Applications` and launches. Look for the bolt icon. The
first time you turn on Keep Awake, macOS asks for your password once to install a small helper.
The first charger warning asks permission to show notifications.

## Menu

| Item | What it does |
|---|---|
| **Keep Awake** | On until you turn it off. |
| **Until This *App* Window Closes** | Ties to the window you were just using. Click into your Claude terminal window, open the menu, pick this, close the lid. Ends within about 15 s of the window closing. |
| **Until *App* Quits** | Same, for the whole app. Ends as soon as it quits. |
| **Reconnect Wi-Fi Automatically** | If you go offline, gets macOS to search for and join known networks. |
| **Launch at Login** | On by default, because Wi-Fi reconnect only works while the app runs. |
| **Charger** (only when plugged in) | What the charger offers (e.g. `30W (20V × 1.5A) max`), what it's delivering now and how that splits between running the Mac and charging the battery, and every voltage it supports. Info only. |
| **⚠︎ / ⛔︎ charger warnings** | Shown at the top of the menu, with a tip, only when something is wrong. Each one also sends a notification once. |

The icon is a dimmed `bolt` when off, `bolt.fill` when on, and a warning triangle when something failed
or a charger is bad for the Mac. If it shows, open the menu to read why.

### Charger warnings

| | When |
|---|---|
| ⛔︎ | Input voltage more than 10% above what the charger agreed to · the charger connects 3 times in a minute · battery at 45°C or more |
| ⚠︎ | 5V-only charger · under 30W · battery draining while power flows in · voltage sagging more than 15% under load · the Mac running hot while charging · battery at 40°C or more |

A warning must last 4 s before it shows, so the steps a charger goes through while negotiating don't
trigger one. Nothing wrong means nothing shown.

If the lid is closed when Keep Awake ends, the Mac goes to sleep at once, unless it's docked to an
external display.

## Power use

Nothing polls while idle: measured 0.0% CPU and 0 idle wakeups over 30 s. Wi-Fi and app-quit
are system events. The only timers are:

- **Window tie:** one 10 s check costing about 0.15 ms, only while tied to a window.
- **Wi-Fi retry:** a scan at 15 s, 30 s, 1 min and so on up to every 5 min, only while offline.
- **Charger:** no timer. It reads the battery registry when macOS reports a power change or publishes
  its own battery update (about once a minute), plus one re-check 5 s later while a warning is being
  confirmed. Measured: about 1 idle wakeup a minute.

For the whole Mac on battery with the lid closed, I measured 0.99 W once the display was off and the
screen locked. It can be well above that until the display timer fires, and whenever apps are busy:
4.39 W on one quiet run, and about 7.7 W with a browser process at 156% CPU. Keep Low Power Mode on for
battery (`pmset -g custom` shows `lowpowermode`). A bag has no airflow, so a busy job can get hot.

## How it works

- **Keep awake:** `pmset -a disablesleep 1`, the only switch macOS honors for lid-closed operation
  on battery (`caffeinate` is AC only). A root launchd job holds it for as long as the app holds a
  Unix socket open, and restores it when the socket closes. The kernel closes the socket however the
  app ends, even on a crash, so sleep can't stay disabled. A second job clears it at boot in case of
  a power cut. The socket is private to your user.
- **Wi-Fi:** macOS keeps network passwords to itself and refuses joins without them (`-3900`), so
  macOS has to do the joining. KeepAwake triggers a scan, which makes it auto-join known networks in
  your priority order, and also requests auto-join directly.
- **iPhone hotspot:** an idle iPhone doesn't broadcast its network, and only macOS can wake it, over
  Bluetooth. So keep **Bluetooth on**, and set System Settings → Wi-Fi → **Ask to join hotspots** to
  **Automatic**. The phone must be nearby, on the same Apple Account, with Personal Hotspot available.
  Other known networks get the first try, because the hotspot uses cellular data. The menu warns if
  Bluetooth is off.
- **Hotspot and the lock screen:** macOS refuses to start Instant Hotspot while the screen is locked
  (`error 45: Screen is locked or Device sleeping`), and no third-party app can get around that. So
  a locked Mac can't start the iPhone hotspot. A hotspot joined before the lock stays connected
  (tested for over 20 minutes), so if you know Wi-Fi will drop, join it before you close the lid.
- **Lock:** KeepAwake doesn't lock anything; macOS does. With Keep Awake on, closing the lid doesn't
  lock right away. macOS locks when its display timer runs out (5m15s after closing, with a 5-minute
  timer), and your "Require password" delay can add more time before a password is needed. To shorten
  that gap, lower those two settings or lock by hand (⌃⌘Q) before closing the lid.

- **Charger:** read from IOKit (`AppleSmartBattery` and `IOPSCopyExternalPowerAdapterDetails`), no root
  needed. The charger's offer (its USB-PD contract and supported voltages) is known the moment it's
  plugged in. What it's delivering comes from macOS telemetry, which refreshes about once a minute,
  so right after plugging in the menu says "measuring…". Readings taken before the current charger
  was plugged in are ignored, so swapping chargers can't raise a false voltage alarm.

## Limits

- Window names aren't shown: reading them needs the Screen Recording or Accessibility permission.
  Ties use the window you were just using instead, so focus it before opening the menu.
- "Online" means a network link exists, not that the internet works. A dead router that still
  accepts Wi-Fi won't trigger a search.
- Disconnecting by hand from the Wi-Fi menu can stop macOS rejoining that network until you pick it
  again.
- Charger warnings use general limits (30W minimum), not your Mac model's own charger rating.
- macOS 27 no longer publishes the battery temperature, so there the heat warning relies on the
  system's thermal state. The 40°C and 45°C checks only work on versions that publish it.
- Right after plugging in, macOS can wait about a minute before it starts using the charger; the
  menu shows "measuring…" until then.

## Live test

The checks in `install.sh` can't close real windows or lids, so run this after changing the app:

1. Focus a Terminal window, then choose **Until This Terminal Window Closes**. The icon fills in and
   `pmset -g | grep SleepDisabled` shows `1`.
2. Close the lid for over 10 minutes and reopen. With a 5-minute display timer and a 5-minute password
   delay, the Mac asks for your password or Touch ID.
3. Close that Terminal window. Within about 15 s the icon empties and `SleepDisabled` shows `0`.

## Check logs

Use the full path: in zsh, plain `log` is a shell builtin.

```sh
/usr/bin/log show --last 1h --predicate 'subsystem == "com.zxmc.keepawake"' --style compact
```

## Uninstall

```sh
pkill -x KeepAwake
sudo launchctl bootout system/com.zxmc.keepawake.guard
sudo launchctl bootout system/com.zxmc.keepawake.reset 2>/dev/null
sudo rm /Library/LaunchDaemons/com.zxmc.keepawake.*.plist
sudo pmset -a disablesleep 0
rm -rf /Applications/KeepAwake.app
```

## Security

- The helper runs as root but only ever runs fixed `pmset` and `ioreg` commands. It ignores anything
  sent to it.
- Its socket belongs to your user (mode 600). Any process running as you can connect and keep the
  Mac awake for as long as it stays connected.
- Closing the lid with Keep Awake on doesn't lock the screen right away, so anyone who opens the lid
  soon after can get in. See the Lock note above.
- It uses one private Apple API, CoreWiFi auto-join. If a macOS update breaks it, the scan still runs.

## Status

Developed and tested on one Apple Silicon Mac running macOS 27, so other setups are untested.

- **Tested live:** menu, staying awake on battery with the lid closed, macOS locking by itself with
  Keep Awake on, ending when a tied window closes, joining an iPhone hotspot with no clicks while
  unlocked, and that hotspot staying connected once locked. Known Wi-Fi rejoined after real signal
  loss, and the log shows the app's scan triggering macOS auto-join at least once. Charger readings
  with an 18W third-party charger and a Ugreen 30W charger, matching the voltages printed on it.
- **Tested automatically:** sleep is restored after a normal exit, `SIGKILL`, `SIGTERM` and an early
  disconnect (`test_guard.sh`). The charger rules run against real readings from those two chargers
  in `--selfcheck`.
- **Not tested:** the iPhone hotspot starting with the lid closed before the lock, and sleeping when a
  tie ends with the lid closed. Charger warnings for overvoltage, sagging and flapping are only tested
  with recorded readings, not with a faulty charger.

## License

[MIT](LICENSE)
