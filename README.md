# MicGuard

A tiny macOS menu-bar app that keeps Bluetooth headphone mics from becoming your default input — so your music stays in high quality when an app starts recording.

## The problem

Bluetooth headphones have two modes:

| Mode | Used for | Sound |
|---|---|---|
| **A2DP** | Listening only | Stereo, high quality |
| **HFP** | Listening + using the headphone mic | Mono, phone-call quality |

When you connect Bluetooth headphones, macOS makes their mic the default input. The moment any app starts recording — dictation, OBS, a voice note — the headphones drop into HFP and your music suddenly sounds muffled (and often changes volume). Setting the input back to the built-in mic fixes it, but macOS switches it back every time the headphones reconnect.

## What MicGuard does

MicGuard listens for CoreAudio's "default input changed" and "devices changed" events. Whenever the default input is a Bluetooth device, it switches it back to the Mac's built-in microphone. It's event-driven (no polling) and identifies devices by transport type, so it works with any Bluetooth headphones — Bose, AirPods, Sony, etc. — regardless of name or system language. Non-Bluetooth mics you choose on purpose (USB, audio interfaces) are left alone.

**Lid closed (clamshell mode):** MacBooks disconnect the built-in mic in hardware while the lid is shut — it still appears in the device list but records silence. MicGuard detects this and switches to another wired mic if one is connected; if not, it lets the Bluetooth mic be used, since call-quality audio beats a dead mic. When you open the lid it switches back to the built-in mic.

Menu:

- **Microphone:** the current default input, plus the last time MicGuard switched away from a Bluetooth mic
- **Keep Bluetooth Mics Off** — on/off switch (turn off when you want to take a call on your headphone mic; the icon dims while paused)
- **Open at Login** — enabled automatically on first launch
- **Quit MicGuard**

## Install

Requires macOS 13+ and the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/ahulterstrom/micguard.git
cd micguard
./build.sh
```

`build.sh` compiles the app, ad-hoc signs it, installs it to `/Applications/MicGuard.app`, and launches it. Run it again after any change to rebuild and reinstall.

## Testing

With MicGuard running and Bluetooth headphones connected:

```bash
swift scripts/selftest.swift
```

The self-test sets the default input the way macOS does (Bluetooth mic, built-in mic, other wired mics), then checks that MicGuard switches — or doesn't — as expected, both immediately and after a few seconds. It restores your original mic when it finishes and exits non-zero if anything fails. Lid-open and lid-closed behavior differ, so run it once each way. Avoid recording anything while it runs, since it briefly changes your mic.

## Tips

- Apps that pick a mic explicitly (instead of using the system default) bypass MicGuard. In OBS, Zoom, etc., set the mic to your Mac's built-in microphone.
- If an app was already running when your headphones were the default input, it may have locked onto them — restart the app.

## Uninstall

```bash
pkill -x MicGuard
rm -rf /Applications/MicGuard.app
rm ~/Library/LaunchAgents/local.micguard.plist
defaults delete local.micguard
```

## Credits

Inspired by [ToothFairy](https://c-command.com/toothfairy/)'s "Improve sound quality" option and Milan Toth's open-source [AirPods Sound Quality Fixer](https://github.com/milgra/airpodssoundqualityfixer).

## License

MIT
