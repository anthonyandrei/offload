# Live smoke comparison

Run date: 2026-08-31

Question: What is the current official Node.js LTS release and its support schedule as of
2026-08-31?

Both legs used the same two independent Flash researcher artifacts so the comparison isolated the
synthesizer and auditor model assignment. Public sources were limited to the official Node.js
previous-releases page and the Node.js Release Working Group schedule JSON.

| leg | researcher stage | synthesis | audit | citation result | judgment |
|---|---:|---:|---:|---|---|
| proposed split (`gemini-3.1-pro-high` for synthesis and audit) | 63s, 2 completed | no output after about 4m 27s; mandatory stage stopped | not run | no final claims | reject split |
| all Flash (`gemini-3.7-flash-high` for every role) | same 2 artifacts | 124s, completed | 96s, completed | 2 URLs resolved and supported 4 claims; conflict and uncertainty remained visible | ship all Flash |

The split failed the completion bar because its mandatory synthesis stage did not complete. The
all-Flash control completed every mandatory stage, preserved the citation audit, reported one
source-status distinction as a conflict, and retained uncertainty around future transition dates.
This is a maintainer smoke judgment, not a permanent benchmark claim.
