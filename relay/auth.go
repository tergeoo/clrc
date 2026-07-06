package relay

import (
	"crypto/subtle"
	"encoding/json"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const (
	// loginMaxAttempts is the number of login attempts allowed per IP per window.
	loginMaxAttempts = 10
	loginWindow      = time.Minute
)

type Auth struct {
	jwtSecret     []byte
	adminPassword string
	loginLimiter  *rateLimiter
}

func NewAuth(jwtSecret, adminPassword string) *Auth {
	limiter := newRateLimiter(loginMaxAttempts, loginWindow, time.Now)
	limiter.startCleanup(5 * time.Minute)
	return &Auth{
		jwtSecret:     []byte(jwtSecret),
		adminPassword: adminPassword,
		loginLimiter:  limiter,
	}
}

// clientIP returns the remote host without the port, for rate-limit keying.
// X-Forwarded-For is intentionally NOT trusted (it is client-controlled and
// would let an attacker bypass the limit by rotating the header).
func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

type Claims struct {
	jwt.RegisteredClaims
	Type string `json:"type"` // "access" or "refresh"
}

func (a *Auth) GenerateAccessToken() (string, error) {
	claims := Claims{
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(15 * time.Minute)),
			IssuedAt:  jwt.NewNumericDate(time.Now()),
		},
		Type: "access",
	}
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return token.SignedString(a.jwtSecret)
}

func (a *Auth) GenerateRefreshToken() (string, error) {
	claims := Claims{
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(30 * 24 * time.Hour)),
			IssuedAt:  jwt.NewNumericDate(time.Now()),
		},
		Type: "refresh",
	}
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return token.SignedString(a.jwtSecret)
}

func (a *Auth) ValidateAccessToken(tokenStr string) (*Claims, error) {
	return a.validateToken(tokenStr, "access")
}

func (a *Auth) ValidateRefreshToken(tokenStr string) (*Claims, error) {
	return a.validateToken(tokenStr, "refresh")
}

func (a *Auth) validateToken(tokenStr, expectedType string) (*Claims, error) {
	token, err := jwt.ParseWithClaims(tokenStr, &Claims{}, func(t *jwt.Token) (any, error) {
		if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, jwt.ErrSignatureInvalid
		}
		return a.jwtSecret, nil
	})
	if err != nil {
		return nil, err
	}
	claims, ok := token.Claims.(*Claims)
	if !ok || !token.Valid || claims.Type != expectedType {
		return nil, jwt.ErrTokenInvalidClaims
	}
	return claims, nil
}

// LoginHandler handles POST /auth/login
func (a *Auth) LoginHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	if !a.loginLimiter.allow(clientIP(r)) {
		http.Error(w, "too many attempts", http.StatusTooManyRequests)
		return
	}

	var req struct {
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid body", http.StatusBadRequest)
		return
	}

	// Constant-time compare avoids leaking the password via response timing.
	if subtle.ConstantTimeCompare([]byte(req.Password), []byte(a.adminPassword)) != 1 {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	accessToken, err := a.GenerateAccessToken()
	if err != nil {
		http.Error(w, "token generation failed", http.StatusInternalServerError)
		return
	}

	refreshToken, err := a.GenerateRefreshToken()
	if err != nil {
		http.Error(w, "token generation failed", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"access_token":  accessToken,
		"refresh_token": refreshToken,
	})
}

// RefreshHandler handles POST /auth/refresh
func (a *Auth) RefreshHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	authHeader := r.Header.Get("Authorization")
	if !strings.HasPrefix(authHeader, "Bearer ") {
		http.Error(w, "missing token", http.StatusUnauthorized)
		return
	}
	tokenStr := strings.TrimPrefix(authHeader, "Bearer ")

	if _, err := a.ValidateRefreshToken(tokenStr); err != nil {
		http.Error(w, "invalid refresh token", http.StatusUnauthorized)
		return
	}

	accessToken, err := a.GenerateAccessToken()
	if err != nil {
		http.Error(w, "token generation failed", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"access_token": accessToken,
	})
}
