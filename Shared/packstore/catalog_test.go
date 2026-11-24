package main

import (
	"crypto/sha1"
	"encoding/json"
	"fmt"
	"io"
	"maps"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"
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
	// The WebP of the same design is published later, when twin is set.
	twinPath, twin := "Craft-Icons-Artist/Solid/FileTypes/pcraft.webp", ""
	id := "Craft-Icons-Artist/Solid"
	first, next := strings.Repeat("1", 40), strings.Repeat("2", 40)
	row := func(body string) string {
		return strings.Join([]string{blob(body), path, path, checksum([]byte(body))}, "\t")
	}
	thumb := "RIFFxxxxWEBPfixture"
	data := "first"
	target := filepath.Join(res, "Catalog")
	write(filepath.Join(target, "ProjectFileTypes.json"), "[{\"Key\":\".pcraft\",\"Application\":\"PhotoCraft\"}]")
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
			entries := []any{map[string]any{"type": "blob", "mode": "100644", "path": path, "sha": blob(data), "size": len(data)}}
			if twin != "" {
				entries = append(entries, map[string]any{"type": "blob", "mode": "100644", "path": twinPath, "sha": blob(twin), "size": len(twin)})
			}
			tree, _ := json.Marshal(map[string]any{"truncated": truncated, "tree": entries})
			b = string(tree)
		case strings.HasSuffix(p, "thumb.webp"):
			b = thumb
		case strings.HasSuffix(p, path):
			b = data
			if bad {
				b = "damaged"
			}
		case twin != "" && strings.HasSuffix(p, twinPath):
			b = twin
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

	// A WebP published next to the PNG is an update. A download fetches one of the twins: the WebP where the app reads WebP
	// (BETTERICON_WEBP_READABLE=1), else the PNG. A file the pack's folder already holds is not fetched again.
	offline, twin, next = false, "webp", strings.Repeat("3", 40)
	if _, err := run([]string{res, state, "refresh"}); err != nil {
		t.Fatal(err)
	}
	if v := load().list()[0]; v.Status != "Update available" || filepath.Base(v.FileIcons[".pcraft"]) != "pcraft.png" {
		t.Fatalf("published WebP twin: %+v", v)
	}
	fetched := func(file string) int {
		count := 0
		for p, n := range requests {
			if strings.HasSuffix(p, "/"+file) {
				count += n
			}
		}
		return count
	}
	read := func(file string) string {
		b, _ := os.ReadFile(file)
		return string(b)
	}
	// acquire with the app's answer, and how many PNG and WebP requests it made.
	acquireWith := func(readable string) (view, int, int) {
		t.Helper()
		t.Setenv("BETTERICON_WEBP_READABLE", readable)
		png, webp := fetched(path), fetched(twinPath)
		if err := load().acquire(id); err != nil {
			t.Fatal(err)
		}
		return load().list()[0], fetched(path) - png, fetched(twinPath) - webp
	}
	v, png, webp := acquireWith("1")
	chosen := v.FileIcons[".pcraft"]
	if png != 0 || webp != 1 || v.Status != "Downloaded" || filepath.Base(chosen) != "pcraft.webp" || read(chosen) != twin || len(v.Fallbacks) != 0 {
		t.Fatalf("download where the app reads WebP, with %d PNG and %d WebP requests: %+v", png, webp, v)
	}
	if v, png, webp = acquireWith("1"); png+webp != 0 || v.Status != "Downloaded" {
		t.Fatalf("a download fetched files the pack already holds: %d PNG and %d WebP requests", png, webp)
	}
	// Where the app can't read WebP, the WebP alone does not make a download: the pack needs its PNG twin. That file did not
	// change with the update, so it comes from the earlier download, which is still there, and nothing is fetched.
	t.Setenv("BETTERICON_WEBP_READABLE", "0")
	if v := load().list()[0]; v.Status != "Download" {
		t.Fatalf("a WebP alone counts as downloaded where the app can't read WebP: %+v", v)
	}
	v, png, webp = acquireWith("0")
	chosen = v.FileIcons[".pcraft"]
	if png != 0 || webp != 0 || v.Status != "Downloaded" || filepath.Base(chosen) != "pcraft.webp" || len(v.Fallbacks[chosen]) != 1 ||
		filepath.Base(v.Fallbacks[chosen][0]) != "pcraft.png" || read(v.Fallbacks[chosen][0]) != data {
		t.Fatalf("download where the app can't read WebP, with %d PNG and %d WebP requests: %+v", png, webp, v)
	}
	// Without its WebP the PNG serves either way. Without both files, the pack must be downloaded again.
	if err := os.Remove(chosen); err != nil {
		t.Fatal(err)
	}
	for _, readable := range []string{"1", "0"} {
		t.Setenv("BETTERICON_WEBP_READABLE", readable)
		if v := load().list()[0]; v.Status != "Downloaded" || filepath.Base(v.FileIcons[".pcraft"]) != "pcraft.png" || len(v.Fallbacks) != 0 {
			t.Fatalf("PNG twin alone, reading WebP %s: %+v", readable, v)
		}
	}
	if err := os.Remove(filepath.Join(filepath.Dir(chosen), "pcraft.png")); err != nil {
		t.Fatal(err)
	}
	if load().list()[0].Status != "Download" {
		t.Fatal("a pack without either twin still marked downloaded")
	}
}

// A download fetches one twin per icon, from the local pack source tests use: never a request.
func TestTwinDownloads(t *testing.T) {
	res, state, source := t.TempDir(), t.TempDir(), t.TempDir()
	write := func(file, data string) {
		t.Helper()
		if err := atomic(file, []byte(data)); err != nil {
			t.Fatal(err)
		}
	}
	old := client.Transport
	t.Cleanup(func() { client.Transport = old })
	client.Transport = serve(func(r *http.Request) (*http.Response, error) {
		t.Errorf("unexpected request %s", r.URL)
		return nil, fmt.Errorf("offline")
	})
	t.Setenv("BETTERICON_PACK_SOURCE", source)
	revision, id := strings.Repeat("1", 40), "Craft-Icons-Artist/Light"
	files := []string{"PhotoCraft.png", "PhotoCraft.webp", "FileTypes/pcraft.webp", "FileTypes/pcraft.png", "FilmCraft.svg", "GridCraft.webp"}
	rows := []string{revision}
	for _, file := range files {
		published := id + "/" + file
		write(filepath.Join(source, filepath.FromSlash(published)), "art "+file)
		rows = append(rows, strings.Join([]string{blob("art " + file), published, published, checksum([]byte("art " + file))}, "\t"))
	}
	catalog := filepath.Join(res, "Catalog")
	write(filepath.Join(catalog, "ProjectFileTypes.json"), `[{"Key":".pcraft","Application":"PhotoCraft"}]`)
	write(filepath.Join(catalog, "packs.tsv"), strings.Join(rows, "\n"))
	write(filepath.Join(catalog, "previews.tsv"), fmt.Sprintf("%s\n%s\tthumb.webp\t%s\t12\tPhotoCraft", revision, id, checksum([]byte("RIFFxxxxWEBP"))))
	for _, c := range []struct{ readable, want string }{
		{"1", "FileTypes/pcraft.webp,FilmCraft.svg,GridCraft.webp,PhotoCraft.webp"},
		{"0", "FileTypes/pcraft.png,FilmCraft.svg,GridCraft.webp,PhotoCraft.png"},
	} {
		t.Setenv("BETTERICON_WEBP_READABLE", c.readable)
		if err := os.RemoveAll(state); err != nil {
			t.Fatal(err)
		}
		result, err := run([]string{res, state, "acquire", id})
		if err != nil {
			t.Fatal(err)
		}
		v := result.([]view)[0]
		l, err := openLibrary(res, state)
		if err != nil {
			t.Fatal(err)
		}
		root := filepath.Join(state, "downloads", l.latest.Packs[id].signature())
		var got []string
		filepath.WalkDir(root, func(file string, d os.DirEntry, err error) error {
			if err == nil && !d.IsDir() {
				rel, _ := filepath.Rel(filepath.Join(root, filepath.FromSlash(id)), file)
				got = append(got, filepath.ToSlash(rel))
			}
			return nil
		})
		slices.Sort(got)
		if strings.Join(got, ",") != c.want || v.Status != "Downloaded" || len(v.Icons) != 3 || len(v.FileIcons) != 1 || len(v.Fallbacks) != 0 {
			t.Fatalf("reading WebP %s, fetched %q: %+v", c.readable, got, v)
		}
	}
}

// An update takes the files an earlier download of the pack has from there, and prune then removes the downloads the new
// one supersedes. Every file comes from the local pack source or from the computer: never a request.
func TestSupersededDownloads(t *testing.T) {
	res, state, source := t.TempDir(), t.TempDir(), t.TempDir()
	write := func(file, data string) {
		t.Helper()
		if err := atomic(file, []byte(data)); err != nil {
			t.Fatal(err)
		}
	}
	old := client.Transport
	t.Cleanup(func() { client.Transport = old })
	client.Transport = serve(func(r *http.Request) (*http.Response, error) {
		t.Errorf("unexpected request %s", r.URL)
		return nil, fmt.Errorf("offline")
	})
	t.Setenv("BETTERICON_PACK_SOURCE", source)
	t.Setenv("BETTERICON_WEBP_READABLE", "0")
	type art struct{ file, data string }
	seed, keep, other := strings.Repeat("1", 40), "Craft-Icons-Artist/Keep", "Craft-Icons-Artist/Other"
	rows := func(revision string, files []art) string {
		list := []string{revision}
		for _, f := range files {
			list = append(list, strings.Join([]string{blob(f.data), f.file, f.file, checksum([]byte(f.data))}, "\t"))
		}
		return strings.Join(list, "\n")
	}
	// The pack list after a refresh.
	publish := func(revision string, files ...art) {
		t.Helper()
		write(filepath.Join(state, "catalog-"+seed), rows(strings.Repeat(revision, 40), files))
	}
	// The local pack source holds exactly these files.
	offer := func(files ...art) {
		t.Helper()
		entries, _ := os.ReadDir(source)
		for _, entry := range entries {
			if err := os.RemoveAll(filepath.Join(source, entry.Name())); err != nil {
				t.Fatal(err)
			}
		}
		for _, f := range files {
			write(filepath.Join(source, filepath.FromSlash(f.file)), f.data)
		}
	}
	command := func(args ...string) (map[string]view, error) {
		result, err := run(append([]string{res, state}, args...))
		if err != nil {
			return nil, err
		}
		packs := map[string]view{}
		for _, v := range result.([]view) {
			packs[v.ID] = v
		}
		return packs, nil
	}
	must := func(args ...string) map[string]view {
		t.Helper()
		packs, err := command(args...)
		if err != nil {
			t.Fatalf("%v: %v", args, err)
		}
		return packs
	}
	downloads := filepath.Join(state, "downloads")
	// The signature folders that hold a download of a pack.
	copies := func(id string) []string {
		var found []string
		entries, _ := os.ReadDir(downloads)
		for _, entry := range entries {
			if info, err := os.Stat(filepath.Join(downloads, entry.Name(), filepath.FromSlash(id))); err == nil && info.IsDir() && hex64.MatchString(entry.Name()) {
				found = append(found, entry.Name())
			}
		}
		return found
	}
	read := func(file string) string {
		b, _ := os.ReadFile(file)
		return string(b)
	}
	photoOne, photoTwo := art{keep + "/PhotoCraft.png", "photo one"}, art{keep + "/PhotoCraft.png", "photo two"}
	film, document, word := art{keep + "/FilmCraft.png", "film"}, art{keep + "/FileTypes/pcraft.png", "document"}, art{keep + "/WordCraft.png", "word"}
	neighbour := art{other + "/PhotoCraft.png", "other"}
	catalog := filepath.Join(res, "Catalog")
	write(filepath.Join(catalog, "ProjectFileTypes.json"), `[{"Key":".pcraft","Application":"PhotoCraft"}]`)
	write(filepath.Join(catalog, "packs.tsv"), rows(seed, []art{photoOne, film, document, neighbour}))
	write(filepath.Join(catalog, "previews.tsv"), fmt.Sprintf("%s\n%s\tthumb.webp\t%s\t12\tPhotoCraft", seed, keep, checksum([]byte("RIFFxxxxWEBP"))))
	offer(photoOne, film, document, neighbour)
	must("acquire", keep)
	must("acquire", other)

	// The update's source has the changed icon and lacks the new one, as when the connection drops midway.
	publish("2", photoTwo, film, document, word, neighbour)
	offer(photoTwo)
	if _, err := command("acquire", keep); err == nil {
		t.Fatal("an update succeeded without one of its files")
	}
	v := must("list")[keep]
	stages, _ := filepath.Glob(filepath.Join(downloads, ".loading-*"))
	if v.Status != "Update available" || read(v.Icons["PhotoCraft"]) != "photo one" || read(v.Icons["FilmCraft"]) != "film" ||
		read(v.FileIcons[".pcraft"]) != "document" || len(copies(keep)) != 1 || len(stages) != 0 {
		t.Fatalf("an interrupted update left %v, stages %v: %+v", copies(keep), stages, v)
	}

	// Now the new icon is there too. The two files that did not change are in no source: they come from the earlier
	// download, which stays until the app asks for its removal.
	offer(photoTwo, word)
	v = must("acquire", keep)[keep]
	if v.Status != "Downloaded" || read(v.Icons["PhotoCraft"]) != "photo two" || read(v.Icons["FilmCraft"]) != "film" ||
		read(v.Icons["WordCraft"]) != "word" || read(v.FileIcons[".pcraft"]) != "document" {
		t.Fatalf("after the update: %+v", v)
	}
	if got := copies(keep); len(got) != 2 {
		t.Fatalf("the update left the downloads %v before the app asked for a removal", got)
	}
	v = must("prune", keep)[keep]
	if got := copies(keep); len(got) != 1 || v.Status != "Downloaded" || !strings.Contains(v.Icons["PhotoCraft"], got[0]) ||
		read(v.Icons["PhotoCraft"]) != "photo two" || len(copies(other)) != 1 {
		t.Fatalf("after the removal: %v, other %v, %+v", got, copies(other), v)
	}

	// WebP twins are published. Where the app can't read WebP the update needs the PNG files it has: nothing is fetched.
	photoWebP, filmWebP := art{keep + "/PhotoCraft.webp", "photo webp"}, art{keep + "/FilmCraft.webp", "film webp"}
	publish("3", photoTwo, photoWebP, film, filmWebP, document, word, neighbour)
	offer()
	if status := must("list")[keep].Status; status != "Update available" {
		t.Fatalf("published twins: %s", status)
	}
	v = must("acquire", keep)[keep]
	must("prune", keep)
	if got := copies(keep); len(got) != 1 || v.Status != "Downloaded" || read(v.Icons["PhotoCraft"]) != "photo two" {
		t.Fatalf("an update without changed files: %v, %+v", got, v)
	}

	// Where the app reads WebP, an update fetches the WebP twins. When one of them can't be used the app asks again
	// without WebP: the PNG twins then come from the earlier download, which is why acquire left it in place.
	wordWebP := art{keep + "/WordCraft.webp", "word webp"}
	publish("4", photoTwo, photoWebP, film, filmWebP, document, word, wordWebP, neighbour)
	offer(photoWebP, filmWebP, wordWebP)
	t.Setenv("BETTERICON_WEBP_READABLE", "1")
	v = must("acquire", keep)[keep]
	if v.Status != "Downloaded" || read(v.Icons["PhotoCraft"]) != "photo webp" || len(v.Fallbacks) != 0 || len(copies(keep)) != 2 {
		t.Fatalf("an update to WebP twins: %v, %+v", copies(keep), v)
	}
	offer()
	t.Setenv("BETTERICON_WEBP_READABLE", "0")
	must("acquire", keep)
	t.Setenv("BETTERICON_WEBP_READABLE", "1")
	v = must("prune", keep)[keep]
	if got := copies(keep); len(got) != 1 || v.Status != "Downloaded" || read(v.Icons["PhotoCraft"]) != "photo webp" ||
		len(v.Fallbacks[v.Icons["PhotoCraft"]]) != 1 || read(v.Fallbacks[v.Icons["PhotoCraft"]][0]) != "photo two" ||
		read(v.Fallbacks[v.Icons["WordCraft"]][0]) != "word" {
		t.Fatalf("PNG twins after a WebP that can't be used: %v, %+v", got, v)
	}

	// A file of the earlier download that no longer matches its checksum is not taken: it is fetched.
	t.Setenv("BETTERICON_WEBP_READABLE", "0")
	deck := art{keep + "/DeckCraft.png", "deck"}
	publish("5", photoTwo, photoWebP, film, filmWebP, document, word, wordWebP, deck, neighbour)
	write(filepath.Join(downloads, copies(keep)[0], filepath.FromSlash(film.file)), "changed on disk")
	offer(deck, film)
	v = must("acquire", keep)[keep]
	must("prune", keep)
	if got := copies(keep); len(got) != 1 || v.Status != "Downloaded" || read(v.Icons["FilmCraft"]) != "film" || read(v.Icons["PhotoCraft"]) != "photo two" {
		t.Fatalf("a changed file in the earlier download: %v, %+v", got, v)
	}

	// Only folders that hold a download of this pack and nothing else, from before its receipt was written, are removed.
	current := copies(keep)[0]
	earlier, mixed, extra, linked := strings.Repeat("c", 64), strings.Repeat("a", 64), strings.Repeat("b", 64), strings.Repeat("d", 64)
	newer := strings.Repeat("e", 64)
	// As a folder that was there before the receipt was written: every folder below but the one a download just made.
	aged := func(name string) {
		t.Helper()
		past := time.Now().Add(-time.Hour)
		if err := os.Chtimes(filepath.Join(downloads, name), past, past); err != nil {
			t.Fatal(err)
		}
	}
	write(filepath.Join(downloads, earlier, filepath.FromSlash(photoOne.file)), "an earlier download")
	write(filepath.Join(downloads, earlier, filepath.FromSlash(document.file)), "an earlier download")
	write(filepath.Join(downloads, mixed, filepath.FromSlash(photoOne.file)), "two packs")
	write(filepath.Join(downloads, mixed, filepath.FromSlash(neighbour.file)), "two packs")
	write(filepath.Join(downloads, extra, filepath.FromSlash(photoOne.file)), "with a file of the user's")
	write(filepath.Join(downloads, extra, "notes.txt"), "with a file of the user's")
	write(filepath.Join(downloads, "not-a-signature", filepath.FromSlash(photoOne.file)), "another name")
	write(filepath.Join(downloads, ".loading-kept", filepath.FromSlash(photoOne.file)), "a download under way")
	// A download another BetterIcon process is finishing: its folder is there, its receipt is not written yet.
	write(filepath.Join(downloads, newer, filepath.FromSlash(photoOne.file)), "a download about to be recorded")
	kept := []string{mixed, extra, "not-a-signature", ".loading-kept", newer, current}
	if err := os.MkdirAll(filepath.Join(downloads, linked, filepath.FromSlash(keep)), 0700); err != nil {
		t.Fatal(err)
	}
	// Where links can be made, a folder with a link in it stays too.
	if os.Symlink(filepath.Join(downloads, extra, "notes.txt"), filepath.Join(downloads, linked, filepath.FromSlash(photoOne.file))) == nil {
		kept = append(kept, linked)
	}
	for _, name := range []string{earlier, mixed, extra, linked, "not-a-signature", ".loading-kept"} {
		aged(name)
	}
	must("prune", keep)
	for _, name := range kept {
		if _, err := os.Lstat(filepath.Join(downloads, name)); err != nil {
			t.Fatalf("the removal took %s: %v", name, err)
		}
	}
	if _, err := os.Lstat(filepath.Join(downloads, earlier)); err == nil || read(filepath.Join(downloads, extra, "notes.txt")) != "with a file of the user's" || len(copies(other)) != 2 {
		t.Fatalf("after the removal, the earlier download is there (%v) or another pack's is not: %v", err == nil, copies(other))
	}

	// A pack whose download in use is not complete supersedes nothing: every other download of it stays.
	write(filepath.Join(downloads, earlier, filepath.FromSlash(photoOne.file)), "an earlier download")
	aged(earlier)
	if err := os.Remove(filepath.Join(downloads, current, filepath.FromSlash(film.file))); err != nil {
		t.Fatal(err)
	}
	if v = must("prune", keep)[keep]; v.Status != "Download" {
		t.Fatalf("a download with a file missing: %+v", v)
	}
	if _, err := os.Lstat(filepath.Join(downloads, earlier)); err != nil {
		t.Fatalf("a removal without a complete download in use took the earlier one: %v", err)
	}
	if _, err := command("prune", ""); err == nil {
		t.Fatal("a removal for a pack without a name was accepted")
	}
}

// Once after it has started, the app asks for the downloads that updates left behind before BetterIcon removed them:
// prune without a pack removes them for every pack whose download in use is complete, and nothing else.
func TestLeftoverDownloads(t *testing.T) {
	res, state, source := t.TempDir(), t.TempDir(), t.TempDir()
	write := func(file, data string) {
		t.Helper()
		if err := atomic(file, []byte(data)); err != nil {
			t.Fatal(err)
		}
	}
	old := client.Transport
	t.Cleanup(func() { client.Transport = old })
	client.Transport = serve(func(r *http.Request) (*http.Response, error) {
		t.Errorf("unexpected request %s", r.URL)
		return nil, fmt.Errorf("offline")
	})
	t.Setenv("BETTERICON_PACK_SOURCE", source)
	t.Setenv("BETTERICON_WEBP_READABLE", "0")
	seed := strings.Repeat("1", 40)
	one, two, partial, never := "Craft-Icons-Artist/One", "Craft-Icons-Artist/Two", "Craft-Icons-Artist/Partial", "Craft-Icons-Artist/Never"
	ids := []string{one, two, partial, never}
	// The pack list in an edition: each pack has one icon, whose contents name the pack and the edition.
	rows := func(revision, edition string) string {
		list := []string{strings.Repeat(revision, 40)}
		for _, id := range ids {
			file, data := id+"/PhotoCraft.png", id+" "+edition
			write(filepath.Join(source, filepath.FromSlash(file)), data)
			list = append(list, strings.Join([]string{blob(data), file, file, checksum([]byte(data))}, "\t"))
		}
		return strings.Join(list, "\n")
	}
	command := func(args ...string) map[string]view {
		t.Helper()
		result, err := run(append([]string{res, state}, args...))
		if err != nil {
			t.Fatalf("%v: %v", args, err)
		}
		packs := map[string]view{}
		for _, v := range result.([]view) {
			packs[v.ID] = v
		}
		return packs
	}
	downloads := filepath.Join(state, "downloads")
	// The signature folders that hold a download of a pack.
	copies := func(id string) []string {
		var found []string
		entries, _ := os.ReadDir(downloads)
		for _, entry := range entries {
			if info, err := os.Stat(filepath.Join(downloads, entry.Name(), filepath.FromSlash(id))); err == nil && info.IsDir() && hex64.MatchString(entry.Name()) {
				found = append(found, entry.Name())
			}
		}
		return found
	}
	read := func(file string) string {
		b, _ := os.ReadFile(file)
		return string(b)
	}
	catalog := filepath.Join(res, "Catalog")
	write(filepath.Join(catalog, "ProjectFileTypes.json"), `[{"Key":".pcraft","Application":"PhotoCraft"}]`)
	write(filepath.Join(catalog, "packs.tsv"), rows("1", "first"))
	write(filepath.Join(catalog, "previews.tsv"), fmt.Sprintf("%s\n%s\tthumb.webp\t%s\t12\tPhotoCraft", seed, one, checksum([]byte("RIFFxxxxWEBP"))))
	downloaded := []string{one, two, partial}
	for _, id := range downloaded {
		command("acquire", id)
	}
	// Every pack is updated, as a version that removed nothing left it: the earlier download beside the new one.
	write(filepath.Join(state, "catalog-"+seed), rows("2", "second"))
	for _, id := range downloaded {
		command("acquire", id)
		if got := copies(id); len(got) != 2 {
			t.Fatalf("%s after its update: %v", id, got)
		}
	}
	// One pack's download in use has lost its file. Another has a folder a download is about to record, and the cache
	// holds a folder with a file of the user's that is as old as the leftovers.
	partialNow := command("list")[partial].Icons["PhotoCraft"]
	if err := os.Remove(partialNow); err != nil {
		t.Fatal(err)
	}
	arriving, foreign := strings.Repeat("e", 64), strings.Repeat("b", 64)
	write(filepath.Join(downloads, arriving, filepath.FromSlash(one+"/PhotoCraft.png")), "a download about to be recorded")
	write(filepath.Join(downloads, foreign, filepath.FromSlash(two+"/PhotoCraft.png")), "with a file of the user's")
	write(filepath.Join(downloads, foreign, "notes.txt"), "with a file of the user's")
	past := time.Now().Add(-time.Hour)
	if err := os.Chtimes(filepath.Join(downloads, foreign), past, past); err != nil {
		t.Fatal(err)
	}
	check := func(when string) {
		t.Helper()
		packs := command("list")
		if got := copies(one); len(got) != 2 || !slices.Contains(got, arriving) || packs[one].Status != "Downloaded" || read(packs[one].Icons["PhotoCraft"]) != one+" second" {
			t.Fatalf("%s, the first pack: %v, %+v", when, got, packs[one])
		}
		if got := copies(two); len(got) != 2 || !slices.Contains(got, foreign) || packs[two].Status != "Downloaded" || read(packs[two].Icons["PhotoCraft"]) != two+" second" ||
			read(filepath.Join(downloads, foreign, "notes.txt")) != "with a file of the user's" {
			t.Fatalf("%s, the second pack: %v, %+v", when, got, packs[two])
		}
		if got := copies(partial); len(got) != 2 || packs[partial].Status != "Download" || packs[never].Status != "Download" || len(copies(never)) != 0 {
			t.Fatalf("%s, the pack without a complete download in use: %v, %+v", when, got, packs[partial])
		}
	}
	command("prune")
	check("after the removal for every pack")
	command("prune")
	check("after a second removal")
}

// The packs Modern Flat replaced: an update takes their files, and their downloads and receipts go once the combined pack
// is downloaded and in use, whether the app asks for that pack or, after it has started, for every pack.
func TestReplacedPackDownloads(t *testing.T) {
	t.Run("asked for the pack", func(t *testing.T) { replacedPackDownloads(t, "prune", modernFlatVariants[4]) })
	t.Run("asked for every pack", func(t *testing.T) { replacedPackDownloads(t, "prune") })
}
func replacedPackDownloads(t *testing.T, removal ...string) {
	res, state, source := t.TempDir(), t.TempDir(), t.TempDir()
	write := func(file, data string) {
		t.Helper()
		if err := atomic(file, []byte(data)); err != nil {
			t.Fatal(err)
		}
	}
	old := client.Transport
	t.Cleanup(func() { client.Transport = old })
	client.Transport = serve(func(r *http.Request) (*http.Response, error) {
		t.Errorf("unexpected request %s", r.URL)
		return nil, fmt.Errorf("offline")
	})
	t.Setenv("BETTERICON_PACK_SOURCE", source)
	t.Setenv("BETTERICON_WEBP_READABLE", "1")
	first, combined := strings.Repeat("1", 40), strings.Repeat("2", 40)
	unrelated := modernFlat + " - Custom"
	row := func(file, art string) string {
		return strings.Join([]string{blob(art), file, file, checksum([]byte(art))}, "\t")
	}
	catalog := filepath.Join(res, "Catalog")
	write(filepath.Join(catalog, "ProjectFileTypes.json"), `[{"Key":".pcraft","Application":"PhotoCraft"}]`)
	write(filepath.Join(catalog, "packs.tsv"), strings.Join([]string{combined, row(modernFlat+"/PhotoCraft.png", "latest"), row(modernFlat+"/FilmCraft.png", "film")}, "\n"))
	write(filepath.Join(catalog, "previews.tsv"), fmt.Sprintf("%s\n%s\tflat.webp\t%s\t12\tPhotoCraft", combined, modernFlat, checksum([]byte("RIFFxxxxWEBP"))))
	l, err := openLibrary(res, state)
	if err != nil {
		t.Fatal(err)
	}
	cache := func(id, art string) {
		t.Helper()
		snapshot := first + "\n" + row(id+"/PhotoCraft.png", art)
		s, err := l.readSnapshot([]byte(snapshot))
		if err != nil {
			t.Fatal(err)
		}
		p := s.Packs[id]
		write(filepath.Join(state, "downloads", p.signature(), p.Assets[0].File), art)
		write(filepath.Join(state, "acquired", checksum([]byte(id))), snapshot)
	}
	cache(modernFlat+" - Spark - Sliders", "old")
	cache(modernFlat+" - Wand - Knob", "latest")
	cache(unrelated, "personal style")
	// The source has the new icon alone. The other is the one an earlier pack's download has.
	write(filepath.Join(source, filepath.FromSlash(modernFlat+"/FilmCraft.png")), "film")
	count := func(folder string) int {
		entries, _ := os.ReadDir(filepath.Join(state, folder))
		return len(entries)
	}
	listed := func(args ...string) map[string]view {
		t.Helper()
		result, err := run(append([]string{res, state}, args...))
		if err != nil {
			t.Fatalf("%v: %v", args, err)
		}
		packs := map[string]view{}
		for _, v := range result.([]view) {
			packs[v.ID] = v
		}
		return packs
	}
	read := func(file string) string {
		b, _ := os.ReadFile(file)
		return string(b)
	}
	if v := listed("list")[modernFlat]; v.Status != "Update available" {
		t.Fatalf("before the update: %+v", v)
	}
	v := listed("acquire", modernFlatVariants[4])[modernFlat]
	if v.Status != "Downloaded" || read(v.Icons["PhotoCraft"]) != "latest" || read(v.Icons["FilmCraft"]) != "film" || count("downloads") != 4 || count("acquired") != 4 {
		t.Fatalf("after the update, %d downloads and %d receipts: %+v", count("downloads"), count("acquired"), v)
	}
	packs := listed(removal...)
	v = packs[modernFlat]
	if v.Status != "Downloaded" || read(v.Icons["PhotoCraft"]) != "latest" || packs[unrelated].Status != "Downloaded" ||
		read(packs[unrelated].Icons["PhotoCraft"]) != "personal style" || count("downloads") != 2 || count("acquired") != 2 {
		t.Fatalf("after the removal, %d downloads and %d receipts: %+v", count("downloads"), count("acquired"), packs)
	}
}

// A pack is listed for apps when it draws app icons and for files when it draws file artwork.
func TestFileTypeArtwork(t *testing.T) {
	res, state := t.TempDir(), t.TempDir()
	catalog := filepath.Join(res, "Catalog")
	write := func(file, data string) {
		t.Helper()
		if err := atomic(file, []byte(data)); err != nil {
			t.Fatal(err)
		}
	}
	revision := strings.Repeat("1", 40)
	contents := map[string]string{}
	row := func(canonical, source string) string {
		contents[canonical] = source
		return strings.Join([]string{blob(source), canonical, source, checksum([]byte(source))}, "\t")
	}
	mixed, documents, plain := "Craft-Icons-Mike22/Dark", "Craft-Icons-Komplett/Dunkel", "Craft-Icons-Artist/Plain"
	rows := []string{
		revision,
		row(mixed+"/PhotoCraft.png", mixed+"/PhotoCraft.png"),
		row(mixed+"/FileTypes/PhotoCraft-files.png", mixed+"/FileTypes/PhotoCraft-PSD.png"),
		row(mixed+"/FileTypes/pcraft.png", mixed+"/FileTypes/pcraft.png"),
		row(documents+"/PhotoCraft.png", documents+"/PhotoCraft-Dunkel.png"),
		row(plain+"/PhotoCraft.png", plain+"/PhotoCraft.png"),
	}
	write(filepath.Join(catalog, "ProjectFileTypes.json"), `[{"Key":".pcraft","Application":"PhotoCraft"},{"Key":".psd","Application":"PhotoCraft"},{"Key":".png","Application":"PhotoCraft","Aliases":[".jpg",".webp"]}]`)
	write(filepath.Join(catalog, "packs.tsv"), strings.Join(rows, "\n"))
	strip, fileStrip := "RIFFxxxxWEBP", "RIFFfileWEBP"
	write(filepath.Join(res, "Previews", "thumb.webp"), strip)
	write(filepath.Join(res, "Previews", "files.webp"), fileStrip)
	write(filepath.Join(catalog, "previews.tsv"), fmt.Sprintf("%s\n%s\tthumb.webp\t%s\t12\tPhotoCraft\n%s\tfiles.webp\t%s\t12\tPhotoCraft,pcraft",
		revision, mixed, checksum([]byte(strip)), mixed+fileSet, checksum([]byte(fileStrip))))
	l, err := openLibrary(res, state)
	if err != nil {
		t.Fatal(err)
	}
	// Each pack was downloaded earlier: its artwork and its record are in the state folder.
	for id, p := range l.seed.Packs {
		var record []string
		for _, a := range p.Assets {
			write(filepath.Join(state, "downloads", p.signature(), filepath.FromSlash(a.File)), contents[a.File])
			record = append(record, strings.Join([]string{blob(contents[a.File]), a.File, a.File, checksum([]byte(contents[a.File]))}, "\t"))
		}
		write(filepath.Join(state, "acquired", checksum([]byte(id))), revision+"\n"+strings.Join(record, "\n"))
	}
	packs := map[string]view{}
	for _, v := range l.list() {
		packs[v.ID] = v
	}
	read := func(file string) string {
		b, _ := os.ReadFile(file)
		return string(b)
	}
	if v := packs[mixed]; len(packs) != 3 || !v.CanApps || !v.CanFiles || v.Status != "Downloaded" ||
		read(v.Icons["PhotoCraft"]) != mixed+"/PhotoCraft.png" || read(v.FileIcons[".pcraft"]) != mixed+"/FileTypes/pcraft.png" ||
		read(v.AppFileIcons["PhotoCraft"]) != mixed+"/FileTypes/PhotoCraft-PSD.png" || len(v.Icons)+len(v.FileIcons)+len(v.AppFileIcons) != 3 {
		t.Fatalf("app and file artwork: %+v", packs)
	}
	if v := packs[documents]; v.CanApps || !v.CanFiles || len(v.Icons) != 0 || len(v.FileIcons) != 0 ||
		read(v.AppFileIcons["PhotoCraft"]) != documents+"/PhotoCraft-Dunkel.png" {
		t.Fatalf("document pack: %+v", v)
	}
	if v := packs[plain]; !v.CanApps || v.CanFiles || len(v.FileIcons)+len(v.AppFileIcons) != 0 {
		t.Fatalf("app icon pack: %+v", v)
	}
	// The file type list shows the strip of a pack's FileTypes artwork, not the one of its app icons.
	if !packs[mixed].HasPreview || !packs[mixed].HasFilePreview || packs[documents].HasFilePreview || packs[plain].HasFilePreview {
		t.Fatalf("file type previews: %+v", packs)
	}
	for request, expected := range map[string]string{"": strip, "files": fileStrip} {
		args := []string{res, state, "preview", mixed}
		if request != "" {
			args = append(args, request)
		}
		if file, err := run(args); err != nil || read(file.(string)) != expected {
			t.Fatalf("preview %q: %v %v", request, file, err)
		}
	}
	if _, err := run([]string{res, state, "preview", mixed, "apps"}); err == nil {
		t.Fatal("accepted an unknown preview kind")
	}
	if file, err := run([]string{res, state, "preview", plain, "files"}); err != nil || file.(string) != "" {
		t.Fatalf("a pack without file artwork has no file type preview: %v %v", file, err)
	}
	// A published tree names an app's file artwork freely. The catalog gives it one stable name.
	if _, a, ok := l.identify(mixed + "/FileTypes/PhotoCraft-PSD.svg"); !ok || !a.Document || !a.AppFiles || a.Key != "PhotoCraft" ||
		a.File != mixed+"/FileTypes/PhotoCraft-files.svg" {
		t.Fatalf("app file artwork: %+v %v", a, ok)
	}
	if _, a, ok := l.identify(mixed + "/FileTypes/.PSD.png"); !ok || !a.Document || a.AppFiles || a.Key != ".psd" || a.File != mixed+"/FileTypes/psd.png" {
		t.Fatalf("format artwork: %+v %v", a, ok)
	}
	for _, unknown := range []string{mixed + "/FileTypes/notes.png", mixed + "/FileTypes/Uninstall PhotoCraft.png", mixed + "/Extra/FileTypes/PhotoCraft.png"} {
		if _, _, ok := l.identify(unknown); ok {
			t.Fatalf("accepted %s", unknown)
		}
	}
	// WebP artwork is named like PNG artwork, whatever the case of its extension. png.webp is the image design in WebP.
	for source, expected := range map[string]asset{
		mixed + "/PhotoCraft.webp":               {Key: "PhotoCraft", File: mixed + "/PhotoCraft.webp"},
		mixed + "/ArtCraft Launcher.webp":        {Key: "ArtCraftLauncher", File: mixed + "/ArtCraftLauncher.webp"},
		mixed + "/FileTypes/pcraft.webp":         {Key: ".pcraft", File: mixed + "/FileTypes/pcraft.webp", Document: true},
		mixed + "/FileTypes/PhotoCraft-PSD.WEBP": {Key: "PhotoCraft", File: mixed + "/FileTypes/PhotoCraft-files.webp", Document: true, AppFiles: true},
		mixed + "/FileTypes/.PSD.webp":           {Key: ".psd", File: mixed + "/FileTypes/psd.webp", Document: true},
		mixed + "/FileTypes/png.webp":            {Key: ".png", File: mixed + "/FileTypes/png.webp", Document: true},
	} {
		expected.Source = source
		if p, a, ok := l.identify(source); !ok || p.ID != mixed || a != expected {
			t.Fatalf("WebP artwork %s: %+v %v", source, a, ok)
		}
	}
	// Aliases name no design, and preview sheets, source sheets and deeper folders are not artwork.
	for _, ignored := range []string{mixed + "/FileTypes/webp.png", mixed + "/FileTypes/jpg.webp", "Craft-Icons-Mains/Chrome Glass Preview.webp",
		"Craft-Icons-หมาแดนซ์/Source sheet.webp", mixed + "/svg/PhotoCraft.webp"} {
		if _, _, ok := l.identify(ignored); ok {
			t.Fatalf("accepted %s", ignored)
		}
	}
	// Two images for one app's files cannot share a pack.
	duplicate := strings.Join([]string{revision, rows[2], row(mixed+"/FileTypes/PhotoCraft-files.png", mixed+"/FileTypes/PhotoCraft-PNG.png")}, "\n")
	if _, err := l.readSnapshot([]byte(duplicate)); err == nil {
		t.Fatal("accepted two images for one app's files")
	}
	// A WebP and a PNG of one icon are two formats of it. Two WebP files for one icon are a duplicate.
	twins := strings.Join([]string{revision, row(mixed+"/PhotoCraft.png", mixed+"/PhotoCraft.png"), row(mixed+"/PhotoCraft.webp", mixed+"/PhotoCraft.webp")}, "\n")
	if s, err := l.readSnapshot([]byte(twins)); err != nil || len(s.Packs[mixed].Assets) != 2 {
		t.Fatalf("PNG and WebP of one icon: %v", err)
	}
	for _, pair := range [][2]string{{"PhotoCraft.webp", "PhotoCraft Dark.webp"}, {"PhotoCraft.WEBP", "photocraft.webp"}} {
		one := revision + "\n" + row(mixed+"/PhotoCraft.webp", mixed+"/"+pair[0])
		if _, err := l.readSnapshot([]byte(one)); err != nil {
			t.Fatalf("%s alone: %v", pair[0], err)
		}
		both := one + "\n" + row(mixed+"/PhotoCraft.webp", mixed+"/"+pair[1])
		if _, err := l.readSnapshot([]byte(both)); err == nil || !strings.HasPrefix(err.Error(), "Invalid or duplicate artwork") {
			t.Fatalf("%s with %s: %v", pair[0], pair[1], err)
		}
	}
}

// When an artist supplies an item in several formats, a downloaded pack lists the preferred file and
// keeps the others, best first, for an app that cannot use it.
func TestWebPPreference(t *testing.T) {
	res, state := t.TempDir(), t.TempDir()
	write := func(file, data string) {
		t.Helper()
		if err := atomic(file, []byte(data)); err != nil {
			t.Fatal(err)
		}
	}
	revision := strings.Repeat("1", 40)
	twins, documents, single, merged := "Craft-Icons-Artist/Twins", "Craft-Icons-Komplett/Dunkel", "Craft-Icons-Artist/Single", "Craft-Icons-Zach/Ink"
	row := func(canonical, source string) string {
		return strings.Join([]string{blob(source), canonical, source, checksum([]byte(source))}, "\t")
	}
	same := func(file string) string { return row(file, file) }
	// The rows of an item are not in order of preference.
	rows := []string{
		revision,
		same(twins + "/PhotoCraft.png"), same(twins + "/PhotoCraft.webp"),
		same(twins + "/FileTypes/pcraft.webp"), same(twins + "/FileTypes/pcraft.png"),
		row(twins+"/FileTypes/PhotoCraft-files.png", twins+"/FileTypes/PhotoCraft-PSD.png"),
		row(twins+"/FileTypes/PhotoCraft-files.webp", twins+"/FileTypes/PhotoCraft-PSD.webp"),
		same(twins + "/FilmCraft.png"), same(twins + "/FilmCraft.svg"),
		same(twins + "/GridCraft.svg"), same(twins + "/GridCraft.ico"),
		same(twins + "/LightCraft.svg"), same(twins + "/LightCraft.webp"), same(twins + "/LightCraft.ico"), same(twins + "/LightCraft.png"),
		row(documents+"/PhotoCraft.png", documents+"/PhotoCraft-Dunkel.png"),
		row(documents+"/PhotoCraft.webp", documents+"/PhotoCraft-Dunkel.webp"),
		same(single + "/PhotoCraft.webp"), same(single + "/FilmCraft.png"), same(single + "/FileTypes/pcraft.svg"),
		// OmegaDarling's packs are listed under Zach, so these two folders make one pack with two PNG files for PhotoCraft.
		same("Craft-Icons-OmegaDarling/Ink/PhotoCraft.png"), same("Craft-Icons-OmegaDarling/Ink/PhotoCraft.webp"), same(merged + "/PhotoCraft.png"),
	}
	catalog := filepath.Join(res, "Catalog")
	write(filepath.Join(catalog, "ProjectFileTypes.json"), `[{"Key":".pcraft","Application":"PhotoCraft"},{"Key":".psd","Application":"PhotoCraft"}]`)
	write(filepath.Join(catalog, "packs.tsv"), strings.Join(rows, "\n"))
	write(filepath.Join(catalog, "previews.tsv"), fmt.Sprintf("%s\n%s\tthumb.webp\t%s\t12\tPhotoCraft", revision, twins, checksum([]byte("RIFFxxxxWEBP"))))
	l, err := openLibrary(res, state)
	if err != nil {
		t.Fatal(err)
	}
	// Each pack was downloaded earlier.
	local := func(id, file string) string {
		return filepath.Join(state, "downloads", l.seed.Packs[id].signature(), filepath.FromSlash(file))
	}
	for id, p := range l.seed.Packs {
		var record []string
		for _, a := range p.Assets {
			write(local(id, a.File), a.Source)
			record = append(record, strings.Join([]string{a.Blob, a.File, a.Source, a.Hash}, "\t"))
		}
		write(filepath.Join(state, "acquired", checksum([]byte(id))), revision+"\n"+strings.Join(record, "\n"))
	}
	result, err := run([]string{res, state, "list"})
	if err != nil {
		t.Fatal(err)
	}
	packs := map[string]view{}
	for _, v := range result.([]view) {
		packs[v.ID] = v
	}
	expect := func(v view, files map[string]string, key, chosen string, others ...string) {
		t.Helper()
		var fallbacks []string
		for _, file := range others {
			fallbacks = append(fallbacks, local(v.ID, file))
		}
		if files[key] != local(v.ID, chosen) || !slices.Equal(v.Fallbacks[files[key]], fallbacks) {
			t.Fatalf("%s %s: chose %s, then %q", v.ID, key, files[key], v.Fallbacks[files[key]])
		}
	}
	v := packs[twins]
	if v.Status != "Downloaded" || len(v.Icons) != 4 || len(v.FileIcons) != 1 || len(v.AppFileIcons) != 1 || len(v.Fallbacks) != 6 {
		t.Fatalf("pack with twins: %+v", v)
	}
	expect(v, v.Icons, "PhotoCraft", twins+"/PhotoCraft.webp", twins+"/PhotoCraft.png")
	expect(v, v.FileIcons, ".pcraft", twins+"/FileTypes/pcraft.webp", twins+"/FileTypes/pcraft.png")
	expect(v, v.AppFileIcons, "PhotoCraft", twins+"/FileTypes/PhotoCraft-files.webp", twins+"/FileTypes/PhotoCraft-files.png")
	// Without WebP, the order stays as it was: PNG, then SVG, then ICO.
	expect(v, v.Icons, "FilmCraft", twins+"/FilmCraft.png", twins+"/FilmCraft.svg")
	expect(v, v.Icons, "GridCraft", twins+"/GridCraft.svg", twins+"/GridCraft.ico")
	expect(v, v.Icons, "LightCraft", twins+"/LightCraft.webp", twins+"/LightCraft.png", twins+"/LightCraft.svg", twins+"/LightCraft.ico")
	d := packs[documents]
	if d.Status != "Downloaded" || len(d.Icons)+len(d.FileIcons) != 0 || len(d.AppFileIcons) != 1 {
		t.Fatalf("document pack with twins: %+v", d)
	}
	expect(d, d.AppFileIcons, "PhotoCraft", documents+"/PhotoCraft.webp", documents+"/PhotoCraft.png")
	// Fallbacks keep one file of each format: the PNG this pack listed before it had a WebP, the one listed last.
	m := packs[merged]
	if m.Status != "Downloaded" || len(m.Icons) != 1 || len(m.Fallbacks) != 1 {
		t.Fatalf("merged pack with a WebP: %+v", m)
	}
	expect(m, m.Icons, "PhotoCraft", "Craft-Icons-OmegaDarling/Ink/PhotoCraft.webp", merged+"/PhotoCraft.png")
	// A pack that has each item in one format only has no Fallbacks in its JSON.
	s := packs[single]
	plain, _ := json.Marshal(s)
	withTwins, _ := json.Marshal(v)
	if s.Status != "Downloaded" || s.Icons["PhotoCraft"] != local(single, single+"/PhotoCraft.webp") || s.Fallbacks != nil ||
		strings.Contains(string(plain), `"Fallbacks"`) || !strings.Contains(string(withTwins), `"Fallbacks"`) {
		t.Fatalf("pack with single formats: %s", plain)
	}
}

// Two packs merged under one name, or a Komplett app icon beside its app's file art, give one key two files in
// one format. Without WebP, such a pack lists what it listed before WebP was accepted: the file listed last, and no
// Fallbacks.
func TestSameFormatFiles(t *testing.T) {
	res, state := t.TempDir(), t.TempDir()
	write := func(file, data string) {
		t.Helper()
		if err := atomic(file, []byte(data)); err != nil {
			t.Fatal(err)
		}
	}
	revision := strings.Repeat("1", 40)
	row := func(canonical, source string) string {
		return strings.Join([]string{blob(source), canonical, source, checksum([]byte(source))}, "\t")
	}
	same := func(file string) string { return row(file, file) }
	hell, getoent, pop := "Craft-Icons-Komplett/Hell", "Craft-Icons-Komplett/Getoent", "Craft-Icons-Zach/Pop"
	rows := []string{
		revision,
		// Komplett themes an app's files with its app icon, so the app icon and the app's file art share a key.
		same(hell + "/PhotoCraft.png"), row(hell+"/FileTypes/PhotoCraft-files.png", hell+"/FileTypes/PhotoCraft-PSD.png"),
		row(getoent+"/FileTypes/PhotoCraft-files.png", getoent+"/FileTypes/PhotoCraft-PSD.png"), same(getoent + "/PhotoCraft.png"),
		// OmegaDarling's packs are listed under Zach, so two folders named Pop make one pack.
		same("Craft-Icons-OmegaDarling/Pop/PhotoCraft.png"), same(pop + "/PhotoCraft.png"),
	}
	catalog := filepath.Join(res, "Catalog")
	write(filepath.Join(catalog, "ProjectFileTypes.json"), `[{"Key":".pcraft","Application":"PhotoCraft"}]`)
	write(filepath.Join(catalog, "packs.tsv"), strings.Join(rows, "\n"))
	write(filepath.Join(catalog, "previews.tsv"), fmt.Sprintf("%s\n%s\tthumb.webp\t%s\t12\tPhotoCraft", revision, pop, checksum([]byte("RIFFxxxxWEBP"))))
	l, err := openLibrary(res, state)
	if err != nil {
		t.Fatal(err)
	}
	// Each pack was downloaded earlier, and its record lists the files in catalog order.
	local := func(id, file string) string {
		return filepath.Join(state, "downloads", l.seed.Packs[id].signature(), filepath.FromSlash(file))
	}
	for id, p := range l.seed.Packs {
		var record []string
		for _, a := range p.Assets {
			write(local(id, a.File), a.Source)
			record = append(record, strings.Join([]string{a.Blob, a.File, a.Source, a.Hash}, "\t"))
		}
		write(filepath.Join(state, "acquired", checksum([]byte(id))), revision+"\n"+strings.Join(record, "\n"))
	}
	result, err := run([]string{res, state, "list"})
	if err != nil {
		t.Fatal(err)
	}
	packs := map[string]view{}
	for _, v := range result.([]view) {
		packs[v.ID] = v
	}
	if len(packs) != 3 {
		t.Fatalf("packs: %+v", packs)
	}
	for id, chosen := range map[string]string{
		hell:    hell + "/FileTypes/PhotoCraft-files.png",
		getoent: getoent + "/PhotoCraft.png",
		pop:     pop + "/PhotoCraft.png",
	} {
		v := packs[id]
		files := v.Icons
		if strings.HasPrefix(id, documentPacks) {
			files = v.AppFileIcons
		}
		b, _ := json.Marshal(v)
		if v.Status != "Downloaded" || len(v.Icons)+len(v.FileIcons)+len(v.AppFileIcons) != 1 || files["PhotoCraft"] != local(id, chosen) ||
			v.Fallbacks != nil || strings.Contains(string(b), `"Fallbacks"`) {
			t.Errorf("%s should list %s alone: %s", id, chosen, b)
		}
	}
}

func TestPackUpdateCheck(t *testing.T) {
	res := t.TempDir()
	state := filepath.Join(t.TempDir(), "state")
	catalog := filepath.Join(res, "Catalog")
	write := func(name, contents string) {
		t.Helper()
		if err := atomic(filepath.Join(catalog, name), []byte(contents)); err != nil {
			t.Fatal(err)
		}
	}
	seed, updated, unrelated, removed := strings.Repeat("1", 40), strings.Repeat("2", 40), strings.Repeat("3", 40), strings.Repeat("4", 40)
	oldPath := modernFlat + "/PhotoCraft.png"
	newPath := "Craft-Icons-Artist/New/PhotoCraft.png"
	unchangedPath := "Craft-Icons-Artist/Same/PhotoCraft.png"
	row := func(path, body string) string {
		return strings.Join([]string{blob(body), path, path, checksum([]byte(body))}, "\t")
	}
	write("ProjectFileTypes.json", `[{"Key":".pcraft","Application":"PhotoCraft"}]`)
	write("packs.tsv", strings.Join([]string{seed, row(oldPath, "old"), row(unchangedPath, "same")}, "\n"))
	write("previews.tsv", fmt.Sprintf("%s\n%s\tthumb.webp\t%s\t12\tPhotoCraft", seed, modernFlat, checksum([]byte("RIFFxxxxWEBP"))))

	// The background command may read the main ref and the pinned tree.
	revision := updated
	artwork := map[string]string{oldPath: "updated", unchangedPath: "same", newPath: "new", "README.md": "metadata"}
	checkTrees, previewRefs := 0, 0
	offline, truncated := false, false
	transport := client.Transport
	t.Cleanup(func() { client.Transport = transport })
	client.Transport = serve(func(r *http.Request) (*http.Response, error) {
		var b []byte
		switch p := r.URL.Path; {
		case strings.HasSuffix(p, "/heads/main"):
			if offline {
				return nil, fmt.Errorf("offline")
			}
			b = []byte(fmt.Sprintf(`{"object":{"sha":%q,"type":"commit"}}`, revision))
		case strings.HasSuffix(p, "/trees/"+revision) && r.URL.RawQuery == "recursive=1":
			checkTrees++
			var entries []map[string]any
			for path, contents := range artwork {
				entries = append(entries, map[string]any{"type": "blob", "mode": "100644", "path": path, "sha": blob(contents), "size": len(contents)})
			}
			b, _ = json.Marshal(map[string]any{"truncated": truncated, "tree": entries})
		case strings.HasSuffix(p, "/heads/artwork/pack-hover-previews-v1"):
			previewRefs++
			b = []byte(fmt.Sprintf(`{"object":{"sha":%q,"type":"commit"}}`, seed))
		default:
			t.Fatalf("unexpected request %s", r.URL)
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(string(b))), Header: make(http.Header)}, nil
	})
	check := func(previous *updateCheck, count, trees int) updateCheck {
		t.Helper()
		args := []string{res, state, "check-updates"}
		if previous != nil {
			args = append(args, previous.Revision, previous.Baseline, strconv.Itoa(previous.Count))
		}
		out, err := run(args)
		result, ok := out.(updateCheck)
		if err != nil || !ok || result.Count != count || result.Revision != revision || !hex64.MatchString(result.Baseline) || checkTrees != trees {
			t.Fatalf("check returned %#v, %v, with %d tree requests; want count %d with %d tree requests", out, err, checkTrees, count, trees)
		}
		return result
	}
	observed := check(nil, 2, 1)
	if repeated := check(&observed, 2, 1); repeated != observed {
		t.Fatal("repeated comparison changed the result")
	}
	invalidPrior := observed
	invalidPrior.Count = -1
	check(&invalidPrior, 2, 2)
	invalidPrior = observed
	invalidPrior.Baseline = strings.Repeat("0", 64)
	check(&invalidPrior, 2, 3)
	if _, err := os.Stat(state); !os.IsNotExist(err) || previewRefs != 0 {
		t.Fatalf("background check touched catalog or previews: stat %v, preview requests %d", err, previewRefs)
	}

	if _, err := run([]string{res, state, "refresh"}); err != nil {
		t.Fatal(err)
	}
	acknowledged := check(&observed, 0, 4)
	if acknowledged.Baseline == observed.Baseline || previewRefs != 1 {
		t.Fatal("explicit refresh did not acknowledge the new pack list")
	}
	paths, err := os.ReadDir(state)
	if err != nil || len(paths) != 1 || paths[0].Name() != "catalog-"+seed {
		t.Fatalf("refresh acquired artwork or wrote unexpected state: %v %v", paths, err)
	}

	revision = unrelated
	artwork["README.md"] = "new metadata"
	checked := check(&acknowledged, 0, 5)
	revision = removed
	delete(artwork, newPath)
	delete(artwork, oldPath)
	artwork[modernFlatVariants[0]+"/PhotoCraft.png"] = "hidden legacy style"
	pruned := check(&checked, 0, 6)
	// A preview sheet beside the packs is not artwork. A WebP published next to an icon's PNG is an update of its pack.
	sheet, twinned := strings.Repeat("5", 40), strings.Repeat("6", 40)
	revision = sheet
	artwork["Craft-Icons-Artist/Preview.webp"] = "preview sheet"
	previewed := check(&pruned, 0, 7)
	revision = twinned
	artwork[strings.TrimSuffix(unchangedPath, ".png")+".webp"] = "same, as WebP"
	check(&previewed, 1, 8)
	if previewRefs != 1 {
		t.Fatal("background check refreshed previews")
	}
	last, err := openLibrary(res, state)
	if err != nil || last.latest.Revision != updated || len(last.latest.Packs) != 3 {
		t.Fatalf("background check applied a pack list: %+v %v", last, err)
	}
	offline = true
	if _, err := run([]string{res, state, "check-updates"}); err == nil {
		t.Fatal("offline check returned a badge result")
	}
	offline, truncated = false, true
	if _, err := run([]string{res, state, "check-updates"}); err == nil {
		t.Fatal("incomplete snapshot returned a badge result")
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
		name, seed, latest string
		cached             []string
		status, art        string
	}{
		{"no download", current, "", nil, "Download", ""},
		{"older download", current, "", []string{"Spark - Sliders"}, "Update available", "old"},
		{"exact among several downloads", current, "", []string{"Bolt - Knob", "Wand - Knob"}, "Downloaded", "latest"},
		{"old snapshot with new seed", current, old, []string{"Wand - Knob"}, "Downloaded", "latest"},
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
					v.Status != status || len(v.PreviousIDs) != 8 || !v.CanApps || v.CanFiles || !v.HasPreview {
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

// The Mac and Linux apps start from the catalog and preview index that the Windows tools write.
// A row this helper refuses would stop them, so the checked-in files must read here as they are staged.
func TestSeedCatalog(t *testing.T) {
	read := func(file string) []byte {
		t.Helper()
		b, err := os.ReadFile(filepath.Join("..", "..", filepath.FromSlash(file)))
		if os.IsNotExist(err) {
			t.Skipf("%s is not in this copy of the source", file)
		}
		if err != nil {
			t.Fatal(err)
		}
		return b
	}
	formats, seed := read("Windows/ProjectFileTypes.json"), read("Windows/PackCatalog.tsv")
	revision, previews := read("Windows/PreviewArtworkRevision.txt"), read("PackPreviews/catalog.tsv")
	l := &library{}
	if err := json.Unmarshal(formats, &l.formats); err != nil {
		t.Fatal(err)
	}
	if s, err := l.readSnapshot(seed); err != nil || len(s.Packs) == 0 {
		t.Fatalf("seed catalog: %v", err)
	}
	// Shared/prepare_packs.py writes the preview index as the revision followed by the index rows.
	index := strings.TrimSpace(string(revision)) + "\n" + string(previews)
	if _, p, err := readPreviews([]byte(index)); err != nil || len(p) == 0 {
		t.Fatalf("preview index: %v", err)
	}
}

// Only FileTypes art published as <App><sep>files.<ext>, as allFilesNames reads it, may draw file types outside
// ProjectFileTypes.json. A pack answers the same before and after it is downloaded, and an older download answers for the
// files AppFileIcons lists.
func TestUnlistedFileIconApps(t *testing.T) {
	res, state := t.TempDir(), t.TempDir()
	write := func(file, data string) {
		t.Helper()
		if err := atomic(file, []byte(data)); err != nil {
			t.Fatal(err)
		}
	}
	read := func(file string) string {
		b, _ := os.ReadFile(file)
		return string(b)
	}
	formats := `[{"Key":".tcraft","Application":"TextureCraft"},{"Key":".psd","Application":"PhotoCraft"}]`
	names := &library{}
	if err := json.Unmarshal([]byte(formats), &names.formats); err != nil {
		t.Fatal(err)
	}
	// Each revision publishes its files with their contents, and the test server serves them by revision.
	published := map[string]map[string]string{}
	publish := func(revision string, files map[string]string) string {
		t.Helper()
		published[revision] = files
		rows := []string{revision}
		for _, source := range slices.Sorted(maps.Keys(files)) {
			_, a, ok := names.identify(source)
			if !ok {
				t.Fatalf("not artwork: %s", source)
			}
			rows = append(rows, strings.Join([]string{blob(files[source]), a.File, source, checksum([]byte(files[source]))}, "\t"))
		}
		return strings.Join(rows, "\n")
	}
	old := client.Transport
	t.Cleanup(func() { client.Transport = old })
	client.Transport = serve(func(r *http.Request) (*http.Response, error) {
		// The path is /<owner>/<repository>/<revision>/<source>.
		if parts := strings.SplitN(r.URL.Path, "/", 5); len(parts) == 5 {
			if body, ok := published[parts[3]][parts[4]]; ok {
				return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}, nil
			}
		}
		return nil, fmt.Errorf("unexpected request %s", r.URL)
	})
	explicit, legacy, twins, mixed := "Craft-Icons-Artist/Explicit", "Craft-Icons-Mike22/Dark", "Craft-Icons-Artist/Twins", "Craft-Icons-Artist/Mixed"
	komplett, opted, ink, pop := "Craft-Icons-Komplett/Dunkel", "Craft-Icons-Komplett/Hell", "Craft-Icons-Zach/Ink", "Craft-Icons-Zach/Pop"
	first := map[string]string{}
	for _, source := range []string{
		// TextureCraft's app icon and its art for one listed format leave the answer to FileTypes/TextureCraft-files.png.
		explicit + "/TextureCraft.png", explicit + "/FileTypes/TextureCraft-files.png", explicit + "/FileTypes/tcraft.png",
		// Mike22 names its file art for a format, as in PhotoCraft-PSD, so it draws PhotoCraft's listed formats only.
		legacy + "/FileTypes/PhotoCraft-PSD.png",
		// A WebP and a PNG of explicit art. An app's name may be spelled any way identify reads it.
		twins + "/FileTypes/PhotoCraft-files.webp", twins + "/FileTypes/PhotoCraft-files.png", twins + "/FileTypes/ArtCraft Launcher-files.webp",
		// Explicit WebP art beside a PNG named for a format leaves PhotoCraft out. Each app answers for itself.
		mixed + "/FileTypes/PhotoCraft-files.webp", mixed + "/FileTypes/PhotoCraft-PSD.png", mixed + "/FileTypes/TextureCraft-files.png",
		// Komplett draws an app's files with the app's icon, which is not art in FileTypes, even when it is named -files.
		komplett + "/CADCraft-Dunkel.png", komplett + "/PhotoCraft-files.png", komplett + "/FileTypes/TextureCraft-files.png",
		// Explicit art in FileTypes beside the app's Komplett icon is mixed.
		opted + "/PhotoCraft-Hell.png", opted + "/FileTypes/PhotoCraft-files.png",
		// OmegaDarling's packs are listed under Zach, so each pair of folders is one pack.
		"Craft-Icons-OmegaDarling/Ink/FileTypes/PhotoCraft-files.png", ink + "/FileTypes/PhotoCraft-files.webp",
		"Craft-Icons-OmegaDarling/Pop/FileTypes/PhotoCraft-files.png", pop + "/FileTypes/PhotoCraft-PSD.png",
	} {
		first[source] = "first " + source
	}
	want := map[string][]string{explicit: {"TextureCraft"}, legacy: nil, twins: {"ArtCraftLauncher", "PhotoCraft"},
		mixed: {"TextureCraft"}, komplett: {"TextureCraft"}, opted: nil, ink: {"PhotoCraft"}, pop: nil}
	catalog, seed := filepath.Join(res, "Catalog"), strings.Repeat("1", 40)
	write(filepath.Join(catalog, "ProjectFileTypes.json"), formats)
	write(filepath.Join(catalog, "packs.tsv"), publish(seed, first))
	write(filepath.Join(catalog, "previews.tsv"), fmt.Sprintf("%s\n%s\tthumb.webp\t%s\t12\tTextureCraft", seed, explicit, checksum([]byte("RIFFxxxxWEBP"))))
	check := func(phase, status string, want map[string][]string) map[string]view {
		t.Helper()
		result, err := run([]string{res, state, "list"})
		if err != nil {
			t.Fatal(err)
		}
		packs := map[string]view{}
		for _, v := range result.([]view) {
			packs[v.ID] = v
		}
		for id, apps := range want {
			v := packs[id]
			b, _ := json.Marshal(v)
			if v.Status != status || !slices.Equal(v.UnlistedFileIconApps, apps) || strings.Contains(string(b), `"UnlistedFileIconApps"`) != (apps != nil) {
				t.Errorf("%s: %s should list %q: %s", phase, id, apps, b)
			}
			// A downloaded pack lists an app only with its art in AppFileIcons.
			for _, app := range v.UnlistedFileIconApps {
				if status != "Download" && read(v.AppFileIcons[app]) == "" {
					t.Errorf("%s: %s lists %s without its art: %s", phase, id, app, b)
				}
			}
		}
		return packs
	}
	// Before a download, the catalog answers. The app reads WebP, so downloads fetch the WebP of twins.
	t.Setenv("BETTERICON_WEBP_READABLE", "1")
	if packs := check("not downloaded", "Download", want); len(packs) != len(want) {
		t.Fatalf("packs: %+v", packs)
	}
	for id := range want {
		if _, err := run([]string{res, state, "acquire", id}); err != nil {
			t.Fatal(err)
		}
	}
	// A download keeps the answer. AppFileIcons still lists art named for a format and Komplett's icons, for listed formats.
	// Mixed's twins came down as the WebP alone, so it has no PNG to fall back on.
	packs := check("downloaded", "Downloaded", want)
	if read(packs[legacy].AppFileIcons["PhotoCraft"]) != first[legacy+"/FileTypes/PhotoCraft-PSD.png"] || len(packs[komplett].AppFileIcons) != 3 ||
		read(packs[mixed].AppFileIcons["PhotoCraft"]) != first[mixed+"/FileTypes/PhotoCraft-files.webp"] || len(packs[mixed].Fallbacks) != 0 {
		t.Fatalf("app-level art: %+v", packs)
	}
	// The next revision changes every file. Explicit's TextureCraft art is now named for a format, and Mike22's PhotoCraft art is explicit.
	renamed := map[string]string{
		explicit + "/FileTypes/TextureCraft-files.png": explicit + "/FileTypes/TextureCraft-TCRAFT.png",
		legacy + "/FileTypes/PhotoCraft-PSD.png":       legacy + "/FileTypes/PhotoCraft-files.png",
	}
	second := map[string]string{}
	for source := range first {
		second[source] = "second " + source
	}
	for before, after := range renamed {
		delete(second, before)
		second[after] = "second " + after
	}
	write(filepath.Join(state, "catalog-"+seed), publish(strings.Repeat("2", 40), second))
	// An older download answers for its own files, which AppFileIcons lists.
	check("update available", "Update available", want)
	for _, id := range []string{explicit, legacy} {
		if _, err := run([]string{res, state, "acquire", id}); err != nil {
			t.Fatal(err)
		}
	}
	others := maps.Clone(want)
	delete(others, explicit)
	delete(others, legacy)
	check("updated", "Downloaded", map[string][]string{explicit: nil, legacy: {"PhotoCraft"}})
	check("updated", "Update available", others)
	// A file renamed without a change keeps its download, whose signature leaves the name out. The catalog's name answers.
	third := maps.Clone(second)
	for before, after := range renamed {
		third[before] = third[after]
		delete(third, after)
	}
	write(filepath.Join(state, "catalog-"+seed), publish(strings.Repeat("3", 40), third))
	check("renamed", "Downloaded", map[string][]string{explicit: {"TextureCraft"}, legacy: nil})
	check("renamed", "Update available", others)
	// An app's name is read as identify reads it. After one ASCII space, underscore, dot or hyphen, the label "files" opts
	// in, in any case. TestAllFilesNames tries every separator.
	for source, opts := range map[string]bool{
		"FileTypes/TextureCraft-files.png": true, "FileTypes/texturecraft-FILES.webp": true, "FileTypes/TextureCraft files.PNG": true,
		"FileTypes/TextureCraft_Files.svg": true, "FileTypes/ArtCraft-Launcher.files.ico": true, "FileTypes/Craft Anything-files.png": true,
		"FileTypes/TextureCraft-TCRAFT.png": false, "FileTypes/TextureCraft-files-dark.png": false, "FileTypes/TextureCraft-filesystem.png": false,
		"FileTypes/TextureCraft - files.png": false, "FileTypes/TextureCraft-file.png": false, "TextureCraft-files.png": false,
	} {
		if _, a, ok := names.identify(explicit + "/" + source); !ok || a.allFiles() != opts {
			t.Errorf("%s opts in: %v, want %v (%+v %v)", source, a.allFiles(), opts, a, ok)
		}
	}
}

// The opt-in spelling is exact: the app's name as identify reads it, one ASCII space, underscore, dot or hyphen, then
// "files" in any case. No other character between them opts in, not even a Unicode space or an ASCII control character,
// so another implementation of the rule must not use a class such as \s, which matches more.
func TestAllFilesNames(t *testing.T) {
	l := &library{formats: []format{{Key: ".tcraft", Application: "TextureCraft"}}}
	folder := "Craft-Icons-Artist/Explicit/FileTypes/"
	// The examples in the comment on UnlistedFileIconApps.
	for name, opts := range map[string]bool{
		"PhotoCraft-files.png": true, "ArtCraft Launcher_files.webp": true, "texturecraft.FILES.svg": true,
		"PhotoCraft-PSD.png": false, "PhotoCraft - files.png": false,
	} {
		if _, a, ok := l.identify(folder + name); !ok || a.allFiles() != opts {
			t.Errorf("%s opts in: %v, want %v (%+v %v)", name, a.allFiles(), opts, a, ok)
		}
	}
	// Every ASCII character, and the Unicode spaces, between an app's name and "files".
	separators := []rune{0x85, 0xa0, 0x1680, 0x2000, 0x2007, 0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000}
	for r := rune(0); r < 0x80; r++ {
		separators = append(separators, r)
	}
	for key, spelling := range map[string]string{"TextureCraft": "TextureCraft", "ArtCraftLauncher": "ArtCraft _-Launcher"} {
		for _, r := range separators {
			name, want := spelling+string(r)+"files", strings.ContainsRune(" _.-", r)
			if got := (asset{Source: folder + name + ".png", Key: key, Document: true, AppFiles: true}).allFiles(); got != want {
				t.Errorf("%q opts in: %v, want %v", name, got, want)
			}
			// Read by identify, as in a catalog: a name that opts in is artwork, and artwork with any other separator does
			// not opt in.
			if _, a, ok := l.identify(folder + name + ".png"); (want && !ok) || (ok && (a.Key != key || a.allFiles() != want)) {
				t.Errorf("%q in a catalog: artwork %v, opts in %v, want %v (%+v)", name, ok, a.allFiles(), want, a)
			}
		}
	}
}

// readSeed reads the seed files that Shared/prepare_packs.py stages: the formats, the pack catalog, and a preview index
// made of the preview revision and the index rows. It skips the test in a copy of the source without them.
func readSeed(t *testing.T) (formats, catalog, previews string) {
	t.Helper()
	read := func(file string) string {
		t.Helper()
		b, err := os.ReadFile(filepath.Join("..", "..", filepath.FromSlash(file)))
		if os.IsNotExist(err) {
			t.Skipf("%s is not in this copy of the source", file)
		}
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	formats, catalog = read("Windows/ProjectFileTypes.json"), read("Windows/PackCatalog.tsv")
	return formats, catalog, strings.TrimSpace(read("Windows/PreviewArtworkRevision.txt")) + "\n" + read("PackPreviews/catalog.tsv")
}

// unlistedByRule restates the rule UnlistedFileIconApps follows, over a catalog's rows, reading each file's published name
// from the third column. An app's app-level art is the art identify reads as the app's in FileTypes and, in a Komplett
// pack, the app's icon. The app opts in when every one of those files is in FileTypes and its name goes on, after the
// app's name as identify spells it, with one ASCII space, underscore, dot or hyphen and the label "files" in any case.
// It returns, by pack, the apps that opt in and the number of apps with app-level art.
func unlistedByRule(t *testing.T, l *library, catalog string) (map[string][]string, map[string]int) {
	t.Helper()
	type item struct{ pack, app string }
	seen, declined := map[item]bool{}, map[item]bool{}
	spellings := map[string]*regexp.Regexp{}
	for _, row := range lines([]byte(catalog))[1:] {
		fields := strings.Split(row, "\t")
		if len(fields) != 4 {
			t.Fatalf("not a catalog row: %q", row)
		}
		source := fields[2]
		p, a, ok := l.identify(source)
		if !ok {
			t.Fatalf("not artwork: %s", source)
		}
		if !a.AppFiles && (a.Document || !strings.HasPrefix(p.ID, documentPacks)) {
			continue
		}
		if spellings[a.Key] == nil {
			spellings[a.Key] = regexp.MustCompile("(?i)^" + craftSpelling(a.Key))
		}
		stem := strings.TrimSuffix(path.Base(source), path.Ext(source))
		label := strings.TrimPrefix(stem, spellings[a.Key].FindString(stem))
		k := item{p.ID, a.Key}
		seen[k] = true
		if path.Base(path.Dir(source)) != "FileTypes" || len(label) < 2 || !strings.ContainsRune(" _.-", rune(label[0])) ||
			!strings.EqualFold(label[1:], "files") {
			declined[k] = true
		}
	}
	apps, counts := map[string][]string{}, map[string]int{}
	for k := range seen {
		counts[k.pack]++
		if !declined[k] {
			apps[k.pack] = append(apps[k.pack], k.app)
		}
	}
	for _, list := range apps {
		slices.Sort(list)
	}
	return apps, counts
}

// listSeedStates stages a catalog, with the seed's formats and preview index, as Shared/prepare_packs.py stages the seed,
// and lists it with nothing downloaded, with every pack downloaded, and with older downloads of every pack. In each
// state, each pack lists the apps unlistedByRule gives, and only a pack that lists some has the key in its JSON. While
// the rule gives no app, the list is the one from before the field existed. A downloaded pack has one AppFileIcons entry
// for each app with app-level art. It returns the apps the rule gives, by pack.
func listSeedStates(t *testing.T, formats, catalog, previews string) map[string][]string {
	t.Helper()
	res, state := t.TempDir(), t.TempDir()
	write := func(file, data string) {
		t.Helper()
		if err := atomic(file, []byte(data)); err != nil {
			t.Fatal(err)
		}
	}
	write(filepath.Join(res, "Catalog", "ProjectFileTypes.json"), formats)
	write(filepath.Join(res, "Catalog", "packs.tsv"), catalog)
	write(filepath.Join(res, "Catalog", "previews.tsv"), previews)
	l, err := openLibrary(res, state)
	if err != nil {
		t.Fatal(err)
	}
	want, apps := unlistedByRule(t, l, catalog)
	// Each pack is downloaded with the files the catalog lists, or with older files of the same names.
	download := func(older bool) {
		for id, p := range l.seed.Packs {
			saved := pack{Assets: slices.Clone(p.Assets)}
			var rows []string
			for i, a := range saved.Assets {
				if older {
					a.Blob = blob("older " + a.File)
					saved.Assets[i] = a
				}
				rows = append(rows, strings.Join([]string{a.Blob, a.File, a.Source, a.Hash}, "\t"))
			}
			for _, a := range saved.Assets {
				write(filepath.Join(state, "downloads", saved.signature(), filepath.FromSlash(a.File)), a.Source)
			}
			write(filepath.Join(state, "acquired", checksum([]byte(id))), l.seed.Revision+"\n"+strings.Join(rows, "\n"))
		}
	}
	for _, status := range []string{"Download", "Downloaded", "Update available"} {
		if status != "Download" {
			download(status == "Update available")
		}
		result, err := run([]string{res, state, "list"})
		if err != nil {
			t.Fatal(err)
		}
		packs := map[string]view{}
		for _, v := range result.([]view) {
			packs[v.ID] = v
		}
		ids := slices.Collect(maps.Keys(packs))
		for id := range want {
			if _, listed := packs[id]; !listed {
				ids = append(ids, id)
			}
		}
		slices.Sort(ids)
		for _, id := range ids {
			v := packs[id]
			art := 0
			if status != "Download" {
				art = apps[id]
			}
			if v.Status != status || !slices.Equal(v.UnlistedFileIconApps, want[id]) || len(v.AppFileIcons) != art {
				t.Errorf("%s: %s is %q and lists %q, with %d apps in AppFileIcons; want %q and %d", status, id, v.Status,
					v.UnlistedFileIconApps, len(v.AppFileIcons), want[id], art)
			}
			if b, _ := json.Marshal(v); strings.Contains(string(b), `"UnlistedFileIconApps"`) != (len(want[id]) > 0) {
				t.Errorf("%s: %s has the key without listing an app, or the other way round: %s", status, id, b)
			}
			for _, app := range v.UnlistedFileIconApps {
				if status != "Download" && v.AppFileIcons[app] == "" {
					t.Errorf("%s: %s lists %s without its art", status, id, app)
				}
			}
		}
	}
	return want
}

// The checked-in seed lists, in every download state, what the rule gives for its rows. Today none of its art is named
// <App><sep>files: Mike22 names its file art for formats, and Komplett draws files with its app icons. So no pack lists
// an app, and the list has no UnlistedFileIconApps key, as before the field existed. A later seed with such art lists
// those apps.
func TestSeedUnlistedFileIconApps(t *testing.T) {
	formats, catalog, previews := readSeed(t)
	want := listSeedStates(t, formats, catalog, previews)
	t.Logf("%d of the seed's packs opt apps in: %v", len(want), want)
}

// The seed's check keeps working once published packs opt in. Here the seed gains new packs in folders it does not have,
// and the first app outside Komplett whose FileTypes art does not opt in, Mike22's today, gets the explicit name in each
// of its files, while the catalog's own name for them stays the same.
func TestSeedUnlistedFileIconAppsOptIn(t *testing.T) {
	formats, catalog, previews := readSeed(t)
	l := &library{}
	if err := json.Unmarshal([]byte(formats), &l.formats); err != nil {
		t.Fatal(err)
	}
	before, _ := unlistedByRule(t, l, catalog)
	rows := lines([]byte(catalog))
	renamed, renamedApp := "", ""
	for i, row := range rows[1:] {
		f := strings.Split(row, "\t")
		p, a, _ := l.identify(f[2])
		if renamed == "" && a.AppFiles && !strings.HasPrefix(p.ID, documentPacks) && !slices.Contains(before[p.ID], a.Key) {
			renamed, renamedApp = p.ID, a.Key
		}
		if a.AppFiles && p.ID == renamed && a.Key == renamedApp {
			f[2] = path.Join(path.Dir(f[2]), path.Base(f[1]))
			rows[i+1] = strings.Join(f, "\t")
		}
	}
	explicit, komplett, zach := "Craft-Icons-TestFixture/Explicit", "Craft-Icons-Komplett/TestFixture", "Craft-Icons-Zach/TestFixture"
	fixtures := map[string][]string{explicit: {"ArtCraftLauncher", "TextureCraft"}, komplett: {"TextureCraft"}, zach: {"PhotoCraft"}}
	for _, source := range []string{
		// The guide's example beside the app's icon, and both formats of ArtCraft Launcher's art in two spellings.
		explicit + "/TextureCraft.png", explicit + "/FileTypes/TextureCraft-files.png",
		explicit + "/FileTypes/ArtCraft Launcher_FILES.webp", explicit + "/FileTypes/ArtCraft-Launcher.files.png",
		// Explicit art beside art named for a format does not opt in, nor does a second separator or a longer label.
		explicit + "/FileTypes/PhotoCraft-files.webp", explicit + "/FileTypes/PhotoCraft-PSD.png",
		explicit + "/FileTypes/SolidCraft - files.png", explicit + "/FileTypes/DeckCraft-files-dark.png",
		// A Komplett app icon is app-level art outside FileTypes, even when it is named -files.
		komplett + "/CADCraft-TestFixture.png", komplett + "/FileTypes/CADCraft-files.png",
		komplett + "/PhotoCraft-files.png", komplett + "/FileTypes/TextureCraft-files.png",
		// OmegaDarling's folder and Zach's of the same name make one pack.
		"Craft-Icons-OmegaDarling/TestFixture/FileTypes/PhotoCraft-files.png", zach + "/FileTypes/PhotoCraft-files.webp",
		"Craft-Icons-OmegaDarling/TestFixture/FileTypes/FilmCraft-files.png", zach + "/FileTypes/FilmCraft-FCPROJ.webp",
	} {
		_, a, ok := l.identify(source)
		if !ok {
			t.Fatalf("not artwork: %s", source)
		}
		rows = append(rows, strings.Join([]string{blob(source), a.File, source, checksum([]byte(source))}, "\t"))
	}
	want := listSeedStates(t, formats, strings.Join(rows, "\n"), previews)
	for id, apps := range fixtures {
		if !slices.Equal(want[id], apps) {
			t.Errorf("%s: the rule gives %q, want %q", id, want[id], apps)
		}
	}
	switch {
	case renamed == "":
		t.Log("the seed has no FileTypes art outside Komplett that does not opt in, so nothing was renamed")
	case !slices.Contains(want[renamed], renamedApp):
		t.Errorf("%s: %s's renamed art does not opt in: %q", renamed, renamedApp, want[renamed])
	default:
		t.Logf("%s: %s's renamed art opts in", renamed, renamedApp)
	}
}
