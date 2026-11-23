package agent

import (
	"encoding/json"
	"regexp"
	"strings"
	"unicode"
)

// Turn report limits. Title and summary follow the clrc output styles; the
// list caps keep one report event comfortably under maxPayloadBytes.
const (
	reportTitleRunes   = 60
	reportSummaryRunes = 200
	reportItemRunes    = 200
	reportMaxItems     = 10
	fallbackQuestions  = 5
)

// Turn report statuses, as defined by the clrc-chat / clrc-brief styles.
const (
	ReportDone       = "done"
	ReportNeedsInput = "needs_input"
	ReportFailed     = "failed"
	ReportInProgress = "in_progress"
)

// Report sources: parsed from the model's clrc-report block, or built by the
// agent when the block is missing or malformed.
const (
	ReportFromBlock    = "block"
	ReportFromFallback = "fallback"
)

// TurnReport is the structured summary of one finished turn. It is carried
// by an event of kind "report", published right before the turn's turn_end.
// List fields are always non-nil so clients get [] rather than null.
type TurnReport struct {
	V            int      `json:"v"`
	Status       string   `json:"status"`
	Title        string   `json:"title"`
	Summary      string   `json:"summary"`
	Questions    []string `json:"questions"`
	NextSteps    []string `json:"next_steps"`
	ChangedFiles []string `json:"changed_files"`
	Header       string   `json:"header"`
	ContextOK    bool     `json:"context_ok"`
	Source       string   `json:"source"`
}

// reportBlockRe matches a ```clrc-report fenced block. An unterminated block
// running to the end of the text is accepted too, so a reply cut off before
// the closing fence still yields its JSON.
var reportBlockRe = regexp.MustCompile("(?s)```clrc-report[ \\t]*\\r?\\n(.*?)(?:```|\\z)")

// headerLineRe matches the style's context header, e.g. "**tergeo · personal**".
var headerLineRe = regexp.MustCompile(`^\*\*([^*]+)\*\*$`)

// blockScan is the outcome of scanning one text for report blocks.
type blockScan struct {
	text      string      // text with every well-formed block removed
	found     bool        // at least one block was present
	report    *TurnReport // the last block, parsed; nil if it was malformed
	malformed bool        // the last block failed to parse
}

// scanReportBlocks finds clrc-report blocks in text. The last block wins.
// Well-formed blocks are removed from the visible text; a malformed block is
// left in place so the user still sees what the model wrote.
func scanReportBlocks(text string) blockScan {
	matches := reportBlockRe.FindAllStringSubmatchIndex(text, -1)
	if len(matches) == 0 {
		return blockScan{text: text}
	}
	var b strings.Builder
	prev := 0
	var last *TurnReport
	lastMalformed := false
	for _, m := range matches {
		body := text[m[2]:m[3]]
		parsed, ok := parseReportJSON(body)
		last, lastMalformed = parsed, !ok
		if !ok {
			continue
		}
		b.WriteString(text[prev:m[0]])
		prev = m[1]
	}
	b.WriteString(text[prev:])
	return blockScan{
		text:      tidyText(b.String()),
		found:     true,
		report:    last,
		malformed: lastMalformed,
	}
}

// parseReportJSON decodes a block body into a normalised report. Unknown
// fields are ignored; a body that is not a JSON object is malformed.
func parseReportJSON(body string) (*TurnReport, bool) {
	var raw struct {
		V            int      `json:"v"`
		Status       string   `json:"status"`
		Title        string   `json:"title"`
		Summary      string   `json:"summary"`
		Questions    []string `json:"questions"`
		NextSteps    []string `json:"next_steps"`
		ChangedFiles []string `json:"changed_files"`
	}
	if err := json.Unmarshal([]byte(strings.TrimSpace(body)), &raw); err != nil {
		return nil, false
	}
	r := &TurnReport{
		V:            raw.V,
		Status:       raw.Status,
		Title:        raw.Title,
		Summary:      raw.Summary,
		Questions:    raw.Questions,
		NextSteps:    raw.NextSteps,
		ChangedFiles: raw.ChangedFiles,
		Source:       ReportFromBlock,
	}
	if r.V == 0 {
		r.V = 1
	}
	if !validStatus(r.Status) {
		r.Status = ReportDone
	}
	return r, true
}

func validStatus(s string) bool {
	switch s {
	case ReportDone, ReportNeedsInput, ReportFailed, ReportInProgress:
		return true
	}
	return false
}

// stripHeader removes the style's header line when it is the first non-empty
// line of text, returning the remaining text and the header's inner text.
func stripHeader(text string) (string, string) {
	lines := strings.Split(text, "\n")
	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}
		m := headerLineRe.FindStringSubmatch(trimmed)
		if m == nil {
			return text, ""
		}
		return tidyText(strings.Join(lines[i+1:], "\n")), strings.TrimSpace(m[1])
	}
	return text, ""
}

// tidyText trims leading and trailing blank space left by removals.
func tidyText(s string) string {
	return strings.TrimSpace(s)
}

// truncateWords caps s at max runes, cutting at a word boundary when one is
// reasonably close and marking the cut with an ellipsis. It never splits a
// multi-byte rune.
func truncateWords(s string, max int) (string, bool) {
	r := []rune(s)
	if len(r) <= max {
		return s, false
	}
	cut := r[:max-1]
	if i := lastSpace(cut); i > max/2 {
		cut = cut[:i]
	}
	return strings.TrimRightFunc(string(cut), func(c rune) bool {
		return unicode.IsSpace(c) || strings.ContainsRune(",;:-", c)
	}) + "…", true
}

func lastSpace(r []rune) int {
	for i := len(r) - 1; i >= 0; i-- {
		if unicode.IsSpace(r[i]) {
			return i
		}
	}
	return -1
}

// collapseSpace joins all whitespace runs into single spaces.
func collapseSpace(s string) string {
	return strings.Join(strings.Fields(s), " ")
}

// markdownLead strips list markers, heading hashes, quotes and emphasis that
// would look odd in a plain-text title.
var markdownLead = regexp.MustCompile(`^(?:[#>*\-+]+\s*|\d+[.)]\s+)+`)

func plainLine(line string) string {
	line = markdownLead.ReplaceAllString(strings.TrimSpace(line), "")
	line = strings.NewReplacer("**", "", "__", "", "`", "").Replace(line)
	return strings.TrimSpace(line)
}

// firstMeaningfulLine returns the first line with a letter or digit, outside
// fenced code, as plain text.
func firstMeaningfulLine(text string) string {
	inFence := false
	for _, line := range strings.Split(text, "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), "```") {
			inFence = !inFence
			continue
		}
		if inFence {
			continue
		}
		if p := plainLine(line); strings.IndexFunc(p, isAlnum) >= 0 {
			return p
		}
	}
	return ""
}

// plainText strips markdown markers line by line and drops fenced code, for
// fallback titles and summaries.
func plainText(text string) string {
	var lines []string
	inFence := false
	for _, line := range strings.Split(text, "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), "```") {
			inFence = !inFence
			continue
		}
		if !inFence {
			lines = append(lines, plainLine(line))
		}
	}
	return strings.TrimSpace(strings.Join(lines, "\n"))
}

func isAlnum(r rune) bool { return unicode.IsLetter(r) || unicode.IsDigit(r) }

// endsWithQuestion reports whether text's last visible character is a
// question mark (ASCII or full-width).
func endsWithQuestion(text string) bool {
	t := strings.TrimRightFunc(text, func(r rune) bool {
		return unicode.IsSpace(r) || r == '*' || r == '_' || r == '`'
	})
	return strings.HasSuffix(t, "?") || strings.HasSuffix(t, "？")
}

// questionLines collects lines that end with a question mark, as plain text.
func questionLines(text string, limit int) []string {
	var out []string
	for _, line := range strings.Split(text, "\n") {
		if !endsWithQuestion(line) {
			continue
		}
		if p := plainLine(line); p != "" {
			out = append(out, p)
		}
		if len(out) == limit {
			break
		}
	}
	return out
}

// capReport enforces the title/summary/list limits in place on a report the
// caller owns, reporting whether anything was cut.
func capReport(r *TurnReport) bool {
	cut := false
	var c bool
	r.Title, c = truncateWords(collapseSpace(r.Title), reportTitleRunes)
	cut = cut || c
	r.Summary, c = truncateWords(collapseSpace(r.Summary), reportSummaryRunes)
	cut = cut || c
	for _, list := range []*[]string{&r.Questions, &r.NextSteps, &r.ChangedFiles} {
		*list, c = capList(*list)
		cut = cut || c
	}
	shrunk := shrinkToBudget(r)
	return cut || shrunk
}

func capList(in []string) ([]string, bool) {
	out := make([]string, 0, len(in))
	cut := len(in) > reportMaxItems
	for _, item := range in {
		if len(out) == reportMaxItems {
			break
		}
		item = collapseSpace(item)
		if item == "" {
			continue
		}
		short, c := truncateWords(item, reportItemRunes)
		cut = cut || c
		out = append(out, short)
	}
	return out, cut
}

// shrinkToBudget drops list tails until the encoded report fits within
// maxPayloadBytes, the same cap tool payloads get.
func shrinkToBudget(r *TurnReport) bool {
	cut := false
	for reportSize(r) > maxPayloadBytes {
		switch {
		case len(r.ChangedFiles) > 0:
			r.ChangedFiles = r.ChangedFiles[:len(r.ChangedFiles)-1]
		case len(r.NextSteps) > 0:
			r.NextSteps = r.NextSteps[:len(r.NextSteps)-1]
		case len(r.Questions) > 0:
			r.Questions = r.Questions[:len(r.Questions)-1]
		default:
			return cut
		}
		cut = true
	}
	return cut
}

func reportSize(r *TurnReport) int {
	b, err := json.Marshal(r)
	if err != nil {
		return 0
	}
	return len(b)
}
