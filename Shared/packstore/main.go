package main

import (
	"bytes"
	"crypto/sha1"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

const api = "https://api.github.com/repos/BinziiBinzet/bettericon-craft-apps/git"
const raw = "https://raw.githubusercontent.com/BinziiBinzet/bettericon-craft-apps/"

var client = &http.Client{Timeout: 45 * time.Second}

func fetch(address string, limit int64) ([]byte, error) {
	req, err := http.NewRequest("GET", address, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "BetterIcon-pack-catalog")
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("Artwork service returned HTTP %d", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, limit+1))
	if int64(len(data)) > limit {
		return nil, errors.New("Artwork service response exceeds its limit")
	}
	return data, err
}
func rawURL(rev, file string) string {
	u := url.URL{Path: file}
	return raw + rev + "/" + u.EscapedPath()
}
func atomic(file string, b []byte) error {
	dir := filepath.Dir(file)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".tmp-")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	_, err = tmp.Write(b)
	closeErr := tmp.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(tmp.Name(), file)
}
func head(branch string) (string, error) {
	var r struct{ Object struct{ SHA, Type string } }
	b, e := fetch(api+"/ref/heads/"+branch, 65536)
	if e != nil {
		return "", e
	}
	e = json.Unmarshal(b, &r)
	if e != nil || r.Object.Type != "commit" || !hex40.MatchString(r.Object.SHA) {
		return "", errors.New("Invalid artwork revision")
	}
	return r.Object.SHA, nil
}
func (l *library) refreshPreviews() error {
	rev, err := head("artwork/pack-hover-previews-v1")
	if err != nil {
		return err
	}
	if rev == l.previewRev {
		return nil
	}
	b, err := fetch(rawURL(rev, "PackPreviews/catalog.tsv"), 2<<20)
	if err != nil {
		return err
	}
	b = append([]byte(rev+"\n"), b...)
	if _, _, e := readPreviews(b); e != nil {
		return e
	}
	return atomic(filepath.Join(l.state, "previews-"+l.seed.Revision), b)
}
func (l *library) fetchPublishedSnapshot(revision string) (snapshot, []byte, error) {
	b, err := fetch(api+"/trees/"+revision+"?recursive=1", 16<<20)
	if err != nil {
		return snapshot{}, nil, err
	}
	var tree struct {
		Truncated *bool
		Tree      []struct {
			Path, SHA, Type, Mode string
			Size                  int64
		}
	}
	if json.Unmarshal(b, &tree) != nil || tree.Truncated == nil || *tree.Truncated || len(tree.Tree) == 0 {
		return snapshot{}, nil, errors.New("The published pack list was incomplete")
	}
	var rows []string
	for _, row := range tree.Tree {
		if row.Type != "blob" || (row.Mode != "100644" && row.Mode != "100755") {
			continue
		}
		_, a, ok := l.identify(row.Path)
		if !ok {
			continue
		}
		if row.Size < 1 || row.Size > 16<<20 {
			return snapshot{}, nil, errors.New("Invalid published artwork size")
		}
		rows = append(rows, strings.Join([]string{row.SHA, a.File, row.Path, "-"}, "\t"))
	}
	sort.Strings(rows)
	data := []byte(revision + "\n" + strings.Join(rows, "\n") + "\n")
	published, err := l.readSnapshot(data)
	return published, data, err
}

type updateCheck struct {
	Revision string `json:"revision"`
	Baseline string `json:"baseline"`
	Count    int    `json:"count"`
}

func (l *library) checkUpdates(previous updateCheck) (updateCheck, error) {
	revision, err := head("main")
	if err != nil {
		return updateCheck{}, err
	}
	known := make(map[string]string, len(l.latest.Packs))
	rows := make([]string, 0, len(l.latest.Packs))
	for id, p := range l.latest.Packs {
		signature := p.signature()
		known[id] = signature
		rows = append(rows, id+"\t"+signature)
	}
	sort.Strings(rows)
	result := updateCheck{Revision: revision, Baseline: checksum([]byte(strings.Join(rows, "\n")))}
	if revision == l.latest.Revision {
		return result, nil
	}
	if previous.Revision == revision && previous.Baseline == result.Baseline && previous.Count >= 0 && previous.Count < 20000 {
		return previous, nil
	}
	published, _, err := l.fetchPublishedSnapshot(revision)
	if err != nil {
		return updateCheck{}, err
	}
	for id, p := range l.visiblePacks(published.Packs) {
		// The picker may retain a downloaded Modern Flat when it is no longer published.
		if _, present := published.Packs[id]; present && known[id] != p.signature() {
			result.Count++
		}
	}
	return result, nil
}

func (l *library) refresh() error {
	rev, err := head("main")
	if err != nil {
		return err
	}
	if rev != l.latest.Revision {
		_, data, e := l.fetchPublishedSnapshot(rev)
		if e != nil {
			return e
		}
		if e = atomic(filepath.Join(l.state, "catalog-"+l.seed.Revision), data); e != nil {
			return e
		}
	}
	if err = l.refreshPreviews(); err != nil {
		return fmt.Errorf("Pack list refreshed. Preview index unavailable: %w", err)
	}
	return nil
}
func sameBlob(b []byte, a asset) bool {
	h := sha1.New()
	fmt.Fprintf(h, "blob %d%c", len(b), 0)
	h.Write(b)
	return fmt.Sprintf("%x", h.Sum(nil)) == a.Blob && (a.Hash == "-" || checksum(b) == a.Hash)
}

// fetchArtwork reads one published file. Tests set BETTERICON_PACK_SOURCE to a local folder laid out like the published
// artwork tree, so no request reaches GitHub; the file is checked against its checksum either way.
func fetchArtwork(revision, source string) ([]byte, error) {
	local := os.Getenv("BETTERICON_PACK_SOURCE")
	if local == "" {
		return fetch(rawURL(revision, source), 16<<20)
	}
	b, err := os.ReadFile(filepath.Join(local, filepath.FromSlash(source)))
	if err != nil {
		return nil, errors.New("Artwork is missing from the local pack source")
	}
	if len(b) > 16<<20 {
		return nil, errors.New("Artwork service response exceeds its limit")
	}
	return b, nil
}
func (l *library) acquire(id string) error {
	p, ok := l.latest.Packs[id]
	if !ok {
		return errors.New("This pack is no longer available to download")
	}
	dir := filepath.Join(l.state, "downloads")
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	stage, err := os.MkdirTemp(dir, ".loading-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(stage)
	final := filepath.Join(dir, p.signature())
	// The receipt keeps every row, so the pack's signature, folder and update check stay those of the whole catalog entry.
	rows := []string{p.Revision}
	for _, a := range p.Assets {
		rows = append(rows, strings.Join([]string{a.Blob, a.File, a.Source, a.Hash}, "\t"))
	}
	// One twin per icon, as the app reads WebP or not. A file the pack's folder already holds is not fetched again.
	wanted := p.downloadAssets(webpReadable())
	for _, a := range wanted {
		if b, e := os.ReadFile(filepath.Join(final, a.File)); e == nil && sameBlob(b, a) {
			continue
		}
		b, e := fetchArtwork(p.Revision, a.Source)
		if e != nil {
			return e
		}
		if !sameBlob(b, a) {
			return fmt.Errorf("Artwork checksum differs: %s", a.File)
		}
		if e = atomic(filepath.Join(stage, a.File), b); e != nil {
			return e
		}
	}
	if err = os.Rename(stage, final); err != nil {
		// Reuse a concurrent complete download, or repair missing files from the verified staging directory.
		info, statErr := os.Lstat(final)
		if statErr != nil || !info.IsDir() {
			return err
		}
		for _, a := range wanted {
			target := filepath.Join(final, a.File)
			if b, e := os.ReadFile(target); e == nil && sameBlob(b, a) {
				continue
			}
			if err := os.MkdirAll(filepath.Dir(target), 0700); err != nil {
				return err
			}
			if err := os.Rename(filepath.Join(stage, a.File), target); err != nil {
				return err
			}
		}
	}
	return atomic(filepath.Join(l.state, "acquired", checksum([]byte(id))), []byte(strings.Join(rows, "\n")+"\n"))
}
func (l *library) thumbnail(id string) (string, error) {
	p, ok := l.previews[id]
	if !ok {
		return "", nil
	}
	target := filepath.Join(l.state, "previews", p.Hash+".webp")
	valid := func(b []byte) bool {
		return len(b) == p.Length && len(b) >= 12 && bytes.Equal(b[:4], []byte("RIFF")) && bytes.Equal(b[8:12], []byte("WEBP")) && checksum(b) == p.Hash
	}
	for _, file := range []string{filepath.Join(l.resources, "Previews", p.File), target} {
		if b, e := os.ReadFile(file); e == nil && valid(b) {
			return file, nil
		}
	}
	b, err := fetch(rawURL(l.previewRev, "PackPreviews/"+p.File), 65536)
	if err != nil {
		return "", err
	}
	if !valid(b) {
		return "", errors.New("Preview checksum differs")
	}
	if err = atomic(target, b); err != nil {
		return "", err
	}
	return target, nil
}
func run(args []string) (any, error) {
	if len(args) < 3 {
		return nil, errors.New("Expected resources, cache and command")
	}
	l, err := openLibrary(args[0], args[1])
	if err != nil {
		return nil, err
	}
	switch args[2] {
	case "check-updates":
		var previous updateCheck
		switch len(args) {
		case 3:
		case 6:
			if count, e := strconv.Atoi(args[5]); e == nil {
				previous = updateCheck{Revision: args[3], Baseline: args[4], Count: count}
			}
		default:
			return nil, errors.New("Expected previous revision, baseline and count")
		}
		return l.checkUpdates(previous)
	case "refresh":
		err = l.refresh()
		if err == nil {
			l, err = openLibrary(args[0], args[1])
		}
	case "acquire":
		if len(args) != 4 {
			return nil, errors.New("Missing pack")
		}
		err = l.acquire(l.currentID(args[3]))
	case "preview":
		// "files" asks for the strip of the pack's file type artwork.
		if len(args) != 4 && (len(args) != 5 || args[4] != "files") {
			return nil, errors.New("Missing preview")
		}
		key := l.currentID(args[3])
		if len(args) == 5 {
			key += fileSet
		}
		return l.thumbnail(key)
	case "list":
	default:
		return nil, errors.New("Unknown catalog operation")
	}
	if err != nil {
		return nil, err
	}
	return l.list(), nil
}
func main() {
	out, err := run(os.Args[1:])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if err = json.NewEncoder(os.Stdout).Encode(out); err != nil {
		os.Exit(1)
	}
}
