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
	One-shot posture as ONE JSON envelope (status/tool/version/ts): capture
	posture (polling vs ebpf+polling, live enrichments), listener inventory,
	exposure/risk badges, flow counts. Always JSON.

*snapshot* [*--json*]
	One-shot attributed flow table. Pretty at a TTY; auto-NDJSON when stdout
	is a pipe (*surveyor snapshot | jq* just works); *--json* forces NDJSON.

*serve*
	Stream live binary IPC frames to stdout (pipe to a frontend).

*serve --socket* _path_
	Run as the box's session daemon. Binary frames on _path_ for windows;
	duplex NDJSON on _path_.json for agents — the same events out, one JSON
	command per line in. All observers share one capture core and one session
	cursor: a focus moved by any of them is followed by all of them. With
	*--exit-idle* the daemon exits when its last observer disconnects.
	Default path: _$XDG_RUNTIME_DIR/cartograph.sock_.

*serve --json* [*--socket* _path_]
	The same live view-model as NDJSON events
	(hello/posture/focus/flow/closed/tick lines) — the agent's live watch
	surface. Every line carries a canonical *event* field (legacy alias: *ev*).

*ctl focus* <*orbit* | *flow* _proto local:port remote:port_ | *app* _comm_ | *asn* _n_ | *host* _addr_> [*--altitude* _a_] [*--socket* _path_]
	Move the live session's shared cursor — every attached window follows.
	Speaks one JSON command to the daemon's _.json_ socket and prints the
	ack/error reply. Exit: 0 acked, 2 no daemon, 3 bad grammar.

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

	surveyor serve --json | jq -c 'select(.event=="flow" and .fresh)'

Run as the shared session daemon and attach a frontend across the privilege boundary:

	surveyor serve --socket /run/user/$UID/cartograph.sock &++
cartograph

Point every attached window at firefox's flows (the agent's hand):

	surveyor ctl focus app firefox

# SEE ALSO

*cartograph*(1), *cartograph-gtk*(1)
