# Wikimedia Commons POTD Wallpaper for Ubuntu

A small Bash and systemd user-timer setup that downloads Wikimedia Commons Picture of the Day images and sets them as your desktop wallpaper.

It supports:

- the latest Wikimedia Commons Picture of the Day
- random historical POTD wallpapers
- GNOME and KDE Plasma wallpaper setting
- daily automatic refresh using a systemd user timer
- local-time scheduling that follows your system timezone and daylight saving rules
- compact image metadata stored in `metadata.json`
- a `potd-info` command for printing information about the current wallpaper
- a `potd-save` command for saving the current wallpaper to your Pictures folder

---

## What gets installed

The installer places these commands in:

```text
~/.local/bin
```

Installed commands:

```text
commons-potd-wallpaper.sh
random-potd
potd-info
potd-save
```

Installed systemd user units:

```text
~/.config/systemd/user/commons-potd.service
~/.config/systemd/user/commons-potd.timer
```

---

## Requirements

Ubuntu packages:

```text
curl
jq
libxml2-utils
```

The installer installs these automatically unless you pass:

```bash
./install.sh --no-apt
```

---

## Install

From the project directory:

```bash
chmod +x install.sh commons-potd-wallpaper.sh
./install.sh
```

Install and run once immediately:

```bash
./install.sh --run-now
```

Install with a custom maximum download width:

```bash
./install.sh --max-width 2560
```

Install with a custom image retention count:

```bash
./install.sh --keep 90
```

Install with a custom local timer time:

```bash
./install.sh --timer-time 01:30
```

Enable user lingering:

```bash
./install.sh --enable-linger
```

Lingering allows the user timer to run even when you are logged out.

---

## PATH setup

The commands are installed into:

```text
~/.local/bin
```

Check whether that directory is already on your `PATH`:

```bash
echo "$PATH" | tr ':' '\n' | grep -x "$HOME/.local/bin" || echo "Not in PATH"
```

If it is not present, add this to `~/.profile`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Then log out and back in, or run:

```bash
source ~/.profile
```

---

## Usage

### Set the latest POTD as wallpaper

```bash
commons-potd-wallpaper.sh --force
```

### Set a random historical POTD as wallpaper

```bash
random-potd
```

Equivalent to:

```bash
commons-potd-wallpaper.sh --random
```

### Download only without changing the wallpaper

```bash
commons-potd-wallpaper.sh --download-only
```

### Print information about the current wallpaper

```bash
potd-info
```

`potd-info` prints a single plain-text string using the compact metadata stored for the current wallpaper.

The output is built from:

- image name
- image description
- original image date
- Wikimedia image URL
- time downloaded

### Save the current wallpaper

```bash
potd-save
```

This copies the currently displayed POTD image to:

```text
~/Pictures/wikimedia
```

The save folder is write-only from the script’s point of view. The script does not use this folder as a source, cache, or wallpaper rotation directory.

---

## Random mode options

Pick a random POTD from 2018 onward:

```bash
commons-potd-wallpaper.sh --random --random-start 2018-01-01
```

Increase the number of attempts used to find a valid random POTD:

```bash
commons-potd-wallpaper.sh --random --random-tries 80
```

This can be useful because some historical POTD template expansions may be empty or may not resolve to a directly usable image.

---

## Scheduling

The installer enables a systemd user timer.

By default, the timer runs daily at:

```text
00:00:00 local system time
```

The timer uses local system time, not fixed UTC time.

This means systems in the United Kingdom run at local midnight in both GMT and British Summer Time. Daylight saving changes are handled by the operating system timezone database.

The timer uses:

```ini
OnCalendar=*-*-* 00:00:00
Persistent=true
```

`Persistent=true` means that if your machine is off, suspended, or the user timer could not run at the scheduled time, systemd will catch up when the timer becomes active again.

### Check timer status

```bash
systemctl --user list-timers --all | grep commons-potd
systemctl --user status commons-potd.timer
```

### Run the scheduled job immediately

```bash
systemctl --user start commons-potd.service
```

### View logs

```bash
journalctl --user -u commons-potd.service -n 200 --no-pager
```

### Change the daily timer time

Re-run the installer with a new local time:

```bash
./install.sh --timer-time 01:30
```

Then check the timer:

```bash
systemctl --user list-timers --all | grep commons-potd
```

---

## Storage

### Images

Downloaded images are stored in:

```text
~/.local/share/commons-potd-wallpaper/images/
```

Latest POTD filenames are prefixed with the local date:

```text
YYYY-MM-DD_<filename>
```

Random POTD filenames are prefixed with the POTD archive date:

```text
potd_YYYY-MM-DD_<filename>
```

### Metadata

Compact metadata is stored in:

```text
~/.local/share/commons-potd-wallpaper/metadata.json
```

The metadata file is a single JSON object.

Each root key is the image name from:

```text
extmetadata.ObjectName.value
```

Each image entry uses this schema:

```json
{
  "ObjectName.value": {
    "image_url": "wikimedia download link",
    "time_downloaded": "UTC timestamp",
    "image_info": {
      "ObjectName": {
        "value": "image name"
      },
      "ImageDescription": {
        "value": "image description"
      },
      "DateTimeOriginal": {
        "value": "original image date"
      }
    }
  }
}
```

Only these selected metadata fields are stored:

```text
extmetadata.ObjectName.value
extmetadata.ImageDescription.value
extmetadata.DateTimeOriginal.value
```

The script does not keep the full Wikimedia Commons API metadata response.

### State cache

The current wallpaper state is stored in:

```text
~/.cache/commons-potd-wallpaper/state
```

This records the current image title, metadata key, display path, and entry id so the script can avoid reapplying the same wallpaper unnecessarily.

---

## Retention

The script keeps a rolling local image archive.

Default retention:

```text
KEEP=30
```

After each successful run, older cached images are deleted from:

```text
~/.local/share/commons-potd-wallpaper/images/
```

### Change retention permanently

```bash
./install.sh --keep 90
```

### Change retention for one run

```bash
KEEP=7 random-potd
```

Or:

```bash
KEEP=7 commons-potd-wallpaper.sh --force
```

---

## Download size

The script requests a resized Wikimedia Commons rendition when the original image is wider than the configured maximum width.

Default maximum width:

```text
MAX_WIDTH=3840
```

### Change maximum width permanently

```bash
./install.sh --max-width 2560
```

### Change maximum width for one run

```bash
MAX_WIDTH=1920 random-potd
```

---

## Desktop environment support

### GNOME / Ubuntu Desktop

The script uses `gsettings` to set:

```text
org.gnome.desktop.background picture-uri
org.gnome.desktop.background picture-uri-dark
```

### KDE Plasma

The script uses `plasma-apply-wallpaperimage` when available.

### Other desktop environments

The download, metadata, `potd-info`, and `potd-save` logic will still work.

Wallpaper setting for XFCE, Cinnamon, MATE, or other environments may require adding another desktop-specific command to the wallpaper-setting section of `commons-potd-wallpaper.sh`.

---

## Useful commands

Latest POTD now:

```bash
commons-potd-wallpaper.sh --force
```

Random POTD now:

```bash
random-potd
```

Print current wallpaper info:

```bash
potd-info
```

Save current wallpaper:

```bash
potd-save
```

Download only:

```bash
commons-potd-wallpaper.sh --download-only
```

View logs:

```bash
journalctl --user -u commons-potd.service -n 200 --no-pager
```

Check timer:

```bash
systemctl --user list-timers --all | grep commons-potd
```

---

## Troubleshooting

### `random-potd`, `potd-info`, or `potd-save`: command not found

Your `~/.local/bin` directory is probably not on your `PATH`.

Check:

```bash
echo "$PATH" | tr ':' '\n' | grep -x "$HOME/.local/bin" || echo "Not in PATH"
```

Add this to `~/.profile` if needed:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Then log out and back in.

### `potd-info` says no metadata was found

Run the wallpaper script once so it can download an image and create metadata:

```bash
random-potd
```

Or:

```bash
commons-potd-wallpaper.sh --force
```

Then run:

```bash
potd-info
```

### `potd-info` still shows jq formatter errors

You are running an older installed copy of the script or wrapper.

Check for the old formatter:

```bash
grep -R 'line("Title"' "$HOME/.local/bin/commons-potd-wallpaper.sh" "$HOME/.local/bin/potd-info" 2>/dev/null || echo "old jq formatter removed"
```

If the old formatter is found, reinstall the current script and wrappers.

### Timer runs but wallpaper does not change

Check the service logs:

```bash
journalctl --user -u commons-potd.service -n 200 --no-pager
```

Then try forcing a manual run:

```bash
commons-potd-wallpaper.sh --force
```

### Download works but wallpaper is not set

GNOME requires a working session bus. The systemd service sets:

```ini
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=%t/bus
```

Try running the script manually from a terminal inside your desktop session:

```bash
commons-potd-wallpaper.sh --force
```

If the image downloads but the wallpaper does not change, your desktop environment may need a different wallpaper-setting command.

### The timer appears to run at the wrong time

Check your system timezone:

```bash
timedatectl
```

The timer uses local system time. On a UK system, midnight means local midnight, so it follows GMT and BST automatically.

Check the timer schedule:

```bash
systemctl --user list-timers --all | grep commons-potd
```

---

## Uninstall

Disable and remove the systemd user timer and service:

```bash
systemctl --user disable --now commons-potd.timer
rm -f ~/.config/systemd/user/commons-potd.service
rm -f ~/.config/systemd/user/commons-potd.timer
systemctl --user daemon-reload
```

Remove installed commands:

```bash
rm -f ~/.local/bin/commons-potd-wallpaper.sh
rm -f ~/.local/bin/random-potd
rm -f ~/.local/bin/potd-info
rm -f ~/.local/bin/potd-save
```

Optionally remove downloaded images and metadata:

```bash
rm -rf ~/.local/share/commons-potd-wallpaper
```

Optionally remove cache/state:

```bash
rm -rf ~/.cache/commons-potd-wallpaper
```

If you enabled lingering and want to disable it:

```bash
sudo loginctl disable-linger "$USER"
```