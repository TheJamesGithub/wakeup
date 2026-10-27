# WakeUp

Personal alarm app for a deep sleeper. The only way to stop the morning alarm is to get out of bed and scan a barcode (toothpaste, deodorant...).

## How a morning works

1. Alarm rings at your set time, with a different sound every day.
2. Hitting Stop on the lock screen only silences it: it rings again every minute (then every 3 min) for up to 2 hours.
3. Scanning the right barcode in the app ends it.
4. A few minutes later (5 by default) a short "bing bing" wake check goes off. Open the app and tap I'M UP.
5. Ignore the check and full alarms start again every minute until you do.

## Getting the app onto your phone

1. Open the latest run under the **Actions** tab of this repo, download **WakeUp-ipa**, unzip it.
2. Drag `WakeUp.ipa` into Sideloadly, sign in with your Apple ID, Start.
3. On the phone: Settings > Privacy & Security > Developer Mode (on, if asked), and Settings > General > VPN & Device Management > trust your Apple ID.
4. Open WakeUp, allow Alarms + Camera + Notifications, add a barcode item, set your times.

A free Apple ID signature lasts 7 days. The app shows the expiry date and sends a notification 2 days, 1 day and 3 hours before. Re-sideload the same .ipa before then (your settings are kept).

## Adding sounds

- In the app: Sounds > Add your own sounds (any audio file; trimmed to 29 s and boosted).
- If iOS won't play an imported sound as an alarm (a known iOS bug on some versions), drop the file into `Sounds/` in this repo instead, named `alarm_something.caf` (or any format, convert with `afconvert`), push, and re-sideload the new build.

## Rebuilding sounds

`python3 tools/make_sounds.py Sounds` regenerates the built-in sounds.
