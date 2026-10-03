# MADLION MAD60 HID protocol

Everything below was recovered from the vendor's own web configurator
(`https://hub.fgg.com.cn/`) and verified against real hardware.  Two independent
methods were used:

1. **Runtime instrumentation** — the site was loaded in Chrome with
   `--remote-debugging-port`, a hook was installed at document start with
   `Page.addScriptToEvaluateOnNewDocument`, and `navigator.hid` / `HIDDevice`
   (`sendReport`, `receiveFeatureReport`, `inputreport`) were wrapped so every byte the
   driver sent or received was logged.  See `tools/cdp_hid_sniff.py`.
2. **Static analysis** — the obfuscated Vite bundle was de-obfuscated by replaying its
   string-array rotation (431 left-rotations, validated by the checksum `0x36223`) and
   substituting all 15 430 string references.

## 1. USB / HID topology

| | |
|---|---|
| Vendor / product | `0x373B` / `0x105D` |
| Manufacturer string | “Shenzhen Yizhita Technology Co., Ltd” |
| Product string | `MAD60` |
| Serial | `MAD HE` |
| `bcdUSB` / `bcdDevice` | 2.10 / 1.00 |
| Interfaces | 3 (all HID class) |

| Interface | Class/subclass/protocol | Report descriptor | Purpose |
|---|---|---|---|
| 0 | 3/1/1 | `05 01 09 06 …` | boot keyboard (8-byte reports; **always zero on this device**) |
| 1 | 3/0/0 | four collections, report IDs 2, 3, 4 and 6 | mouse (id 2), system control (id 3), consumer control (id 4), **NKRO keyboard** (id 6) |
| 2 | 3/0/0 | `06 60 FF 09 61 A1 01 …` | VIA-style raw HID: 32-byte input, 32-byte output |

Interface 2 is the one that matters:

```
Usage Page (0xFF60), Usage (0x61), Collection (Application)
  Usage (0x62)  Logical Min 0, Logical Max 255, Report Size 8, Report Count 32, Input
  Usage (0x63)  Logical Min 0, Logical Max 255, Report Size 8, Report Count 32, Output
```

Real keystrokes arrive as HID *values* on **interface 1's NKRO collection**
(usage page `0x07`).  Interface 0 never carries key data.

## 2. Frame format

All traffic on interface 2 uses **report ID 0** and a fixed **32-byte** payload.
Byte 0 is the command; the rest is command-specific.  On macOS:

```swift
IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, bytes, 32)
```

and the answer arrives asynchronously as an input report, matched on **byte 0**.

The command byte follows the VIA numbering:

| | | | |
|---|---|---|---|
| `0x01` get protocol version | `0x05` dynamic keymap set keycode | `0x09` custom save | `0x0D` macro buffer size |
| `0x02` **get keyboard value** | `0x06` dynamic keymap reset | `0x0A` eeprom reset | `0x0E`/`0x0F` macro buffer get/set |
| `0x03` **set keyboard value** | `0x07` custom set value | `0x0B` bootloader jump | `0x10` macro reset |
| `0x04` dynamic keymap get keycode | `0x08` custom get value | `0x0C` macro count | `0x11` layer count, `0x12`/`0x13` keymap buffer |

### The vendor namespace

`0x02` (read) and `0x03` (write) carry a vendor namespace selector in byte 1:

```
byte 1 = 0x96   (customId)
byte 2 = <vendor sub-command>
```

Vendor sub-commands (complete, from the bundle):

```
0x01 tapDanceGet      0x0B deadBand          0x16 realTimeAdcAxleBuffer
0x02 tapDanceSet      0x0D bufferTogTh       0x17 realTimeTripAxleBuffer
0x03 oneTogTh (APC)   0x0E bufferRt          0x18 calibrationStart
0x07 oneRt (RT)       0x0F dks               0x19 calibrationFinish
0x08 calibrate        0x10 mixAxle           0x1B completeStatusBuffer
0x09 realTimeAdcAxle  0x11 feature           0x1C adcTripCompStatusBuffer
0x0A realTimeTripAxle 0x13 layer             0x1E gameMode
                      0x14 dataReporting     0x1F calibration (init status)
                      0x15 resetAll         0x22 physical / 0x23 profile
                                            0x24 travel / 0x25 aiMatch
                                            0x41 lightInfo …
```

## 3. Reading live key travel

**This is the command MagMIDI uses.**

```
Request  (32 bytes, report ID 0)
  [0] = 0x02   id_get_keyboard_value
  [1] = 0x96   customId
  [2] = 0x16   realTimeAdcAxleBuffer
  [3] = 0x00
  [4] = 0x00
  [5..6] = start index, big-endian UInt16      (keep byte 5 = 0; see note)
  [7] = count                                  (1…12)
  [8..31] = 0x00

Response
  [0] = 0x02, [1] = 0x96, [2] = 0x16           (echoed)
  [5..6] = start echo, [7] = count echo
  [8 …] = count × big-endian UInt16 ADC values
```

Verified behaviour:

* The payload starts at **byte 8** and each key occupies **2 bytes, big-endian**.
* `count` of 12 is accepted (24 payload bytes); 16 is rejected (all-zero response).
  Twelve keys per round trip means **six requests for the full 70-position matrix**.
* Requests may only be issued **one at a time** — the firmware answers one command per
  input report, so the reader is strictly request/response.
* The start index behaves as a big-endian UInt16 at bytes 5–6: `00 06` yields keys
  6–17 and `00 0C` yields keys 12–23, while setting byte 5 non-zero (e.g. `06 00`,
  i.e. index 1536) returns zeros.  In practice byte 5 is always 0 and byte 6 is the
  start index.
* A full scan measures at **~250 Hz** (≈4 ms per six round trips) on an M-series Mac.

### Value semantics

Measured on a MAD60 with amber-pro magnetic switches:

| | |
|---|---|
| Resting value | 2 200 – 2 470 (varies per key) |
| Full depression | ≈ 880 – 970 counts below rest (rest 2373 → 1494 for `A`) |
| Travel direction | **pressing decreases the value** |
| Empty matrix position | `4096` (`0x1000`, i.e. 12-bit full scale) |

So:

```
travel = clamp((rest − adc) / (rest − bottom), 0, 1)
```

The MAD60's populated positions are `r0c0…r0c13`, `r1c0…r1c13`, `r2c0…r2c11` + `r2c13`,
`r3c0` + `r3c2…r3c11` + `r3c13`, and `r4c0…r4c2` + `r4c6` + `r4c10…r4c13` — 61 keys, i.e.
a standard 60 % ANSI layout, which the ADC `4096` readings confirm independently.

## 4. Other confirmed commands

### Calibration / “axial alignment” table (`0x1C`)

The command the vendor's *Performance ▸ Calibration ▸ Axial Alignment* page polls:

```
[0]=0x02 [1]=0x96 [2]=0x1C [5..6]=offset [7]=size
```

The driver walks `offset = 6·i`, `size = 6`, and decodes **four bytes per key starting
at byte 7**:

```
entry = [ UInt16 ADC,  0.02 × UInt8 threshold,  UInt8 status ]
```

Two newer layouts exist in the vendor bundle, selected by firmware generation — a
5-byte stride with `0.01 × UInt16` thresholds, and one with `0.001 × UInt16` thresholds
(the latter matches this board's `advancedKeyVersion "1.03"`).  Note that the vendor
code reads these fields through the *request* prototype, so treat the exact response
offsets as the least certain part of this document; the `0x16` command above has been
verified directly against hardware and is what MagMIDI relies on.

### Travel metadata (`0x24`)

```
[0]=0x02 [1]=0x96 [2]=0x24
```

Documented fields (`UInt16 × 0.001` → mm): travel max/min/step at bytes 3/5/7 and rapid
trigger max/min/step at bytes 9/11/13.  On this firmware the command answers with zeros,
so MagMIDI calibrates empirically instead.

### Rapid trigger and actuation point

* Per key, `0x03`/`0x07` (`oneTogTh` / `oneRt`), with `row` in byte 2 and `column` in
  byte 3; APC is `0.02 × UInt8` (or `0.01 × UInt16` on V2).
* Whole board, buffered: `0x0D`/`0x0E` (`bufferTogTh` / `bufferRt`), 3 bytes per key —
  `enabled`, `0.02 × release mm`, `0.02 × press mm`.
* Calibration: `0x18` start, `0x19` finish, `0x08` axle calibrate, `0x1F` init status
  buffer, `0x1B` complete status buffer.

### Unsolicited reports

The firmware can push three report types, matched on byte 0; none of them carries
per-key analogue data:

* `0x02 0x96 0x14` — `dataReporting`
* `0xA0` — debug (`keyInfo`, `UInt16 mm` at byte 5, `calibraCnt` at byte 9)
* `0xA1` — sync

`0x09` / `0x0A` / `0x16` / `0x17` exist in the vendor enum, but the shipped
configurator never sends `0x09`, `0x0A` or `0x17`.  `0x16` was found by probing and is
the live stream MagMIDI uses.

## 5. Legacy 64-byte protocol (different controller class)

Some boards in the same family use a 64-byte frame instead:

```
[0] = 0x55 flag   [1] = command   [2] = key   [3] = checksum   [4] = length
[5..6] = address, big-endian
```

with opcodes `0xA0 GetKeyTriggerTravel`, `0xA1 SetKeyTriggerTravel`, `0xA8`/`0xA9`
start/end calibration, `0xAA GetCalibration`, `0x01`/`0x02` fast-communication
start/stop.  8 bytes per key.  The MAD60 is **not** this class — it uses the 32-byte
protocol above — but it is included here because it is the fallback to try on sibling
boards.

## 6. Permissions on macOS

Interface 2 is a vendor collection, not a keyboard collection, so reading it needs
**no Input Monitoring, Accessibility or Screen Recording permission**, and no
entitlement or kernel extension.  (For comparison, opening interface 0 or 1 *is*
gated by Input Monitoring — verified: with permission denied, `IOHIDDeviceOpen` on
interface 2 returned `kIOReturnSuccess` while interfaces 0 and 1 returned
`kIOReturnNotPermitted`.)

## 7. Reproducing the capture

```bash
# Chrome must run without its own sandbox when launched from a sandboxed shell
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --no-sandbox --remote-debugging-port=9333 --remote-allow-origins=* \
  --user-data-dir=/tmp/fgg-profile about:blank

python3 tools/cdp_hid_sniff.py --port 9333 --out capture.jsonl
# then in Chrome: connect the device, open Performance > Calibration > Axial Alignment
```

Probing the raw channel directly is much quicker once you know the framing:

```bash
swiftc -O -o madprobe tools/madprobe.swift -framework IOKit -framework CoreFoundation
./madprobe query "02 96 16 00 00 00 00 06"   # live ADC for keys 0-5
./madprobe query "02 96 1C 00 00 00 00 06"   # axial-alignment table, keys 0-5
```
