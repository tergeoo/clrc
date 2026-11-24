package relay

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const (
	maxPushDevices   = 10
	minPushTokenLen  = 64
	maxPushTokenLen  = 200
	maxPushBodyBytes = 1024
	maxPushQuestions = 3
	apnsTokenTTL     = 50 * time.Minute
	apnsSendTimeout  = 5 * time.Second
	apnsHost         = "https://api.push.apple.com"
	apnsSandboxHost  = "https://api.sandbox.push.apple.com"
)

var errBadPushToken = errors.New("invalid device token")

// PushDevice is one phone that wants notifications for some report statuses.
type PushDevice struct {
	Token   string   `json:"device_token"`
	Sandbox bool     `json:"sandbox"`
	Notify  []string `json:"notify"`
}

// PushRegistry keeps the registered devices in memory (devices register
// again on every connect, so a relay restart only loses them briefly).
type PushRegistry struct {
	mu      sync.Mutex
	devices []PushDevice
}

func NewPushRegistry() *PushRegistry { return &PushRegistry{} }

// Register adds or replaces a device; the oldest is dropped past the cap.
func (r *PushRegistry) Register(d PushDevice) error {
	d.Token = strings.ToLower(strings.TrimSpace(d.Token))
	if len(d.Token) < minPushTokenLen || len(d.Token) > maxPushTokenLen || !isHex(d.Token) {
		return errBadPushToken
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	kept := r.devices[:0]
	for _, existing := range r.devices {
		if existing.Token != d.Token {
			kept = append(kept, existing)
		}
	}
	r.devices = append(kept, d)
	if len(r.devices) > maxPushDevices {
		r.devices = r.devices[len(r.devices)-maxPushDevices:]
	}
	return nil
}

// Remove forgets a token APNs reported as no longer valid.
func (r *PushRegistry) Remove(token string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	kept := r.devices[:0]
	for _, d := range r.devices {
		if d.Token != token {
			kept = append(kept, d)
		}
	}
	r.devices = kept
}

func (r *PushRegistry) Devices() []PushDevice {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]PushDevice(nil), r.devices...)
}

// DevicesFor returns the devices that asked to be notified about status.
func (r *PushRegistry) DevicesFor(status string) []PushDevice {
	var out []PushDevice
	for _, d := range r.Devices() {
		for _, s := range d.Notify {
			if s == status {
				out = append(out, d)
				break
			}
		}
	}
	return out
}

func isHex(s string) bool {
	for _, c := range s {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

// reportPayload is the part of a chat report a push needs.
type reportPayload struct {
	Status    string   `json:"status"`
	Title     string   `json:"title"`
	Summary   string   `json:"summary"`
	Questions []string `json:"questions"`
}

var statusLabels = map[string]string{
	"needs_input": "Ждёт ответа",
	"failed":      "Ошибка",
	"done":        "Готово",
}

// buildReportPush renders the APNs payload for a report: title, summary and
// numbered questions, a category with one action per question (≤ 3).
func buildReportPush(agentID, sessionID string, r reportPayload) ([]byte, string) {
	title := strings.TrimSpace(r.Title)
	if title == "" {
		title = statusLabels[r.Status]
		if title == "" {
			title = "Claude закончил"
		}
	}
	body := strings.TrimSpace(r.Summary)
	questions := r.Questions
	if len(questions) > maxPushQuestions {
		questions = questions[:maxPushQuestions]
	}
	for i, q := range questions {
		body += fmt.Sprintf("\n%d. %s", i+1, q)
	}
	body = capUTF8(strings.TrimSpace(body), maxPushBodyBytes)

	payload, _ := json.Marshal(map[string]any{
		"aps": map[string]any{
			"alert":     map[string]string{"title": title, "body": body},
			"sound":     "default",
			"category":  fmt.Sprintf("CLRC_Q%d", len(questions)),
			"thread-id": sessionID,
		},
		"agent_id":   agentID,
		"session_id": sessionID,
		"status":     r.Status,
	})
	return payload, r.Status
}

// capUTF8 cuts s to at most n bytes without splitting a character.
func capUTF8(s string, n int) string {
	if len(s) <= n {
		return s
	}
	cut := n - len("…")
	for cut > 0 && !utf8RuneStart(s[cut]) {
		cut--
	}
	return s[:cut] + "…"
}

func utf8RuneStart(b byte) bool { return b&0xC0 != 0x80 }

// PushSender delivers one payload to one device.
type PushSender interface {
	Send(ctx context.Context, device PushDevice, payload []byte) error
}

// errPushGone means APNs says the token is no longer valid (HTTP 410).
var errPushGone = errors.New("device token is no longer valid")

// APNs sends pushes with token-based (ES256 JWT) authentication.
type APNs struct {
	key    *ecdsa.PrivateKey
	keyID  string
	teamID string
	topic  string
	host   string
	client *http.Client

	mu       sync.Mutex
	token    string
	issuedAt time.Time
}

// NewAPNsFromEnv reads APNS_KEY_FILE, APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC
// (and APNS_SANDBOX). It returns nil, nil when push is not configured.
func NewAPNsFromEnv() (*APNs, error) {
	keyFile, keyID := os.Getenv("APNS_KEY_FILE"), os.Getenv("APNS_KEY_ID")
	teamID, topic := os.Getenv("APNS_TEAM_ID"), os.Getenv("APNS_TOPIC")
	if keyFile == "" || keyID == "" || teamID == "" || topic == "" {
		return nil, nil
	}
	pemBytes, err := os.ReadFile(keyFile)
	if err != nil {
		return nil, fmt.Errorf("read APNs key: %w", err)
	}
	block, _ := pem.Decode(pemBytes)
	if block == nil {
		return nil, errors.New("APNs key is not PEM")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("parse APNs key: %w", err)
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New("APNs key is not an EC key")
	}
	host := apnsHost
	if os.Getenv("APNS_SANDBOX") == "1" {
		host = apnsSandboxHost
	}
	return &APNs{key: key, keyID: keyID, teamID: teamID, topic: topic, host: host,
		client: &http.Client{Timeout: apnsSendTimeout}}, nil
}

// bearer returns the provider token, re-signed when older than apnsTokenTTL.
func (a *APNs) bearer() (string, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.token != "" && time.Since(a.issuedAt) < apnsTokenTTL {
		return a.token, nil
	}
	now := time.Now()
	t := jwt.NewWithClaims(jwt.SigningMethodES256, jwt.MapClaims{"iss": a.teamID, "iat": now.Unix()})
	t.Header["kid"] = a.keyID
	signed, err := t.SignedString(a.key)
	if err != nil {
		return "", fmt.Errorf("sign APNs token: %w", err)
	}
	a.token, a.issuedAt = signed, now
	return signed, nil
}

func (a *APNs) Send(ctx context.Context, device PushDevice, payload []byte) error {
	bearer, err := a.bearer()
	if err != nil {
		return err
	}
	host := a.host
	if device.Sandbox {
		host = apnsSandboxHost
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, host+"/3/device/"+device.Token, bytes.NewReader(payload))
	if err != nil {
		return fmt.Errorf("build APNs request: %w", err)
	}
	req.Header.Set("authorization", "bearer "+bearer)
	req.Header.Set("apns-topic", a.topic)
	req.Header.Set("apns-push-type", "alert")
	resp, err := a.client.Do(req)
	if err != nil {
		return fmt.Errorf("send APNs push: %w", err)
	}
	defer resp.Body.Close()
	switch {
	case resp.StatusCode == http.StatusOK:
		return nil
	case resp.StatusCode == http.StatusGone:
		return errPushGone
	default:
		var reason struct {
			Reason string `json:"reason"`
		}
		json.NewDecoder(resp.Body).Decode(&reason)
		return fmt.Errorf("APNs %d: %s", resp.StatusCode, reason.Reason)
	}
}

// pushReport sends a report push to every device that wants its status.
func pushReport(sender PushSender, registry *PushRegistry, agentID, sessionID string, report reportPayload) {
	payload, status := buildReportPush(agentID, sessionID, report)
	for _, device := range registry.DevicesFor(status) {
		go func(d PushDevice) {
			ctx, cancel := context.WithTimeout(context.Background(), apnsSendTimeout)
			defer cancel()
			if err := sender.Send(ctx, d, payload); err != nil {
				if errors.Is(err, errPushGone) {
					registry.Remove(d.Token)
				}
				log.Printf("push to %s…: %v", d.Token[:8], err)
			}
		}(device)
	}
}
