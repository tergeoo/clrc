package relay

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"nhooyr.io/websocket"
)

const goodToken = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90"

func TestPushRegisterValidation(t *testing.T) {
	r := NewPushRegistry()
	if err := r.Register(PushDevice{Token: "not-hex!", Notify: []string{"done"}}); err == nil {
		t.Error("non-hex token accepted")
	}
	if err := r.Register(PushDevice{Token: "abcd", Notify: []string{"done"}}); err == nil {
		t.Error("short token accepted")
	}
	for i := 0; i < maxPushDevices+3; i++ {
		tok := strings.Repeat("0", 60) + strings.Repeat("f", 0) + hexByte(i)
		if err := r.Register(PushDevice{Token: tok, Notify: []string{"done"}}); err != nil {
			t.Fatalf("register %d: %v", i, err)
		}
	}
	devices := r.Devices()
	if len(devices) != maxPushDevices {
		t.Fatalf("devices = %d, want %d", len(devices), maxPushDevices)
	}
	if devices[len(devices)-1].Token != strings.Repeat("0", 60)+hexByte(maxPushDevices+2) {
		t.Error("newest device not kept")
	}
	// Re-registering replaces, not duplicates.
	r.Register(PushDevice{Token: devices[0].Token, Notify: nil})
	if len(r.Devices()) != maxPushDevices {
		t.Error("re-register duplicated the device")
	}
}

func hexByte(i int) string {
	const digits = "0123456789abcdef"
	return string([]byte{digits[(i>>4)&0xf], digits[i&0xf], 'a', 'b'})
}

func TestPushFilterByStatus(t *testing.T) {
	r := NewPushRegistry()
	r.Register(PushDevice{Token: goodToken, Notify: []string{"needs_input", "failed"}})
	other := strings.Repeat("b", 64)
	r.Register(PushDevice{Token: other, Notify: []string{"done"}})
	got := r.DevicesFor("failed")
	if len(got) != 1 || got[0].Token != goodToken {
		t.Errorf("failed → %+v", got)
	}
	if len(r.DevicesFor("unknown")) != 0 {
		t.Error("unknown status should notify nobody")
	}
}

func TestBuildReportPush(t *testing.T) {
	payload, status := buildReportPush("agent-1", "sess-1", reportPayload{
		Status: "needs_input", Title: "Миграция", Summary: "Запустить?",
		Questions: []string{"Запусти", "Покажи SQL", "Отмена", "Ещё"},
	})
	if status != "needs_input" {
		t.Fatalf("status = %q", status)
	}
	var p map[string]any
	if err := json.Unmarshal(payload, &p); err != nil {
		t.Fatal(err)
	}
	aps := p["aps"].(map[string]any)
	alert := aps["alert"].(map[string]any)
	if alert["title"] != "Миграция" || !strings.Contains(alert["body"].(string), "1. Запусти") {
		t.Errorf("alert = %+v", alert)
	}
	if aps["category"] != "CLRC_Q3" || aps["thread-id"] != "sess-1" || aps["sound"] != "default" {
		t.Errorf("aps = %+v", aps)
	}
	if p["agent_id"] != "agent-1" || p["session_id"] != "sess-1" || p["status"] != "needs_input" {
		t.Errorf("custom keys = %+v", p)
	}

	long, _ := buildReportPush("a", "s", reportPayload{Status: "done", Summary: strings.Repeat("я", 2000)})
	json.Unmarshal(long, &p)
	body := p["aps"].(map[string]any)["alert"].(map[string]any)["body"].(string)
	if len(body) > maxPushBodyBytes {
		t.Errorf("body not capped: %d", len(body))
	}
	if title := p["aps"].(map[string]any)["alert"].(map[string]any)["title"]; title != "Готово" {
		t.Errorf("empty title should fall back to the status label, got %v", title)
	}
}

func TestNewAPNsFromEnvDisabled(t *testing.T) {
	for _, k := range []string{"APNS_KEY_FILE", "APNS_KEY_ID", "APNS_TEAM_ID", "APNS_TOPIC"} {
		t.Setenv(k, "")
	}
	a, err := NewAPNsFromEnv()
	if a != nil || err != nil {
		t.Fatalf("unconfigured: %v %v", a, err)
	}
	dir := t.TempDir()
	bad := filepath.Join(dir, "key.p8")
	os.WriteFile(bad, []byte("not a key"), 0o600)
	t.Setenv("APNS_KEY_FILE", bad)
	t.Setenv("APNS_KEY_ID", "KEY123")
	t.Setenv("APNS_TEAM_ID", "TEAM123")
	t.Setenv("APNS_TOPIC", "gtg.app")
	if a, err := NewAPNsFromEnv(); a != nil || err == nil {
		t.Fatal("malformed key must be an error")
	}
}

func TestAPNsJWT(t *testing.T) {
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	der, _ := x509.MarshalPKCS8PrivateKey(key)
	path := filepath.Join(t.TempDir(), "AuthKey.p8")
	os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), 0o600)
	t.Setenv("APNS_KEY_FILE", path)
	t.Setenv("APNS_KEY_ID", "KEY123")
	t.Setenv("APNS_TEAM_ID", "TEAM123")
	t.Setenv("APNS_TOPIC", "gtg.app")
	t.Setenv("APNS_SANDBOX", "1")
	a, err := NewAPNsFromEnv()
	if err != nil || a == nil {
		t.Fatalf("NewAPNsFromEnv: %v", err)
	}
	if !strings.Contains(a.host, "sandbox") {
		t.Errorf("host = %s", a.host)
	}
	signed, err := a.bearer()
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := jwt.Parse(signed, func(*jwt.Token) (any, error) { return &key.PublicKey, nil })
	if err != nil || !parsed.Valid {
		t.Fatalf("jwt invalid: %v", err)
	}
	if parsed.Header["kid"] != "KEY123" || parsed.Header["alg"] != "ES256" {
		t.Errorf("header = %+v", parsed.Header)
	}
	claims := parsed.Claims.(jwt.MapClaims)
	if claims["iss"] != "TEAM123" || claims["iat"] == nil {
		t.Errorf("claims = %+v", claims)
	}
	again, _ := a.bearer()
	if again != signed {
		t.Error("token should be cached")
	}
}

type capturedPush struct {
	device  PushDevice
	payload []byte
}

type fakeSender struct {
	mu   sync.Mutex
	sent []capturedPush
}

func (f *fakeSender) Send(_ context.Context, d PushDevice, p []byte) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.sent = append(f.sent, capturedPush{d, p})
	return nil
}

func (f *fakeSender) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.sent)
}

func TestReportEventTriggersPush(t *testing.T) {
	hub, agent, client := connectPairWithHub(t)
	sender := &fakeSender{}
	hub.SetPush(sender)
	writeMsg(t, client, "push_register", map[string]any{
		"device_token": goodToken, "sandbox": true, "notify": []string{"needs_input"},
	})
	// Registration is processed in order with the next frames; give the hub a beat via a round trip.
	writeMsg(t, client, "list_sessions", map[string]any{"agent_id": testAgentID, "request_id": "sync"})
	readUntil(t, agent, "list_sessions")

	writeMsg(t, agent, "chat_event", map[string]any{
		"session_id": testSessionID,
		"event": map[string]any{"kind": "report", "seq": 5, "report": map[string]any{
			"status": "needs_input", "title": "Вопрос", "summary": "s", "questions": []string{"a"},
		}},
	})
	writeMsg(t, agent, "chat_event", map[string]any{
		"session_id": testSessionID,
		"event":      map[string]any{"kind": "report", "seq": 6, "report": map[string]any{"status": "done"}},
	})
	writeMsg(t, agent, "chat_event", map[string]any{
		"session_id": testSessionID, "event": map[string]any{"kind": "text", "seq": 7, "text": "hi"},
	})

	deadline := time.Now().Add(2 * time.Second)
	for sender.count() < 1 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	time.Sleep(100 * time.Millisecond)
	if sender.count() != 1 {
		t.Fatalf("pushes = %d, want 1 (only needs_input)", sender.count())
	}
	var p map[string]any
	json.Unmarshal(sender.sent[0].payload, &p)
	if p["session_id"] != testSessionID || p["agent_id"] != testAgentID || !sender.sent[0].device.Sandbox {
		t.Errorf("push = %+v device = %+v", p, sender.sent[0].device)
	}
}

// connectPairWithHub is connectPair that also returns the relay's hub.
func connectPairWithHub(t *testing.T) (*Hub, *websocket.Conn, *websocket.Conn) {
	t.Helper()
	hub, auth, base := newTestRelay(t)
	agent := dial(t, base+"/ws/agent")
	writeMsg(t, agent, "register", map[string]any{"agent_id": testAgentID, "name": "test-mac", "secret": testAgentSecret})
	token, err := auth.GenerateAccessToken()
	if err != nil {
		t.Fatalf("mint token: %v", err)
	}
	client := dial(t, base+"/ws/client")
	writeMsg(t, client, "auth", map[string]any{"token": token})
	time.Sleep(100 * time.Millisecond)
	return hub, agent, client
}
