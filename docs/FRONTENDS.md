# Cartograph — Frontends: one brain, many expressions

**Principle: feature parity by construction.** There is exactly one place where features
live — the Zig core (`surveyor`) plus a shared, frontend-agnostic **view-model**
(`libcartograph`). Every frontend is a *renderer* over that model, so a capability can
never exist in one UI but not another. A new lens, a new risk badge, a new verb — added
once, appears everywhere.

```
            surveyor (Zig, privileged)  ──socket──▶  libcartograph (Zig view-model)
                                                            │   (state, lenses, scoring,
                                                            │    identity resolution)
                          ┌─────────────────────────────────┼─────────────────────────────┐
                          ▼                                  ▼                             ▼
                 TUI expression                     GTK expression              (optional) remote
                 Zig + libvaxis                     GTK4 + zig-gobject           Elixir/LiveView
                 keyboard-first, kitty-graphics     GPU canvas, libadwaita       view from phone/server
```

## The Terminal expression — Zig + libvaxis
- **Why libvaxis:** modern Zig TUI; detects terminal capabilities at runtime (no
  terminfo); `vxfw` gives a Flutter-like widget/runtime with mouse, focus, event loop.
- **It can show real logos.** libvaxis supports the **kitty graphics protocol**, so on
  kitty/ghostty/wezterm the TUI renders actual app icons and remote logos — not a
  second-class citizen. Box-drawing + glyph fallback on plain terminals.
- **Semantic zoom, terminal-native:** orbit = a clustered list/graph of entities with
  sparkline throughput; Enter drills region → flow → packet; `[`/`]` change altitude.
  Everything reachable by keyboard; mouse optional.
- **Same lenses, same risk rings** rendered as colored Unicode arcs + `[██░░]` confidence
  bars + glyph badges (see DESIGN-LANGUAGE.md).
- *Status (M1):* the first TUI is a **native-Zig renderer** (`src/tui`) over
  `libcartograph` — alt-screen, raw `/dev/tty`, `poll`-driven, with category color+glyph,
  animated throughput sparklines, IPv6-bracketed endpoints, fresh-flow glow, and lens
  profiles. It already runs both in-process and over the binary IPC through one `render()`.
  **libvaxis is deferred, not dropped:** it targets Zig 0.15.1 and needs patching for 0.16's
  reworked I/O, and its headline win (kitty-graphics logos) isn't needed until logos land
  (M4/M7). Because everything routes through the view-model + a thin render boundary,
  adopting libvaxis later is a *render-backend swap*, not a rewrite.

## The GTK expression — GTK4 (Zig)
- *Status (D21):* **a live GTK4 window ships now** (`src/gtk/main.zig`, build `-Dgtk`,
  launch `./scripts/try-gtk.sh`). It connects to `surveyor serve --socket` over the Unix
  socket, decodes the **same binary IPC frames** as the TUI, folds them into the **same
  `FlowTable`**, and renders a live attributed-flow table — category color + glyph, fresh-
  flow amber dot, IPv6-bracketed endpoints, live throughput, totals, RTT. The colors are
  `Category.hex()`, the truecolor twin of the TUI's `Category.ansi()`, so the two renderers
  draw one design-language palette from the view-model (D14) — parity by construction.
- **Binding: direct C FFI for now, zig-gobject later.** The window reaches GTK4 through
  hand-written `extern` declarations linking system `gtk4`/`glib`/`gobject` — no codegen
  dependency. This is the **libvaxis precedent** applied to GTK: we are frozen on Zig 0.16
  *ahead of the ecosystem* (D16), so we ship a native renderer behind the view-model
  boundary today; adopting zig-gobject's generated bindings later is a *binding-layer swap*,
  not a rewrite (D10). It also keeps the app Zig-native and glue-free, the original reason
  for the binding choice.
- **Why zig-gobject (the eventual path):** GObject-introspection-generated GTK4 bindings for
  Zig, actively maintained and **used in production by Ghostty** — type-safe bindings that
  still link the *same* `libcartograph`. Swap it in when its ergonomics are wanted and it
  tracks our pinned Zig.
- **GPU-accelerated for free:** GTK4's GSK renderer uses Vulkan/GL — the map canvas is
  hardware-accelerated on your RX 6700 XT out of the box (see GPU.md for the custom
  compute path on top).
- **libadwaita** for a first-class Cinnamon/GNOME feel; the full continuous-zoom map,
  motion semantics (pulse/fade/bloom), the docked "Why" panel, drag-to-tag entities.
- Unprivileged; it only *asks* `surveyor` to act (capture/block) over the socket.

## Optional third expression — remote view (Elixir/Phoenix LiveView)
Erlang/OTP 27 + Elixir are installed, so a **companion web view** is cheap and natural:
read the same `surveyor` socket, model each flow as a GenServer, push the live map to a
browser. Use case: watch a headless home-server's traffic from your phone. **Not
required**, never the primary UI — a bonus that falls out of the architecture.

## Display-server strategy: great on X11 *and* Wayland (you said Wayland is coming)
- **GTK4 is natively dual.** It speaks X11 and Wayland with zero special code — the GTK
  expression is Wayland-ready today; nothing to port when you switch.
- **TUI is display-agnostic** (it's a terminal). Works identically under either.
- **Avoid Xlib/XCB entirely** in app code — that's the only thing that would tie us to X11.
- For anything "global" later (an always-on ambient overlay, screenshots): go through
  **XDG Desktop Portals** (work on both) and, for true overlays, the Wayland
  **wlr-layer-shell** with an X11 `_NET_WM` fallback behind one trait — chosen at runtime
  from `XDG_SESSION_TYPE` (already detected: `x11` now). So the overlay ambition has a
  clean path on both without rewrites.
- Icons/identity via the **XDG icon theme + .desktop** lookup — identical on both.

**Net:** picking GTK4 + a terminal frontend means we are display-server-independent by
default; Wayland is a config change, not a project.
