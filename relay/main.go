package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"time"
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

	hub := NewHub()
	go hub.Run()

	auth := NewAuth(jwtSecret, adminPassword)

	mux := http.NewServeMux()

	// Health check for Railway
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	})

	// Auth endpoint
	mux.HandleFunc("/auth/login", auth.LoginHandler)
	mux.HandleFunc("/auth/refresh", auth.RefreshHandler)

	// WebSocket endpoints
	mux.HandleFunc("/ws/agent", func(w http.ResponseWriter, r *http.Request) {
		handleAgentWS(w, r, hub, agentSecret)
	})
	mux.HandleFunc("/ws/client", func(w http.ResponseWriter, r *http.Request) {
		handleClientWS(w, r, hub, auth)
	})

	server := &http.Server{
		Addr:         ":" + port,
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 0, // No timeout for WebSocket connections
		IdleTimeout:  120 * time.Second,
	}

	log.Printf("Relay server starting on :%s", port)
	if err := server.ListenAndServe(); err != nil {
		log.Fatalf("Server error: %v", err)
	}

	_ = context.Background()
}
