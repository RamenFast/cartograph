# Cartograph — GPU & AMD Radeon integration

Your machine: **Radeon RX 6700 XT (Navi 22, RDNA2, 12 GB)**, `amdgpu` driver, Vulkan
(RADV) present, telemetry readable unprivileged. That's a great canvas. Three distinct,
independently-useful ways Cartograph uses the GPU:

## 1. Rendering the living map (the obvious win)
- **GTK4's GSK renderer already uses Vulkan/GL**, so the GTK expression is
  hardware-accelerated for free on the RX 6700 XT.
- For the heavy custom map (potentially thousands of nodes/edges, smooth continuous zoom
  from orbit→byte), a dedicated **Vulkan canvas** keeps it at refresh rate. RADV is the
  best Vulkan path on AMD/Linux (ACO compiler; excellent compute throughput).

## 2. GPU compute: force-directed layout & viz (the interesting bit)
- The orbit view is a force-directed constellation. Laying out many nodes (N-body
  repulsion + spring attraction) every frame is exactly a **Vulkan compute shader** job —
  offload it to the GPU so the map stays fluid as connections churn. RADV runs compute
  well on Navi 22.
- Stretch ideas (only if they earn their keep): GPU heatmaps of traffic over time;
  GPU-side aggregation of high-rate counters for the timeline. *Not* packet matching —
  that belongs in eBPF/CPU.
- Always optional: a CPU layout fallback ships first; GPU layout is an accel path,
  auto-enabled when a capable device is present.

## 3. Telemetry: show the GPU's own life (PROVEN — `experiments/sysmon.zig`)
Read straight from sysfs, unprivileged, zero deps:
- `gpu_busy_percent` · `mem_info_vram_used/total` · hwmon `power1_average` (µW→W) ·
  `temp1_input` (m°C→°C) · clocks (`pp_dpm_sclk`). Live sample on this box:
  **busy 5% · VRAM 0.7/12.0 GiB · 9.0 W · 41 °C.**
- This powers the **Resource lens** and the **cross-resource correlation** that seeds the
  future-OS vision: line up a traffic spike with a GPU/VRAM spike →
  *"this flow is the game streaming"* or *"ollama just loaded a 6 GB model to explain
  your traffic."* Self-aware and genuinely useful.

## AMD-specific notes
- **RADV over AMDVLK** for compute/perf on Linux; needs Mesa 25/26-era (this box is current).
- Telemetry lives under `/sys/class/drm/cardN/device/` + `…/hwmon/hwmonN/` — we discover
  the card dynamically (done in sysmon.zig), so no hard-coded `card1`.
- **ROCm/HIP** is *not* required (and not installed) — we use Vulkan compute, which is
  lighter and already available. If you later run `ollama` on the GPU via ROCm, Cartograph
  can surface that VRAM/compute usage in the Resource lens.
- All GPU use is **opt-in / auto-detected with CPU fallback** — Cartograph must run fine on
  a machine with no usable GPU.

## Decisions
- Rendering: GTK path uses GSK (free); a Vulkan canvas is added for the custom map (D-GPU).
- Compute: Vulkan compute (RADV) for graph layout, CPU fallback first. No ROCm dependency.
- Telemetry: ship now as the Resource lens (already proven).
