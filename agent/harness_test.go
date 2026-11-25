package agent

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// writeFile creates path (and its parents) with content.
func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

// harnessFixture builds a harness root and a home with one synced profile
// (rtd), one defined-but-unsynced profile (dats), a template and a profile
// with an invalid name.
func harnessFixture(t *testing.T) (home, root string) {
	t.Helper()
	home = t.TempDir()
	root = filepath.Join(home, "harness")
	writeFile(t, filepath.Join(root, "profiles/rtd/profile.json"),
		`{"description":"RTD","launch_args":["--dangerously-skip-permissions"]}`)
	writeFile(t, filepath.Join(root, "profiles/dats/profile.json"), `{"description":"DATS"}`)
	writeFile(t, filepath.Join(root, "profiles/_template/profile.json"), `{}`)
	writeFile(t, filepath.Join(root, "profiles/Bad_Name/profile.json"), `{}`)
	writeFile(t, filepath.Join(home, ".claude-rtd/.harness-state.json"), `{}`)
	writeFile(t, filepath.Join(home, ".claude-Bad_Name/.harness-state.json"), `{}`)
	return home, root
}

func TestLoadHarnessProfiles(t *testing.T) {
	home, root := harnessFixture(t)
	got := LoadHarnessProfiles(home, root)
	want := []HarnessProfile{{Name: "rtd", Description: "RTD", LaunchArgs: []string{"--dangerously-skip-permissions"}}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("LoadHarnessProfiles() = %+v, want %+v", got, want)
	}
}

func TestLoadHarnessProfilesSkipsBrokenJSON(t *testing.T) {
	home, root := harnessFixture(t)
	writeFile(t, filepath.Join(root, "profiles/broken/profile.json"), `{not json`)
	writeFile(t, filepath.Join(home, ".claude-broken/.harness-state.json"), `{}`)
	got := LoadHarnessProfiles(home, root)
	if len(got) != 1 || got[0].Name != "rtd" {
		t.Errorf("LoadHarnessProfiles() = %+v, want only rtd", got)
	}
}

func TestLoadHarnessProfilesMissingRoot(t *testing.T) {
	if got := LoadHarnessProfiles(t.TempDir(), "/nonexistent/harness"); len(got) != 0 {
		t.Errorf("LoadHarnessProfiles() = %+v, want none", got)
	}
}

func TestHarnessProfileDefined(t *testing.T) {
	_, root := harnessFixture(t)
	for name, want := range map[string]bool{"rtd": true, "dats": true, "nope": false, "_template": false} {
		if got := harnessProfileDefined(root, name); got != want {
			t.Errorf("harnessProfileDefined(%q) = %v, want %v", name, got, want)
		}
	}
}

func TestHarnessRoot(t *testing.T) {
	t.Setenv("HARNESS_ROOT", "")
	if got := harnessRoot("/Users/x"); got != "/Users/x/harness" {
		t.Errorf("default harnessRoot = %q", got)
	}
	t.Setenv("HARNESS_ROOT", "/opt/h")
	if got := harnessRoot("/Users/x"); got != "/opt/h" {
		t.Errorf("HARNESS_ROOT harnessRoot = %q", got)
	}
}

func TestParseEnvFile(t *testing.T) {
	input := "# comment\n" +
		"export A=1\n" +
		"B=\"two words\"\n" +
		"C='x=y'\n" +
		"D=plain=with=eq\n" +
		"\n" +
		"not a var\n" +
		"1BAD=x\n"
	vars, skipped := ParseEnvFile([]byte(input))
	wantVars := []string{"A=1", "B=two words", "C=x=y", "D=plain=with=eq"}
	if !reflect.DeepEqual(vars, wantVars) {
		t.Errorf("vars = %q, want %q", vars, wantVars)
	}
	if !reflect.DeepEqual(skipped, []int{7, 8}) {
		t.Errorf("skipped = %v, want [7 8]", skipped)
	}
}
