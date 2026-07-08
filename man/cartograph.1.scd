cartograph(1)

# NAME

cartograph - live attributed-flow TUI: every process on this machine and who it is talking to, by real name

# SYNOPSIS

*cartograph*++
*cartograph* *--ipc* < _frames_++
*cartograph* *--socket* _path_ [*--geoip* _dir_]

# DESCRIPTION

*cartograph* is the terminal expression of Cartograph, a living map of your
machine's network. It renders, live at 1 Hz, every TCP/UDP flow on the box with
the owning process, category colour and glyph, throughput sparklines, remote
hostname/owner/country (when enrichment data is present), RTT, and a docked
"Why" panel that narrates the selected flow in plain language.

Run bare, it captures in-process (unprivileged inet_diag + /proc — no root, no
daemon). Run against *surveyor*(1) it renders the exact same view-model over a
binary IPC stream; a Unix socket is full-duplex, so profile and lens toggles
travel upstream and every observer of that surveyor shares one session truth.

# OPTIONS

*--ipc*
	Read binary IPC frames from stdin: *surveyor serve | cartograph --ipc*

*--socket* _path_
	Connect to *surveyor serve --socket* _path_. Implies *--ipc*; enables the
	upstream (full-duplex) channel for profile/lens/focus changes.

*--geoip* _dir_
	Directory holding _asn.mmdb_ and _country.mmdb_ for in-process capture.
	Default: _~/.local/share/cartograph/geoip_ (populate once with
	*cartograph-fetch-geoip*). Missing databases degrade loudly to rDNS-only
	names — never silently.

*--version*, *-V*
	Print the version and exit.

*--help*, *-h*
	Print usage and exit.

# KEYS

*q*, *Ctrl-C*
	Quit.

*j* / *k*, arrow keys
	Move the flow selection; the Why panel narrates the selected flow.

*Esc*
	Clear the selection (back to the whole-machine view).

*p*, *Tab*
	Cycle the lens profile: calm → nerd → security → resource.

*1* — *6*
	Toggle individual lenses (identity, endpoint, volume, class, risk, system).

# SEE ALSO

*surveyor*(1), *cartograph-gtk*(1)

Project docs: https://github.com/RamenFast/cartograph
