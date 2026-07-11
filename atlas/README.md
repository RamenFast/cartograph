# atlas — the remote shared-presence layer (unstarted)

This directory is a **placeholder, not a scaffold**. There is no Elixir code here yet
(audit F28 called out the difference, and the difference matters).

What atlas is *for* (D9 as amended, FRONTENDS.md): the BEAM/LiveView distribution layer
where a human and their AI(s) — possibly on other machines — watch one box together:
presence, cursors, conversation, history.

What already exists *without* it: the **local** multi-observer story shipped in surveyor
itself. `surveyor serve --socket` multiplexes one capture core to any number of windows
(binary frames) and agents (duplex NDJSON on `<sock>.json`), all sharing one session
cursor that `surveyor ctl focus …` moves. Atlas builds *on top of* that daemon — it is
the remote/multi-machine/persistent half, not the first half.

When work starts here, it starts with `mix phx.new`. Until then, treat every mention of
"the atlas scaffold" in older docs as aspiration.
