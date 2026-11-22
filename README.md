# LRU — Locally Real Universe

A self-contained, causally-closed neural "micro-universe" that trains a
self-model, broadcasts to peers, spawns children, votes on its own
parameters via an on-chain-style DAO, and rebirths itself through a
Phoenix Protocol when its state collapses.

Everything runs offline on POSIX tools (`awk`, `bc`, `sha256sum`, `seq`) or
— for the heavier workload — Python 3 and Go.

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

## Attribution

Successor to the original Termux-hosted `local-real-universe` workspace.
Shell paths were converted from the Termux-specific
`/storage/emulated/0/Download/picoclaw/workspace/local-real-universe`
to a portable `LRU_BASE_DIR` that resolves to the repo root by default.

Licensed under the MIT License (see `LICENSE`).
