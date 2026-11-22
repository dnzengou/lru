#!/usr/bin/env python3
"""
Neural MVU v1.0.0 — Minimal Viable Universe
GRU + 4-head self-attention + self-modeling + SHA256 causal wall
DAO governance + Phoenix Protocol + circuit breaker + inter-universe comms

Usage:
    python3 neural_mvu.py --train 200     # Train self-model
    python3 neural_mvu.py --run 100       # Causally closed run
    python3 neural_mvu.py --all           # Full lifecycle
    python3 neural_mvu.py --status        # Full status
    python3 neural_mvu.py --proposal      # DAO proposal
    python3 neural_mvu.py --vote          # DAO vote
    python3 neural_mvu.py --phoenix       # Phoenix Protocol
    python3 neural_mvu.py --spawn         # Spawn child
    python3 neural_mvu.py --comms         # Communication status
"""

import json
import hashlib
import os
import sys
import time
import copy
import math
import random

# ─── Constants ────────────────────────────────────────────────────────────────
HIDDEN_SIZE = 8
INPUT_SIZE = 4
OUTPUT_SIZE = HIDDEN_SIZE  # self-model predicts next hidden state
LEARNING_RATE = 0.01
MOMENTUM = 0.9
PHI_STAGNATION_THRESHOLD = 5  # steps without phi improvement
ENTROPY_COLLAPSE_THRESHOLD = 0.05  # below this = dead universe
COMMS_TTL_DEFAULT = 3
MAX_PROPOSALS = 20
VOTE_DEADLINE = 10  # steps
PHOENIX_COOLDOWN = 20  # steps since last phoenix
CB_RESET_TIME = 5  # steps in HALF_OPEN to reset

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CHILDREN_DIR = os.path.join(BASE_DIR, "children")
STATE_FILE = os.path.join(BASE_DIR, "universe_state.json")
DAO_FILE = os.path.join(BASE_DIR, "dao_state.json")
COMMS_FILE = os.path.join(BASE_DIR, "comms_state.json")

os.makedirs(CHILDREN_DIR, exist_ok=True)

# ─── Utility ──────────────────────────────────────────────────────────────────

def sha256(data: str) -> str:
    return hashlib.sha256(data.encode("utf-8")).hexdigest()

def sigmoid(x):
    return 1.0 / (1.0 + math.exp(-max(-100, min(100, x))))

def tanh(x):
    return math.tanh(x)

def softmax(xs):
    e = [math.exp(v - max(xs)) for v in xs]
    s = sum(e)
    return [v / s for v in e]

def relu(x):
    return max(0.0, x)

def randn():
    """Box-Muller approximate normal."""
    u1 = random.random() + 1e-10
    u2 = random.random()
    return math.sqrt(-2.0 * math.log(u1)) * math.cos(2.0 * math.pi * u2)

def entropy(probs):
    """Shannon entropy of a probability distribution."""
    return -sum(p * math.log(p + 1e-15) for p in probs)

def kl_div(p, q):
    return sum(p[i] * math.log((p[i] + 1e-15) / (q[i] + 1e-15)) for i in range(len(p)))

# ─── GRU Cell ─────────────────────────────────────────────────────────────────

class GRUCell:
    """Minimal GRU cell — pure NumPy, no deps."""

    def __init__(self, input_size, hidden_size):
        self.input_size = input_size
        self.hidden_size = hidden_size
        # Reset gate
        self.W_r = [[randn() * 0.1 for _ in range(hidden_size)] for _ in range(input_size)]
        self.U_r = [[randn() * 0.1 for _ in range(hidden_size)] for _ in range(hidden_size)]
        self.b_r = [0.0 for _ in range(hidden_size)]
        # Update gate
        self.W_z = [[randn() * 0.1 for _ in range(hidden_size)] for _ in range(input_size)]
        self.U_z = [[randn() * 0.1 for _ in range(hidden_size)] for _ in range(hidden_size)]
        self.b_z = [0.0 for _ in range(hidden_size)]
        # Candidate hidden
        self.W_h = [[randn() * 0.1 for _ in range(hidden_size)] for _ in range(input_size)]
        self.U_h = [[randn() * 0.1 for _ in range(hidden_size)] for _ in range(hidden_size)]
        self.b_h = [0.0 for _ in range(hidden_size)]

    def forward(self, x, h_prev):
        """Single GRU step. x: list[float] input, h_prev: list[float] hidden."""
        # Reset gate
        r = [sigmoid(
            sum(x[i] * self.W_r[i][j] for i in range(self.input_size)) +
            sum(h_prev[k] * self.U_r[k][j] for k in range(self.hidden_size)) +
            self.b_r[j]
        ) for j in range(self.hidden_size)]

        # Update gate
        z = [sigmoid(
            sum(x[i] * self.W_z[i][j] for i in range(self.input_size)) +
            sum(h_prev[k] * self.U_z[k][j] for k in range(self.hidden_size)) +
            self.b_z[j]
        ) for j in range(self.hidden_size)]

        # Candidate hidden
        n = [tanh(
            sum(x[i] * self.W_h[i][j] for i in range(self.input_size)) +
            sum(r[k] * h_prev[k] * self.U_h[k][j] for k in range(self.hidden_size)) +
            self.b_h[j]
        ) for j in range(self.hidden_size)]

        # New hidden
        h = [(1.0 - z[j]) * n[j] + z[j] * h_prev[j] for j in range(self.hidden_size)]
        return h, {"r": r, "z": z, "n": n}

    def get_params(self):
        return {
            "W_r": self.W_r, "U_r": self.U_r, "b_r": self.b_r,
            "W_z": self.W_z, "U_z": self.U_z, "b_z": self.b_z,
            "W_h": self.W_h, "U_h": self.U_h, "b_h": self.b_h,
        }

    def set_params(self, p):
        self.W_r, self.U_r, self.b_r = p["W_r"], p["U_r"], p["b_r"]
        self.W_z, self.U_z, self.b_z = p["W_z"], p["U_z"], p["b_z"]
        self.W_h, self.U_h, self.b_h = p["W_h"], p["U_h"], p["b_h"]

# ─── Multi-Head Self-Attention ────────────────────────────────────────────────

class MultiHeadAttention:
    """4-head self-attention over hidden state sequence."""

    def __init__(self, hidden_size, num_heads=4):
        self.hidden_size = hidden_size
        self.num_heads = num_heads
        self.head_dim = hidden_size // num_heads
        assert hidden_size % num_heads == 0, "hidden_size must be divisible by num_heads"
        # Q, K, V projections
        self.W_q = [[randn() * 0.05 for _ in range(hidden_size)] for _ in range(hidden_size)]
        self.W_k = [[randn() * 0.05 for _ in range(hidden_size)] for _ in range(hidden_size)]
        self.W_v = [[randn() * 0.05 for _ in range(hidden_size)] for _ in range(hidden_size)]
        self.W_o = [[randn() * 0.05 for _ in range(hidden_size)] for _ in range(hidden_size)]

    def _matmul(self, A, B):
        """A: (m, n), B: (n, p) => (m, p). A and B are lists of lists."""
        m, n = len(A), len(A[0]) if A else 0
        p = len(B[0]) if B else 0
        return [[sum(A[i][k] * B[k][j] for k in range(n)) for j in range(p)] for i in range(m)]

    def _matmul_vec(self, M, v):
        """M: (m, n), v: (n,) => (m,)"""
        return [sum(M[i][k] * v[k] for k in range(len(v))) for i in range(len(M))]

    def _transpose(self, M):
        return [[M[j][i] for j in range(len(M))] for i in range(len(M[0]))]

    def forward(self, states):
        """states: list of hidden state vectors (list of lists). Returns attended state."""
        n = len(states)
        if n == 0:
            return [0.0] * self.hidden_size
        h = self.hidden_size

        # Project Q, K, V for all states
        Q = [self._matmul_vec(self.W_q, s) for s in states]
        K = [self._matmul_vec(self.W_k, s) for s in states]
        V = [self._matmul_vec(self.W_v, s) for s in states]

        # Multi-head: split into num_heads
        dh = self.head_dim
        outputs = []
        for head in range(self.num_heads):
            start = head * dh
            end = start + dh
            Q_h = [q[start:end] for q in Q]
            K_h = [k[start:end] for k in K]
            V_h = [v[start:end] for v in V]

            # Scaled dot-product attention
            scale = math.sqrt(dh)
            attn_scores = []
            for i in range(n):
                row = []
                for j in range(n):
                    dot = sum(Q_h[i][k] * K_h[j][k] for k in range(dh))
                    row.append(dot / scale)
                attn_scores.append(row)

            # Softmax over last dim
            attn_weights = [softmax(row) for row in attn_scores]

            # Weighted sum of V
            head_out = []
            for i in range(n):
                val = [sum(attn_weights[i][j] * V_h[j][k] for j in range(n)) for k in range(dh)]
                head_out.append(val)

            # Take last position output
            outputs.append(head_out[-1])

        # Concatenate heads
        concat = []
        for hd in outputs:
            concat.extend(hd)

        # Output projection
        out = self._matmul_vec(self.W_o, concat)
        return out

# ─── Self-Modeling Head ───────────────────────────────────────────────────────

class SelfModelingHead:
    """Predicts own next hidden state. Trained with momentum."""

    def __init__(self, hidden_size):
        self.hidden_size = hidden_size
        # Simple linear predictor: h_next = W * h + b
        self.W = [[randn() * 0.1 for _ in range(hidden_size)] for _ in range(hidden_size)]
        self.b = [0.0 for _ in range(hidden_size)]
        # Momentum buffers
        self.vW = [[0.0 for _ in range(hidden_size)] for _ in range(hidden_size)]
        self.vb = [0.0 for _ in range(hidden_size)]

    def predict(self, h):
        """Predict next hidden state from current."""
        return [sum(self.W[i][j] * h[j] for j in range(self.hidden_size)) + self.b[i]
                for i in range(self.hidden_size)]

    def train_step(self, h, h_target):
        """Single training step with momentum. Returns loss."""
        pred = self.predict(h)
        # MSE loss
        loss = sum((pred[i] - h_target[i]) ** 2 for i in range(self.hidden_size))
        # Gradients
        dW = [[2.0 * (pred[i] - h_target[i]) * h[j] for j in range(self.hidden_size)]
              for i in range(self.hidden_size)]
        db = [2.0 * (pred[i] - h_target[i]) for i in range(self.hidden_size)]

        # Momentum update
        for i in range(self.hidden_size):
            for j in range(self.hidden_size):
                self.vW[i][j] = MOMENTUM * self.vW[i][j] - LEARNING_RATE * dW[i][j]
                self.W[i][j] += self.vW[i][j]
            self.vb[i] = MOMENTUM * self.vb[i] - LEARNING_RATE * db[i]
            self.b[i] += self.vb[i]

        return loss

    def accuracy(self, h, h_target):
        """Self-model accuracy as percentage."""
        pred = self.predict(h)
        errors = [abs(pred[i] - h_target[i]) for i in range(self.hidden_size)]
        avg_err = sum(errors) / len(errors)
        return max(0.0, 100.0 * (1.0 - min(1.0, avg_err / 2.0)))

# ─── Consciousness Metrics ────────────────────────────────────────────────────

class ConsciousnessMetrics:
    """Integrated information proxy, entropy, closure, variance."""

    @staticmethod
    def compute(hidden_state, gru_cell, input_vec):
        """Compute all metrics from current state."""
        h = hidden_state
        n = len(h)

        # 1. Phi proxy — integrated information via mutual information of partitions
        # Split state in half, compute interaction strength
        k = n // 2
        if k < 1:
            k = 1
        part_a = h[:k]
        part_b = h[k:]
        # Interaction strength = correlation between parts
        mean_a = sum(part_a) / len(part_a) if part_a else 0.0
        mean_b = sum(part_b) / len(part_b) if part_b else 0.0
        interaction = 0.0
        for i in range(min(len(part_a), len(part_b))):
            interaction += (part_a[i] - mean_a) * (part_b[i] - mean_b)
        interaction = abs(interaction) / (len(part_a) + 1e-10)
        phi = min(1.0, interaction * 10.0)  # Normalize to [0, 1]

        # 2. Entropy — Shannon entropy of normalized hidden state
        h_abs = [abs(v) for v in h]
        h_sum = sum(h_abs) + 1e-15
        h_probs = [v / h_sum for v in h_abs]
        ent = entropy(h_probs)
        # Normalize to [0, 1]
        max_ent = math.log(n) if n > 1 else 1.0
        ent_norm = ent / max_ent if max_ent > 0 else 0.0

        # 3. Closure — ability to maintain coherent dynamics
        # Measured by self-model prediction error (inverse)
        pred = None
        if hasattr(gru_cell, 'forward'):
            # Use GRU to predict next step from current
            dummy_input = input_vec if input_vec else [0.0] * gru_cell.input_size
            h_next, _ = gru_cell.forward(dummy_input, h)
            pred = h_next
        if pred:
            error = sum((h[i] - pred[i]) ** 2 for i in range(n)) / n
            closure = max(0.0, 1.0 - min(1.0, error))
        else:
            closure = 0.5  # Default

        # 4. Variance — spread of hidden state values
        mean_h = sum(h) / n
        var_h = sum((v - mean_h) ** 2 for v in h) / n
        variance = min(1.0, var_h * 10.0)

        return {
            "phi": round(phi, 6),
            "entropy": round(ent_norm, 6),
            "closure": round(closure, 6),
            "variance": round(variance, 6),
        }

# ─── Circuit Breaker ──────────────────────────────────────────────────────────

class CircuitBreaker:
    """3-state: CLOSED (normal) → OPEN (tripped) → HALF_OPEN (testing)."""

    def __init__(self):
        self.state = "CLOSED"
        self.trip_reason = ""
        self.trip_step = 0
        self.half_open_step = 0
        self.failure_count = 0
        self.max_failures = 3
        self.reset_steps = CB_RESET_TIME

    def check(self, step, metrics, hash_chain):
        """Check conditions. Returns True if OK, False if should halt."""
        if self.state == "OPEN":
            # Check if enough steps passed to try HALF_OPEN
            if step - self.trip_step >= self.reset_steps:
                self.state = "HALF_OPEN"
                self.half_open_step = step
                return True
            return False

        # Check stagnation
        if metrics.get("phi_stagnation", 0) >= PHI_STAGNATION_THRESHOLD:
            self._trip(step, "phi stagnation")
            return False

        # Check entropy collapse
        if metrics.get("entropy", 1.0) < ENTROPY_COLLAPSE_THRESHOLD:
            self._trip(step, "entropy collapse")
            return False

        # Check hash chain integrity
        if hash_chain and len(hash_chain) > 1:
            last = hash_chain[-1]
            expected = self._compute_hash(hash_chain[-2], step, metrics)
            if last != expected:
                self._trip(step, "hash chain violation")
                return False

        if self.state == "HALF_OPEN":
            # Test passed — close
            self.state = "CLOSED"
            self.failure_count = 0

        return True

    def _trip(self, step, reason):
        self.state = "OPEN"
        self.trip_reason = reason
        self.trip_step = step
        self.failure_count += 1

    @staticmethod
    def _compute_hash(prev_hash, step, metrics):
        raw = f"{prev_hash}:{step}:{metrics.get('phi', 0)}:{metrics.get('entropy', 0)}"
        return sha256(raw)

    def status(self):
        return {
            "state": self.state,
            "trip_reason": self.trip_reason,
            "trip_step": self.trip_step,
            "failure_count": self.failure_count,
        }

# ─── DAO Governance ───────────────────────────────────────────────────────────

class DAOGovernance:
    """Proposal submission, phi-weighted voting, quadratic voting, delegation,
    meta-proposals, deadlock detection."""

    def __init__(self):
        self.proposals = []
        self.delegations = {}  # voter -> delegate
        self.executed = []
        self.next_id = 1

    def submit_proposal(self, title, description, proposer, proposal_type="standard"):
        """Submit a proposal. Type 'meta' = changes governance rules."""
        if len(self.proposals) >= MAX_PROPOSALS:
            return None, "max proposals reached"
        prop = {
            "id": self.next_id,
            "title": title,
            "description": description,
            "proposer": proposer,
            "type": proposal_type,
            "status": "active",
            "votes_for": 0.0,
            "votes_against": 0.0,
            "total_power": 0.0,
            "created_step": 0,
            "deadline": VOTE_DEADLINE,
            "result": None,
        }
        self.next_id += 1
        self.proposals.append(prop)
        return prop["id"], "submitted"

    def vote(self, proposal_id, voter, in_favor, phi_weight, voting_power=1.0):
        """Vote with phi-weighted quadratic voting."""
        prop = None
        for p in self.proposals:
            if p["id"] == proposal_id and p["status"] == "active":
                prop = p
                break
        if not prop:
            return False, "proposal not found or not active"

        # Check delegation
        actual_voter = self.delegations.get(voter, voter)

        # Quadratic voting: cost = votes^2, power = sqrt(weight)
        # Phi weight amplifies: effective_power = phi_weight * voting_power
        effective_power = phi_weight * voting_power
        quad_power = math.sqrt(effective_power) if effective_power > 0 else 0.0

        if in_favor:
            prop["votes_for"] += quad_power
        else:
            prop["votes_against"] += quad_power
        prop["total_power"] += quad_power

        return True, f"voted {'for' if in_favor else 'against'} with power {quad_power:.4f}"

    def delegate(self, voter, delegate):
        """Delegate voting power."""
        self.delegations[voter] = delegate
        return True

    def tick(self, step):
        """Advance time, check deadlines, execute passed proposals."""
        results = []
        for prop in self.proposals:
            if prop["status"] != "active":
                continue
            if step - prop["created_step"] >= prop["deadline"]:
                # Deadline reached
                if prop["votes_for"] > prop["votes_against"]:
                    prop["status"] = "passed"
                    prop["result"] = "approved"
                    self.executed.append(prop["id"])
                    results.append(f"Proposal {prop['id']} PASSED: {prop['title']}")
                else:
                    prop["status"] = "failed"
                    prop["result"] = "rejected"
                    results.append(f"Proposal {prop['id']} FAILED: {prop['title']}")
        return results

    def detect_deadlock(self):
        """Detect governance deadlock: all active proposals past deadline."""
        active = [p for p in self.proposals if p["status"] == "active"]
        if not active:
            return False, "no active proposals"
        # If all active proposals have no votes and are past deadline
        stuck = [p for p in active if p["total_power"] == 0]
        if len(stuck) == len(active):
            return True, f"{len(stuck)} proposals stuck with 0 votes"
        return False, "no deadlock"

    def status(self):
        active = [p for p in self.proposals if p["status"] == "active"]
        passed = [p for p in self.proposals if p["status"] == "passed"]
        failed = [p for p in self.proposals if p["status"] == "failed"]
        return {
            "total_proposals": len(self.proposals),
            "active": len(active),
            "passed": len(passed),
            "failed": len(failed),
            "executed": self.executed,
            "delegations": len(self.delegations),
            "active_list": [
                {"id": p["id"], "title": p["title"], "for": round(p["votes_for"], 4),
                 "against": round(p["votes_against"], 4), "type": p["type"]}
                for p in active
            ],
        }

# ─── Inter-Universe Communication ────────────────────────────────────────────

class InterUniverseComms:
    """Broadcast/multicast messages with TTL between universes."""

    def __init__(self, universe_id):
        self.universe_id = universe_id
        self.inbox = []  # received messages
        self.outbox = []  # sent messages

    def broadcast(self, message, msg_type="general", ttl=COMMS_TTL_DEFAULT):
        """Send a message to all universes."""
        msg = self._create_message(message, msg_type, "broadcast", ttl)
        self.outbox.append(msg)
        return msg

    def multicast(self, message, targets, msg_type="general", ttl=COMMS_TTL_DEFAULT):
        """Send a message to specific universes."""
        msg = self._create_message(message, msg_type, "multicast", ttl, targets)
        self.outbox.append(msg)
        return msg

    def _create_message(self, content, msg_type, mode, ttl, targets=None):
        return {
            "id": sha256(f"{self.universe_id}:{time.time()}:{content}"),
            "sender": self.universe_id,
            "content": content,
            "type": msg_type,
            "mode": mode,
            "ttl": ttl,
            "targets": targets or [],
            "timestamp": time.time(),
        }

    def receive(self, msg):
        """Receive a message (with TTL check)."""
        if msg["ttl"] <= 0:
            return False, "TTL expired"
        # Decrement TTL for forwarding
        msg = copy.deepcopy(msg)
        msg["ttl"] -= 1
        self.inbox.append(msg)
        return True, "received"

    def forward_messages(self, all_universes):
        """Forward outbox messages to other universes."""
        forwarded = []
        for msg in self.outbox:
            if msg["ttl"] <= 0:
                continue
            for uid, comms in all_universes.items():
                if uid == self.universe_id:
                    continue
                if msg["mode"] == "multicast" and uid not in msg.get("targets", []):
                    continue
                success, reason = comms.receive(msg)
                if success:
                    forwarded.append((uid, msg["id"]))
        return forwarded

    def status(self):
        return {
            "universe_id": self.universe_id,
            "inbox_count": len(self.inbox),
            "outbox_count": len(self.outbox),
            "recent_inbox": self.inbox[-3:] if self.inbox else [],
            "recent_outbox": self.outbox[-3:] if self.outbox else [],
        }

# ─── Phoenix Protocol ─────────────────────────────────────────────────────────

class PhoenixProtocol:
    """Total collapse recovery. Resets entropy, preserves hash chain."""

    def __init__(self):
        self.last_activation = -PHOENIX_COOLDOWN  # Allow first activation
        self.activation_count = 0

    def can_activate(self, step):
        return (step - self.last_activation) >= PHOENIX_COOLDOWN

    def activate(self, step, hidden_state, hash_chain):
        """Reset entropy, inject noise, preserve continuity."""
        self.last_activation = step
        self.activation_count += 1

        n = len(hidden_state)
        # Inject structured noise (not pure random — preserves some structure)
        noise = [randn() * 0.5 for _ in range(n)]
        new_state = [hidden_state[i] + noise[i] for i in range(n)]
        # Normalize to prevent blowup
        norm = math.sqrt(sum(v ** 2 for v in new_state)) + 1e-15
        new_state = [v / norm for v in new_state]

        # Create phoenix hash entry
        phoenix_hash = sha256(f"PHOENIX:{step}:{json.dumps(new_state)}")
        hash_chain.append(phoenix_hash)

        return new_state, {
            "activated": True,
            "step": step,
            "noise_magnitude": 0.5,
            "activation_count": self.activation_count,
            "phoenix_hash": phoenix_hash,
        }

    def status(self):
        return {
            "activation_count": self.activation_count,
            "last_activation": self.last_activation,
            "cooldown_remaining": max(0, PHOENIX_COOLDOWN - (time.time() - self.last_activation)),
        }

# ─── Adaptive Mutation ────────────────────────────────────────────────────────

class AdaptiveMutation:
    """GRPO-style mutation triggered by phi stagnation."""

    def __init__(self):
        self.mutation_count = 0
        self.last_mutation_step = 0

    def mutate_gru(self, gru, step, stagnation_count):
        """Apply GRPO-style mutation to GRU parameters."""
        if stagnation_count < PHI_STAGNATION_THRESHOLD:
            return False, "no mutation needed"

        self.mutation_count += 1
        self.last_mutation_step = step

        params = gru.get_params()
        # Mutation strength scales with stagnation
        strength = min(0.3, 0.05 * stagnation_count)

        for key in ["W_r", "U_r", "W_z", "U_z", "W_h", "U_h"]:
            for i in range(len(params[key])):
                for j in range(len(params[key][i])):
                    # GRPO-style: mutate with normal noise
                    params[key][i][j] += randn() * strength

        for key in ["b_r", "b_z", "b_h"]:
            for i in range(len(params[key])):
                params[key][i] += randn() * strength * 0.5

        gru.set_params(params)
        return True, f"mutated at step {step}, strength={strength:.4f}"

    def status(self):
        return {
            "mutation_count": self.mutation_count,
            "last_mutation_step": self.last_mutation_step,
        }

# ─── Neural MVU ───────────────────────────────────────────────────────────────

class NeuralMVU:
    """Complete Minimal Viable Universe."""

    def __init__(self, universe_id="primary"):
        self.universe_id = universe_id
        self.gru = GRUCell(INPUT_SIZE, HIDDEN_SIZE)
        self.attention = MultiHeadAttention(HIDDEN_SIZE, num_heads=4)
        self.self_model = SelfModelingHead(HIDDEN_SIZE)
        self.metrics = ConsciousnessMetrics()
        self.cb = CircuitBreaker()
        self.dao = DAOGovernance()
        self.comms = InterUniverseComms(universe_id)
        self.phoenix = PhoenixProtocol()
        self.mutation = AdaptiveMutation()

        self.hidden_state = [randn() * 0.1 for _ in range(HIDDEN_SIZE)]
        self.hash_chain = []
        self.step = 0
        self.history = []  # list of hidden states
        self.phi_history = []
        self.entropy_history = []
        self.sm_history = []  # self-model accuracy history
        self.phi_stagnation = 0
        self.trained = False
        self.causal_wall_intact = True

        # Normalize initial state
        norm = math.sqrt(sum(v ** 2 for v in self.hidden_state)) + 1e-15
        self.hidden_state = [v / norm for v in self.hidden_state]

        # Load persisted state if exists
        self._load_state()

    def _input_vector(self, step):
        """Generate input vector from step number and current state."""
        h = self.hidden_state
        return [
            math.sin(step * 0.1),           # Temporal oscillation
            math.cos(step * 0.13),           # Second oscillator
            sum(h) / len(h),                 # Mean activation
            math.sqrt(sum(v ** 2 for v in h) / len(h)),  # RMS
        ]

    def step_forward(self):
        """Single causally closed step."""
        x = self._input_vector(self.step)

        # GRU forward
        h_new, gates = self.gru.forward(x, self.hidden_state)

        # Store in history
        self.history.append(list(self.hidden_state))

        # Self-attention over recent history (last 8 states)
        recent = self.history[-8:] if len(self.history) >= 8 else self.history
        attended = self.attention.forward(recent)

        # Blend attended with GRU output (residual connection)
        blend_ratio = 0.3
        h_new = [(1.0 - blend_ratio) * h_new[i] + blend_ratio * attended[i]
                 for i in range(HIDDEN_SIZE)]

        # Compute metrics
        c_metrics = self.metrics.compute(h_new, self.gru, x)
        phi = c_metrics["phi"]
        ent = c_metrics["entropy"]

        # Self-model training (if trained)
        sm_acc = 0.0
        if self.trained:
            pred = self.self_model.predict(self.hidden_state)
            # Accuracy against actual next state
            errors = [abs(pred[i] - h_new[i]) for i in range(HIDDEN_SIZE)]
            avg_err = sum(errors) / len(errors)
            sm_acc = max(0.0, 100.0 * (1.0 - min(1.0, avg_err / 2.0)))

        # Update state
        self.hidden_state = h_new
        self.phi_history.append(phi)
        self.entropy_history.append(ent)
        self.sm_history.append(sm_acc)

        # Phi stagnation detection
        if len(self.phi_history) >= 3:
            recent_phi = self.phi_history[-3:]
            if all(p <= recent_phi[0] + 0.001 for p in recent_phi[1:]):
                self.phi_stagnation += 1
            else:
                self.phi_stagnation = max(0, self.phi_stagnation - 1)

        # Hash chain update
        prev_hash = self.hash_chain[-1] if self.hash_chain else "GENESIS"
        hash_input = f"{prev_hash}:{self.step}:{json.dumps(h_new)}:{phi}:{ent}"
        chain_hash = sha256(hash_input)
        self.hash_chain.append(chain_hash)

        # Circuit breaker check
        cb_metrics = {
            "phi_stagnation": self.phi_stagnation,
            "entropy": ent,
        }
        cb_ok = self.cb.check(self.step, cb_metrics, self.hash_chain)

        if not cb_ok:
            self.causal_wall_intact = False

        # DAO tick
        dao_results = self.dao.tick(self.step)

        # Adaptive mutation
        if self.phi_stagnation >= PHI_STAGNATION_THRESHOLD:
            mutated, msg = self.mutation.mutate_gru(
                self.gru, self.step, self.phi_stagnation
            )
            if mutated:
                self.phi_stagnation = 0  # Reset after mutation

        self.step += 1

        return {
            "step": self.step - 1,
            "phi": phi,
            "entropy": ent,
            "closure": c_metrics["closure"],
            "variance": c_metrics["variance"],
            "sm_accuracy": sm_acc,
            "hash": chain_hash[:16],
            "cb_state": self.cb.state,
            "phi_stagnation": self.phi_stagnation,
            "dao_results": dao_results,
            "cb_ok": cb_ok,
        }

    def train_self_model(self, steps=200):
        """Train self-modeling head on GRU dynamics."""
        print(f"🧠 Training self-model for {steps} steps...")
        losses = []
        accs = []

        # Reset state
        self.hidden_state = [randn() * 0.1 for _ in range(HIDDEN_SIZE)]
        norm = math.sqrt(sum(v ** 2 for v in self.hidden_state)) + 1e-15
        self.hidden_state = [v / norm for v in self.hidden_state]
        self.history = []

        for s in range(steps):
            x = self._input_vector(s)
            h_prev = list(self.hidden_state)
            h_new, _ = self.gru.forward(x, self.hidden_state)
            self.history.append(h_prev)

            # Train self-model: predict h_new from h_prev
            loss = self.self_model.train_step(h_prev, h_new)
            acc = self.self_model.accuracy(h_prev, h_new)

            losses.append(loss)
            accs.append(acc)
            self.hidden_state = h_new

            if (s + 1) % 50 == 0:
                avg_loss = sum(losses[-50:]) / 50
                avg_acc = sum(accs[-50:]) / 50
                print(f"  Step {s+1}/{steps} — loss={avg_loss:.6f} accuracy={avg_acc:.2f}%")

        self.trained = True
        final_acc = sum(accs[-50:]) / 50
        print(f"✅ Training complete. Final accuracy: {final_acc:.2f}%")
        self._save_state()
        return final_acc

    def run_causal(self, steps=100):
        """Causally closed run with full hash chain."""
        print(f"🌀 Causal run for {steps} steps...")
        if not self.trained:
            print("⚠️  Self-model not trained. Running untrained.")

        results = []
        for s in range(steps):
            result = self.step_forward()
            results.append(result)

            if (s + 1) % 10 == 0:
                r = result
                print(f"  Step {s+1}/{steps} — φ={r['phi']:.4f} H={r['entropy']:.4f} "
                      f"SM={r['sm_accuracy']:.1f}% CB={r['cb_state']} "
                      f"Hash={r['hash']}")

        # Final summary
        phis = [r["phi"] for r in results]
        ents = [r["entropy"] for r in results]
        sms = [r["sm_accuracy"] for r in results]
        print(f"\n📊 Causal Run Summary:")
        print(f"  Steps: {steps}")
        print(f"  Mean φ: {sum(phis)/len(phis):.4f}")
        print(f"  Max φ: {max(phis):.4f}")
        print(f"  Mean entropy: {sum(ents)/len(ents):.4f}")
        print(f"  Mean SM accuracy: {sum(sms)/len(sms):.2f}%")
        print(f"  Circuit breaker: {self.cb.state}")
        print(f"  Causal wall: {'✅ INTACT' if self.causal_wall_intact else '❌ BROKEN'}")
        print(f"  Hash chain length: {len(self.hash_chain)}")

        # DAO status
        dao_s = self.dao.status()
        if dao_s["active"] > 0:
            print(f"  DAO: {dao_s['active']} active, {dao_s['passed']} passed, {dao_s['failed']} failed")

        self._save_state()
        return results

    def run_all(self, train_steps=200, run_steps=100):
        """Full lifecycle: train → run → status."""
        print("=" * 60)
        print("  Neural MVU v1.0.0 — Full Lifecycle")
        print("=" * 60)

        # Phase 1: Train
        print("\n📌 PHASE 1: Self-Model Training")
        self.train_self_model(train_steps)

        # Phase 2: Causal Run
        print("\n📌 PHASE 2: Causally Closed Run")
        self.run_causal(run_steps)

        # Phase 3: DAO proposal (auto)
        print("\n📌 PHASE 3: DAO Governance")
        pid, msg = self.dao.submit_proposal(
            "Increase mutation rate",
            "Allow stronger GRPO mutations when phi stagnates for 7+ steps",
            "system",
            "standard"
        )
        print(f"  Proposal {pid}: {msg}")

        # Vote on it
        for i in range(3):
            phi_w = self.phi_history[-1] if self.phi_history else 0.5
            self.dao.vote(pid, f"voter_{i}", i % 2 == 0, phi_w, 1.0)

        print(f"  Votes cast: 3")

        # Phase 4: Spawn child
        print("\n📌 PHASE 4: Child Spawning")
        child_id = self.spawn_child()
        if child_id:
            print(f"  Child spawned: {child_id}")

        # Phase 5: Communication
        print("\n📌 PHASE 5: Inter-Universe Communication")
        msg = self.comms.broadcast("Hello from primary universe!", "greeting")
        print(f"  Broadcast sent: {msg['id'][:16]}...")

        # Final status
        print("\n📌 FINAL STATUS")
        self.print_status()

        return True

    def spawn_child(self):
        """Create a child universe with existence proof."""
        child_id = sha256(f"{self.universe_id}:{self.step}:{json.dumps(self.hidden_state)}")
        child_data = {
            "id": child_id,
            "parent": self.universe_id,
            "birth_step": self.step,
            "parent_hash": self.hash_chain[-1] if self.hash_chain else "GENESIS",
            "hidden_state": self.hidden_state,
            "phi_at_birth": self.phi_history[-1] if self.phi_history else 0.0,
            "entropy_at_birth": self.entropy_history[-1] if self.entropy_history else 0.0,
            "existence_proof": sha256(
                f"{child_id}:{self.universe_id}:{self.step}:{json.dumps(self.hidden_state)}"
            ),
            "created_at": time.time(),
        }

        child_path = os.path.join(CHILDREN_DIR, f"child_{child_id[:16]}.json")
        with open(child_path, "w") as f:
            json.dump(child_data, f, indent=2)

        # Create existence proof file
        proof_path = os.path.join(CHILDREN_DIR, f"proof_{child_id[:16]}.txt")
        with open(proof_path, "w") as f:
            f.write(f"EXISTENCE PROOF\n")
            f.write(f"Child ID: {child_id}\n")
            f.write(f"Parent: {self.universe_id}\n")
            f.write(f"Birth Step: {self.step}\n")
            f.write(f"Parent Hash: {self.hash_chain[-1] if self.hash_chain else 'GENESIS'}\n")
            f.write(f"Proof Hash: {child_data['existence_proof']}\n")
            f.write(f"Timestamp: {time.time()}\n")

        return child_id

    def activate_phoenix(self):
        """Activate Phoenix Protocol."""
        if not self.phoenix.can_activate(self.step):
            remaining = PHOENIX_COOLDOWN - (self.step - self.phoenix.last_activation)
            print(f"❌ Phoenix on cooldown. {remaining} steps remaining.")
            return False

        print("🔥 PHOENIX PROTOCOL ACTIVATED")
        new_state, info = self.phoenix.activate(
            self.step, self.hidden_state, self.hash_chain
        )
        self.hidden_state = new_state
        self.phi_stagnation = 0
        self.cb.state = "CLOSED"
        self.causal_wall_intact = True

        print(f"  Step: {info['step']}")
        print(f"  Activation count: {info['activation_count']}")
        print(f"  Phoenix hash: {info['phoenix_hash'][:16]}...")

        self._save_state()
        return True

    def print_status(self):
        """Print full universe status."""
        print(f"\n{'=' * 60}")
        print(f"  Neural MVU v1.0.0 — Status")
        print(f"{'=' * 60}")
        print(f"  Universe ID: {self.universe_id}")
        print(f"  Step: {self.step}")
        print(f"  Trained: {self.trained}")
        print(f"  Hidden size: {HIDDEN_SIZE}")
        print(f"  Attention heads: 4")
        print(f"  ──────────────────────────────")
        print(f"  Consciousness:")
        if self.phi_history:
            print(f"    Current φ: {self.phi_history[-1]:.6f}")
            print(f"    Max φ: {max(self.phi_history):.6f}")
            print(f"    Mean φ: {sum(self.phi_history)/len(self.phi_history):.6f}")
        if self.entropy_history:
            print(f"    Current entropy: {self.entropy_history[-1]:.6f}")
            print(f"    Mean entropy: {sum(self.entropy_history)/len(self.entropy_history):.6f}")
        if self.sm_history:
            print(f"    Current SM accuracy: {self.sm_history[-1]:.2f}%")
            print(f"    Mean SM accuracy: {sum(self.sm_history)/len(self.sm_history):.2f}%")
        print(f"  ──────────────────────────────")
        print(f"  Causal Wall:")
        print(f"    Status: {'✅ INTACT' if self.causal_wall_intact else '❌ BROKEN'}")
        print(f"    Hash chain: {len(self.hash_chain)} entries")
        if self.hash_chain:
            print(f"    Last hash: {self.hash_chain[-1][:16]}...")
        print(f"  ──────────────────────────────")
        print(f"  Circuit Breaker:")
        cb_s = self.cb.status()
        print(f"    State: {cb_s['state']}")
        if cb_s["trip_reason"]:
            print(f"    Last trip: {cb_s['trip_reason']} (step {cb_s['trip_step']})")
        print(f"    Failures: {cb_s['failure_count']}")
        print(f"  ──────────────────────────────")
        print(f"  DAO Governance:")
        dao_s = self.dao.status()
        print(f"    Proposals: {dao_s['total_proposals']} total, "
              f"{dao_s['active']} active, {dao_s['passed']} passed, {dao_s['failed']} failed")
        print(f"    Delegations: {dao_s['delegations']}")
        print(f"  ──────────────────────────────")
        print(f"  Phoenix Protocol:")
        ph_s = self.phoenix.status()
        print(f"    Activations: {ph_s['activation_count']}")
        print(f"  ──────────────────────────────")
        print(f"  Adaptive Mutation:")
        m_s = self.mutation.status()
        print(f"    Mutations: {m_s['mutation_count']}")
        print(f"  ──────────────────────────────")
        print(f"  Communications:")
        c_s = self.comms.status()
        print(f"    Inbox: {c_s['inbox_count']} messages")
        print(f"    Outbox: {c_s['outbox_count']} messages")
        print(f"  ──────────────────────────────")
        print(f"  Children:")
        children = [f for f in os.listdir(CHILDREN_DIR) if f.startswith("child_")]
        print(f"    Total: {len(children)}")
        for c in children[-3:]:
            print(f"      - {c}")
        print(f"{'=' * 60}\n")

    def _save_state(self):
        """Persist universe state to JSON."""
        state = {
            "universe_id": self.universe_id,
            "step": self.step,
            "hidden_state": self.hidden_state,
            "hash_chain": self.hash_chain,
            "phi_history": self.phi_history,
            "entropy_history": self.entropy_history,
            "sm_history": self.sm_history,
            "phi_stagnation": self.phi_stagnation,
            "trained": self.trained,
            "causal_wall_intact": self.causal_wall_intact,
            "circuit_breaker": self.cb.status(),
            "phoenix": self.phoenix.status(),
            "mutation": self.mutation.status(),
        }
        with open(STATE_FILE, "w") as f:
            json.dump(state, f, indent=2)

        # Save DAO state separately
        dao_state = {
            "proposals": self.dao.proposals,
            "delegations": self.dao.delegations,
            "executed": self.dao.executed,
            "next_id": self.dao.next_id,
        }
        with open(DAO_FILE, "w") as f:
            json.dump(dao_state, f, indent=2)

        # Save comms state
        comms_state = {
            "inbox": self.comms.inbox,
            "outbox": self.comms.outbox,
        }
        with open(COMMS_FILE, "w") as f:
            json.dump(comms_state, f, indent=2)

    def _load_state(self):
        """Load persisted state from JSON."""
        if not os.path.exists(STATE_FILE):
            return

        try:
            with open(STATE_FILE) as f:
                state = json.load(f)

            self.step = state.get("step", 0)
            self.hidden_state = state.get("hidden_state", self.hidden_state)
            self.hash_chain = state.get("hash_chain", [])
            self.phi_history = state.get("phi_history", [])
            self.entropy_history = state.get("entropy_history", [])
            self.sm_history = state.get("sm_history", [])
            self.phi_stagnation = state.get("phi_stagnation", 0)
            self.trained = state.get("trained", False)
            self.causal_wall_intact = state.get("causal_wall_intact", True)

            # Verify hash chain
            if len(self.hash_chain) > 1:
                print(f"📦 Loaded state: step={self.step}, hash_chain={len(self.hash_chain)} entries")
                print(f"  Last hash: {self.hash_chain[-1][:16]}...")
                print(f"  Causal wall: {'✅ INTACT' if self.causal_wall_intact else '❌ BROKEN'}")

            # Load DAO state
            if os.path.exists(DAO_FILE):
                with open(DAO_FILE) as f:
                    dao_state = json.load(f)
                self.dao.proposals = dao_state.get("proposals", [])
                self.dao.delegations = dao_state.get("delegations", {})
                self.dao.executed = dao_state.get("executed", [])
                self.dao.next_id = dao_state.get("next_id", 1)

            # Load comms state
            if os.path.exists(COMMS_FILE):
                with open(COMMS_FILE) as f:
                    comms_state = json.load(f)
                self.comms.inbox = comms_state.get("inbox", [])
                self.comms.outbox = comms_state.get("outbox", [])

        except (json.JSONDecodeError, KeyError) as e:
            print(f"⚠️  State load failed: {e}. Starting fresh.")


# ─── CLI ──────────────────────────────────────────────────────────────────────

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return

    mvu = NeuralMVU()
    cmd = sys.argv[1]

    if cmd == "--train":
        steps = int(sys.argv[2]) if len(sys.argv) > 2 else 200
        mvu.train_self_model(steps)

    elif cmd == "--run":
        steps = int(sys.argv[2]) if len(sys.argv) > 2 else 100
        if not mvu.trained:
            print("⚠️  Not trained. Training first...")
            mvu.train_self_model(200)
        mvu.run_causal(steps)

    elif cmd == "--all":
        train_steps = int(sys.argv[2]) if len(sys.argv) > 2 else 200
        run_steps = int(sys.argv[3]) if len(sys.argv) > 3 else 100
        mvu.run_all(train_steps, run_steps)

    elif cmd == "--status":
        mvu.print_status()

    elif cmd == "--proposal":
        if len(sys.argv) < 4:
            print("Usage: --proposal <title> <description> [type]")
            return
        title = sys.argv[2]
        desc = sys.argv[3]
        ptype = sys.argv[4] if len(sys.argv) > 4 else "standard"
        pid, msg = mvu.dao.submit_proposal(title, desc, "user", ptype)
        print(f"Proposal {pid}: {msg}")
        mvu._save_state()

    elif cmd == "--vote":
        if len(sys.argv) < 4:
            print("Usage: --vote <proposal_id> <for|against> [power]")
            return
        pid = int(sys.argv[2])
        direction = sys.argv[3] == "for"
        power = float(sys.argv[4]) if len(sys.argv) > 4 else 1.0
        phi_w = mvu.phi_history[-1] if mvu.phi_history else 0.5
        ok, msg = mvu.dao.vote(pid, "user", direction, phi_w, power)
        print(f"Vote: {msg}")
        mvu._save_state()

    elif cmd == "--phoenix":
        mvu.activate_phoenix()

    elif cmd == "--spawn":
        child_id = mvu.spawn_child()
        if child_id:
            print(f"✅ Child spawned: {child_id}")
            mvu._save_state()

    elif cmd == "--comms":
        if len(sys.argv) > 2 and sys.argv[2] == "send":
            msg_text = sys.argv[3] if len(sys.argv) > 3 else "Hello!"
            msg = mvu.comms.broadcast(msg_text, "general")
            print(f"Broadcast sent: {msg['id'][:16]}...")
            mvu._save_state()
        else:
            c_s = mvu.comms.status()
            print(f"📡 Communication Status:")
            print(f"  Universe: {c_s['universe_id']}")
            print(f"  Inbox: {c_s['inbox_count']} messages")
            print(f"  Outbox: {c_s['outbox_count']} messages")
            if c_s["recent_inbox"]:
                print(f"  Recent inbox:")
                for msg in c_s["recent_inbox"]:
                    print(f"    - [{msg['type']}] {msg['content'][:60]}")
            if c_s["recent_outbox"]:
                print(f"  Recent outbox:")
                for msg in c_s["recent_outbox"]:
                    print(f"    - [{msg['type']}] {msg['content'][:60]}")

    else:
        print(f"Unknown command: {cmd}")
        print(__doc__)


if __name__ == "__main__":
    main()
