# MagMIDI

**Turn a MADLION MAD60 magnetic-switch keyboard into a velocity-sensitive MIDI controller.**

MagMIDI reads the keyboard's live per-key analogue travel straight from its USB HID
interface — no vendor web page, no browser, no kernel extension, no Input Monitoring
permission — and publishes it as a Core MIDI virtual source that any DAW can use.

<p align="center"><img src="MagMIDI/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" alt="MagMIDI icon"></p>

---

## Why this exists

Magnetic (Hall-effect) keyboards like the MAD60 know *how far down* every key is at any
moment, but they only expose that richness through a browser-based configurator.  For
playing music you want the analogue data on the Mac, at low latency, in a form a DAW
understands.  MagMIDI does exactly that:

* **~250 matrix scans per second.**  A full 70-position scan of the key matrix takes
  about 4 ms, so key movement is sampled roughly every 4 ms.
* **Velocity from strike speed.**  How fast a key crossed the actuation point becomes
  the MIDI velocity — press gently for a soft note, snap the key for an accent.
* **Pitch bend and aftertouch from pressure.**  Keep pushing a held key past a
  threshold and MagMIDI bends pitch and/or streams an expression CC.
* **Everything is re-mappable.**  Any physical key can be a note, a control change, a
  program change, a pitch-bend source, or nothing at all.
* **Nothing to install.**  No driver, no background daemon and no kernel extension.
  Reading key travel needs no privacy permission at all, because the analogue data
  lives in a vendor HID collection rather than the keyboard collection.
* **Optional "Play MIDI only" mode.**  Because the MAD60 is still a normal keyboard,
  playing it also types into whatever has focus.  MagMIDI can take exclusive
  ownership of its keyboard collection so the notes never reach your DAW.  That one
  feature needs the Input Monitoring permission, so it is off by default.

## Requirements

* Apple silicon Mac (arm64)
* macOS 14.0 or later
* A MADLION MAD60 (USB `0x373B:0x105D`) connected over USB
* Xcode 16 or later to build

## Build

```bash
git clone https://github.com/XiaoGanCN/MAD60-MIDI.git
cd MAD60-MIDI
xcodebuild -project MagMIDI.xcodeproj -scheme MagMIDI \
           -configuration Release -destination 'platform=macOS,arch=arm64' build
```

Or just open `MagMIDI.xcodeproj` in Xcode and press ⌘R.  The app is ad-hoc signed, so
it runs locally without a developer account.

## Using it

1. **Launch MagMIDI** with the MAD60 plugged in.  The sidebar footer shows
   *MAD60 connected* and the Overview page starts drawing live key travel.
2. **In your DAW**, arm a software instrument track and choose **“MAD60 Magnetic Keys”**
   as the MIDI input.  (Logic Pro: *Track ▸ External MIDI* or a software-instrument
   track's input menu.  FL Studio: *Options ▸ MIDI Settings ▸ Input*.)
3. **Play.**  The home row is a piano out of the box: `A S D F G H J K L ; '` are the
   white keys from C4 and `W E T Y U O P` are the black keys.  The number row sends
   expression CCs (`1` = mod wheel, and so on).
4. **Calibrate** (optional but recommended).  Open *Calibration*:
   * *Measure resting position* re-reads where every key sits when untouched.
   * *Measure full travel (10 s)* asks you to press every key to the bottom once, which
     teaches MagMIDI each key's full range so travel percentages and velocities are
     consistent across the board.
5. **Re-map.**  Open *Mapping*, click any key, and choose what it sends.  *MIDI Learn*
   captures the next note that arrives from any MIDI source.

### Default mappings

| Matrix row | Keys | Default action |
|---|---|---|
| row 0 | `1 2 3 4 5 6 7 8 9 0 - =` | CC 1, 74, 71, 91, 93, 10, 5, 84, 7, 11, 64, 66 |
| row 1 | `W E T Y U O P` | black keys (C♯4 … D♯5) |
| row 2 | `A S D F G H J K L ; '` | white keys (C4 … F5) |
| everything else | | unassigned |

Presets for *Chromatic*, *Drum pads* and *Empty* are one click away in the Mapping pane.

## How it works

The MAD60 exposes a 32-byte VIA-style raw HID channel on usage page `0xFF60`,
usage `0x61`.  Inside it, the vendor namespace (`0x96`) has a *real-time ADC* command
(`0x16`) that returns the raw analogue value of up to 12 matrix positions per round trip:

```
→ 02 96 16 00 00 <start hi> <start lo> <count>
← 02 96 16 ... <count × big-endian UInt16 ADC>   (payload starts at byte 8)
```

Six such round trips cover the whole 5 × 14 matrix.  Travel is derived from the ADC
value relative to each key's resting and bottom readings; a press is detected when
travel crosses the actuation point.  The full byte-level protocol, including the
commands the vendor's own configurator uses for calibration, is documented in
[docs/PROTOCOL.md](docs/PROTOCOL.md).

## Tuning velocity

Strike speed is measured across the **whole** key motion — from the moment the key
starts moving to the moment it crosses the actuation point — rather than from a short
derivative, which makes it much steadier at a 5 ms sample interval.

Two knobs in *Travel & Velocity* control it:

* **Full velocity at** — the strike speed (in travel-fractions per second) that maps to
  velocity 127. Lower it until a normal hard press reaches 127. The pane shows your
  live strike speed so you can see what you actually produce.
* **Curve** — shapes the response between soft and hard.

The default of 14/s is calibrated so a firm press reaches 127. The Mapping inspector
also shows a live `strike/s` figure per key while you tune.

## Design notes

* The HID polling thread runs at `.userInteractive` quality of service and never
  allocates in the hot path.
* A key only fires a note when travel crosses the actuation point, and only releases
  below a lower release point — the hysteresis prevents chattering.
* Strike speed is measured over a rolling ~15 ms window, so it reflects the strike
  rather than the whole motion.
* MIDI is emitted as UMP MIDI 1.0 to a `.midi1_0` Core MIDI source, which is what
  DAWs expect.

## Limitations

* Only the MADLION MAD60 is supported, and the device must be connected by USB.
* Key labels describe **physical matrix positions**.  If you have re-mapped keys in the
  vendor's editor, the labels still refer to the physical key; the analogue positions
  are unaffected by keymap changes.
* By default the MAD60 continues to type while MagMIDI runs.  Switch on *Play MIDI
  only* (Overview or Settings) to stop that; macOS will ask for Input Monitoring the
  first time, and the keyboard is released again as soon as you switch the option
  off or quit MagMIDI.
* **Rebuilding the app invalidates the Input Monitoring grant.**  The app is ad-hoc
  signed, so macOS identifies it by its code hash, which changes on every build.  After
  rebuilding, re-enable MagMIDI under *Privacy & Security ▸ Input Monitoring* — the app's
  path is copied to your clipboard when you press *Open Input Monitoring…*.  Signing with
  a stable identity avoids this.
* The *Peak depth* velocity mode deliberately adds about 20 ms of latency while a key
  settles.  *Strike speed* is the default and has no such cost.

## Repository layout

```
MagMIDI/                 the app (open MagMIDI.xcodeproj)
  Core/                  HID driver, travel engine, Core MIDI, configuration
  UI/                    SwiftUI views
  Resources/             app icon
docs/PROTOCOL.md         the reverse-engineered MAD60 HID protocol
tools/                   reverse-engineering and verification utilities
  madprobe.swift         raw HID enumerate / listen / query
  madanalog.swift        live per-key ADC reader
  madtrain.swift         pair analogue indices with HID keycodes
  madguide.swift         guided, deterministic key-map calibration
  seizetest.swift        shows whether the keyboard collection can be seized (--probe is read-only)
  keyrestore.swift       recovery: clears any stray HID key mapping on the MAD60
  cdp_hid_sniff.py       Chrome DevTools WebHID sniffer (how the protocol was found)
  midimon.swift          Core MIDI monitor used for end-to-end verification
  makeicon.swift         renders the app icon
```

## Credits

The MAD60 analogue protocol was recovered by instrumenting the vendor's own web
configurator in Chrome over the DevTools Protocol and by static analysis of its
JavaScript bundle.  See [docs/PROTOCOL.md](docs/PROTOCOL.md) for the details and for
the methodology, so others can extend this to sibling boards.

## Licence

MIT — see [LICENSE](LICENSE).
