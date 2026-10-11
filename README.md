# CC Factory Monitor

ComputerCraft dashboard for a Create Factory Controller. It shows every gauge with its stock, target, items on the way and status, plus health, shortage, in-transit and missing-link totals and the Mech Crafter's activity. It also shares the gauge data over rednet so the [Mech Crafter](https://github.com/levisnakes/cc-mech-crafter) knows what to make.

![Dashboard preview](preview.png)

## Install

```
wget https://raw.githubusercontent.com/levisnakes/cc-factory-monitor/main/factory_monitor.lua startup.lua
```

## Setup

- Put a wired modem on the Factory Controller and connect it to this computer.
- Connect a monitor and a DirectGPU block. Without DirectGPU it falls back to plain monitor text.
- Put this computer and the Mech Crafter computer on the same cable network, or give both a wireless modem, so they can talk over rednet.

Settings at the top of the file: `MONITOR`, `CONTROLLER` (both found automatically when left `nil`), `TITLE`, `PAGE_SECONDS`, `RESOLUTION`.

Tap the left or right half of the monitor to flip pages when there are more gauges than fit.
