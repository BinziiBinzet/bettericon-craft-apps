package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

type format struct {
	Key, Application string
	Aliases          []string
}
type asset struct {
	Blob, File, Source, Hash, Key string
	Document                      bool
}
type pack struct {
	ID, Name, Author, Revision string
	Assets                     []asset
}
type preview struct {
	File, Hash string
	Length     int
	Names      string
}
type snapshot struct {
	Revision string
	Packs    map[string]pack
}
type library struct {
	resources, state string
	formats          []format
	seed, latest     snapshot
	previewRev       string
	previews         map[string]preview
	bundled          bool
}
type view struct {
	ID, Name, Author, Status      string
	Icons, FileIcons              map[string]string
	CanApps, CanFiles, HasPreview bool
}

var hex40 = regexp.MustCompile("^[0-9a-f]{40}$")
var hex64 = regexp.MustCompile("^[0-9a-f]{64}$")
var previewName = regexp.MustCompile("^[A-Za-z0-9-]+[.]webp$")
var badPart = regexp.MustCompile("[<>:\"/\\\\|?*\\x00-\\x1f]|[. ]$")
var excluded = regexp.MustCompile("(?i)(^|[\\W_])(uninstall|uninstaller|remove|setup|help|documentation)([\\W_]|$)")
var craftNames = strings.Fields("AniCraft ArtCraftLauncher CADCraft CraftAnything DeckCraft DesignCraft EffectCraft FigCraft FilmCraft GridCraft LightCraft MailCraft MaterialCraft PdfCraft PhotoCraft SolidCraft SoundCraft TextureCraft VectorCraft WordCraft")
var craftPatterns = func() []*regexp.Regexp {
	var patterns []*regexp.Regexp
	for _, name := range craftNames {
		s := strings.ReplaceAll(strings.ReplaceAll(name, "ArtCraftLauncher", "ArtCraft[[:space:]_-]*Launcher"), "CraftAnything", "Craft[[:space:]_-]*Anything")
		patterns = append(patterns, regexp.MustCompile("(?i)^"+s+"(?:[[:space:]_.-].*)?$"))
	}
	return patterns
}()

func checksum(b []byte) string { v := sha256.Sum256(b); return hex.EncodeToString(v[:]) }
func (l *library) identify(source string) (pack, asset, bool) {
	parts := strings.Split(source, "/")
	if len(parts) < 2 || len(parts) > 4 || !strings.HasPrefix(parts[0], "Craft-Icons-") || len(parts[0]) <= 12 {
		return pack{}, asset{}, false
	}
	for _, part := range parts {
		if part == "" || part == "." || part == ".." || len([]rune(part)) > 120 || badPart.MatchString(part) {
			return pack{}, asset{}, false
		}
	}
	filename := parts[len(parts)-1]
	suffix := path.Ext(filename)
	ext := strings.ToLower(suffix)
	if ext != ".png" && ext != ".svg" && ext != ".ico" {
		return pack{}, asset{}, false
	}
	stem := strings.TrimSuffix(filename, suffix)
	doc := parts[len(parts)-2] == "FileTypes"
	depth := len(parts)
	key := ""
	if doc {
		depth--
		k := "." + strings.ToLower(strings.TrimLeft(stem, "."))
		for _, f := range l.formats {
			if f.Key == k {
				key = k
				break
			}
		}
	} else if !excluded.MatchString(stem) {
		for i, re := range craftPatterns {
			if re.MatchString(stem) {
				key = craftNames[i]
				break
			}
		}
	}
	if key == "" || depth < 2 || depth > 3 {
		return pack{}, asset{}, false
	}
	name := "Root"
	if depth == 3 {
		name = parts[1]
	}
	group := parts[0]
	author := strings.TrimPrefix(group, "Craft-Icons-")
	if group == "Craft-Icons-OmegaDarling" {
		group = "Craft-Icons-Zach"
	}
	canonical := path.Join(path.Dir(source), strings.TrimPrefix(key, ".")+ext)
	return pack{ID: group + "/" + name, Name: name, Author: author}, asset{Source: source, Key: key, File: canonical, Document: doc}, true
}
func lines(b []byte) []string {
	return strings.Split(strings.TrimSpace(strings.ReplaceAll(string(b), "\r\n", "\n")), "\n")
}
func (l *library) readSnapshot(b []byte) (snapshot, error) {
	rows := lines(b)
	s := snapshot{Revision: rows[0], Packs: map[string]pack{}}
	seen := map[string]bool{}
	if !hex40.MatchString(s.Revision) || len(rows) < 2 || len(rows) > 20000 {
		return s, errors.New("Invalid icon pack catalog")
	}
	for _, row := range rows[1:] {
		fields := strings.Split(row, "\t")
		if len(fields) != 4 || !hex40.MatchString(fields[0]) || (fields[3] != "-" && !hex64.MatchString(fields[3])) {
			return s, errors.New("Invalid catalog checksums")
		}
		p, a, ok := l.identify(fields[2])
		k := strings.ToLower(fields[1])
		if !ok || a.File != fields[1] || seen[k] {
			return s, fmt.Errorf("Invalid or duplicate artwork: %s", fields[1])
		}
		seen[k] = true
		if existing, ok := s.Packs[p.ID]; ok {
			p = existing
		}
		a.Blob = fields[0]
		a.Hash = fields[3]
		p.Revision = s.Revision
		p.Assets = append(p.Assets, a)
		s.Packs[p.ID] = p
	}
	return s, nil
}
func readPreviews(b []byte) (string, map[string]preview, error) {
	rows := lines(b)
	index := map[string]preview{}
	if len(rows) < 2 || len(rows) > 10000 || !hex40.MatchString(rows[0]) {
		return "", nil, errors.New("Invalid preview index")
	}
	for _, row := range rows[1:] {
		f := strings.Split(row, "\t")
		if len(f) != 5 || !strings.HasPrefix(f[0], "Craft-Icons-") || !previewName.MatchString(f[1]) || !hex64.MatchString(f[2]) || f[4] == "" || len(strings.Split(f[4], ",")) > 3 {
			return "", nil, errors.New("Invalid preview entry")
		}
		size, err := strconv.Atoi(f[3])
		_, exists := index[f[0]]
		if err != nil || size <= 0 || size > 65536 || exists {
			return "", nil, errors.New("Invalid preview metadata")
		}
		index[f[0]] = preview{f[1], f[2], size, f[4]}
	}
	return rows[0], index, nil
}
func openLibrary(resources, state string) (*library, error) {
	l := &library{resources: resources, state: state}
	folder := filepath.Join(resources, "Catalog")
	b, err := os.ReadFile(filepath.Join(folder, "ProjectFileTypes.json"))
	if err != nil {
		return nil, err
	}
	if err = json.Unmarshal(b, &l.formats); err != nil {
		return nil, err
	}
	b, err = os.ReadFile(filepath.Join(folder, "packs.tsv"))
	if err != nil {
		return nil, err
	}
	l.seed, err = l.readSnapshot(b)
	if err != nil {
		return nil, err
	}
	l.latest = l.seed
	if b, e := os.ReadFile(filepath.Join(state, "catalog-"+l.seed.Revision)); e == nil {
		if s, e := l.readSnapshot(b); e == nil {
			l.latest = s
		}
	}
	b, err = os.ReadFile(filepath.Join(folder, "previews.tsv"))
	if err != nil {
		return nil, err
	}
	l.previewRev, l.previews, err = readPreviews(b)
	if err != nil {
		return nil, err
	}
	if b, e := os.ReadFile(filepath.Join(state, "previews-"+l.seed.Revision)); e == nil {
		if r, p, e := readPreviews(b); e == nil {
			l.previewRev = r
			l.previews = p
		}
	}
	edition, err := os.ReadFile(filepath.Join(folder, "edition"))
	if err != nil {
		return nil, err
	}
	l.bundled = strings.TrimSpace(string(edition)) == "Bundled"
	return l, nil
}
func (p pack) signature() string {
	keys := make([]string, 0, len(p.Assets))
	for _, a := range p.Assets {
		keys = append(keys, a.File+"\t"+a.Blob)
	}
	sort.Strings(keys)
	return checksum([]byte(strings.Join(keys, "\n")))
}
func (l *library) filesPresent(p pack) bool {
	root := filepath.Join(l.state, "downloads", p.signature())
	for _, a := range p.Assets {
		info, err := os.Lstat(filepath.Join(root, a.File))
		if err != nil || !info.Mode().IsRegular() || info.Size() == 0 {
			return false
		}
	}
	return true
}

func (l *library) acquired() map[string]pack {
	saved := map[string]pack{}
	entries, _ := os.ReadDir(filepath.Join(l.state, "acquired"))
	for _, entry := range entries {
		if !hex64.MatchString(entry.Name()) {
			continue
		}
		b, e := os.ReadFile(filepath.Join(l.state, "acquired", entry.Name()))
		if e != nil {
			continue
		}
		s, e := l.readSnapshot(b)
		if e != nil || len(s.Packs) != 1 {
			continue
		}
		for id, p := range s.Packs {
			if checksum([]byte(id)) == entry.Name() && l.filesPresent(p) {
				saved[id] = p
			}
		}
	}
	return saved
}
func (l *library) list() []view {
	saved := l.acquired()
	available := map[string]pack{}
	if l.bundled {
		for id, p := range l.seed.Packs {
			available[id] = p
		}
	}
	for id, p := range saved {
		available[id] = p
	}
	for id, p := range l.latest.Packs {
		available[id] = p
	}
	result := make([]view, 0, len(available))
	for id, p := range available {
		v := view{ID: id, Name: p.Name, Author: p.Author, Status: "Download", Icons: map[string]string{}, FileIcons: map[string]string{}}
		_, v.HasPreview = l.previews[id]
		for _, a := range p.Assets {
			if a.Document {
				v.CanFiles = true
			} else {
				v.CanApps = true
				for _, f := range l.formats {
					if a.Key == f.Application {
						v.CanFiles = true
						break
					}
				}
			}
		}
		local, ok := saved[id]
		root := ""
		seed, included := l.seed.Packs[id]
		matches := l.bundled && included && seed.signature() == p.signature()
		if ok && (local.signature() == p.signature() || !matches) {
			root = filepath.Join(l.state, "downloads", local.signature())
			v.Status = "Downloaded"
		} else if l.bundled && included {
			local = seed
			root = filepath.Join(l.resources, "Packs")
			v.Status = "Included"
		}
		if root != "" {
			if local.signature() != p.signature() {
				v.Status = "Update available"
			}
			// Prefer PNG when an artist supplies several formats.
			for _, ext := range []string{".ico", ".svg", ".png"} {
				for _, a := range local.Assets {
					if path.Ext(a.File) != ext {
						continue
					}
					files := v.Icons
					if a.Document {
						files = v.FileIcons
					}
					files[a.Key] = filepath.Join(root, filepath.FromSlash(a.File))
				}
			}
		}
		result = append(result, v)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].ID < result[j].ID })
	return result
}
