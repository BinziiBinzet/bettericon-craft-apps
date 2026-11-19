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
	result, err := run([]string{res, state, "refresh"})
	if err != nil {
		t.Fatal(err)
	}
	updated := result.([]view)[0]
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

func TestModernFlatUpgrade(t *testing.T) {
	first, combined := strings.Repeat("1", 40), strings.Repeat("2", 40)
	otherArtist := "Craft-Icons-Other/Modern Flat - Wand - Knob"
	unrelated := modernFlat + " - Custom"
	row := func(id, art string) string {
		file := id + "/PhotoCraft.png"
		return strings.Join([]string{blob(art), file, file, checksum([]byte(art))}, "\t")
	}
	legacy := []string{first, row(otherArtist, "other")}
	for _, id := range modernFlatVariants {
		art := "old"
		if id == modernFlat+" - Wand - Knob" {
			art = "latest"
		}
		legacy = append(legacy, row(id, art))
	}
	current := strings.Join([]string{combined, row(modernFlat, "latest"), row(otherArtist, "other")}, "\n")
	old := strings.Join(legacy, "\n")
	for _, tc := range []struct {
		name, edition, seed, latest string
		cached                      []string
		status, art                 string
	}{
		{"old bundle after refresh", "Bundled", old, current, nil, "Included", "latest"},
		{"new bundle and old download", "Bundled", current, "", []string{"Spark - Sliders"}, "Included", "latest"},
		{"no download", "OnDemand", current, "", nil, "Download", ""},
		{"older download", "OnDemand", current, "", []string{"Spark - Sliders"}, "Update available", "old"},
		{"exact among several downloads", "OnDemand", current, "", []string{"Bolt - Knob", "Wand - Knob"}, "Downloaded", "latest"},
		{"old snapshot with new seed", "OnDemand", current, old, []string{"Wand - Knob"}, "Downloaded", "latest"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			res, state := t.TempDir(), t.TempDir()
			write := func(file, data string) {
				t.Helper()
				if err := atomic(file, []byte(data)); err != nil {
					t.Fatal(err)
				}
			}
			catalog := filepath.Join(res, "Catalog")
			seedRevision := lines([]byte(tc.seed))[0]
			write(filepath.Join(catalog, "ProjectFileTypes.json"), `[{"Key":".pcraft","Application":"PhotoCraft"}]`)
			write(filepath.Join(catalog, "edition"), tc.edition)
			write(filepath.Join(catalog, "packs.tsv"), tc.seed)
			thumb := "RIFFxxxxWEBPfixture"
			write(filepath.Join(catalog, "previews.tsv"), fmt.Sprintf("%s\n%s\tflat.webp\t%s\t%d\tPhotoCraft", combined, modernFlat, checksum([]byte(thumb)), len(thumb)))
			write(filepath.Join(res, "Previews", "flat.webp"), thumb)
			if tc.latest != "" {
				write(filepath.Join(state, "catalog-"+seedRevision), tc.latest)
			}
			l, err := openLibrary(res, state)
			if err != nil {
				t.Fatal(err)
			}
			if l.bundled {
				for id, p := range l.seed.Packs {
					art := "old"
					if id == modernFlat || id == modernFlat+" - Wand - Knob" {
						art = "latest"
					}
					write(filepath.Join(res, "Packs", p.Assets[0].File), art)
				}
			}
			cache := func(id, art string) {
				snapshot := first + "\n" + row(id, art)
				s, err := l.readSnapshot([]byte(snapshot))
				if err != nil {
					t.Fatal(err)
				}
				p := s.Packs[id]
				write(filepath.Join(state, "downloads", p.signature(), p.Assets[0].File), art)
				write(filepath.Join(state, "acquired", checksum([]byte(id))), snapshot)
			}
			cache(unrelated, "personal style")
			for _, suffix := range tc.cached {
				art := "old"
				if suffix == "Wand - Knob" {
					art = "latest"
				}
				cache(modernFlat+" - "+suffix, art)
			}
			check := func(status, art string) {
				t.Helper()
				result, err := run([]string{res, state, "list"})
				if err != nil {
					t.Fatal(err)
				}
				packs := map[string]view{}
				for _, v := range result.([]view) {
					packs[v.ID] = v
				}
				v := packs[modernFlat]
				if len(packs) != 3 || packs[otherArtist].ID == "" || packs[unrelated].Status != "Downloaded" ||
					v.Status != status || len(v.PreviousIDs) != 8 || !v.CanApps || !v.CanFiles || !v.HasPreview {
					t.Fatalf("unexpected packs: %+v", packs)
				}
				if art == "" {
					if len(v.Icons) != 0 {
						t.Fatal(v.Icons)
					}
				} else if b, err := os.ReadFile(v.Icons["PhotoCraft"]); err != nil || string(b) != art {
					t.Fatalf("offline artwork %q: %v", b, err)
				}
			}
			oldTransport := client.Transport
			t.Cleanup(func() { client.Transport = oldTransport })
			requests := 0
			client.Transport = serve(func(r *http.Request) (*http.Response, error) {
				requests++
				if !strings.HasSuffix(r.URL.Path, modernFlat+"/PhotoCraft.png") {
					t.Fatalf("unexpected URL %s", r.URL.Path)
				}
				return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader("latest")), Header: make(http.Header)}, nil
			})
			check(tc.status, tc.art)
			if _, err := run([]string{res, state, "preview", modernFlatVariants[4]}); err != nil {
				t.Fatal(err)
			}
			if requests != 0 {
				t.Fatal("opening or hovering downloaded artwork")
			}
			if tc.status == "Update available" || tc.status == "Download" {
				if _, err := run([]string{res, state, "acquire", modernFlatVariants[4]}); err != nil {
					t.Fatal(err)
				}
				check("Downloaded", "latest")
				if requests != 1 {
					t.Fatalf("explicit selection fetched %d files", requests)
				}
			}
		})
	}
}
