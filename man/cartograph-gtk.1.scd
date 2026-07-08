cartograph-gtk(1)

# NAME

cartograph-gtk - the GTK4 window: every process on this machine and who it is talking to, by real name

# SYNOPSIS

*cartograph-gtk*++
*surveyor serve* | *cartograph-gtk*++
*cartograph-gtk* *--socket* _path_

# DESCRIPTION

*cartograph-gtk* is the desktop expression of Cartograph — the same live
view-model the TUI renders, drawn as a native GTK4 window: an attributed flow
list (app icon, category colour, remote by name/owner/country, throughput,
totals, RTT) beside a docked "Why" panel that narrates the selected flow in
plain language.

Launched with nothing on stdin (a double-click, a menu, a bare terminal
command), it spawns its own private *surveyor serve* — the child dies with the
window. Piped frames or *--socket* attach it to an existing surveyor instead;
the socket is full-duplex, so profile, lens, and focus changes travel upstream
and every observer of that surveyor shares one session truth.

# OPTIONS

*--socket* _path_
	Connect to *surveyor serve --socket* _path_ (the daemon privilege
	boundary) instead of spawning a private capture core.

*--version*, *-V*; *--help*, *-h*
	Version / usage.

# CONTROLS

The headerbar carries the same controls as the keys: the profile button
cycles calm → nerd → security → resource, and the six lens toggles switch
columns on and off.

*click*, *↑* / *↓*
	Select a flow; the Why panel narrates it.

*Esc*
	Clear the selection (back to the whole-machine view).

*p*
	Cycle the lens profile.

*1* — *6*
	Toggle individual lenses (identity, endpoint, volume, class, risk, system).

# SEE ALSO

*surveyor*(1), *cartograph*(1)

Project docs: https://github.com/RamenFast/cartograph
