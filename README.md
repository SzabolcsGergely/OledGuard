# OledGuard

Burn-in protection for an OLED TV used as a Windows display. A single PowerShell script, nothing
to install.

The TV is recognised by its EDID id (Samsung S95F = `SAM78B4`), so it works on whatever port or
display number the TV gets, and other monitors are left alone.

## What it does

While the TV is an active display:

- **Blanks it when idle.** After 10 minutes without activity a black, topmost window covers the
  TV (black on OLED = pixels off). It never takes focus; any input removes it.
- **Auto-hides the taskbar** (the most common burn-in spot).
- **Makes the desktop background plain black.** The picture is switched off, not replaced, so a
  slideshow / Spotlight / picture comes back exactly as it was.
- **Hides the desktop icons** (the same as desktop right-click > View > Show desktop icons).

When the TV goes away (unplugged, switched off, `Win+P`), or the guard exits, taskbar,
background and icons go back to your own settings within 2 s. The originals are saved in
`%LOCALAPPDATA%\OledGuard\` first, so a crash or kill is recovered on the next start (or with
`-Restore`).

Activity is any of:

- keyboard / mouse input
- an XInput controller (Xbox pads; PlayStation pads through Steam Input or DS4Windows)
- sound on the default playback device, so a playing movie isn't blanked (a paused one is).
  Windows doesn't let a normal app see other apps' "keep the display on" requests, so audio is
  the stand-in. Turn it off with `-IgnoreAudio`.

A tray icon offers **Blank TV now**, **Pause for 1 hour**, **Resume** and **Exit**.

## Install

```powershell
git clone https://github.com/SzabolcsGergely/OledGuard
cd OledGuard
powershell -ExecutionPolicy Bypass -File .\install.ps1      # starts at logon + now
```

Options go after `install.ps1` and are passed to the guard, e.g. `.\install.ps1 -IdleMinutes 5`.
Running `install.ps1` again replaces the task. Remove it with `.\uninstall.ps1` (stops the guard,
removes the task, restores taskbar and background).

## Options

| Option | Default | |
|---|---|---|
| `-Match <ids>` | `SAM78B4` | Monitor id substrings of the TV(s). Find yours with `-Status` (the part after `DISPLAY#`). |
| `-IdleMinutes <n>` | `10` | Idle time before blanking. |
| `-IgnoreAudio` | off | Don't count sound as activity. |
| `-AudioThreshold <0..1>` | `0.001` | Peak level that counts as sound. |
| `-KeepTaskbar` | off | Don't touch the taskbar. |
| `-KeepWallpaper` | off | Don't touch the background. |
| `-KeepIcons` | off | Don't touch the desktop icons. |
| `-Status` | | Print displays, taskbar / background / icon state, idle time, controllers, audio; then exit. |
| `-Restore` | | Put taskbar, background and icons back; then exit. |

## Limits

- An exclusive-fullscreen game can draw over the black cover (you'd be holding the controller
  anyway).
- If the TV mirrors another monitor, that monitor is blanked too.
- Taskbar auto-hide, the background and the desktop icons are Windows-wide settings, so they also
  change on a second monitor while the TV is active.
- Turn the TV off with its remote, not at the wall: OLED TVs run their pixel compensation in
  standby.
