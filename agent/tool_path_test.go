package agent

import "testing"

func TestWithToolDirs(t *testing.T) {
	tests := []struct {
		name string
		path string
		want string
	}{
		{
			name: "launchd path gets user tool dirs in front",
			path: "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin",
			want: "/Users/u/.local/bin:/Users/u/go/bin:/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin",
		},
		{
			name: "dirs already present are kept in place",
			path: "/opt/homebrew/bin:/Users/u/.local/bin:/usr/bin:/usr/local/bin:/Users/u/go/bin",
			want: "/opt/homebrew/bin:/Users/u/.local/bin:/usr/bin:/usr/local/bin:/Users/u/go/bin:/bin",
		},
		{
			name: "empty path",
			path: "",
			want: "/Users/u/.local/bin:/Users/u/go/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := WithToolDirs(tt.path, "/Users/u"); got != tt.want {
				t.Errorf("WithToolDirs() = %q, want %q", got, tt.want)
			}
		})
	}
}
