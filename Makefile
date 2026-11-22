SHELL := /bin/bash
REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
export LRU_BASE_DIR := $(REPO_ROOT)

.PHONY: help all train train-fast run spawn evolve status phoenix verify \
        dashboard go-build go-run docker-build docker-run clean test \
        benchmark

help:
	@echo "LRU — Locally Real Universe"
	@echo ""
	@echo "Targets:"
	@echo "  make all          — full lifecycle (train → run → spawn → evolve)"
	@echo "  make train        — train self-model for TRAIN_STEPS (default 100)"
	@echo "  make train-fast   — fast batch training (v8/v9)"
	@echo "  make run          — causally closed run for RUN_STEPS (default 50)"
	@echo "  make spawn        — spawn a child universe"
	@echo "  make evolve       — DAO evolutionary cycle"
	@echo "  make status       — show universe + DAO status"
	@echo "  make phoenix      — run Phoenix Protocol test"
	@echo "  make verify       — verify causal wall integrity"
	@echo "  make benchmark    — run 10-step timing benchmark"
	@echo "  make dashboard    — serve cross-track dashboard on :8080"
	@echo "  make go-build     — compile universe-dao Go binary"
	@echo "  make go-run       — run universe-dao HTTP server"
	@echo "  make docker-build — build Docker image"
	@echo "  make docker-run   — run Docker container"
	@echo "  make test         — smoke tests"
	@echo "  make clean        — remove generated runtime artefacts"

TRAIN_STEPS ?= 100
RUN_STEPS   ?= 50

all:
	@bash scripts/run_universe.sh

train:
	@bash scripts/run_universe.sh --train $(TRAIN_STEPS)

train-fast:
	@bash scripts/run_universe.sh --train-fast $(TRAIN_STEPS)

run:
	@bash scripts/run_universe.sh --run $(RUN_STEPS)

spawn:
	@bash scripts/neural_mvu_v8.sh --spawn

evolve:
	@bash scripts/run_universe.sh --evolve

status:
	@bash scripts/run_universe.sh --status

phoenix:
	@bash scripts/phoenix_test.sh

verify:
	@bash scripts/neural_mvu_v8.sh --verify

benchmark:
	@bash scripts/run_universe.sh --benchmark

dashboard:
	@echo "Dashboard: http://localhost:8080/"
	@cd web && python3 -m http.server 8080

go-build:
	@cd go && CGO_ENABLED=0 go build -ldflags="-s -w" -o universe-dao .

go-run: go-build
	@UNIVERSE_BASE_DIR=$(REPO_ROOT) ./go/universe-dao

docker-build:
	@docker build -t lru:latest .

docker-run:
	@docker run --rm -it -v $(REPO_ROOT):/workspace -p 8080:8080 lru:latest

test:
	@bash tests/smoke.sh

clean:
	@rm -rf backups children tmp .tmp_v* \
	        *_history*.txt history.txt evolution_history.txt \
	        universe_state_v*.json cross_track_bridge.dat \
	        dao/comms dao/votes dao/votes_v* dao/proposals dao/proposals_v* \
	        dao/dao_state_v*.json dao/comms_history*.txt \
	        phoenix/phoenix_*.json go/universe-dao
	@echo "Cleaned runtime artefacts."
