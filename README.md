![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)
# amdim

`amdim` is a low-level hardware control utility for AMD GPUs on Linux. It interacts directly with the GPU display controller registers via the User Mode Register (`umr`) tool to provide display adjustments that often bypass software limitations and OS-level brightness curves.

## Features

- **Sub-Threshold Dimming:** Lower the monitor brightness below the minimum values allowed by standard software drivers.
- **Hardware-Level Blue Light Filter:** Implements "eyecare" mode by remapping the hardware color gamut to eliminate blue channels at the silicon level, rather than using software overlays.
- **ABM Deactivation:** Automatically disables Adaptive Backlight Management and power-saving features that cause flickering or unwanted color shifting.
- **Persistence Loop:** Includes a monitoring mode to detect and override hardware register resets triggered by the kernel or display managers.

## Prerequisites

- **AMD GPU:** Requires a card supported by the `umr` tool (DCN/DCE IP blocks).
- **umr:** The AMD User Mode Register debugger must be installed and available in your PATH.
- **V Compiler:** Required to build the binary from source.

## Installation

Compile the source using the V compiler with high optimization flags:

```bash
v -prod -cflags "-O3 -march=native" -o amdim amdim.v
strip -s amdim
```

*Note: Do not use `-prealloc` or `-autofree` flags as they may cause instability with the threading model used in this tool.*

## Usage

The tool requires root privileges to access hardware registers.

```bash
sudo ./amdim <offset> <loopmode> <eyecare>
```

### Parameters

1.  **`<+/-><hex_offset>`**: The hex value to add or subtract from the current PWM base brightness.
    - Example: `-0x2000` (Dimmer)
    - Example: `+0x1000` (Brighter)
2.  **`loopmode`**: Controls how the program maintains the state.
    - `0`: Apply once and exit.
    - `1`: Apply once and disable ABM features.
    - `2`: Persistent mode. Runs in the background and re-applies settings if the system tries to reset the registers.
3.  **`eyecare`**: Hardware blue light filter.
    - `0`: Disabled.
    - `1`: Enabled (Remaps gamut to filter blue light).

### Example Commands

**Maximum Dimming with Blue Light Filter and Persistence:**
```bash
sudo ./amdim -0xFFFF 2 1
```

**Slightly Dimming without persistence:**
```bash
sudo ./amdim -0x3000 0 0
```

## How it Works

`amdim` identifies the active Display Core Next (DCN) or Display Core Engine (DCE) block on your GPU. It then locates the active PWM (Pulse Width Modulation) register responsible for the backlight. By modifying these registers directly, it achieves a lower luminosity than the standard ACPI backlight interface typically allows. 

The "Eyecare" mode functions by writing to the `mmCM_GAMUT_REMAP` registers, providing a flicker-free, hardware-accelerated warm color profile.

## Disclaimer

This tool writes directly to hardware registers. Use it at your own risk. While it is designed to manage brightness and color, incorrect register offsets on unsupported hardware could lead to temporary display artifacts until a reboot.
