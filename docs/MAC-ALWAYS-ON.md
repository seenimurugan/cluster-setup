# Keep the Mac always reachable (no sleep)

The homelab runs on this MacBook Pro. If the Mac sleeps:
- The OrbStack VM pauses → k3s stops responding
- Tailscale URLs return `connection refused`
- The HDD may unmount → photo/movie pods break (see [HDD-RECOVERY.md](HDD-RECOVERY.md))

This page fixes the sleep + suspend behaviour so the Mac stays a 24/7 home server while plugged in. Battery behaviour is unchanged.

**On this page:** [TL;DR — the 5 commands](#tl;dr--the-5-commands) · [How `pmset` flags work](#how-`pmset`-flags-work) · [What sleep modes still happen](#what-sleep-modes-still-happen) · [Clamshell mode (closed lid)](#clamshell-mode-closed-lid) · [OrbStack-specific](#orbstack-specific) · [Tailscale-specific](#tailscale-specific) · [Verify everything stays up across a fake sleep cycle](#verify-everything-stays-up-across-a-fake-sleep-cycle) · [Change later — battery-only sleep / split AC vs battery / full revert](#change-later--battery-only-sleep--split-ac-vs-battery--full-revert) · [Battery considerations](#battery-considerations) · [Quick reference](#quick-reference)

---

## TL;DR — the 5 commands

```bash
# Mac power settings — apply to BOTH AC and battery (-a)
sudo pmset -a sleep 0          # never sleep system
sudo pmset -a disksleep 0      # never spin down disks (keeps HDD attached)
sudo pmset -a womp 1           # wake on network packets (AC only by macOS design)

# OrbStack: don't pause VM when Mac sleeps
orbctl config set power.pause_in_sleep false
orbctl stop && orbctl start     # restart to apply

# Verify
pmset -g
orbctl config show | grep power
```

That's it. The Mac will now stay running indefinitely — on AC OR battery.

⚠️ **Battery caveat**: on battery with `sleep 0`, the laptop will drain to 0% if you forget to plug it in. Postgres + the cluster handle sudden power loss reasonably (journaled writes), but exFAT on the HDD can lose in-flight file writes if power is yanked mid-write. **Best practice: keep it plugged in.** If battery drops below 10% and you can't plug in, do `sudo shutdown -h now` for a clean stop rather than letting it die.

---

## How `pmset` flags work

| Flag | Meaning |
|---|---|
| `-c` | Settings when on AC power (charger plugged in) |
| `-b` | Settings when on battery |
| `-a` | Settings for both — what we use for this homelab |

We use `-a` because the Mac is always the homelab server, so the same "never sleep" behaviour applies regardless of power source. The battery is effectively a UPS — if AC is yanked, the Mac keeps serving until battery dies.

| Setting | Default | Homelab | What it does |
|---|---|---|---|
| `sleep` | 1-30 min idle | `0` (never) | System suspension. `0` keeps CPU/RAM alive forever. |
| `disksleep` | 10 min idle | `0` (never) | Spin-down for HDDs. Affects external USB drives too! Critical for our HDD. |
| `displaysleep` | 2 min idle | (leave default) | Display only. Display can sleep, system stays up. |
| `womp` | 0 | `1` | Wake-on-magic-packet (wake-on-LAN). Lets the Mac wake from sleep when traffic arrives. |
| `tcpkeepalive` | 1 | `1` (no change) | Keeps TCP connections alive briefly during sleep. |
| `proximitywake` | varies | (leave default) | Wake via Bluetooth proximity. |

---

## What sleep modes still happen

Even with `sleep 0`:

| You do this | What happens |
|---|---|
| Close the lid | Display sleeps, system stays up (clamshell-style) |
| Press power button briefly | System sleeps until pressed again |
| `pmset sleepnow` from terminal | Same |
| Unplug AC and idle | Battery behaviour kicks in — system can sleep |
| Disk Utility / Finder ejects the HDD | HDD unmounts (manually intervened) |

The "always on" only applies to **idle-triggered** sleep when on AC. Explicit user actions still work.

---

## Clamshell mode (closed lid)

By default, macOS only allows running with the lid closed if **both**:
- External display connected
- USB device or power connected

For a homelab without external display, you have options:

### Option 1 — keep lid open (simplest)
Just leave the laptop with lid open in a corner. With `sleep 0`, this works fine. Display can sleep (set `displaysleep 1` if you want it dark).

### Option 2 — Use Amphetamine (Mac App Store, free)
A polished app that gives you Lid-close, time-based, location-based "stay awake" rules. Recommended if you want fine control.

### Option 3 — kbflux / InsomniaX / sleepwatcher
Older free CLI tools. Less polished but free and scriptable. See https://github.com/newmarcel/KeepingYouAwake.

### Option 4 — `caffeinate` for ad-hoc
```bash
caffeinate -d -i -m -s   # disable display+idle+disk+system sleep for current session
```
Useful for one-off "leave laptop running tonight" tasks. Stops when terminal closes.

---

## OrbStack-specific

OrbStack has its own "pause when Mac sleeps" setting. Even if macOS never sleeps, **OrbStack used to pause its VM when the Mac said "going idle"** which would break the cluster.

```bash
# Turn it off — VM stays running 24/7
orbctl config set power.pause_in_sleep false

# Apply (requires restart)
orbctl stop && orbctl start
```

Verify after restart:
```bash
orbctl config show | grep power
# Expected: power.pause_in_sleep: false
```

---

## Tailscale-specific

The Tailscale operator + per-Ingress proxies run **inside the cluster** (in the `tailscale` namespace). They don't need anything on the macOS side. As long as OrbStack's VM is running, the tailnet exposure stays up.

If your devices (phone, TV) lose access:
1. First check if your phone's Tailscale is connected (toggle in the app)
2. Then check if Mac is reachable: `tailscale status` on phone → look for `tailscale-operator`, `jellyfin`, etc.
3. If they show "offline, last seen N min ago" — the homelab Mac/VM is the problem

---

## Verify everything stays up across a fake sleep cycle

After applying the settings:
```bash
# Close the lid for ~10 minutes
# Then re-open

# These should all still work without re-mount / restart:
kubectl get pods -n homelab
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8096/health
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:2283/api/server/ping
ls /Volumes/Seeni\'s\ HDD/                # HDD still mounted?
```

If anything breaks after a 10-min lid-close, the settings didn't fully apply or you're on battery (check `pmset -g batt`).

---

## Change later — battery-only sleep / split AC vs battery / full revert

The flags are reversible. Pick the mode you want and apply.

### Mode A — current setup (Mac never sleeps, AC + battery)

```bash
sudo pmset -a sleep 0
sudo pmset -a disksleep 0
sudo pmset -a womp 1
```

### Mode B — sleep on battery only (preserves battery when unplugged)

```bash
# AC: never sleep
sudo pmset -c sleep 0
sudo pmset -c disksleep 0
sudo pmset -c womp 1

# Battery: sleep after 10 min idle, spin down HDD after 10 min
sudo pmset -b sleep 10
sudo pmset -b disksleep 10
```

### Mode C — restore macOS defaults (laptop is a laptop again, not a server)

```bash
sudo pmset -a sleep 1            # default: 1 min idle
sudo pmset -a disksleep 10       # default
sudo pmset -a womp 0             # default

# Optional: also re-enable OrbStack pause-in-sleep
orbctl config set power.pause_in_sleep true
orbctl stop && orbctl start
```

### Inspect what's currently set

```bash
pmset -g custom    # all explicit settings (AC + battery columns)
pmset -g           # what's active right now
```

The output shows AC settings on the left, battery settings on the right. Anything you've set with `-a` applies to both.

### Switching modes safely

Going from Mode A → Mode B (battery now allowed to sleep): just run the Mode B commands. They override prior `-a` values.

Going from any mode → Mode C: reset and you're back to a normal laptop.

There's no "save state" you can break with pmset — it's all live config that takes effect immediately. Worst case, run `sudo pmset -a sleep 1 disksleep 10 womp 0` and you're back to factory.

---

## Battery considerations

With `-a sleep 0`, the laptop will NOT sleep on battery either:
- The battery acts as a UPS — if you yank the AC cable, the laptop keeps running on battery
- Apps stay online until battery is depleted (a few hours typically)
- If battery drops to 0% with no AC, you get a hard power-off → potential exFAT write loss

Recommended habit: if battery falls below 10% and you can't plug in soon, run `sudo shutdown -h now` for a clean stop.

If you want a true UPS-grade 24/7 homelab without battery dependency, see [migrating to a Pi](https://www.raspberrypi.com/) or similar — but that's a much bigger project.

---

## Quick reference

```bash
# Once-off setup (apply to both AC and battery)
sudo pmset -a sleep 0
sudo pmset -a disksleep 0
sudo pmset -a womp 1
orbctl config set power.pause_in_sleep false
orbctl stop && orbctl start

# Verify
pmset -g
orbctl config show | grep power
kubectl get nodes
```
