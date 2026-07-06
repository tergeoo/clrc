package relay

import "regexp"

// Security limits. These are deliberate — see CLAUDE.md. Do not remove.
const (
	// maxMessageBytes caps a single WebSocket message. It is large enough for
	// fs_read results (100 KB file → ~137 KB base64) and terminal pastes, while
	// bounding memory an authenticated peer can force per message.
	maxMessageBytes = 4 << 20 // 4 MB

	maxAgents       = 50
	maxClients      = 20
	maxAgentIDLen   = 64
	maxAgentNameLen = 128
)

// uuidV4 matches a lowercase RFC 4122 version-4 UUID, exactly the form produced
// by the iOS client (`UUID().uuidString.lowercased()`) and the agent
// (`github.com/google/uuid` `New().String()`).
var uuidV4 = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

// validSessionID reports whether id is a well-formed lowercase UUID v4.
// Session IDs are used as map keys and (on the agent) as on-disk filenames,
// so anything else is rejected before use.
func validSessionID(id string) bool {
	return uuidV4.MatchString(id)
}

// validAgentID reports whether id is a well-formed lowercase UUID v4.
func validAgentID(id string) bool {
	return uuidV4.MatchString(id)
}
