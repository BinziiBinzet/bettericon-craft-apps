package main

import (
	"crypto/sha1"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type serve func(*http.Request) (*http.Response, error)

func (f serve) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func blob(b string) string {
	return fmt.Sprintf("%x", sha1.Sum([]byte(fmt.Sprintf("blob %d%c%s", len(b), 0, b))))
}
func TestExplicitPackLifecycle(t *testing.T) {
	res, state := t.TempDir(), t.TempDir()
	write := func(p, b string) {
		t.Helper()
		if err := atomic(p, []byte(b)); err != nil {
			t.Fatal(err)
		}
	}
	path := "Craft-Icons-Artist/Solid/FileTypes/pcraft.png"
	id := "Craft-Icons-Artist/Solid"
	first, next := strings.Repeat("1", 40), strings.Repeat("2", 40)
	row := func(body string) string {
		return strings.Join([]string{blob(body), path, path, checksum([]byte(body))}, "\t")
	}
	thumb := "RIFFxxxxWEBPfixture"
	data := "first"
	target := filepath.Join(res, "Catalog")
	write(filepath.Join(target, "ProjectFileTypes.json"), "[{\"Key\":\".pcraft\",\"Application\":\"PhotoCraft\"}]")
	write(filepath.Join(target, "edition"), "OnDemand")
	write(filepath.Join(target, "packs.tsv"), first+"\n"+row(data))
	write(filepath.Join(target, "previews.tsv"), fmt.Sprintf("%s\n%s\tthumb.webp\t%s\t%d\tPhotoCraft", first, id, checksum([]byte(thumb)), len(thumb)))
	load := func() *library {
		t.Helper()
		l, err := openLibrary(res, state)
		if err != nil {
			t.Fatal(err)
		}
		return l
	}
	requests := map[string]int{}
	truncated, bad, offline := false, false, false
	old := client.Transport
	t.Cleanup(func() { client.Transport = old })
	client.Transport = serve(func(r *http.Request) (*http.Response, error) {
		p := r.URL.Path
		requests[p]++
		if offline {
			return nil, fmt.Errorf("offline")
		}
		b := ""
		switch {
		case strings.HasSuffix(p, "/heads/main"):
			b = fmt.Sprintf("{\"object\":{\"sha\":%q,\"type\":\"commit\"}}", next)
		case strings.Contains(p, "/heads/artwork/"):
			b = fmt.Sprintf("{\"object\":{\"sha\":%q,\"type\":\"commit\"}}", first)
		case strings.Contains(p, "/trees/"):
			tree, _ := json.Marshal(map[string]any{"truncated": truncated, "tree": []any{map[string]any{"type": "blob", "mode": "100644", "path": path, "sha": blob(data), "size": len(data)}}})
			b = string(tree)
		case strings.HasSuffix(p, "thumb.webp"):
			b = thumb
		case strings.HasSuffix(p, path):
			b = data
			if bad {
				b = "damaged"
			}
		default:
			t.Errorf("unexpected request %s", p)
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(b)), Header: make(http.Header)}, nil
	})
	l := load()
	v := l.list()[0]
	if v.Status != "Download" || v.CanApps || !v.CanFiles || len(requests) != 0 {
		t.Fatalf("initial state: %+v", v)
	}
	if _, err := l.thumbnail(id); err != nil {
		t.Fatal(err)
	}
	if _, err := l.thumbnail(id); err != nil {
		t.Fatal(err)
	}
	if len(requests) != 1 || l.list()[0].Status != "Download" {
		t.Fatal("hover acquired full artwork")
	}
	if err := l.acquire(id); err != nil {
		t.Fatal(err)
	}
	if got := load().list()[0]; got.Status != "Downloaded" || got.FileIcons[".pcraft"] == "" {
		t.Fatal(got)
	}
	data = "second"
	truncated = true
	if err := load().refresh(); err == nil || load().latest.Revision != first {
		t.Fatal("accepted partial tree")
	}
	truncated = false
	if err := load().refresh(); err != nil {
		t.Fatal(err)
	}
	updated := load().list()[0]
	if updated.Status != "Update available" || len(updated.FileIcons) != 1 {
		t.Fatal(updated)
	}
	bad = true
	if err := load().acquire(id); err == nil {
		t.Fatal("accepted bad checksum")
	}
	if b, _ := os.ReadFile(updated.FileIcons[".pcraft"]); string(b) != "first" {
		t.Fatal("previous artwork lost")
	}
	bad = false
	if err := load().acquire(id); err != nil {
		t.Fatal(err)
	}
	latest := load().list()[0]
	if latest.Status != "Downloaded" {
		t.Fatal(latest)
	}
	if err := os.Remove(latest.FileIcons[".pcraft"]); err != nil {
		t.Fatal(err)
	}
	if load().list()[0].Status != "Download" {
		t.Fatal("missing artwork still marked downloaded")
	}
	if err := load().acquire(id); err != nil {
		t.Fatal(err)
	}
	offline = true
	if _, err := load().thumbnail(id); err != nil {
		t.Fatal(err)
	}
	if load().list()[0].Status != "Downloaded" {
		t.Fatal("offline cache lost")
	}
	if err := load().refresh(); err == nil || load().latest.Revision != next {
		t.Fatal("offline refresh replaced catalog")
	}
}
