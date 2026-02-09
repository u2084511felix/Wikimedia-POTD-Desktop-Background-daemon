# Wikimedia Commons POTD Wallpaper (Ubuntu)

A small Bash + systemd user-timer setup that:

- downloads the **latest Wikimedia Commons Picture of the Day** (POTD)
- sets it as your desktop wallpaper (GNOME and KDE supported)
- refreshes **daily at 00:00 UTC** (midnight GMT)
- if your machine is off/logged out at midnight, it updates on **next login** (`Persistent=true`)
- lets you instantly switch to a **random POTD from the archive** via a convenience command:

    ```bash 
    random-potd
    ```

---

## What gets installed

Files installed into your home directory:

- Main script: `~/.local/bin/commons-potd-wallpaper.sh`
- Random shortcut command: `~/.local/bin/random-potd`
- systemd user units:
  - `~/.config/systemd/user/commons-potd.service`
  - `~/.config/systemd/user/commons-potd.timer`

Where data is stored:

- Images: `~/.local/share/commons-potd-wallpaper/images/`
- State cache: `~/.cache/commons-potd-wallpaper/state`

---

## Requirements

Ubuntu packages:

- `curl`
- `jq`
- `libxml2-utils` (for `xmllint`)

The installer will install these unless you pass `--no-apt`.

---

## Install

From your repo directory:

```bash
chmod +x install.sh
./install.sh
````

Install and run once immediately:

```bash
./install.sh --run-now
```

Enable “lingering” (optional): makes the user timer run even while you’re logged out:

```bash
./install.sh --enable-linger
```

---

## Make sure `~/.local/bin` is on your PATH

The random shortcut command is installed into `~/.local/bin`.

Check:

```bash
echo "$PATH" | tr ':' '\n' | grep -x "$HOME/.local/bin" || echo "Not in PATH"
```

If not present, add to `~/.profile`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Then log out/in (or `source ~/.profile`).

---

## Usage

### Update to the latest POTD (now)

```bash
~/.local/bin/commons-potd-wallpaper.sh --force
```

### Set a random POTD (now)

Convenience command (recommended):

```bash
random-potd
```

Equivalent to:

```bash
~/.local/bin/commons-potd-wallpaper.sh --random
```

### Download only (do not set wallpaper)

```bash
~/.local/bin/commons-potd-wallpaper.sh --download-only
```

### Random mode tuning (optional)

Pick random POTD but only from 2018 onward:

```bash
~/.local/bin/commons-potd-wallpaper.sh --random --random-start 2018-01-01
```

Increase the number of attempts if you want (some template expansions can be empty on a few dates):

```bash
~/.local/bin/commons-potd-wallpaper.sh --random --random-tries 80
```

---

## Scheduling (systemd user timer)

The installer enables a user timer that runs at **00:00 UTC** daily.

Check timer status:

```bash
systemctl --user list-timers --all | grep commons-potd
systemctl --user status commons-potd.timer
```

Run the job immediately via systemd:

```bash
systemctl --user start commons-potd.service
```

View logs:

```bash
journalctl --user -u commons-potd.service -n 200 --no-pager
```

---

## Storage and cache settings

### Where images are stored

Downloaded images go to:

```
~/.local/share/commons-potd-wallpaper/images/
```

Each downloaded file is named like:

* latest mode: `YYYY-MM-DD_<filename>`
* random mode: `potd_YYYY-MM-DD_<filename>`

### Retention (how many images to keep)

The script keeps a rolling archive and deletes older files.

* Default retention: `KEEP=30`
* Oldest images are deleted first.
* Retention is enforced after each successful download.

#### Change retention permanently (recommended)

Re-run the installer with `--keep`:

```bash
./install.sh --keep 90
```

This writes `Environment=KEEP=90` into the systemd service.

Then reload units (installer already does this, but if you edited manually):

```bash
systemctl --user daemon-reload
```

#### Change retention for a one-off run

```bash
KEEP=7 random-potd
```

(or)

```bash
KEEP=7 ~/.local/bin/commons-potd-wallpaper.sh --force
```

### Download size / bandwidth (max width)

The script requests a resized rendition from Commons when the original is larger.

* Default: `MAX_WIDTH=3840`

#### Set permanently

```bash
./install.sh --max-width 2560
```

#### Set for a one-off run

```bash
MAX_WIDTH=1920 random-potd
```

### Cache (state)

The state file is:

```
~/.cache/commons-potd-wallpaper/state
```

It stores the last applied entry id + file title so the scheduled job doesn’t reapply the same wallpaper unnecessarily.

If you want to force an update regardless of cache:

```bash
~/.local/bin/commons-potd-wallpaper.sh --force
```

To wipe cache (so it behaves like “first run”):

```bash
rm -f ~/.cache/commons-potd-wallpaper/state
```

---

## Uninstall

Basic uninstall:

```bash
chmod +x uninstall.sh
./uninstall.sh
```

Remove downloaded images and cache as well:

```bash
./uninstall.sh --purge-data --purge-cache
```

If you enabled lingering earlier and want to disable it:

```bash
./uninstall.sh --disable-linger
```

---

## Desktop environment support

* **GNOME / Ubuntu Desktop:** uses `gsettings` to set:

  * `org.gnome.desktop.background picture-uri`
  * `org.gnome.desktop.background picture-uri-dark` (if available)
* **KDE Plasma:** uses `plasma-apply-wallpaperimage` when present

If you use XFCE, Cinnamon, etc., the download logic will still work, but the wallpaper-setting section may need a small extension.

---

## Troubleshooting

### “command not found: random-potd”

Your `~/.local/bin` probably isn’t on PATH. See “Make sure `~/.local/bin` is on your PATH”.

### Timer runs but wallpaper doesn’t change

Check logs:

```bash
journalctl --user -u commons-potd.service -n 200 --no-pager
```

Then try running manually with force:

```bash
~/.local/bin/commons-potd-wallpaper.sh --force
```

### Download works but wallpaper isn’t set

GNOME requires a working session bus. The systemd service includes:

```
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=%t/bus
```

If you’re using a non-standard session setup, run manually from a terminal inside your desktop session and confirm `gsettings` changes the wallpaper.
