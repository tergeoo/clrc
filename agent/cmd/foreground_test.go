package main

import (
	"os"
	"strings"
	"testing"
)

// `clrc` with no arguments runs an agent in the foreground. While the daemon
// is running that would register a second connection with the same agent ID;
// when the foreground one exits the Mac disappears from the iPhone.
func TestForegroundRunRefusedWhileDaemonRuns(t *testing.T) {
	tests := []struct {
		name    string
		pid     int // written to the pid file; 0 = no pid file
		wantErr bool
	}{
		{name: "no daemon", pid: 0, wantErr: false},
		{name: "stale pid file", pid: 999999, wantErr: false},
		{name: "daemon running", pid: -1, wantErr: true}, // -1 = this test process
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Setenv("HOME", t.TempDir())
			t.Setenv("XDG_CONFIG_HOME", "")
			pid := tt.pid
			if pid == -1 {
				pid = os.Getpid()
			}
			if pid != 0 {
				writePID(pid)
			}
			err := checkNoDaemon()
			if (err != nil) != tt.wantErr {
				t.Fatalf("checkNoDaemon() = %v, wantErr %v", err, tt.wantErr)
			}
			if err != nil && !strings.Contains(err.Error(), "clrc restart") {
				t.Errorf("error %q should point to clrc restart", err)
			}
		})
	}
}
