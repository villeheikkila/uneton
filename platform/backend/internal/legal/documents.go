// Package legal owns the public, browser-readable Uneton legal documents.
package legal

import (
	"bytes"
	"embed"
	"html/template"
)

//go:embed privacy.html privacy.fi.html terms.html terms.fi.html support.html support.fi.html
var pages embed.FS

type Details struct {
	Operator string
	Email    string
}

func Page(name, language string, details Details) ([]byte, error) {
	file := name + ".html"
	if language == "fi" {
		file = name + ".fi.html"
	}
	contents, err := pages.ReadFile(file)
	if err != nil {
		return nil, err
	}
	page, err := template.New(file).Parse(string(contents))
	if err != nil {
		return nil, err
	}
	var rendered bytes.Buffer
	if err := page.Execute(&rendered, details); err != nil {
		return nil, err
	}
	return rendered.Bytes(), nil
}
