# Dell G15 5530 Power Optimization

Power-saving configuration for the Dell G15 5530 with an Intel Core i5-13450HX.

> **WARNING:** THESE SCRIPTS REQUIRE ADMINISTRATOR PRIVILEGES. REVIEW THEM BEFORE RUNNING. DO NOT BLINDLY RUN RANDOM POWERSHELL SCRIPTS AS ADMINISTRATOR XD.

## Forenote

The main idea about this whole power saving stuff is to keep your CPU as close to true idle, nothing unnecessary running, no polling, hell I went as far as changing to UTC just to reduce once CPU compute to add time from UTC to my time zone. Essentially going nuclear on everything, ie, to lobotomize your PC. This really helped me to get better FPS while gaming by reducing CPU bottleneck (caused by interrupts and random bs spying on me) and, but most importantly, excellent thermals and battery life. Kinda sad that now I lost a room heater tho XD

This has been an 8 month journey fighting Windows, Nvidia and Intel back and forth till I won (Windows updates still manage to derail my efforts so run the power battery and debloat after every update in the said order). So I wouldn't expect anyone just running the CTT/Raphire/my scripts to reach my level of effeciency. Always use a trusted LLM or maybe someone who knows what things do if you're stuck with what you're doing.

Running only the power optimization won't help you if there are background tasks (telemetry and other bs) who keep polling the CPU and keep it running at higher clockspeeds, so first I'd recomend disabling almost all non essential services and turning on airplane mode. If you're using BitLocker, disable it while running the CTT/Raphire, the benifits are little, it helps your SSD be safe by encrypting it if your laptop gets stolen but tbf as a student, the last thing I'd worried about is encrypting my NVMe when my laptop is missing (rip wallet). But disabling BitLocker might cause a bit of trouble in zipping huge files.

Also your first task on an Alienware PC is to remove AlienwareFX bloatware lmao. **Just running the debloat script of mine or CTT or Raphire won't be enough, you'll need to manually disable stuff from services.msc and task manager.**

I understand stuff is confusing so if you're interested but don't know where to start, this is a very tiny fraction of the tweaks I've done and will give you decent results but not something as good as mine, I'd strongly suggest you to get your hands dirty and get the feel of tweaking out your machine, you will most probably end up discovering something new that I haven't created. You can drop a message via [LinkedIn](https://www.linkedin.com/in/jonathan-go4th/) I'd probably reply a LinkedIn more likely. And **NO this is not a money extorting pyramid scheme**. Hell, I'd be glad someone made it this far through my yap session. If you made it this far, one more advice read every single documentation here. All of them were hand typed by me and I did use AI for formatting/grammar/spellings. It'll definitely add more context/knowledge on what you're working with.

PS. For those who say "Just use Linux bro", I tried using debloated CachyOS + LXQT (this had the best results) but the issue was it only went to as low as 11w on idle and higher power usage on a single firefox tab (about 40w) before I gave up. Unironically a Linux VM on my Windows takes 10.5w on idle and not a huge jump while working on it which gives me less reason as my only goal is to optimize power but also I'll need 2 system for my Lab classes. My possible reasoning why LXQT failed is probably because there's no way to disable Intel turbo boost on Linux which is a bummer.

## Layout

- **`Power/`**: the daily low-power plan (`G15-Power-Optimization.ps1`) and the
  Windows "Best power efficiency" toggle (`Battery-Mode-Optimization.ps1`).
  Read [`Power/Power-Optimization-Guide.md`](Power/Power-Optimization-Guide.md)
  for the reasoning behind every setting before you touch anything.
- **`Debloat/`**: read-only system audit and a small, reversible debloat script.
  Read [`Debloat/Debloat.md`](Debloat/Debloat.md) before running it.

## Power: apply the daily plan

Open **PowerShell as Administrator** and run:

```powershell
Set-Location "C:\code\dell-g15-power-optimizer\Power"
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\G15-Power-Optimization.ps1 -Apply
```

Preview changes first without applying them:

```powershell
.\G15-Power-Optimization.ps1 -Preview
```

Restore the previous configuration:

```powershell
.\G15-Power-Optimization.ps1 -RestoreLatest
```

Diagnostics:

```powershell
.\G15-Power-Optimization.ps1 -Diagnose
```

## Power: apply the plan *and* battery-optimizing mode together

`G15-Power-Optimization.ps1 -Apply` resets Windows' power mode to
neutral/Balanced as part of applying, so you also want Windows' "Best
power efficiency" mode active to get the best results, run `Battery-Mode-Optimization.ps1`
**after** it, not before:

```powershell
Set-Location "C:\code\dell-g15-power-optimizer\Power"
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

.\G15-Power-Optimization.ps1 -Apply
.\Battery-Mode-Optimization.ps1
```

Or just run `Run-Power-Optimization.ps1`, which does both steps in the
correct order:

```powershell
Set-Location "C:\code\dell-g15-power-optimizer\Power"
.\Run-Power-Optimization.ps1
```

## Measured power draw (r14, battery)

* 3.3w avg idle / 3.1w lows (pdf reading)
* 2.8w avg on battery overall (pdf reading)

The next 3 are AC only benchmarks, will be lower on battery, I haven't tested it out yet.
* 13.5w avg on Google Meet
* 8.5w on 1080p fullscreen YouTube
* 5.9-6w YouTube background play while reading a PDF in browser (Helium)

For the best battery experience, remove the mouse. Using one can push power
usage up to 8-9w while navigating. See
[`Power/Power-Optimization-Guide.md`](Power/Power-Optimization-Guide.md)
for the full breakdown of settings and measurement conditions.

## Status

The power configuration is considered final. It's not going to be updated
further, this is the absolute best result achievable on this hardware, and
there's no more headroom to optimize. If you want to change something
anyway, run HWiNFO tests first and measure before and after; don't tweak
based on theory alone, "1 test worth a 1000 theory aah". Windows and Intel
is weird.

## Debloat

See [`Debloat/Debloat.md`](Debloat/Debloat.md) for the audit and debloat
scripts.

## License

See [LICENSE](LICENSE).
