# SAMA / TURZX cooler LCD – serial protocol notes

These notes describe what this project uses. They were worked out by observing how the vendor app talks to the device. They were tested on a SAMA 4" 720×720 screen reporting `chs_4inch.dev1_rom1.91`, and other models or firmware may differ.

## Transport

- USB CDC serial device, `VID_1D6B&PID_A040` (shows up as e.g. `COM3`)
- 115200 8N1, DTR and RTS on (the baud rate is nominal; it is a USB device)
- Every write is a **250-byte packet**

## Command header (one 250-byte packet)

| Offset | Size | Meaning |
|---|---|---|
| 0 | 1 | command |
| 1–2 | 2 | magic `EF 69` |
| 3–6 | 4 | payload length, big-endian |
| 7 | 1 | flag (0) |
| 10… | n | small inline payload (command-specific) |

## Payload

A payload follows the header as further 250-byte packets. Each packet carries **249 data bytes** plus one padding byte. A short last packet is zero-padded.

## Commands used

| Cmd | Name | Header payload | Data | Reply |
|---|---|---|---|---|
| `1` | version | `C5 D3` at offset 10 | – | e.g. `chs_4inch.dev1_rom1.91\0` |
| `200` | full frame (opaque) | – | raw frame, `W×H×4` bytes BGRA (as `Format32bppArgb` in memory), top-left origin | `full_png_sucess…` |
| `204` | delta frame | `[frame id BE32][mask length BE32 = 0]` | delta-encoded pixels + `EF 69` | none |
| `207` | status | – | – | `needReSend:0\|renderCnt:N\0` (1024 bytes) |

Other commands seen in the vendor app but not needed here include `202` (frame with transparency, followed by a `208` mask), `123`/`125`/`129` (settings), `140` (play an image stored on the device) and `150` (stop media).

### Frame sequencing

1. Send `1` and check that the reply contains `rom`.
2. Send one full frame with `200`. **Delta frame ids then restart at 0.**
3. Send `204` deltas with ids 0, 1, 2, … Each delta is relative to the previous frame.
4. Poll `207` every few seconds. On `needReSend:1`, or on no reply, send a full frame again.

### Delta encoding (`204` data)

Pixels are compared as 4-byte BGRA values. A pixel counts as changed if any of its 4 bytes differ. Each maximal run of consecutive changed pixels, at pixel index `pos`, is encoded as:

- **single pixel:** `[0x80 | pos>>16][pos>>8 & FF][pos & FF]` followed by 4 bytes BGRA
- **run of `n` ≥ 2:** `[pos>>16][pos>>8 & FF][pos & FF][n>>8][n & FF]` followed by `n` × 4 bytes BGRA

The longest allowed run is 65000 pixels. If a run would exceed that, send a full frame instead. Append `EF 69` after the encoded data. See `src/CoolerLcd.cs` for a reference implementation.
