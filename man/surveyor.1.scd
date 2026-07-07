surveyor(1)

# NAME

surveyor - cartograph's capture core: attributed network flows as a table, stream, or daemon

# SYNOPSIS

*surveyor* [_command_] [_flags_]

# DESCRIPTION

*surveyor* is the (optionally privileged) capture/attribution/enrichment core of
Cartograph. It scans the box's sockets (inet_diag netlink + /proc), attributes
each flow to its owning process, enriches remotes with rDNS + offline GeoIP/ASN
identity, and serves the resulting view-model to any number of frontends —
human or machine — over pipes, Unix sockets, or NDJSON.

With *--bpf* (and the file capabilities set), an eBPF source fuses into the
poller: short-lived flows the 1 Hz scan would miss, UDP/QUIC byte counters, and
passive-DNS true hostnames from the box's own :53 answers.

# COMMANDS

*status*
	One-shot posture as ONE JSON object: listener inventory, exposure/risk
	badges, flow counts. Always JSON.

*snapshot* [*--json*]
	One-shot attributed flow table. Pretty at a TTY; auto-NDJSON when stdout
	is a pipe (*surveyor snapshot | jq* just works); *--json* forces NDJSON.

*serve*
	Stream live binary IPC frames to stdout (pipe to a frontend).

*serve --socket* _path_
	Serve frames over a Unix socket — the daemon privilege boundary. Frontends
	(*cartograph*, *cartograph-gtk*, *planisphere*) connect unprivileged; the
	socket is full-duplex (session/lens/focus changes travel upstream).

*serve --json* [*--socket* _path_]
	The same live view-model as NDJSON events (hello/flow/closed/tick lines) —
	the agent's live watch surface.

*schema*, *--schema*
	Print the machine-readable contract of every surface (fields, events,
	vocabularies), generated from the same enums the binaries use.

*--version*, *-V*; *--help*, *-h*
	Version / usage.

# FLAGS

*--bpf*
	Use the eBPF hybrid source if the binary holds the needed capabilities;
	degrades loudly to unprivileged inet_diag otherwise. Grant capabilities
	with: *sudo setcap cap_bpf,cap_perfmon,cap_net_admin,cap_net_raw+ep* _surveyor_

*--socket* _path_
	Unix socket path for *serve*.

*--geoip* _dir_
	Directory holding _asn.mmdb_ and _country.mmdb_.
	Default: _~/.local/share/cartograph/geoip_ (populate once with
	*cartograph-fetch-geoip*). Missing databases degrade loudly to rDNS-only.

# EXAMPLES

Who is my machine talking to right now, by name?

	surveyor snapshot

Watch live flows as JSON events, filtered to fresh ones:

	surveyor serve --json | jq -c 'select(.ev=="flow" and .fresh)'

Run as the shared daemon and attach a frontend across the privilege boundary:

	surveyor serve --socket /tmp/cartograph.sock &++
cartograph --socket /tmp/cartograph.sock

# SEE ALSO

*cartograph*(1), *cartograph-gtk*(1)
