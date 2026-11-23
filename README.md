# LRU — Locally Real Universe

A self-contained, causally-closed neural "micro-universe" that trains a
self-model, broadcasts to peers, spawns children, votes on its own
parameters via an on-chain-style DAO, and rebirths itself through a
Phoenix Protocol when its state collapses.

Everything runs offline on POSIX tools (`awk`, `bc`, `sha256sum`, `seq`) or
— for the heavier workload — Python 3 and Go.

## Inspiration

This project was inspired by the 2022 Nobel Prize 🏆 in Physics awarded
to Alain Aspect, John F. Clauser, and Anton Zeilinger "for experiments
with entangled photons, establishing the violation of Bell inequalities
and pioneering quantum information science" — work that showed the
universe is **not locally real**, and which has fuelled the modern
simulation-hypothesis conversation ("we 'might' be living in a
simulation").

LRU flips the question around: *what does it take to build a universe
that **is** locally real — from scratch?* A deterministic, causally
closed, self-modelling micro-universe with its own clock, its own
constitution (the DAO), and its own rebirth protocol. The goal is to
study it as a counterpoint to the "locally unreal" one we actually
inhabit — to see which properties of physics have to be sacrificed to
keep locality + realism, and which emerge anyway.

Further reading / watching:

- [Why the universe is not locally real — and the 2022 Nobel Prize](https://youtu.be/o-g0HnbZ_kQ)
- [Simulation hypothesis, briefly](https://youtu.be/EykaPqzzdQg)

```
┌──────────────────────────────────────────────────────────────┐
│  Neural MVU  ─▶  Self-model (GRU + 8-head attention)         │
│       │          ├─ Causal wall (SHA-256)                    │
│       │          ├─ Φ / entropy / closure metrics            │
│       │          └─ Child spawning                           │
│       ▼                                                      │
│   DAO Engine ─▶  Proposals · votes · parameter evolution     │
│       │          ├─ Treasury                                 │
│       │          └─ Phoenix rebirth on stagnation            │
│       ▼                                                      │
│  Cross-track bridge ─▶ Comms protocol / dashboard (web/)     │
└──────────────────────────────────────────────────────────────┘
```

## Quick start

```sh
# Full lifecycle: train → run → spawn → DAO evolve
make all

# Or more granular:
make train TRAIN_STEPS=200
make run   RUN_STEPS=100
make spawn
make evolve
make status
make phoenix
make verify
```

Direct entrypoint:

```sh
sh scripts/run_universe.sh --help
sh scripts/run_universe.sh --train 200
sh scripts/run_universe.sh --train-fast 500
sh scripts/run_universe.sh --run 100
sh scripts/run_universe.sh --evolve
sh scripts/run_universe.sh --benchmark
```

The runtime auto-detects the best available engine:
`neural_mvu_v9.sh` → `neural_mvu_v8.sh` → `neural_mvu_v7.sh` →
`python/neural_mvu_v2.py`.

## Layout

| Path | Purpose |
|---|---|
| `scripts/` | Shell engines (neural MVU v8/v9, DAO, Phoenix, cross-track bridge) |
| `python/` | Enhanced Python engines (v1 / v2) |
| `go/`     | `universe_dao.go` — Go port with an HTTP governance API |
| `web/`    | Cross-track live dashboard (`index.html`) |
| `dao/`    | Seed DAO state, treasury, votes |
| `evolution/` | Seed evolutionary state |
| `registry/`  | Universe registry |
| `phoenix/`   | Phoenix-protocol snapshots |
| `tests/`  | Smoke tests |

Generated runtime artefacts (`children/`, `backups/`, `tmp/`,
`*_history*.txt`, `universe_state_v*.json`, etc.) are git-ignored and
rebuilt on demand.

## Go DAO engine

```sh
make go-build
make go-run                 # HTTP server, see UNIVERSE_BASE_DIR env
```

The Go port exposes a REST-ish governance surface (`/train`, `/run`,
`/spawn`, `/propose`, `/vote`, `/status`, `/phoenix`) and shares state
with the shell engines through JSON files under `UNIVERSE_BASE_DIR`.

## Live dashboard

```sh
make dashboard   # http://localhost:8080/
```

## Docker

```sh
make docker-build
make docker-run
```

## Environment

| Var | Purpose | Default |
|---|---|---|
| `LRU_BASE_DIR` | Root for shell engine state | repo root |
| `UNIVERSE_BASE_DIR` | Root for Go engine state | `/data/universe` |

## Tests

```sh
make test
```

Runs bash parse checks, Python compile, `go vet` + build, JSON state
validation, and `--help` dispatch. CI runs this on every push.

## Related work & sibling projects

LRU is the broad sandbox; several narrower tools borrow one slice of it
and apply it to a single, hardened use case. The relationship is
deliberate: experimental frames stay here, productised slices leave.

### Sealwright — the audit-grade claw

[`dnzengou/sealwright`](https://github.com/dnzengou/sealwright) is a
sealed desk for private work with a provable audit. Its per-epoch
"claw" asks a single-epoch question (did this mutant drop fitness, did
it open the seal). Sealwright is adopting **one** slice of LRU's
quorum toolkit: a `quorum_pressure` field accumulated across epochs,
surfaced on the Guard tile, used to refuse a new epoch once the
threshold is crossed (reviewer must acknowledge).

The framing that justifies that import — *"quorum tips before the
curve peaks"* — is the argument for why a weekly stamp beats a
per-request guardrail, and lives in Sealwright's whitepaper as a
single paragraph that links back here.

Everything downstream of that one field stays in LRU.

### The quorum engine

A cumulative-pressure read across epochs (in contrast to the claw's
per-epoch gate). Two uses:

1. **Drift pressure on the policy.** Each PARTIAL_MERGE and each small
   fitness dip is an "autoinducer". When running pressure crosses
   threshold, the desk refuses further epochs and surfaces
   `quorum reached — review the lineage` instead of silently shipping
   the eleventh almost-fine stamp. Catches slow policy decay that a
   single-epoch gate misses.
2. **Audit pressure on the operator.** Accumulate signals correlated
   with a seal being lifted on purpose (remote base set, airgap
   lifted, bounds dropped, heavy balloon on). A weekly quorum-style
   index; a reviewer reading `state.json` sees a number, not seven
   flags. Scoring change, not a new gate.

### Research themes that live here, not downstream

LRU is where speculative and biomimetic frames belong — kept out of
hardened productised tools so their lexicon stays plain:

- **SEIR / epidemic dynamics** — modelling policy-drift spread across a
  universe's children.
- **Kessler syndrome** — cascade failure of orbital constraints as a
  metaphor for runaway mutation.
- **Red Queen dynamics** — co-evolving self-model vs. environment.
- **Trophic cascade** — top-down effects of a Phoenix rebirth on the
  child registry.
- **DARE (Deterrence / Assurance / Reassurance / Engagement)** — the
  governance posture layer around the DAO.
- **Biomimicry** — quorum sensing, autoinducers, sporulation thresholds.
- **Costate / citadel** — dual-process guardrails around the self-model.
- **Garden game** — the playable "tend a locally real universe" layer.
- **Stoic / quantum essays** — prose that frames *why* a locally real
  universe is a worthwhile foil to our locally unreal one.

### Containment / Effect-Based Assurance

Adjacent academic framing for the DAO's refusal rule — "the engine
refuses any edit that removes containment, regardless of fitness
gain." Worth a "Related work" line in a future whitepaper here.

## Attribution

Successor to the original Termux-hosted `local-real-universe` workspace.
Shell paths were converted from the Termux-specific
`/storage/emulated/0/Download/picoclaw/workspace/local-real-universe`
to a portable `LRU_BASE_DIR` that resolves to the repo root by default.

Licensed under the MIT License (see `LICENSE`).
