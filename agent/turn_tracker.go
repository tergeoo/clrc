package agent

import (
	"encoding/json"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
)

// fileEditTools are the tools whose file_path input counts as a changed file
// in a fallback report.
var fileEditTools = map[string]bool{"Edit": true, "Write": true, "MultiEdit": true}

// filePathRe finds file_path in a tool_use input. A regexp rather than
// json.Unmarshal because the input may already be cut at maxPayloadBytes
// (a large Write), which leaves the JSON unparseable while the path, near
// the start, is intact.
var filePathRe = regexp.MustCompile(`"file_path"\s*:\s*("(?:[^"\\]|\\.)*")`)

// turnTracker turns the per-line event stream into the client contract for
// structured output: it strips the style header and clrc-report blocks from
// assistant text, and inserts a report event right before each turn_end.
// It holds per-turn state, so unlike TranslateLine it is not pure; process
// is safe for concurrent use.
type turnTracker struct {
	cwd          string
	headerPrefix string

	mu   sync.Mutex
	turn turnState
}

// turnState is everything the tracker remembers about the current turn.
type turnState struct {
	firstTextSeen bool
	header        string
	lastText      string
	hasContent    bool
	scan          blockScan
	files         []string
}

func newTurnTracker(cwd, headerPrefix string) *turnTracker {
	return &turnTracker{cwd: cwd, headerPrefix: headerPrefix}
}

// process rewrites one batch of events. Text events may be edited or
// dropped (when nothing visible remains), and each turn_end gains a
// preceding report event when the turn produced any content.
func (t *turnTracker) process(events []ChatEvent) []ChatEvent {
	t.mu.Lock()
	defer t.mu.Unlock()

	out := make([]ChatEvent, 0, len(events)+1)
	for i, e := range events {
		switch e.Kind {
		case EventTurnStart:
			t.turn = turnState{}
		case EventText:
			if !t.observeText(&e) {
				continue
			}
		case EventToolUse:
			t.observeToolUse(e)
		case EventTurnEnd:
			if t.turn.hasContent {
				out = append(out, t.reportEvent(e, errorFollows(events[i+1:])))
			}
			t.turn = turnState{}
		}
		out = append(out, e)
	}
	return out
}

// observeText strips the header (first text of the turn only) and report
// blocks from e.Text in place, and reports whether anything visible is left.
func (t *turnTracker) observeText(e *ChatEvent) bool {
	text := e.Text
	if !t.turn.firstTextSeen {
		t.turn.firstTextSeen = true
		text, t.turn.header = stripHeader(text)
	}
	scan := scanReportBlocks(text)
	if scan.found {
		t.turn.scan = scan
	}
	t.turn.hasContent = true
	visible := tidyText(scan.text)
	if visible == "" {
		return false
	}
	t.turn.lastText = visible
	e.Text = visible
	return true
}

func (t *turnTracker) observeToolUse(e ChatEvent) {
	t.turn.hasContent = true
	if !fileEditTools[e.Name] {
		return
	}
	m := filePathRe.FindStringSubmatch(e.Input)
	if m == nil {
		return
	}
	var path string
	if err := json.Unmarshal([]byte(m[1]), &path); err != nil || path == "" {
		return
	}
	path = t.relPath(path)
	for _, f := range t.turn.files {
		if f == path {
			return
		}
	}
	t.turn.files = append(t.turn.files, path)
}

// relPath makes an absolute path relative to the session's cwd when it lies
// inside it, matching the repo-relative paths the styles ask the model for.
func (t *turnTracker) relPath(p string) string {
	if t.cwd == "" || !filepath.IsAbs(p) {
		return p
	}
	rel, err := filepath.Rel(t.cwd, p)
	if err != nil || rel == ".." || strings.HasPrefix(rel, "../") {
		return p
	}
	return rel
}

// reportEvent builds the report for the turn ending with end.
func (t *turnTracker) reportEvent(end ChatEvent, failed bool) ChatEvent {
	var r TurnReport
	if t.turn.scan.report != nil && !t.turn.scan.malformed {
		r = *t.turn.scan.report
		if len(r.ChangedFiles) == 0 {
			r.ChangedFiles = t.turn.files
		}
	} else {
		r = t.fallback(end, failed)
	}
	r.Header = t.turn.header
	r.ContextOK = r.Header != "" && strings.HasPrefix(r.Header, t.headerPrefix)
	truncated := capReport(&r)
	return ChatEvent{Kind: EventReport, TS: end.TS, Report: &r, Truncated: truncated}
}

// fallback builds a report from what the turn showed when the model wrote no
// usable clrc-report block.
func (t *turnTracker) fallback(end ChatEvent, failed bool) TurnReport {
	text := plainText(reportBlockRe.ReplaceAllString(t.turn.lastText, ""))
	status := ReportDone
	switch {
	case failed:
		status = ReportFailed
	case end.StopReason == "interrupted":
		status = ReportInProgress
	case endsWithQuestion(text):
		status = ReportNeedsInput
	}
	var questions []string
	if status == ReportNeedsInput {
		questions = questionLines(text, fallbackQuestions)
	}
	title := firstMeaningfulLine(text)
	if title == "" {
		title = fallbackTitles[status]
	}
	return TurnReport{
		V:            1,
		Status:       status,
		Title:        title,
		Summary:      collapseSpace(text),
		Questions:    questions,
		NextSteps:    nil,
		ChangedFiles: t.turn.files,
		Source:       ReportFromFallback,
	}
}

var fallbackTitles = map[string]string{
	ReportDone:       "Done",
	ReportNeedsInput: "Waiting for your answer",
	ReportFailed:     "Turn failed",
	ReportInProgress: "Interrupted",
}

// errorFollows reports whether an error event follows a turn_end in the same
// batch, which is how TranslateLine renders a result with is_error.
func errorFollows(rest []ChatEvent) bool {
	for _, e := range rest {
		if e.Kind == EventError {
			return true
		}
	}
	return false
}
