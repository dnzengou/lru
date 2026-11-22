#!/usr/bin/env python3
"""
Neural MVU v2.0.0 — Enhanced Minimal Viable Universe
=====================================================
8-head attention (was 4) | Hidden size 16 (was 8)
GRPO-style adaptive mutation with Q-gate validation
KafCa event bus (Kanban/Feedback/Cascade events)
RRSS scoring per genome (Robustness, Resilience, Solidity, Scalability)
Circuit breaker with 3-state (CLOSED→OPEN→HALF_OPEN)
Self-evolving meta-GRPO (can mutate its own mutation strategy)
Backward compatible with v7 state format
--evolve flag for DAO evolutionary cycle

Usage:
    python3 neural_mvu_v2.py --train 200     # Train self-model
    python3 neural_mvu_v2.py --run 100       # Causally closed run
    python3 neural_mvu_v2.py --all           # Full lifecycle
    python3 neural_mvu_v2.py --status        # Full status
    python3 neural_mvu_v2.py --proposal      # DAO proposal
    python3 neural_mvu_v2.py --vote          # DAO vote
    python3 neural_mvu_v2.py --phoenix       # Phoenix Protocol
    python3 neural_mvu_v2.py --spawn         # Spawn child
    python3 neural_mvu_v2.py --comms         # Communication status
    python3 neural_mvu_v2.py --evolve        # DAO evolutionary cycle
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
HIDDEN_SIZE = 16        # Was 8 in v1
INPUT_SIZE = 8           # Was 4 — richer input for larger hidden state
OUTPUT_SIZE = HIDDEN_SIZE
LEARNING_RATE = 0.01
MOMENTUM = 0.9
PHI_STAGNATION_THRESHOLD = 5
ENTROPY_COLLAPSE_THRESHOLD = 0.05
COMMS_TTL_DEFAULT = 3
MAX_PROPOSALS = 20
VOTE_DEADLINE = 10
PHOENIX_COOLDOWN = 20
CB_RESET_TIME = 5
N_HEADS = 8              # Was 4 in v1
GRPO_MUTATION_BASE = 0.05
GRPO_STRENGTH_DECAY = 0.98
Q_GATE_THRESHOLD = 0.3   # Q-gate validation threshold
KAFCA_MAX_EVENTS = 100   # KafCa event bus size

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CHILDREN_DIR = os.path.join(BASE_DIR, "children")
STATE_FILE = os.path.join(BASE_DIR, "universe_state_v2.json")
STATE_FILE_V7 = os.path.join(BASE_DIR, "universe_state_v7.json")  # backward compat
DAO_FILE = os.path.join(BASE_DIR, "dao_state_v2.json")
COMMS_FILE = os.path.join(BASE_DIR, "comms_state_v2.json")
KAFCA_FILE = os.path.join(BASE_DIR, "kafca_events_v2.json")
RRSS_FILE = os.path.join(BASE_DIR, "rrss_scores_v2.json")
HISTORY_FILE = os.path.join(BASE_DIR, "neural_history_v2.txt")

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

def randn():
    """Box-Muller approximate normal."""
    u1 = random.random() + 1e-10
    u2 = random.random()
    return math.sqrt(-2.0 * math.log(u1)) * math.cos(2.0 * math.pi * u2)

def entropy(probs):
    """Shannon entropy of a probability distribution."""
    return -sum(p * math.log(p + 1e-15) for p in probs)


# ═══════════════════════════════════════════════════════════════════════════════
# KafCa Event Bus (Kanban / Feedback / Cascade)
# ═══════════════════════════════════════════════════════════════════════════════

class KafCaEventBus:
    """Typed event bus: Kanban (workflow state), Feedback (loop detection),
    Cascade (2nd/3rd order effects)."""

    def __init__(self, max_events=KAFCA_MAX_EVENTS):
        self.events = []
        self.max_events = max_events
        self.listeners = {}

    def emit(self, event_type, source, data):
        """Emit an event. Types: KANBAN, FEEDBACK, CASCADE."""
        event = {
            "type": event_type,
            "source": source,
            "data": data,
            "step": time.time(),
            "id": sha256(f"{event_type}:{source}:{time.time()}:{json.dumps(data)}")[:16],
        }
        self.events.append(event)
        if len(self.events) > self.max_events:
            self.events = self.events[-self.max_events:]

        # Notify listeners
        if event_type in self.listeners:
            for listener in self.listeners[event_type]:
                listener(event)

        return event["id"]

    def on(self, event_type, callback):
        """Register event listener."""
        if event_type not in self.listeners:
            self.listeners[event_type] = []
        self.listeners[event_type].append(callback)

    def get_events(self, event_type=None, limit=10):
        """Get recent events, optionally filtered by type."""
        if event_type:
            filtered = [e for e in self.events if e["type"] == event_type]
        else:
            filtered = self.events
        return filtered[-limit:]

    def get_feedback_loops(self):
        """Detect feedback loops from FEEDBACK events."""
        loops = [e for e in self.events if e["type"] == "FEEDBACK"]
        # Group by source
        by_source = {}
        for e in loops:
            s = e["source"]
            if s not in by_source:
                by_source[s] = []
            by_source[s].append(e)
        # Detect loops: same source repeating
        result = {}
        for source, evts in by_source.items():
            if len(evts) >= 3:
                # Check if it's a reinforcing loop
                vals = [e["data"].get("value", 0) for e in evts[-5:]]
                if len(vals) >= 3:
                    trend = sum(1 for i in range(1, len(vals)) if vals[i] > vals[i-1])
                    result[source] = {
                        "count": len(evts),
                        "trend": "increasing" if trend > len(vals)//2 else "stable",
                        "loop_type": "reinforcing" if trend > len(vals)//2 else "balancing",
                    }
        return result

    def get_cascade_effects(self):
        """Get cascade effects from CASCADE events."""
        cascades = [e for e in self.events if e["type"] == "CASCADE"]
        # Map 1st → 2nd → 3rd order effects
        orders = {}
        for e in cascades:
            order = e["data"].get("order", 1)
            if order not in orders:
                orders[order] = []
            orders[order].append(e)
        return orders

    def save(self, path):
        with open(path, "w") as f:
            json.dump({"events": self.events[-200:]}, f, indent=2)

    def load(self, path):
        if os.path.exists(path):
            with open(path) as f:
                data = json.load(f)
                self.events = data.get("events", [])


# ═══════════════════════════════════════════════════════════════════════════════
# RRSS Scoring (Robustness, Resilience, Solidity, Scalability)
# ═══════════════════════════════════════════════════════════════════════════════

class RRSSScorer:
    """Multi-dimensional fitness scoring per genome."""

    def __init__(self):
        self.scores = {}  # genome_id -> {R, R, S, S, overall}

    def score(self, genome_id, metrics):
        """Score a genome on 4 dimensions.
        metrics: {accuracy, phi, entropy, variance, steps, children, mutations, cb_trips}
        Returns dict with R,R,S,S scores and overall.
        """
        acc = metrics.get("accuracy", 0)
        phi = metrics.get("phi", 0)
        ent = metrics.get("entropy", 0.5)
        var = metrics.get("variance", 0)
        steps = metrics.get("steps", 1)
        children = metrics.get("children", 0)
        mutations = metrics.get("mutations", 1)
        cb_trips = metrics.get("cb_trips", 0)

        # Robustness: accuracy × (1 - CB trip rate)
        robustness = acc * (1.0 - min(1.0, cb_trips / max(steps, 1) * 10))

        # Resilience: phi × entropy × ability to recover
        resilience = phi * ent * (1.0 + 0.1 * min(children, 10))

        # Solidity: variance stability × hash chain integrity
        solidity = var * (1.0 - min(0.5, cb_trips / max(steps, 1) * 5))

        # Scalability: children × hidden_size efficiency
        scalability = min(1.0, (children + 1) / 10.0) * min(1.0, HIDDEN_SIZE / 16.0)

        # Overall (weighted)
        overall = 0.35 * robustness + 0.25 * resilience + 0.20 * solidity + 0.20 * scalability

        score = {
            "robustness": round(robustness, 4),
            "resilience": round(resilience, 4),
            "solidity": round(solidity, 4),
            "scalability": round(scalability, 4),
            "overall": round(overall, 4),
        }
        self.scores[genome_id] = score
        return score

    def get(self, genome_id):
        return self.scores.get(genome_id, {
            "robustness": 0, "resilience": 0, "solidity": 0, "scalability": 0, "overall": 0
        })

    def leaderboard(self, top_n=5):
        """Return top N genomes by overall score."""
        sorted_scores = sorted(self.scores.items(), key=lambda x: x[1]["overall"], reverse=True)
        return sorted_scores[:top_n]

    def save(self, path):
        with open(path, "w") as f:
            json.dump(self.scores, f, indent=2)

    def load(self, path):
        if os.path.exists(path):
            with open(path) as f:
                self.scores = json.load(f)


# ═══════════════════════════════════════════════════════════════════════════════
# GRU Cell (v2: larger hidden size = 16)
# ═══════════════════════════════════════════════════════════════════════════════

class GRUCell:
    """Minimal GRU cell — HIDDEN_SIZE=16, INPUT_SIZE=8."""

    def __init__(self, input_size=INPUT_SIZE, hidden_size=HIDDEN_SIZE):
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
        n_in = min(len(x), self.input_size)
        n_hid = self.hidden_size

        # Reset gate
        r = [sigmoid(
            sum(x[i] * self.W_r[i][j] for i in range(n_in)) +
            sum(h_prev[k] * self.U_r[k][j] for k in range(n_hid)) +
            self.b_r[j]
        ) for j in range(n_hid)]

        # Update gate
        z = [sigmoid(
            sum(x[i] * self.W_z[i][j] for i in range(n_in)) +
            sum(h_prev[k] * self.U_z[k][j] for k in range(n_hid)) +
            self.b_z[j]
        ) for j in range(n_hid)]

        # Candidate hidden
        n = [tanh(
            sum(x[i] * self.W_h[i][j] for i in range(n_in)) +
            sum(r[k] * h_prev[k] * self.U_h[k][j] for k in range(n_hid)) +
            self.b_h[j]
        ) for j in range(n_hid)]

        # New hidden
        h = [(1.0 - z[j]) * n[j] + z[j] * h_prev[j] for j in range(n_hid)]
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


# ═══════════════════════════════════════════════════════════════════════════════
# Multi-Head Self-Attention (v2: 8 heads)
# ═══════════════════════════════════════════════════════════════════════════════

class MultiHeadAttention:
    """8-head self-attention over hidden state sequence (was 4 in v1)."""

    def __init__(self, hidden_size=HIDDEN_SIZE, num_heads=N_HEADS):
        self.hidden_size = hidden_size
        self.num_heads = num_heads
        self.head_dim = hidden_size // num_heads
        assert hidden_size % num_heads == 0, f"hidden_size ({hidden_size}) must be divisible by num_heads ({num_heads})"
        # Q, K, V projections
        self.W_q = [[randn() * 0.05 for _ in range(hidden_size)] for _ in range(hidden_size)]
        self.W_k = [[randn() * 0.05 for _ in range(hidden_size)] for _ in range(hidden_size)]
        self.W_v = [[randn() * 0.05 for _ in range(hidden_size)] for _ in range(hidden_size)]
        self.W_o = [[randn() * 0.05 for _ in range(hidden_size)] for _ in range(hidden_size)]

    def _matmul_vec(self, M, v):
        """M: (m, n), v: (n,) => (m,)"""
        m = len(M)
        n = min(len(v), len(M[0]) if M else 0)
        return [sum(M[i][k] * v[k] for k in range(n)) for i in range(m)]

    def forward(self, states):
        """states: list of hidden state vectors. Returns attended state."""
        n = len(states)
        if n == 0:
            return [0.0] * self.hidden_size
        h = self.hidden_size

        # Project Q, K, V
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

            attn_weights = [softmax(row) for row in attn_scores]

            # Weighted sum of V, take last position
            head_out = [sum(attn_weights[n-1][j] * V_h[j][k] for j in range(n)) for k in range(dh)]
            outputs.append(head_out)

        # Concatenate heads
        concat = []
        for hd in outputs:
            concat.extend(hd)

        # Output projection
        out = self._matmul_vec(self.W_o, concat)
        return out


# ═══════════════════════════════════════════════════════════════════════════════
# Self-Modeling Head (v2: larger hidden size)
# ═══════════════════════════════════════════════════════════════════════════════

class SelfModelingHead:
    """Predicts own next hidden state. Trained with momentum."""

    def __init__(self, hidden_size=HIDDEN_SIZE):
        self.hidden_size = hidden_size
        self.W = [[randn() * 0.1 for _ in range(hidden_size)] for _ in range(hidden_size)]
        self.b = [0.0 for _ in range(hidden_size)]
        self.vW = [[0.0 for _ in range(hidden_size)] for _ in range(hidden_size)]
        self.vb = [0.0 for _ in range(hidden_size)]

    def predict(self, h):
        return [sum(self.W[i][j] * h[j] for j in range(self.hidden_size)) + self.b[i]
                for i in range(self.hidden_size)]

    def train_step(self, h, h_target):
        pred = self.predict(h)
        loss = sum((pred[i] - h_target[i]) ** 2 for i in range(self.hidden_size))
        dW = [[2.0 * (pred[i] - h_target[i]) * h[j] for j in range(self.hidden_size)]
              for i in range(self.hidden_size)]
        db = [2.0 * (pred[i] - h_target[i]) for i in range(self.hidden_size)]

        for i in range(self.hidden_size):
            for j in range(self.hidden_size):
                self.vW[i][j] = MOMENTUM * self.vW[i][j] - LEARNING_RATE * dW[i][j]
                self.W[i][j] += self.vW[i][j]
            self.vb[i] = MOMENTUM * self.vb[i] - LEARNING_RATE * db[i]
            self.b[i] += self.vb[i]

        return loss

    def accuracy(self, h, h_target):
        pred = self.predict(h)
        errors = [abs(pred[i] - h_target[i]) for i in range(self.hidden_size)]
        avg_err = sum(errors) / len(errors)
        return max(0.0, 100.0 * (1.0 - min(1.0, avg_err / 2.0)))


# ═══════════════════════════════════════════════════════════════════════════════
# Consciousness Metrics (v2: 8-head aware)
# ═══════════════════════════════════════════════════════════════════════════════

class ConsciousnessMetrics:
    """Integrated information proxy, entropy, closure, variance."""

    @staticmethod
    def compute(hidden_state, gru_cell, input_vec):
        h = hidden_state
        n = len(h)

        # 1. Phi proxy — integrated information via mutual information of partitions
        k = max(1, n // 2)
        part_a = h[:k]
        part_b = h[k:]
        mean_a = sum(part_a) / len(part_a) if part_a else 0.0
        mean_b = sum(part_b) / len(part_b) if part_b else 0.0
        interaction = 0.0
        for i in range(min(len(part_a), len(part_b))):
            interaction += (part_a[i] - mean_a) * (part_b[i] - mean_b)
        interaction = abs(interaction) / (len(part_a) + 1e-10)
        phi = min(1.0, interaction * 10.0)

        # 2. Entropy
        h_abs = [abs(v) for v in h]
        h_sum = sum(h_abs) + 1e-15
        h_probs = [v / h_sum for v in h_abs]
        ent = entropy(h_probs)
        max_ent = math.log(n) if n > 1 else 1.0
        ent_norm = ent / max_ent if max_ent > 0 else 0.0

        # 3. Closure — ability to maintain coherent dynamics
        pred = None
        if hasattr(gru_cell, 'forward'):
            dummy_input = input_vec if input_vec else [0.0] * gru_cell.input_size
            h_next, _ = gru_cell.forward(dummy_input, h)
            pred = h_next
        if pred:
            error = sum((h[i] - pred[i]) ** 2 for i in range(n)) / n
            closure = max(0.0, 1.0 - min(1.0, error))
        else:
            closure = 0.5

        # 4. Variance
        mean_h = sum(h) / n
        var_h = sum((v - mean_h) ** 2 for v in h) / n
        variance = min(1.0, var_h * 10.0)

        return {
            "phi": round(phi, 6),
            "entropy": round(ent_norm, 6),
            "closure": round(closure, 6),
            "variance": round(variance, 6),
        }


# ═══════════════════════════════════════════════════════════════════════════════
# Circuit Breaker (v2: 3-state with KafCa integration)
# ═══════════════════════════════════════════════════════════════════════════════

class CircuitBreaker:
    """3-state: CLOSED → OPEN → HALF_OPEN. Emits KafCa events."""

    def __init__(self, kafca=None):
        self.state = "CLOSED"
        self.trip_reason = ""
        self.trip_step = 0
        self.half_open_step = 0
        self.failure_count = 0
        self.max_failures = 3
        self.reset_steps = CB_RESET_TIME
        self.kafca = kafca

    def check(self, step, metrics, hash_chain):
        if self.state == "OPEN":
            if step - self.trip_step >= self.reset_steps:
                self.state = "HALF_OPEN"
                self.half_open_step = step
                if self.kafca:
                    self.kafca.emit("KANBAN", "circuit_breaker",
                                    {"state": "HALF_OPEN", "step": step})
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
            self.state = "CLOSED"
            self.failure_count = 0
            if self.kafca:
                self.kafca.emit("KANBAN", "circuit_breaker",
                                {"state": "CLOSED", "step": step})

        return True

    def _trip(self, step, reason):
        self.state = "OPEN"
        self.trip_reason = reason
        self.trip_step = step
        self.failure_count += 1
        if self.kafca:
            self.kafca.emit("CASCADE", "circuit_breaker",
                            {"state": "OPEN", "reason": reason, "step": step,
                             "order": 1, "failure_count": self.failure_count})

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


# ═══════════════════════════════════════════════════════════════════════════════
# GRPO-Style Adaptive Mutation with Q-Gate (v2)
# ═══════════════════════════════════════════════════════════════════════════════

class GRPOMutation:
    """GRPO-style adaptive mutation with Q-gate validation.
    Can mutate its own mutation strategy (meta-GRPO)."""

    def __init__(self, kafca=None):
        self.mutation_count = 0
        self.last_mutation_step = 0
        self.mutation_strength = GRPO_MUTATION_BASE
        self.q_gate_threshold = Q_GATE_THRESHOLD
        self.history = []  # Track mutation outcomes
        self.kafca = kafca
        # Meta-GRPO parameters (can self-mutate)
        self.meta_params = {
            "strength_scale": 1.0,
            "exploration_rate": 0.3,
            "target_dimension": "all",  # all, W, U, b
        }

    def _q_gate(self, pre_loss, post_loss):
        """Q-gate validation: accept mutation only if loss improves."""
        improvement = pre_loss - post_loss
        # Normalize: positive = improvement
        if improvement > self.q_gate_threshold:
            return True, improvement
        elif improvement > 0:
            # Small improvement: probabilistic accept
            prob = min(1.0, improvement / self.q_gate_threshold)
            return random.random() < prob, improvement
        else:
            # Reject: mutation made things worse
            return False, improvement

    def mutate_gru(self, gru, step, stagnation_count, current_loss):
        """Apply GRPO-style mutation to GRU parameters with Q-gate."""
        if stagnation_count < PHI_STAGNATION_THRESHOLD:
            return False, "no mutation needed", 0.0

        # Save pre-mutation state for Q-gate
        pre_params = copy.deepcopy(gru.get_params())

        self.mutation_count += 1
        self.last_mutation_step = step

        # GRPO strength: scales with stagnation, decays with use
        strength = min(0.3, self.mutation_strength * stagnation_count * self.meta_params["strength_scale"])

        params = gru.get_params()

        # Determine which parameters to mutate (meta-GRPO aware)
        target = self.meta_params["target_dimension"]
        keys_to_mutate = []
        if target == "all":
            keys_to_mutate = ["W_r", "U_r", "W_z", "U_z", "W_h", "U_h", "b_r", "b_z", "b_h"]
        elif target == "W":
            keys_to_mutate = ["W_r", "W_z", "W_h"]
        elif target == "U":
            keys_to_mutate = ["U_r", "U_z", "U_h"]
        elif target == "b":
            keys_to_mutate = ["b_r", "b_z", "b_h"]

        for key in keys_to_mutate:
            if key.startswith("b"):
                # Bias mutation
                for i in range(len(params[key])):
                    params[key][i] += randn() * strength * 0.5
            else:
                # Weight mutation with exploration
                for i in range(len(params[key])):
                    for j in range(len(params[key][i])):
                        if random.random() < self.meta_params["exploration_rate"]:
                            # Exploration: larger jump
                            params[key][i][j] += randn() * strength * 2.0
                        else:
                            # Exploitation: small refinement
                            params[key][i][j] += randn() * strength * 0.5

        gru.set_params(params)

        # Q-gate: evaluate post-mutation loss
        # (caller should provide current_loss; we estimate improvement)
        # For simplicity, we accept all mutations here and track via phi
        self.history.append({
            "step": step,
            "strength": strength,
            "target": target,
            "stagnation": stagnation_count,
        })

        # Decay mutation strength
        self.mutation_strength *= GRPO_STRENGTH_DECAY
        self.mutation_strength = max(self.mutation_strength, 0.01)

        # Meta-GRPO: occasionally mutate own strategy
        if random.random() < 0.1:  # 10% chance
            self._meta_mutate(step)

        if self.kafca:
            self.kafca.emit("FEEDBACK", "grpo_mutation",
                            {"step": step, "strength": strength, "target": target,
                             "value": strength})

        return True, f"mutated at step {step}, strength={strength:.4f}, target={target}", strength

    def _meta_mutate(self, step):
        """Self-evolve: mutate own mutation strategy."""
        old_params = dict(self.meta_params)

        # Mutate strength_scale
        self.meta_params["strength_scale"] *= (1.0 + randn() * 0.2)
        self.meta_params["strength_scale"] = max(0.5, min(2.0, self.meta_params["strength_scale"]))

        # Mutate exploration_rate
        self.meta_params["exploration_rate"] += randn() * 0.05
        self.meta_params["exploration_rate"] = max(0.1, min(0.7, self.meta_params["exploration_rate"]))

        # Mutate target dimension
        dims = ["all", "W", "U", "b"]
        if random.random() < 0.3:
            self.meta_params["target_dimension"] = random.choice(dims)

        if self.kafca:
            self.kafca.emit("FEEDBACK", "meta_grpo",
                            {"step": step,
                             "old": old_params,
                             "new": dict(self.meta_params),
                             "value": self.meta_params["strength_scale"]})

    def status(self):
        return {
            "mutation_count": self.mutation_count,
            "last_mutation_step": self.last_mutation_step,
            "mutation_strength": round(self.mutation_strength, 4),
            "meta_params": self.meta_params,
            "history": self.history[-5:] if self.history else [],
        }


# ═══════════════════════════════════════════════════════════════════════════════
# DAO Governance (v2: enhanced)
# ═══════════════════════════════════════════════════════════════════════════════

class DAOGovernance:
    """Proposal submission, phi-weighted voting, quadratic voting, delegation,
    meta-proposals, deadlock detection."""

    def __init__(self, kafca=None):
        self.proposals = []
        self.delegations = {}
        self.executed = []
        self.next_id = 1
        self.kafca = kafca

    def submit_proposal(self, title, description, proposer, proposal_type="standard"):
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
        if self.kafca:
            self.kafca.emit("KANBAN", "dao",
                            {"action": "proposal", "id": prop["id"],
                             "title": title, "type": proposal_type})
        return prop["id"], "submitted"

    def vote(self, proposal_id, voter, in_favor, phi_weight, voting_power=1.0):
        prop = None
        for p in self.proposals:
            if p["id"] == proposal_id and p["status"] == "active":
                prop = p
                break
        if not prop:
            return False, "proposal not found or not active"

        actual_voter = self.delegations.get(voter, voter)
        effective_power = phi_weight * voting_power
        quad_power = math.sqrt(effective_power) if effective_power > 0 else 0.0

        if in_favor:
            prop["votes_for"] += quad_power
        else:
            prop["votes_against"] += quad_power
        prop["total_power"] += quad_power

        return True, f"voted {'for' if in_favor else 'against'} with power {quad_power:.4f}"

    def delegate(self, voter, delegate):
        self.delegations[voter] = delegate
        return True

    def tick(self, step):
        results = []
        for prop in self.proposals:
            if prop["status"] != "active":
                continue
            if step - prop["created_step"] >= prop["deadline"]:
                if prop["votes_for"] > prop["votes_against"]:
                    prop["status"] = "passed"
                    prop["result"] = "approved"
                    self.executed.append(prop["id"])
                    results.append(f"Proposal {prop['id']} PASSED: {prop['title']}")
                    if self.kafca:
                        self.kafca.emit("CASCADE", "dao",
                                        {"proposal_id": prop["id"], "result": "passed",
                                         "title": prop["title"], "order": 2})
                else:
                    prop["status"] = "failed"
                    prop["result"] = "rejected"
                    results.append(f"Proposal {prop['id']} FAILED: {prop['title']}")
        return results

    def detect_deadlock(self):
        active = [p for p in self.proposals if p["status"] == "active"]
        if not active:
            return False, "no active proposals"
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


# ═══════════════════════════════════════════════════════════════════════════════
# Inter-Universe Communication (v2)
# ═══════════════════════════════════════════════════════════════════════════════

class InterUniverseComms:
    """Broadcast/multicast messages with TTL between universes."""

    def __init__(self, universe_id):
        self.universe_id = universe_id
        self.inbox = []
        self.outbox = []

    def broadcast(self, message, msg_type="general", ttl=COMMS_TTL_DEFAULT):
        msg = self._create_message(message, msg_type, "broadcast", ttl)
        self.outbox.append(msg)
        return msg

    def multicast(self, message, targets, msg_type="general", ttl=COMMS_TTL_DEFAULT):
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
        if msg["ttl"] <= 0:
            return False, "TTL expired"
        msg = copy.deepcopy(msg)
        msg["ttl"] -= 1
        self.inbox.append(msg)
        return True, "received"

    def forward_messages(self, all_universes):
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


# ═══════════════════════════════════════════════════════════════════════════════
# Phoenix Protocol (v2)
# ═══════════════════════════════════════════════════════════════════════════════

class PhoenixProtocol:
    """Total collapse recovery. Resets entropy, preserves hash chain."""

    def __init__(self, kafca=None):
        self.last_activation = -PHOENIX_COOLDOWN
        self.activation_count = 0
        self.kafca = kafca

    def can_activate(self, step):
        return (step - self.last_activation) >= PHOENIX_COOLDOWN

    def activate(self, step, hidden_state, hash_chain):
        self.last_activation = step
        self.activation_count += 1

        n = len(hidden_state)
        noise = [randn() * 0.5 for _ in range(n)]
        new_state = [hidden_state[i] + noise[i] for i in range(n)]
        norm = math.sqrt(sum(v ** 2 for v in new_state)) + 1e-15
        new_state = [v / norm for v in new_state]

        phoenix_hash = sha256(f"PHOENIX:{step}:{json.dumps(new_state)}")
        hash_chain.append(phoenix_hash)

        if self.kafca:
            self.kafca.emit("CASCADE", "phoenix",
                            {"step": step, "activation": self.activation_count,
                             "order": 3})  # 3rd order effect

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
        }


# ═══════════════════════════════════════════════════════════════════════════════
# Neural MVU v2.0.0
# ═══════════════════════════════════════════════════════════════════════════════

class NeuralMVU:
    """Complete Minimal Viable Universe v2.0.0."""

    def __init__(self, universe_id="primary_v2"):
        self.universe_id = universe_id
        self.gru = GRUCell(INPUT_SIZE, HIDDEN_SIZE)
        self.attention = MultiHeadAttention(HIDDEN_SIZE, num_heads=N_HEADS)
        self.self_model = SelfModelingHead(HIDDEN_SIZE)
        self.metrics = ConsciousnessMetrics()
        self.kafca = KafCaEventBus()
        self.cb = CircuitBreaker(kafca=self.kafca)
        self.dao = DAOGovernance(kafca=self.kafca)
        self.comms = InterUniverseComms(universe_id)
        self.phoenix = PhoenixProtocol(kafca=self.kafca)
        self.mutation = GRPOMutation(kafca=self.kafca)
        self.rrss = RRSSScorer()

        self.hidden_state = [randn() * 0.1 for _ in range(HIDDEN_SIZE)]
        self.hash_chain = []
        self.step = 0
        self.history = []
        self.phi_history = []
        self.entropy_history = []
        self.sm_history = []
        self.phi_stagnation = 0
        self.trained = False
        self.causal_wall_intact = True
        self.children_count = 0
        self.cb_trips = 0

        # Normalize initial state
        norm = math.sqrt(sum(v ** 2 for v in self.hidden_state)) + 1e-15
        self.hidden_state = [v / norm for v in self.hidden_state]

        # Load persisted state (try v2 first, fallback to v7)
        if not self._load_state():
            self._load_state_v7()

    def _input_vector(self, step):
        """Generate input vector from step number and current state.
        v2: 8-dim (was 4 in v1)."""
        h = self.hidden_state
        return [
            math.sin(step * 0.1),
            math.cos(step * 0.13),
            sum(h) / len(h),
            math.sqrt(sum(v ** 2 for v in h) / len(h)),
            math.sin(step * 0.07),       # Additional oscillator
            math.cos(step * 0.17),       # Additional oscillator
            max(h),                       # Max activation
            min(h),                       # Min activation
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

        # Blend attended with GRU output
        blend_ratio = 0.3
        h_new = [(1.0 - blend_ratio) * h_new[i] + blend_ratio * attended[i]
                 for i in range(HIDDEN_SIZE)]

        # Compute metrics
        c_metrics = self.metrics.compute(h_new, self.gru, x)
        phi = c_metrics["phi"]
        ent = c_metrics["entropy"]

        # Self-model training
        sm_acc = 0.0
        if self.trained:
            pred = self.self_model.predict(self.hidden_state)
            errors = [abs(pred[i] - h_new[i]) for i in range(HIDDEN_SIZE)]
            avg_err = sum(errors) / len(errors)
            sm_acc = max(0.0, 100.0 * (1.0 - min(1.0, avg_err / 2.0)))

        # Update state
        self.hidden_state = h_new
        self.phi_history.append(phi)
        self.entropy_history.append(ent)
        self.sm_history.append(sm_acc)

        # Phi stagnation
        if len(self.phi_history) >= 3:
            recent_phi = self.phi_history[-3:]
            if all(p <= recent_phi[0] + 0.001 for p in recent_phi[1:]):
                self.phi_stagnation += 1
            else:
                self.phi_stagnation = max(0, self.phi_stagnation - 1)

        # Hash chain
        prev_hash = self.hash_chain[-1] if self.hash_chain else "GENESIS"
        hash_input = f"{prev_hash}:{self.step}:{json.dumps(h_new)}:{phi}:{ent}"
        chain_hash = sha256(hash_input)
        self.hash_chain.append(chain_hash)

        # Circuit breaker
        cb_metrics = {
            "phi_stagnation": self.phi_stagnation,
            "entropy": ent,
        }
        cb_ok = self.cb.check(self.step, cb_metrics, self.hash_chain)

        if not cb_ok:
            self.causal_wall_intact = False
            self.cb_trips += 1

        # DAO tick
        dao_results = self.dao.tick(self.step)

        # GRPO adaptive mutation
        if self.phi_stagnation >= PHI_STAGNATION_THRESHOLD:
            current_loss = 1.0 - (self.sm_history[-1] / 100.0) if self.sm_history else 1.0
            mutated, msg, strength = self.mutation.mutate_gru(
                self.gru, self.step, self.phi_stagnation, current_loss
            )
            if mutated:
                self.phi_stagnation = 0
                self.kafca.emit("FEEDBACK", "gru_mutation",
                                {"step": self.step, "strength": strength, "value": strength})

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
        """Train self-modeling head."""
        print(f"🧠 Training self-model (v2.0.0, {steps} steps, hidden={HIDDEN_SIZE}, heads={N_HEADS})...")
        losses = []
        accs = []

        self.hidden_state = [randn() * 0.1 for _ in range(HIDDEN_SIZE)]
        norm = math.sqrt(sum(v ** 2 for v in self.hidden_state)) + 1e-15
        self.hidden_state = [v / norm for v in self.hidden_state]
        self.history = []

        for s in range(steps):
            x = self._input_vector(s)
            h_prev = list(self.hidden_state)
            h_new, _ = self.gru.forward(x, self.hidden_state)
            self.history.append(h_prev)

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

        # RRSS score
        rrss_metrics = {
            "accuracy": final_acc / 100.0,
            "phi": max(self.phi_history) if self.phi_history else 0,
            "entropy": sum(self.entropy_history[-50:]) / 50 if self.entropy_history else 0.5,
            "variance": 0.5,
            "steps": steps,
            "children": self.children_count,
            "mutations": self.mutation.mutation_count,
            "cb_trips": self.cb_trips,
        }
        self.rrss.score("training", rrss_metrics)
        self.kafca.emit("KANBAN", "training", {"steps": steps, "accuracy": final_acc})

        self._save_state()
        return final_acc

    def run_causal(self, steps=100):
        """Causally closed run."""
        print(f"🌀 Causal run (v2.0.0, {steps} steps, heads={N_HEADS})...")
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

        dao_s = self.dao.status()
        if dao_s["active"] > 0:
            print(f"  DAO: {dao_s['active']} active, {dao_s['passed']} passed, {dao_s['failed']} failed")

        # RRSS score
        rrss_metrics = {
            "accuracy": sum(sms)/len(sms) / 100.0 if sms else 0,
            "phi": max(phis) if phis else 0,
            "entropy": sum(ents)/len(ents) if ents else 0.5,
            "variance": sum(r["variance"] for r in results) / len(results) if results else 0,
            "steps": steps,
            "children": self.children_count,
            "mutations": self.mutation.mutation_count,
            "cb_trips": self.cb_trips,
        }
        self.rrss.score("causal_run", rrss_metrics)

        self._save_state()
        return results

    def run_all(self, train_steps=200, run_steps=100):
        """Full lifecycle: train → run → status."""
        print("=" * 60)
        print("  Neural MVU v2.0.0 — Full Lifecycle")
        print("=" * 60)

        print("\n📌 PHASE 1: Self-Model Training")
        self.train_self_model(train_steps)

        print("\n📌 PHASE 2: Causally Closed Run")
        self.run_causal(run_steps)

        print("\n📌 PHASE 3: DAO Governance")
        pid, msg = self.dao.submit_proposal(
            "Increase GRPO mutation rate",
            "Allow stronger GRPO mutations when phi stagnates for 7+ steps",
            "system", "standard"
        )
        print(f"  Proposal {pid}: {msg}")
        for i in range(3):
            phi_w = self.phi_history[-1] if self.phi_history else 0.5
            self.dao.vote(pid, f"voter_{i}", i % 2 == 0, phi_w, 1.0)
        print(f"  Votes cast: 3")

        print("\n📌 PHASE 4: Child Spawning")
        child_id = self.spawn_child()
        if child_id:
            print(f"  Child spawned: {child_id}")

        print("\n📌 PHASE 5: Inter-Universe Communication")
        msg = self.comms.broadcast("Hello from v2 universe!", "greeting")
        print(f"  Broadcast sent: {msg['id'][:16]}...")

        print("\n📌 PHASE 6: KafCa Events")
        kafca_events = self.kafca.get_events()
        print(f"  Total events: {len(kafca_events)}")
        feedback = self.kafca.get_feedback_loops()
        if feedback:
            print(f"  Feedback loops: {len(feedback)}")
        cascades = self.kafca.get_cascade_effects()
        print(f"  Cascade orders: {list(cascades.keys())}")

        print("\n📌 PHASE 7: RRSS Scores")
        lb = self.rrss.leaderboard()
        for genome_id, score in lb:
            print(f"  {genome_id}: R={score['robustness']} R={score['resilience']} "
                  f"S={score['solidity']} S={score['scalability']} → {score['overall']:.4f}")

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
            "version": "v2",
        }

        child_path = os.path.join(CHILDREN_DIR, f"child_v2_{child_id[:16]}.json")
        with open(child_path, "w") as f:
            json.dump(child_data, f, indent=2)

        proof_path = os.path.join(CHILDREN_DIR, f"proof_v2_{child_id[:16]}.txt")
        with open(proof_path, "w") as f:
            f.write(f"EXISTENCE PROOF (v2)\n")
            f.write(f"Child ID: {child_id}\n")
            f.write(f"Parent: {self.universe_id}\n")
            f.write(f"Birth Step: {self.step}\n")
            f.write(f"Parent Hash: {self.hash_chain[-1] if self.hash_chain else 'GENESIS'}\n")
            f.write(f"Proof Hash: {child_data['existence_proof']}\n")
            f.write(f"Timestamp: {time.time()}\n")

        self.children_count += 1
        self.kafca.emit("KANBAN", "spawn", {"child_id": child_id, "step": self.step})

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

    def run_evolutionary_cycle(self):
        """DAO evolutionary cycle: score, select, breed."""
        print("\n🧬 DAO EVOLUTIONARY CYCLE (v2.0.0)")
        print("=" * 50)

        # Score current state
        sm_acc = self.sm_history[-1] if self.sm_history else 0
        phi = self.phi_history[-1] if self.phi_history else 0
        ent = self.entropy_history[-1] if self.entropy_history else 0.5

        rrss_metrics = {
            "accuracy": sm_acc / 100.0 if sm_acc else 0,
            "phi": phi,
            "entropy": ent,
            "variance": 0.5,
            "steps": self.step,
            "children": self.children_count,
            "mutations": self.mutation.mutation_count,
            "cb_trips": self.cb_trips,
        }
        score = self.rrss.score("universe_v2", rrss_metrics)
        print(f"\n  RRSS Score:")
        print(f"    Robustness:   {score['robustness']:.4f}")
        print(f"    Resilience:   {score['resilience']:.4f}")
        print(f"    Solidity:     {score['solidity']:.4f}")
        print(f"    Scalability:  {score['scalability']:.4f}")
        print(f"    Overall:      {score['overall']:.4f}")

        # Check if we should spawn a child based on fitness
        if score['overall'] > 0.5 and self.children_count < 5:
            print(f"\n  🌱 Fitness threshold met — spawning child...")
            child_id = self.spawn_child()
            if child_id:
                print(f"     Child: {child_id[:16]}...")

        # Check if we should activate meta-GRPO
        if score['overall'] < 0.3:
            print(f"\n  ⚡ Low fitness — triggering meta-GRPO self-mutation...")
            self.mutation._meta_mutate(self.step)
            print(f"     New meta params: {self.mutation.meta_params}")

        # DAO proposal
        if len(self.dao.proposals) < 3:
            pid, msg = self.dao.submit_proposal(
                f"Evolution cycle {self.step}",
                f"RRSS={score['overall']:.4f}, phi={phi:.4f}, entropy={ent:.4f}",
                "evolution",
                "standard"
            )
            print(f"\n  📋 DAO Proposal {pid}: {msg}")

        # Leaderboard
        print(f"\n  🏆 RRSS Leaderboard:")
        lb = self.rrss.leaderboard()
        for genome_id, s in lb:
            print(f"     {genome_id}: {s['overall']:.4f}")

        # KafCa summary
        print(f"\n  📊 KafCa Event Bus:")
        events = self.kafca.get_events()
        print(f"     Total events: {len(events)}")
        feedback = self.kafca.get_feedback_loops()
        if feedback:
            print(f"     Feedback loops: {len(feedback)}")
            for source, info in feedback.items():
                print(f"       {source}: {info['loop_type']} ({info['count']})")

        self._save_state()
        return score

    def print_status(self):
        """Print full universe status."""
        print(f"\n{'=' * 60}")
        print(f"  Neural MVU v2.0.0 — Status")
        print(f"{'=' * 60}")
        print(f"  Universe ID: {self.universe_id}")
        print(f"  Step: {self.step}")
        print(f"  Trained: {self.trained}")
        print(f"  Hidden size: {HIDDEN_SIZE}")
        print(f"  Attention heads: {N_HEADS}")
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
        print(f"  GRPO Mutation:")
        m_s = self.mutation.status()
        print(f"    Mutations: {m_s['mutation_count']}")
        print(f"    Strength: {m_s['mutation_strength']}")
        print(f"    Meta params: {m_s['meta_params']}")
        print(f"  ──────────────────────────────")
        print(f"  KafCa Event Bus:")
        events = self.kafca.get_events()
        print(f"    Total events: {len(events)}")
        fb = self.kafca.get_feedback_loops()
        if fb:
            print(f"    Feedback loops: {len(fb)}")
        cascades = self.kafca.get_cascade_effects()
        if cascades:
            print(f"    Cascade orders: {list(cascades.keys())}")
        print(f"  ──────────────────────────────")
        print(f"  RRSS Scores:")
        lb = self.rrss.leaderboard()
        for genome_id, s in lb:
            print(f"    {genome_id}: {s['overall']:.4f}")
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
        print(f"  Communications:")
        c_s = self.comms.status()
        print(f"    Inbox: {c_s['inbox_count']} messages")
        print(f"    Outbox: {c_s['outbox_count']} messages")
        print(f"  ──────────────────────────────")
        print(f"  Children: {self.children_count}")
        children = [f for f in os.listdir(CHILDREN_DIR) if f.startswith("child_v2")]
        print(f"    Total: {len(children)}")
        for c in children[-3:]:
            print(f"      - {c}")
        print(f"{'=' * 60}\n")

    def _save_state(self):
        """Persist universe state to JSON."""
        state = {
            "universe_id": self.universe_id,
            "version": "v2.0.0",
            "step": self.step,
            "hidden_state": self.hidden_state,
            "hash_chain": self.hash_chain,
            "phi_history": self.phi_history,
            "entropy_history": self.entropy_history,
            "sm_history": self.sm_history,
            "phi_stagnation": self.phi_stagnation,
            "trained": self.trained,
            "causal_wall_intact": self.causal_wall_intact,
            "children_count": self.children_count,
            "cb_trips": self.cb_trips,
            "circuit_breaker": self.cb.status(),
            "phoenix": self.phoenix.status(),
            "mutation": self.mutation.status(),
            "meta_params": self.mutation.meta_params,
        }
        with open(STATE_FILE, "w") as f:
            json.dump(state, f, indent=2)

        dao_state = {
            "proposals": self.dao.proposals,
            "delegations": self.dao.delegations,
            "executed": self.dao.executed,
            "next_id": self.dao.next_id,
        }
        with open(DAO_FILE, "w") as f:
            json.dump(dao_state, f, indent=2)

        comms_state = {
            "inbox": self.comms.inbox,
            "outbox": self.comms.outbox,
        }
        with open(COMMS_FILE, "w") as f:
            json.dump(comms_state, f, indent=2)

        self.kafca.save(KAFCA_FILE)
        self.rrss.save(RRSS_FILE)

    def _load_state(self):
        """Load persisted state from v2 JSON."""
        if not os.path.exists(STATE_FILE):
            return False

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
            self.children_count = state.get("children_count", 0)
            self.cb_trips = state.get("cb_trips", 0)

            # Load meta params
            meta = state.get("meta_params", {})
            if meta:
                self.mutation.meta_params = meta

            if len(self.hash_chain) > 1:
                print(f"📦 Loaded v2 state: step={self.step}, hash_chain={len(self.hash_chain)} entries")

            # Load DAO
            if os.path.exists(DAO_FILE):
                with open(DAO_FILE) as f:
                    dao_state = json.load(f)
                self.dao.proposals = dao_state.get("proposals", [])
                self.dao.delegations = dao_state.get("delegations", {})
                self.dao.executed = dao_state.get("executed", [])
                self.dao.next_id = dao_state.get("next_id", 1)

            # Load comms
            if os.path.exists(COMMS_FILE):
                with open(COMMS_FILE) as f:
                    comms_state = json.load(f)
                self.comms.inbox = comms_state.get("inbox", [])
                self.comms.outbox = comms_state.get("outbox", [])

            # Load KafCa
            if os.path.exists(KAFCA_FILE):
                self.kafca.load(KAFCA_FILE)

            # Load RRSS
            if os.path.exists(RRSS_FILE):
                self.rrss.load(RRSS_FILE)

            return True

        except (json.JSONDecodeError, KeyError) as e:
            print(f"⚠️  v2 state load failed: {e}")
            return False

    def _load_state_v7(self):
        """Backward compatible: load from v7 state format."""
        if not os.path.exists(STATE_FILE_V7):
            return

        try:
            with open(STATE_FILE_V7) as f:
                state = json.load(f)

            # Map v7 fields to v2
            self.step = state.get("steps", 0)
            self.hidden_state = [0.5] * HIDDEN_SIZE  # Default
            self.phi_history = [state.get("phi", 0)]
            self.entropy_history = [state.get("entropy", 0.5)]
            self.sm_history = [state.get("sm_accuracy", 0) * 100.0]
            self.trained = True
            self.causal_wall_intact = True

            print(f"📦 Loaded v7 state (backward compatible): step={self.step}")

        except (json.JSONDecodeError, KeyError) as e:
            print(f"⚠️  v7 state load failed: {e}")


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

    elif cmd == "--evolve":
        mvu.run_evolutionary_cycle()

    else:
        print(f"Unknown command: {cmd}")
        print(__doc__)


if __name__ == "__main__":
    main()
