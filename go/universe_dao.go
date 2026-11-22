// Universe DAO Engine v0.6.0 — Go port
// Evolutionary Governance + Inter-Universe Communication
// Safe, secure, scalable deployment model
//
// Build: CGO_ENABLED=0 go build -ldflags="-s -w" -o universe-dao .
// Deploy: flyctl deploy (or standalone binary)

package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math"
	"math/rand"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ─── Configuration ───────────────────────────────────────────────────────────

var (
	BASE_DIR        = getEnv("UNIVERSE_BASE_DIR", "/data/universe")
	HIDDEN_SIZE     = 32
	N_HEADS         = 8
	LEARNING_RATE   = 0.015
	MUTATION_PCT    = 0.23
	PHI_THRESHOLD   = 0.3
	COMMS_TTL       = 3600
	VOTING_PERIOD   = 50
	QUORUM          = 0.50
	PASS_THRESHOLD  = 0.60
	QUADRATIC       = true
	PHI_WEIGHTED    = true
	DELEGATION      = true
	DEADLOCK_TIMEOUT = 100
	LEARNING_RATE_DECAY = 0.995
)

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" { return v }
	return fallback
}

// ─── Data Types ──────────────────────────────────────────────────────────────

type UniverseState struct {
	Name             string  `json:"name"`
	Hash             string  `json:"hash"`
	Created          int64   `json:"created"`
	Steps            int     `json:"steps"`
	HiddenSize       int     `json:"hidden_size"`
	NHeads           int     `json:"n_heads"`
	ClosureScore     float64 `json:"closure_score"`
	Entropy          float64 `json:"entropy"`
	Phi              float64 `json:"phi"`
	SMAccuracy       float64 `json:"sm_accuracy"`
	Variance         float64 `json:"variance"`
	CommsReceived    int     `json:"comms_received"`
	CommsSent        int     `json:"comms_sent"`
	LastComms        int64   `json:"last_comms_broadcast"`
	Parent           string  `json:"parent"`
}

type Proposal struct {
	ID               string  `json:"id"`
	Proposer         string  `json:"proposer"`
	Type             string  `json:"type"`
	Params           string  `json:"params"`
	Timestamp        int64   `json:"timestamp"`
	VotingEnd        int64   `json:"voting_end"`
	Status           string  `json:"status"` // active, passed, rejected
	VotesFor         float64 `json:"votes_for"`
	VotesAgainst     float64 `json:"votes_against"`
	VotingWeightTotal float64 `json:"voting_weight_total"`
	PhiWeighted      bool    `json:"phi_weighted"`
	IsMeta           bool    `json:"is_meta"`
	Reason           string  `json:"reason,omitempty"`
}

type CommsMessage struct {
	ID          string `json:"id"`
	From        string `json:"from"`
	To          string `json:"to"`
	PayloadHash string `json:"payload_hash"`
	Message     string `json:"message"`
	Timestamp   int64  `json:"timestamp"`
	TTL         int64  `json:"ttl"`
	Signature   string `json:"signature"`
	Status      string `json:"status"`
}

type Treasury struct {
	AFRIBalance    float64       `json:"afri_balance"`
	TotalDeposited float64       `json:"total_deposited"`
	TotalWithdrawn float64       `json:"total_withdrawn"`
	Transactions   []TreasuryTx  `json:"transactions"`
}

type TreasuryTx struct {
	Amount   float64 `json:"amount"`
	From     string  `json:"from"`
	Type     string  `json:"type"`
	Ts       int64   `json:"ts"`
}

type Delegation struct {
	Voter string `json:"voter"`
	To    string `json:"to"`
}

type DAOParams struct {
	MutationRate   float64 `json:"mutation_rate"`
	LearningRate   float64 `json:"learning_rate"`
	SelectionMethod string `json:"selection_method"`
	FitnessAlpha   float64 `json:"fitness_alpha"`
	FitnessBeta    float64 `json:"fitness_beta"`
	FitnessGamma   float64 `json:"fitness_gamma"`
	FitnessDelta   float64 `json:"fitness_delta"`
}

type DAOState struct {
	Version        string              `json:"version"`
	Created        int64               `json:"created"`
	VotingPeriod   int                 `json:"voting_period"`
	Quorum         float64             `json:"quorum"`
	PassThreshold  float64             `json:"pass_threshold"`
	PhiWeighted    bool                `json:"phi_weighted"`
	Delegation     bool                `json:"delegation_enabled"`
	DeadlockTimeout int                `json:"deadlock_timeout"`
	ProposalCount  int                 `json:"proposal_count"`
	PassedCount    int                 `json:"passed_count"`
	RejectedCount  int                 `json:"rejected_count"`
	Delegations    map[string]string   `json:"delegations"`
	Treasury       Treasury            `json:"treasury"`
	Parameters     DAOParams           `json:"parameters"`
	PhoenixActive  bool                `json:"phoenix_activated"`
	LastPhoenix    *int64              `json:"last_phoenix"`
	CommsCount     int                 `json:"comms_count"`
}

type AuditEntry struct {
	Ts      int64  `json:"ts"`
	Action  string `json:"action"`
	Universe string `json:"universe"`
	Details string `json:"details"`
	Hash    string `json:"hash"`
}

// ─── Engine ──────────────────────────────────────────────────────────────────

type UniverseDAO struct {
	mu         sync.RWMutex
	state      DAOState
	parent     *UniverseState
	children   map[string]*UniverseState
	proposals  map[string]*Proposal
	comms      map[string]*CommsMessage
	audit      []AuditEntry
	auditNext  int
}

func NewUniverseDAO() *UniverseDAO {
	e := &UniverseDAO{
		children:  make(map[string]*UniverseState),
		proposals: make(map[string]*Proposal),
		comms:     make(map[string]*CommsMessage),
		audit:     make([]AuditEntry, 0),
	}
	e.loadState()
	return e
}

// ─── Persistence ─────────────────────────────────────────────────────────────

func (e *UniverseDAO) loadState() {
	os.MkdirAll(BASE_DIR, 0700)
	os.MkdirAll(filepath.Join(BASE_DIR, "children"), 0700)
	os.MkdirAll(filepath.Join(BASE_DIR, "proposals"), 0700)
	os.MkdirAll(filepath.Join(BASE_DIR, "comms"), 0700)

	// Load DAO state
	e.loadJSON("dao_state.json", &e.state)
	if e.state.Version == "" {
		e.state = DAOState{
			Version: "0.6.0",
			Created: time.Now().Unix(),
			VotingPeriod: VOTING_PERIOD,
			Quorum: QUORUM,
			PassThreshold: PASS_THRESHOLD,
			PhiWeighted: PHI_WEIGHTED,
			Delegation: DELEGATION,
			DeadlockTimeout: DEADLOCK_TIMEOUT,
			Delegations: make(map[string]string),
			Treasury: Treasury{
				Transactions: make([]TreasuryTx, 0),
			},
			Parameters: DAOParams{
				MutationRate: 0.02,
				LearningRate: 0.01,
				SelectionMethod: "tournament",
				FitnessAlpha: 0.40,
				FitnessBeta: 0.30,
				FitnessGamma: 0.20,
				FitnessDelta: 0.10,
			},
			PhoenixActive: true,
		}
		e.saveState()
	}

	// Load parent state
	e.loadJSON("universe_state.json", &e.parent)
	if e.parent == nil {
		e.parent = &UniverseState{
			Name:       "parent",
			Hash:       e.hashString("genesis_" + time.Now().String()),
			Created:    time.Now().Unix(),
			HiddenSize: HIDDEN_SIZE,
			NHeads:     N_HEADS,
		}
		e.saveJSON("universe_state.json", e.parent)
	}

	// Load children
	childrenDir := filepath.Join(BASE_DIR, "children")
	entries, _ := os.ReadDir(childrenDir)
	for _, entry := range entries {
		if strings.HasSuffix(entry.Name(), "_state.json") {
			var child UniverseState
			data, _ := os.ReadFile(filepath.Join(childrenDir, entry.Name()))
			json.Unmarshal(data, &child)
			e.children[child.Hash] = &child
		}
	}

	// Load proposals
	propDir := filepath.Join(BASE_DIR, "proposals")
	propEntries, _ := os.ReadDir(propDir)
	for _, entry := range propEntries {
		if strings.HasSuffix(entry.Name(), ".json") {
			var prop Proposal
			data, _ := os.ReadFile(filepath.Join(propDir, entry.Name()))
			json.Unmarshal(data, &prop)
			e.proposals[prop.ID] = &prop
		}
	}

	// Load comms
	commsDir := filepath.Join(BASE_DIR, "comms")
	commsEntries, _ := os.ReadDir(commsDir)
	for _, entry := range commsEntries {
		if strings.HasSuffix(entry.Name(), ".json") {
			var msg CommsMessage
			data, _ := os.ReadFile(filepath.Join(commsDir, entry.Name()))
			json.Unmarshal(data, &msg)
			// Check TTL
			if time.Now().Unix()-msg.Timestamp < msg.TTL {
				e.comms[msg.ID] = &msg
			}
		}
	}
}

func (e *UniverseDAO) saveState() {
	e.saveJSON("dao_state.json", &e.state)
	e.saveJSON("universe_state.json", e.parent)
}

func (e *UniverseDAO) loadJSON(name string, v interface{}) {
	data, err := os.ReadFile(filepath.Join(BASE_DIR, name))
	if err != nil { return }
	json.Unmarshal(data, v)
}

func (e *UniverseDAO) saveJSON(name string, v interface{}) {
	data, _ := json.MarshalIndent(v, "", "  ")
	tmp := filepath.Join(BASE_DIR, name + ".tmp")
	os.WriteFile(tmp, data, 0600)
	os.Rename(tmp, filepath.Join(BASE_DIR, name))
}

func (e *UniverseDAO) hashString(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:16])
}

// ─── Audit ───────────────────────────────────────────────────────────────────

func (e *UniverseDAO) auditLog(action, universe, details string) {
	entry := AuditEntry{
		Ts:       time.Now().Unix(),
		Action:   action,
		Universe: universe,
		Details:  details,
	}
	hashInput := fmt.Sprintf("%d|%s|%s|%s|%d", entry.Ts, action, universe, details, len(e.audit))
	entry.Hash = e.hashString(hashInput)
	e.audit = append(e.audit, entry)
	if len(e.audit) > 10000 { e.audit = e.audit[len(e.audit)-5000:] }
	e.saveJSON("audit.json", e.audit)
}

// ─── 8-Head Attention ────────────────────────────────────────────────────────

func attention8Head(h float64, step int, commsSignal float64) float64 {
	// Head 1: Positional
	h1 := math.Sin(float64(step)/10.0) * h * 0.8

	// Head 2: Content
	h2 := h * 1.0

	// Head 3: Novelty
	h3 := (1 - math.Cos(float64(step)/20.0)) * h * 0.6

	// Head 4: Self
	h4 := h*0.5 + 0.1*(1-h)

	// Head 5: Temporal
	windowFactor := math.Sin(float64(step)*0.3)*0.5 + 0.5
	h5 := windowFactor * h * 0.7

	// Head 6: Relational
	relFactor := math.Cos(float64(step)*0.15)*0.5 + 0.5
	h6 := relFactor * (1 - h) * 0.9

	// Head 7: Meta-Cognitive
	metaAvg := (h1 + h2 + h3 + h4 + h5 + h6) / 6.0
	metaVar := math.Pow(h1-metaAvg, 2) + math.Pow(h2-metaAvg, 2) + math.Pow(h3-metaAvg, 2) +
		math.Pow(h4-metaAvg, 2) + math.Pow(h5-metaAvg, 2) + math.Pow(h6-metaAvg, 2)
	h7 := metaVar * 2.0

	// Head 8: Cross-Universe
	h8 := commsSignal * 0.1 * 2.0

	// Weighted sum
	return (1.0*h1 + 1.0*h2 + 0.8*h3 + 0.9*h4 + 1.1*h5 + 1.1*h6 + 1.2*h7 + 1.3*h8) / 8.4
}

// ─── Sigmoid ─────────────────────────────────────────────────────────────────

func sigmoid(x float64) float64 {
	return 1.0 / (1.0 + math.Exp(-x))
}

func tanh(x float64) float64 {
	return math.Tanh(x)
}

// ─── Compute Phi ─────────────────────────────────────────────────────────────

func computePhi(smAcc, entropy, variance, crossSignal float64) float64 {
	basePhi := variance * entropy * smAcc
	crossBonus := crossSignal * 0.15
	return basePhi + crossBonus
}

// ─── Train Universe ──────────────────────────────────────────────────────────

func (e *UniverseDAO) Train(steps int) *UniverseState {
	e.mu.Lock()
	defer e.mu.Unlock()

	p := e.parent
	hidden := p.ClosureScore
	if hidden <= 0 { hidden = 0.5 }

	var momentum float64
	var bestLoss = 1.0
	var variance float64
	var prevHidden = hidden
	var lr = LEARNING_RATE
	var stagnationCounter int
	var totalComms int

	for step := 1; step <= steps; step++ {
		// Read comms
		var commsSignal float64
		for _, msg := range e.comms {
			if msg.To == p.Hash || msg.To == "broadcast" {
				sig := float64(len(msg.Message)) / 100.0 * 0.1
				commsSignal += sig
				totalComms++
			}
		}

		// 8-head attention
		attended := attention8Head(hidden, step, commsSignal)

		// GRU update
		resetGate := sigmoid(attended * 1.5)
		updateGate := sigmoid(attended * 2.0)
		candidate := tanh(attended*0.8 + resetGate*hidden*0.2)
		newHidden := (1-updateGate)*hidden + updateGate*candidate

		// Self-model prediction
		prediction := sigmoid(newHidden*1.2 + momentum*0.3)
		target := sigmoid(newHidden*1.5 + 0.1*math.Sin(float64(step)*0.1))
		loss := math.Pow(prediction-target, 2)

		// Momentum update
		grad := 2 * (prediction - target) * (1 - math.Pow(prediction, 2))
		momentum = 0.9*momentum + lr*grad
		hidden = newHidden

		// Track variance
		variance = variance*0.9 + math.Pow(hidden-prevHidden, 2)*0.1
		prevHidden = hidden

		if loss < bestLoss { bestLoss = loss }

		// Stagnation detection
		if math.Abs(prevHidden-hidden) < 0.01 {
			stagnationCounter++
			if stagnationCounter >= 20 {
				lr = math.Min(lr*2.0, 0.1)
				stagnationCounter = 0
			}
		} else {
			stagnationCounter = 0
		}

		lr = math.Max(lr*LEARNING_RATE_DECAY, 0.001)

		// Broadcast periodically
		if step%10 == 0 {
			msg := fmt.Sprintf("mv_state:%.4f:phi:%.4f", hidden, variance*2.0)
			e.broadcastInternal(p.Hash, msg)
		}
	}

	smAcc := 1.0 - bestLoss
	if smAcc < 0 { smAcc = 0 }

	entropy := -(hidden*math.Log(hidden+1e-10) + (1-hidden)*math.Log(1-hidden+1e-10)) / 2.6667
	if entropy < 0 { entropy = 0 }

	var commsSignal float64
	for _, msg := range e.comms {
		if msg.To == p.Hash || msg.To == "broadcast" {
			commsSignal += float64(len(msg.Message)) / 100.0 * 0.1
		}
	}

	phi := computePhi(smAcc, entropy, variance, commsSignal)

	// Update parent state
	newHash := e.hashString(fmt.Sprintf("%s %f %f %f %d", p.Hash, bestLoss, hidden, phi, time.Now().Unix()))
	p.Hash = newHash
	p.ClosureScore = hidden
	p.Entropy = entropy
	p.Phi = phi
	p.SMAccuracy = smAcc
	p.Variance = variance
	p.Steps += steps
	p.CommsReceived += totalComms

	e.saveState()
	e.auditLog("train", p.Name, fmt.Sprintf("steps=%d sm=%.4f entropy=%.4f phi=%.4f", steps, smAcc, entropy, phi))

	return p
}

// ─── Run Causally Closed ─────────────────────────────────────────────────────

func (e *UniverseDAO) Run(steps int) *UniverseState {
	e.mu.Lock()
	defer e.mu.Unlock()

	p := e.parent
	hidden := p.ClosureScore
	variance := p.Variance
	commsRx := p.CommsReceived
	commsTx := p.CommsSent
	chainHash := p.Hash
	prevHidden := hidden
	var smError float64

	for step := 1; step <= steps; step++ {
		noise := (rand.Float64()*2 - 1) * 0.1

		var commsSignal float64
		var commsCount int
		for _, msg := range e.comms {
			if (msg.To == p.Hash || msg.To == "broadcast") && time.Now().Unix()-msg.Timestamp < msg.TTL {
				commsSignal += float64(len(msg.Message)) / 100.0 * 0.1
				commsCount++
			}
		}
		if commsCount > 0 { commsRx += commsCount }

		attended := attention8Head(hidden, step, commsSignal)

		resetGate := sigmoid(attended*1.5 + noise)
		updateGate := sigmoid(attended*2.0 + noise*0.5)
		candidate := tanh(attended*0.8 + noise*2.0 + resetGate*hidden*0.2)
		newHidden := (1-updateGate)*hidden + updateGate*candidate

		prediction := sigmoid(newHidden * 1.2)
		target := sigmoid(newHidden*1.5 + 0.05*math.Sin(float64(step)*0.2))
		smError = math.Pow(prediction-target, 2)

		chainHash = e.hashString(fmt.Sprintf("%s %f %f %f %f", chainHash, newHidden, smError, noise, commsSignal))

		variance = variance*0.9 + math.Pow(newHidden-prevHidden, 2)*0.1
		prevHidden = newHidden

		if step%10 == 0 {
			msg := fmt.Sprintf("mv_state:%.4f:phi:%.4f", newHidden, variance*2.0)
			e.broadcastInternal(p.Hash, msg)
			commsTx++
		}

		hidden = newHidden
	}

	entropy := -(hidden*math.Log(hidden+1e-10) + (1-hidden)*math.Log(1-hidden+1e-10)) / 2.6667
	if entropy < 0 { entropy = 0 }

	var finalCommsSignal float64
	for _, msg := range e.comms {
		if msg.To == p.Hash || msg.To == "broadcast" {
			finalCommsSignal += float64(len(msg.Message)) / 100.0 * 0.1
		}
	}

	finalPhi := computePhi(1.0-smError/float64(steps), entropy, variance, finalCommsSignal)

	p.Hash = chainHash
	p.ClosureScore = hidden
	p.Entropy = entropy
	p.Phi = finalPhi
	p.SMAccuracy = 1.0 - smError/float64(steps)
	p.Variance = variance
	p.Steps += steps
	p.CommsReceived = commsRx
	p.CommsSent = commsTx
	p.LastComms = time.Now().Unix()

	e.saveState()
	e.auditLog("run", p.Name, fmt.Sprintf("steps=%d phi=%.4f entropy=%.4f", steps, finalPhi, entropy))

	return p
}

// ─── Spawn Child ─────────────────────────────────────────────────────────────

func (e *UniverseDAO) Spawn() *UniverseState {
	e.mu.Lock()
	defer e.mu.Unlock()

	p := e.parent
	ts := time.Now().Unix()
	mutation := MUTATION_PCT * (rand.Float64()*2 - 1)
	childClosure := p.ClosureScore * (1 + mutation)
	if childClosure > 1 { childClosure = 1 }
	if childClosure < 0 { childClosure = 0 }

	childHash := e.hashString(fmt.Sprintf("%s %d %f", p.Hash, ts, childClosure))

	child := &UniverseState{
		Name:         fmt.Sprintf("child_%d", ts),
		Hash:         childHash,
		Created:      ts,
		HiddenSize:   HIDDEN_SIZE,
		NHeads:       N_HEADS,
		ClosureScore: childClosure,
		Entropy:      p.Entropy,
		Parent:       p.Hash,
	}

	e.children[childHash] = child
	e.saveJSON(filepath.Join("children", childHash+"_state.json"), child)

	// Broadcast spawn
	e.broadcastInternal(childHash, fmt.Sprintf("spawned:parent=%s:closure=%.4f", p.Hash, childClosure))

	e.auditLog("spawn", child.Name, fmt.Sprintf("hash=%s parent=%s mutation=%.4f", childHash, p.Hash, mutation))

	return child
}

// ─── Proposals ───────────────────────────────────────────────────────────────

func (e *UniverseDAO) SubmitProposal(propType, params, proposer string) (*Proposal, error) {
	e.mu.Lock()
	defer e.mu.Unlock()

	validTypes := map[string]bool{
		"mutation_rate": true, "learning_rate": true, "selection_method": true,
		"fitness_alpha": true, "fitness_beta": true, "fitness_gamma": true,
		"fitness_delta": true, "kill_orphan": true, "phoenix_trigger": true,
		"delegation": true, "meta_proposal": true, "treasury_allocation": true,
		"comms_protocol": true,
	}
	if !validTypes[propType] {
		return nil, fmt.Errorf("invalid proposal type: %s", propType)
	}

	id := e.hashString(fmt.Sprintf("%s %s %s %d", proposer, propType, params, time.Now().Unix()))

	prop := &Proposal{
		ID:        id,
		Proposer:  proposer,
		Type:      propType,
		Params:    params,
		Timestamp: time.Now().Unix(),
		VotingEnd: time.Now().Unix() + int64(VOTING_PERIOD*10),
		Status:    "active",
		PhiWeighted: PHI_WEIGHTED,
		IsMeta:    propType == "meta_proposal",
	}

	e.proposals[id] = prop
	e.saveJSON(filepath.Join("proposals", id+".json"), prop)
	e.state.ProposalCount++
	e.saveState()

	e.auditLog("proposal_submit", proposer, fmt.Sprintf("type=%s params=%s id=%s", propType, params, id))

	return prop, nil
}

func (e *UniverseDAO) Vote(proposalID, voter string, choice string) error {
	e.mu.Lock()
	defer e.mu.Unlock()

	prop, ok := e.proposals[proposalID]
	if !ok { return fmt.Errorf("proposal not found: %s", proposalID) }

	if prop.Status != "active" { return fmt.Errorf("proposal not active (status: %s)", prop.Status) }

	// Check expiry with deadlock detection
	if time.Now().Unix() > prop.VotingEnd {
		expiredFor := (time.Now().Unix() - prop.VotingEnd) / 10
		if expiredFor >= int64(DEADLOCK_TIMEOUT) {
			prop.Status = "rejected"
			prop.Reason = "deadlock_timeout"
			e.saveJSON(filepath.Join("proposals", proposalID+".json"), prop)
			e.state.RejectedCount++
			e.saveState()
			e.auditLog("deadlock", voter, fmt.Sprintf("proposal=%s rejected: deadlock timeout", proposalID))
			return fmt.Errorf("proposal rejected by deadlock timeout (%d periods expired)", expiredFor)
		}
		return fmt.Errorf("voting period ended (%.0f periods until deadlock)", float64(DEADLOCK_TIMEOUT)-float64(expiredFor))
	}

	// Get phi weight
	phiWeight := 1.0
	if PHI_WEIGHTED {
		// Check delegation
		if DELEGATION {
			if delegateTo, ok := e.state.Delegations[voter]; ok {
				if child, ok := e.children[delegateTo]; ok {
					phiWeight = child.Phi
					if phiWeight <= 0 { phiWeight = 0.1 }
				}
			}
		}
		if phiWeight == 1.0 {
			phiWeight = e.parent.Phi
			if phiWeight <= 0 { phiWeight = 0.1 }
		}
	}

	voteWeight := phiWeight
	if QUADRATIC {
		voteWeight = math.Sqrt(phiWeight)
	}

	if choice == "for" {
		prop.VotesFor += voteWeight
	} else {
		prop.VotesAgainst += voteWeight
	}
	prop.VotingWeightTotal += voteWeight

	e.saveJSON(filepath.Join("proposals", proposalID+".json"), prop)
	e.auditLog("vote", voter, fmt.Sprintf("proposal=%s choice=%s weight=%.4f", proposalID, choice, voteWeight))

	return nil
}

func (e *UniverseDAO) ExecuteProposal(proposalID string) (string, error) {
	e.mu.Lock()
	defer e.mu.Unlock()

	prop, ok := e.proposals[proposalID]
	if !ok { return "", fmt.Errorf("proposal not found") }
	if prop.Status == "passed" { return "", fmt.Errorf("already executed") }

	// Check quorum
	universeCount := len(e.children) + 1
	quorumNeeded := int(float64(universeCount) * QUORUM)
	voters := int(prop.VotingWeightTotal)
	if voters < quorumNeeded {
		prop.Status = "rejected"
		prop.Reason = "quorum_not_met"
		e.saveJSON(filepath.Join("proposals", proposalID+".json"), prop)
		return "", fmt.Errorf("quorum not met: %d < %d", voters, quorumNeeded)
	}

	// Check pass threshold
	totalVotes := prop.VotesFor + prop.VotesAgainst
	passNeeded := totalVotes * PASS_THRESHOLD
	if prop.VotesFor < passNeeded {
		prop.Status = "rejected"
		prop.Reason = "threshold_not_met"
		e.saveJSON(filepath.Join("proposals", proposalID+".json"), prop)
		return "", fmt.Errorf("threshold not met: %.2f < %.2f", prop.VotesFor, passNeeded)
	}

	prop.Status = "passed"
	var result string

	switch prop.Type {
	case "mutation_rate":
		rate, _ := strconv.ParseFloat(prop.Params, 64)
		e.state.Parameters.MutationRate = rate
		result = fmt.Sprintf("mutation_rate → %.4f", rate)
	case "learning_rate":
		rate, _ := strconv.ParseFloat(prop.Params, 64)
		e.state.Parameters.LearningRate = rate
		result = fmt.Sprintf("learning_rate → %.4f", rate)
	case "phoenix_trigger":
		result = e.executePhoenix()
	case "meta_proposal":
		result = fmt.Sprintf("meta-proposal executed: %s", prop.Params)
	case "treasury_allocation":
		amt, _ := strconv.ParseFloat(prop.Params, 64)
		e.state.Treasury.AFRIBalance += amt
		e.state.Treasury.TotalDeposited += amt
		e.state.Treasury.Transactions = append(e.state.Treasury.Transactions, TreasuryTx{
			Amount: amt, From: "dao_proposal", Type: "proposal", Ts: time.Now().Unix(),
		})
		result = fmt.Sprintf("treasury: +%.2f AFRI", amt)
	default:
		result = fmt.Sprintf("executed: %s → %s", prop.Type, prop.Params)
	}

	e.saveJSON(filepath.Join("proposals", proposalID+".json"), prop)
	e.state.PassedCount++
	e.saveState()
	e.auditLog("proposal_execute", "dao", result)

	return result, nil
}

// ─── Phoenix Protocol ────────────────────────────────────────────────────────

func (e *UniverseDAO) executePhoenix() string {
	// Backup children
	backupDir := filepath.Join(BASE_DIR, "phoenix", fmt.Sprintf("backup_%d", time.Now().Unix()))
	os.MkdirAll(backupDir, 0700)
	for hash, child := range e.children {
		e.saveJSON(filepath.Join("phoenix", fmt.Sprintf("backup_%d", time.Now().Unix()), hash+"_state.json"), child)
	}

	// Clear children
	e.children = make(map[string]*UniverseState)

	// Spawn new child with mutation boost
	mutation := 0.05
	childClosure := e.parent.ClosureScore * (1 + mutation)
	if childClosure > 1 { childClosure = 1 }

	childHash := e.hashString(fmt.Sprintf("phoenix_%d", time.Now().Unix()))
	child := &UniverseState{
		Name:         fmt.Sprintf("phoenix_%d", time.Now().Unix()),
		Hash:         childHash,
		Created:      time.Now().Unix(),
		HiddenSize:   HIDDEN_SIZE,
		NHeads:       N_HEADS,
		ClosureScore: childClosure,
		Entropy:      1.3333,
		Phi:          0.1,
		Parent:       "phoenix",
	}
	e.children[childHash] = child
	e.saveJSON(filepath.Join("children", childHash+"_state.json"), child)

	now := time.Now().Unix()
	e.state.LastPhoenix = &now
	e.saveState()

	e.auditLog("phoenix", "system", fmt.Sprintf("backup=%s child=%s", backupDir, childHash))

	return fmt.Sprintf("Phoenix complete. Child %s spawned from backup %s", childHash, backupDir)
}

// ─── Internal Broadcast ──────────────────────────────────────────────────────

func (e *UniverseDAO) broadcastInternal(from, message string) {
	ts := time.Now().Unix()
	payloadHash := e.hashString(fmt.Sprintf("%s broadcast %s %d", from, message, ts))
	msgID := e.hashString(fmt.Sprintf("%s %d", payloadHash, rand.Int()))

	msg := &CommsMessage{
		ID:          msgID,
		From:        from,
		To:          "broadcast",
		PayloadHash: payloadHash,
		Message:     message,
		Timestamp:   ts,
		TTL:         int64(COMMS_TTL),
		Signature:   payloadHash,
		Status:      "broadcast",
	}

	e.comms[msgID] = msg
	e.saveJSON(filepath.Join("comms", msgID+".json"), msg)
	e.state.CommsCount++
}

// ─── Stats ───────────────────────────────────────────────────────────────────

type DAOStats struct {
	UniverseCount int             `json:"universe_count"`
	ParentPhi     float64         `json:"parent_phi"`
	ParentHash    string          `json:"parent_hash"`
	ChildrenCount int             `json:"children_count"`
	AvgChildPhi   float64         `json:"avg_child_phi"`
	BestChildPhi  float64         `json:"best_child_phi"`
	ProposalCount int             `json:"proposal_count"`
	PassedCount   int             `json:"passed_count"`
	RejectedCount int             `json:"rejected_count"`
	ActiveProposals int           `json:"active_proposals"`
	CommsCount    int             `json:"comms_count"`
	Treasury      float64         `json:"treasury_afri"`
	BreakerState  string          `json:"breaker_state"`
	Parameters    DAOParams       `json:"parameters"`
}

func (e *UniverseDAO) GetStats() DAOStats {
	e.mu.RLock()
	defer e.mu.RUnlock()

	s := DAOStats{
		UniverseCount: 1 + len(e.children),
		ParentPhi:     e.parent.Phi,
		ParentHash:    e.parent.Hash,
		ChildrenCount: len(e.children),
		ProposalCount: e.state.ProposalCount,
		PassedCount:   e.state.PassedCount,
		RejectedCount: e.state.RejectedCount,
		CommsCount:    len(e.comms),
		Treasury:      e.state.Treasury.AFRIBalance,
		BreakerState:  "CLOSED",
		Parameters:    e.state.Parameters,
	}

	var totalPhi float64
	for _, child := range e.children {
		totalPhi += child.Phi
		if child.Phi > s.BestChildPhi { s.BestChildPhi = child.Phi }
	}
	if len(e.children) > 0 { s.AvgChildPhi = totalPhi / float64(len(e.children)) }

	for _, prop := range e.proposals {
		if prop.Status == "active" { s.ActiveProposals++ }
	}

	return s
}

// ─── Deadlock Detection & Cleanup ────────────────────────────────────────────

func (e *UniverseDAO) DetectDeadlocks() []string {
	e.mu.Lock()
	defer e.mu.Unlock()

	var deadlocks []string
	now := time.Now().Unix()

	for id, prop := range e.proposals {
		if prop.Status != "active" { continue }

		// Check if voting period has expired
		if now > prop.VotingEnd {
			expiredFor := (now - prop.VotingEnd) / 10 // in "voting periods"
			if expiredFor >= int64(DEADLOCK_TIMEOUT) {
				// Deadlock: proposal has been expired for too long without resolution
				prop.Status = "rejected"
				prop.Reason = "deadlock_timeout"
				e.saveJSON(filepath.Join("proposals", id+".json"), prop)
				e.state.RejectedCount++
				e.saveState()
				deadlocks = append(deadlocks, fmt.Sprintf("proposal %s (%s) rejected: deadlock timeout", id[:12], prop.Type))
				e.auditLog("deadlock", "dao", fmt.Sprintf("proposal=%s type=%s expired=%d periods", id, prop.Type, expiredFor))
			}
		}
	}

	// Check for governance deadlock: too many rejected proposals in a row
	if e.state.RejectedCount > e.state.PassedCount+3 && e.state.RejectedCount > 5 {
		deadlocks = append(deadlocks, fmt.Sprintf("governance deadlock: %d rejected vs %d passed", e.state.RejectedCount, e.state.PassedCount))
		e.auditLog("deadlock", "dao", fmt.Sprintf("governance_deadlock rejected=%d passed=%d", e.state.RejectedCount, e.state.PassedCount))
	}

	// Clean stale comms messages
	for id, msg := range e.comms {
		if now > msg.Timestamp+msg.TTL {
			delete(e.comms, id)
		}
	}

	return deadlocks
}

// ─── HTTP API ────────────────────────────────────────────────────────────────

func (e *UniverseDAO) ServeHTTP(addr string) {
	mux := http.NewServeMux()

	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"status": "ok", "version": "0.6.0"})
	})

	mux.HandleFunc("/status", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(e.GetStats())
	})

	mux.HandleFunc("/parent", func(w http.ResponseWriter, r *http.Request) {
		e.mu.RLock()
		defer e.mu.RUnlock()
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(e.parent)
	})

	mux.HandleFunc("/children", func(w http.ResponseWriter, r *http.Request) {
		e.mu.RLock()
		defer e.mu.RUnlock()
		var children []*UniverseState
		for _, c := range e.children { children = append(children, c) }
		sort.Slice(children, func(i, j int) bool { return children[i].Phi > children[j].Phi })
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(children)
	})

	mux.HandleFunc("/train", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" { http.Error(w, "POST required", 405); return }
		steps := 100
		if s := r.URL.Query().Get("steps"); s != "" {
			if v, err := strconv.Atoi(s); err == nil { steps = v }
		}
		result := e.Train(steps)
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(result)
	})

	mux.HandleFunc("/run", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" { http.Error(w, "POST required", 405); return }
		steps := 50
		if s := r.URL.Query().Get("steps"); s != "" {
			if v, err := strconv.Atoi(s); err == nil { steps = v }
		}
		result := e.Run(steps)
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(result)
	})

	mux.HandleFunc("/spawn", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" { http.Error(w, "POST required", 405); return }
		child := e.Spawn()
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(child)
	})

	mux.HandleFunc("/proposal/submit", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" { http.Error(w, "POST required", 405); return }
		body, _ := io.ReadAll(r.Body)
		var req struct {
			Type     string `json:"type"`
			Params   string `json:"params"`
			Proposer string `json:"proposer"`
		}
		json.Unmarshal(body, &req)
		prop, err := e.SubmitProposal(req.Type, req.Params, req.Proposer)
		if err != nil { http.Error(w, err.Error(), 400); return }
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(prop)
	})

	mux.HandleFunc("/proposal/list", func(w http.ResponseWriter, r *http.Request) {
		e.mu.RLock()
		defer e.mu.RUnlock()
		var props []*Proposal
		for _, p := range e.proposals { props = append(props, p) }
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(props)
	})

	mux.HandleFunc("/vote", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" { http.Error(w, "POST required", 405); return }
		body, _ := io.ReadAll(r.Body)
		var req struct {
			ProposalID string `json:"proposal_id"`
			Voter      string `json:"voter"`
			Choice     string `json:"choice"`
		}
		json.Unmarshal(body, &req)
		err := e.Vote(req.ProposalID, req.Voter, req.Choice)
		if err != nil { http.Error(w, err.Error(), 400); return }
		json.NewEncoder(w).Encode(map[string]string{"status": "voted"})
	})

	mux.HandleFunc("/comms/send", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" { http.Error(w, "POST required", 405); return }
		body, _ := io.ReadAll(r.Body)
		var req struct {
			From    string `json:"from"`
			To      string `json:"to"`
			Message string `json:"message"`
		}
		json.Unmarshal(body, &req)
		e.mu.Lock()
		e.broadcastInternal(req.From, req.Message)
		e.mu.Unlock()
		json.NewEncoder(w).Encode(map[string]string{"status": "sent"})
	})

	mux.HandleFunc("/comms/inbox", func(w http.ResponseWriter, r *http.Request) {
		e.mu.RLock()
		defer e.mu.RUnlock()
		var msgs []*CommsMessage
		universe := r.URL.Query().Get("universe")
		for _, msg := range e.comms {
			if universe == "" || msg.To == universe || msg.To == "broadcast" || msg.From == universe {
				msgs = append(msgs, msg)
			}
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(msgs)
	})

	mux.HandleFunc("/treasury", func(w http.ResponseWriter, r *http.Request) {
		e.mu.RLock()
		defer e.mu.RUnlock()
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(e.state.Treasury)
	})

	mux.HandleFunc("/audit", func(w http.ResponseWriter, r *http.Request) {
		e.mu.RLock()
		defer e.mu.RUnlock()
		n := len(e.audit)
		start := n - 100
		if start < 0 { start = 0 }
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(e.audit[start:])
	})

	mux.HandleFunc("/phoenix", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" { http.Error(w, "POST required", 405); return }
		result := e.executePhoenix()
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"result": result})
	})

	mux.HandleFunc("/deadlock", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" { http.Error(w, "POST required", 405); return }
		deadlocks := e.DetectDeadlocks()
		w.Header().Set("Content-Type", "application/json")
		if len(deadlocks) > 0 {
			json.NewEncoder(w).Encode(map[string]interface{}{"deadlocks": deadlocks, "count": len(deadlocks)})
		} else {
			json.NewEncoder(w).Encode(map[string]string{"status": "no deadlocks"})
		}
	})

	fmt.Printf("Universe DAO Engine v0.6.0 listening on %s\n", addr)
	log.Fatal(http.ListenAndServe(addr, mux))
}

// ─── Main ────────────────────────────────────────────────────────────────────

func main() {
	port := os.Getenv("PORT")
	if port == "" { port = "8081" }

	engine := NewUniverseDAO()
	stats := engine.GetStats()

	fmt.Printf("Universe DAO Engine v0.6.0 — Evolutionary Governance\n")
	fmt.Printf("Base dir: %s\n", BASE_DIR)
	fmt.Printf("Universes: %d (parent + %d children)\n", stats.UniverseCount, stats.ChildrenCount)
	fmt.Printf("Parent phi: %.4f\n", stats.ParentPhi)
	fmt.Printf("Attention heads: %d\n", N_HEADS)
	fmt.Printf("Proposals: %d active, %d passed, %d rejected\n",
		stats.ActiveProposals, stats.PassedCount, stats.RejectedCount)
	fmt.Printf("Comms messages: %d\n", stats.CommsCount)
	fmt.Printf("Treasury: %.2f AFRI\n", stats.Treasury)

	engine.ServeHTTP(":" + port)
}
