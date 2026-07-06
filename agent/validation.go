package agent

import "regexp"

// uuidV4 matches a lowercase RFC 4122 version-4 UUID — the form the iOS client
// and the agent both generate. Session IDs are used as on-disk filenames, so
// anything else is rejected before use.
var uuidV4 = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

// validSessionID reports whether id is a well-formed lowercase UUID v4.
func validSessionID(id string) bool {
	return uuidV4.MatchString(id)
}
