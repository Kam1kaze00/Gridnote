package account

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
)

const instructions = "Tutor a student on the single exercise they selected. Give concise, numbered working and a final answer with units when applicable. Use plain text for a compact notebook panel. For a code fragment, reason about it without executing it. Use the selected image to check notation and diagrams. If essential information is unreadable or missing, ask for it rather than guessing."

func (c client) explain(ctx context.Context, access string, exercise Request) (string, error) {
	list, _ := http.NewRequestWithContext(ctx, "GET", c.api+"/models", nil)
	list.Header.Set("Authorization", "Bearer "+access)
	resp, err := c.http.Do(list)
	if err != nil {
		return "", errors.New("Could not reach ChatGPT. Check your connection and try again.")
	}
	var catalog struct {
		Models []struct {
			Slug, Visibility string
			Modalities       []string `json:"input_modalities"`
		}
	}
	if err = readJSON(resp, &catalog); err != nil {
		return "", err
	}
	var model string
	for _, m := range catalog.Models {
		if m.Visibility != "list" || m.Slug == "" {
			continue
		}
		if exercise.Image != "" && len(m.Modalities) > 0 {
			vision := false
			for _, v := range m.Modalities {
				if v == "image" {
					vision = true
				}
			}
			if !vision {
				continue
			}
		}
		model = m.Slug
		break
	}
	if model == "" {
		return "", errors.New("Your ChatGPT account has no available model for this exercise. Review your plan or workspace permissions.")
	}
	content := []map[string]string{{"type": "input_text", "text": exercise.Text}}
	if exercise.Image != "" {
		content = append(content, map[string]string{"type": "input_image", "image_url": exercise.Image})
	}
	if strings.TrimSpace(exercise.Text) == "" {
		content[0]["text"] = "Solve the exercise in the selected image."
	}
	payload, err := json.Marshal(map[string]any{"model": model, "instructions": instructions, "input": []map[string]any{{"role": "user", "content": content}}, "stream": true, "store": false})
	if err != nil {
		return "", err
	}
	req, _ := http.NewRequestWithContext(ctx, "POST", c.api+"/responses", bytes.NewReader(payload))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "text/event-stream")
	req.Header.Set("Authorization", "Bearer "+access)
	resp, err = c.http.Do(req)
	if err != nil {
		return "", errors.New("The connection to ChatGPT was interrupted. Try again.")
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return "", httpProblem(resp)
	}
	return readAnswer(resp.Body)
}

// A closed stream is not proof that the answer completed.
func readAnswer(body io.Reader) (string, error) {
	scanner := bufio.NewScanner(io.LimitReader(body, 12<<20))
	scanner.Buffer(make([]byte, 8192), 4<<20)
	var data, answer strings.Builder
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "data:") {
			data.WriteString(strings.TrimPrefix(strings.TrimPrefix(line, "data:"), " "))
			data.WriteByte('\n')
			continue
		}
		if line != "" || data.Len() == 0 {
			continue
		}
		var e struct {
			Type, Delta string
			Response    struct {
				Output []struct {
					Content []struct{ Type, Text, Refusal string }
				}
			}
		}
		raw := data.String()
		data.Reset()
		if json.Unmarshal([]byte(raw), &e) != nil {
			continue
		}
		switch e.Type {
		case "response.output_text.delta", "response.refusal.delta":
			answer.WriteString(e.Delta)
		case "response.completed":
			var parts []string
			for _, item := range e.Response.Output {
				for _, part := range item.Content {
					if part.Type == "output_text" && part.Text != "" {
						parts = append(parts, part.Text)
					} else if part.Type == "refusal" && part.Refusal != "" {
						parts = append(parts, part.Refusal)
					}
				}
			}
			if len(parts) > 0 {
				return strings.Join(parts, "\n"), nil
			}
			if strings.TrimSpace(answer.String()) != "" {
				return answer.String(), nil
			}
			return "", errors.New("ChatGPT returned an empty answer. Try the exercise again.")
		case "response.failed", "response.incomplete", "error":
			return "", errors.New("ChatGPT could not finish this answer. Check your plan usage or try again.")
		}
	}
	return "", errors.New("The connection ended before ChatGPT finished the answer. Try again.")
}
