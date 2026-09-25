This is just a setup/guide to the specific settings I've used and why I've used them.

**Laptop:** Dell G15 5530, Intel Core i5-13450HX, RTX 3050, Windows 11, Hybrid/Optimus graphics. The display is typically 60 Hz at 0% brightness, with no external monitor.

The r14 configuration is the one I now consider truly supreme with **final wattage of average of 3.3w idle / 3.1w lows and 2.8w avg on battery**.. Its verified settings include:

* EPP: 60 AC / 72 DC
* Maximum processor state: 99% AC and DC; this is a firm requirement
  * This prevents turbo boost from waking up (Unfortunately it wakes up even after disabling in the next step)
* Processor boost: disabled
  * Keep this disabled all the time. Turning this alone can ruin the entire script. (I ended up clocking 30w)
* Autonomous hardware performance control and processor idle states: enabled 
* Long- and short-thread heterogeneous scheduling: Automatic, 5/5
  * Don't use any other scheduling policy. This is the **best**
* PCIe link-state power management: Maximum savings
  * Just works
* USB selective suspend: enabled
  * Really helpful if you decide to use a mouse and just leave it (I would recomend to use trackpad and keyboard scrolling unless a mouse is specifically needed). Using a mouse can increase your power usage to 8-9w.
* Wi-Fi power saving: Maximum savings, 3 AC / 3 DC
  * Optional, I don't see any diff in my wifi speed or latency, but if you feel you can use other options.
* NVMe primary idle timeout: 100 ms AC / 100 ms DC
  * **Do not change these**
* NVMe secondary idle timeout: 1000 ms AC / 1000 ms DC
  * **Do not change these**
* NVMe transition latency tolerance: 100/200 ms primary and 200/200 ms secondary
  * **Do not change these**

Windows/Dell normalizes the core-parking minimum from 0% to 4%. That is expected on this machine; don't try to force it by changing permissions or using undocumented workarounds. 
I once tried doing it and my laptop power went upto 25w on idle. One of the things I've learnt from my journey is to **not force windows** to do something it does not want to do, ie use the "optimized" defaults from microsoft/intel

The script deliberately leaves `PERFAUTONOMOUSWINDOW`, latency-hint and heterogeneous-floor controls, performance increase/decrease policies, fixed frequency caps, cooling policy, NVMe active-power cap, display settings, and sleep/hibernate settings inherited from its base plan. It does not query or poll the NVIDIA GPU, change services or drivers, or install a resident process. Applying it sets Windows' power mode to neutral through the power-mode API before activating the plan.
You will **need to** run a battery mode script after running this script.

The laptop has had different measured idle readings under earlier configurations; I described the latest successful setup as giving a "supreme result," a precise **final wattage of average of 3.3w idle / 3.1w lows and 2.8w avg on battery**.