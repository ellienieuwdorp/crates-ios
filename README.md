# Crates iOS

Native iOS proof-of-concept client for the [Crates](https://crates.co) music server. The phone
connects to a Crates server running on a computer on the same network and becomes an instant,
offline-capable, iOS-native listening companion.

**Start here → [`docs/PHILOSOPHY.md`](docs/PHILOSOPHY.md)** — the alignment doc for anyone
(human or agent) working on this project.

## Docs

| Doc | What it is |
| --- | --- |
| [`docs/PHILOSOPHY.md`](docs/PHILOSOPHY.md) | Core direction, time-agnostic. Read first. |
| [`docs/ideas/feature-ideas.md`](docs/ideas/feature-ideas.md) | The founding feature ideas, in full. |
| [`docs/api/capabilities-and-hurdles.md`](docs/api/capabilities-and-hurdles.md) | What the Crates API enables/blocks for this app. |
| [`docs/research/stack-decision.md`](docs/research/stack-decision.md) | Stack decision + library research. |
| [`docs/research/reports/`](docs/research/reports/) | Deep-dive research reports (Liquid Glass, audio, persistence, product context, online-source preview feasibility). |
| [`docs/design/`](docs/design/) | Dogfood-round design records — complaint → research → fix → on-device verification (`now-playing-redesign.md`, `dogfood-round-3.md`, `dogfood-round-4.md`). |
| [`docs/TODO.md`](docs/TODO.md) | Roadmap, categorized, with per-item status. |

## Server context

- Crates desktop app exposes a REST API at `http://<lan-ip>:54735/resources`
  (OpenAPI spec: `../api-specs/latest/openapi.yaml`, 1.15.3-beta.1, 447 paths).
- Auth: `Authorization: Bearer <token>`, obtained through a pairing flow approved on the
  desktop. (The spec claims a `Client-ID` header — that's wrong; verified against the live
  server. Details in the API doc.)
- Audio: `GET /stream/{tuneID}` with HTTP Range support. Library change notifications flow
  over an undocumented websocket (no SSE); POC polls, websocket is a later upgrade.
