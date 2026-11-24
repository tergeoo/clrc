package main

import (
	"log"
	"net/http"
	"os"
	"time"

	relay "github.com/claude-orchestrator/relay"
)

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	jwtSecret := os.Getenv("JWT_SECRET")
	if jwtSecret == "" {
		log.Fatal("JWT_SECRET environment variable is required")
	}
	adminPassword := os.Getenv("ADMIN_PASSWORD")
	if adminPassword == "" {
		log.Fatal("ADMIN_PASSWORD environment variable is required")
	}
	agentSecret := os.Getenv("AGENT_SECRET")
	if agentSecret == "" {
		log.Fatal("AGENT_SECRET environment variable is required")
	}

	hub := relay.NewHub()
	go hub.Run()

	auth := relay.NewAuth(jwtSecret, adminPassword)

	// Optional push: APNS_KEY_FILE, APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC
	// (+ APNS_SANDBOX=1). A broken key disables push, not the relay.
	switch apns, err := relay.NewAPNsFromEnv(); {
	case err != nil:
		log.Printf("Push disabled: %v", err)
	case apns == nil:
		log.Printf("Push disabled: APNS_* not set")
	default:
		hub.SetPush(apns)
		log.Printf("Push enabled")
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	})
	mux.HandleFunc("/auth/login", auth.LoginHandler)
	mux.HandleFunc("/auth/refresh", auth.RefreshHandler)
	mux.HandleFunc("/ws/agent", func(w http.ResponseWriter, r *http.Request) {
		relay.HandleAgentWS(w, r, hub, agentSecret)
	})
	mux.HandleFunc("/ws/client", func(w http.ResponseWriter, r *http.Request) {
		relay.HandleClientWS(w, r, hub, auth)
	})

	server := &http.Server{
		Addr:         ":" + port,
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 0,
		IdleTimeout:  120 * time.Second,
	}

	// Optional native TLS: set both TLS_CERT_FILE and TLS_KEY_FILE to serve
	// https/wss directly (self-hosted with a real cert). Leave them unset when
	// TLS is terminated upstream (Railway/fly.io, Cloudflare Tunnel) or when the
	// relay is only reachable over an encrypted private network (Tailscale).
	certFile := os.Getenv("TLS_CERT_FILE")
	keyFile := os.Getenv("TLS_KEY_FILE")
	if (certFile == "") != (keyFile == "") {
		log.Fatal("TLS_CERT_FILE and TLS_KEY_FILE must be set together")
	}

	if certFile != "" {
		log.Printf("Relay server starting on :%s (TLS)", port)
		if err := server.ListenAndServeTLS(certFile, keyFile); err != nil {
			log.Fatalf("Server error: %v", err)
		}
		return
	}

	log.Printf("Relay server starting on :%s (plaintext — use TLS or a private network if internet-exposed)", port)
	if err := server.ListenAndServe(); err != nil {
		log.Fatalf("Server error: %v", err)
	}
}
