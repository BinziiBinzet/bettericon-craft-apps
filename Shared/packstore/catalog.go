package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
)

type format struct {
	Key, Application string
	Aliases          []string
}
// A Document draws one file format. AppFiles draws every file type its app opens.
type asset struct {
	Blob, File, Source, Hash, Key string
	Document, AppFiles            bool
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
}
type view struct {
	ID, Name, Author, Status       string
	PreviousIDs                    []string `json:",omitempty"`
	Icons, FileIcons, AppFileIcons map[string]string
	CanApps, CanFiles, HasPreview  bool
	// The artwork in a pack's FileTypes folder has a strip of its own for the file type list.
	HasFilePreview bool
	// A file chosen in Icons, FileIcons or AppFileIcons lists one file for each other format of its item, best first.
	Fallbacks map[string][]string `json:",omitempty"`
	// The ArtCraft apps, sorted, whose AppFileIcons art may also draw a file type outside ProjectFileTypes.json when the
	// app is that type's real default opener. Only art in a FileTypes folder whose published name is <App><sep>files.<ext>
	// opts in: the app's name as identify reads it, exactly one ASCII space, underscore, dot or hyphen, then "files", with
	// letters in any case, as in PhotoCraft-files.png, "ArtCraft Launcher_files.webp" or texturecraft.FILES.svg.
	// allFilesNames has the exact pattern. Art named for a format, such as FileTypes/PhotoCraft-PSD.png, and a Komplett
	// pack's app icons stay with the app's listed formats, although AppFileIcons lists them too. When an app's art comes
	// in several files, such as a WebP and a PNG, every one must be named so. A pack that is not downloaded yet tells what
	// its published files will give.
	UnlistedFileIconApps []string `json:",omitempty"`
}

// The preview index lists the strip for a pack's file type artwork under the pack's ID and this suffix.
const fileSet = "/FileTypes"
const modernFlat = "Craft-Icons-VimiummuimiV/Modern Flat"

// Komplett draws each app as a document. Its packs theme the files those apps open.
const documentPacks = "Craft-Icons-Komplett/"

var modernFlatVariants = func() []string {
	var ids []string
	for _, effect := range []string{"Wand", "Bolt", "Spark", "Sliders"} {
		for _, sound := range []string{"Knob", "Sliders"} {
			ids = append(ids, modernFlat+" - "+effect+" - "+sound)
		}
	}
	return ids
}()

var hex40 = regexp.MustCompile("^[0-9a-f]{40}$")
var hex64 = regexp.MustCompile("^[0-9a-f]{64}$")
var previewName = regexp.MustCompile("^[A-Za-z0-9-]+[.]webp$")
var badPart = regexp.MustCompile("[<>:\"/\\\\|?*\\x00-\\x1f]|[. ]$")
var excluded = regexp.MustCompile("(?i)(^|[\\W_])(uninstall|uninstaller|remove|setup|help|documentation)([\\W_]|$)")
var craftNames = strings.Fields("AniCraft ArtCraftLauncher CADCraft CraftAnything DeckCraft DesignCraft EffectCraft FigCraft FilmCraft GridCraft LightCraft MailCraft MaterialCraft PdfCraft PhotoCraft SolidCraft SoundCraft TextureCraft VectorCraft WordCraft")

// craftSpelling is the pattern of an app's name as artists write it. ArtCraft Launcher and Craft Anything may be split by
// spaces, underscores or hyphens.
func craftSpelling(name string) string {
	return strings.ReplaceAll(strings.ReplaceAll(name, "ArtCraftLauncher", "ArtCraft[[:space:]_-]*Launcher"), "CraftAnything", "Craft[[:space:]_-]*Anything")
}

var craftPatterns = func() []*regexp.Regexp {
	var patterns []*regexp.Regexp
	for _, name := range craftNames {
		patterns = append(patterns, regexp.MustCompile("(?i)^"+craftSpelling(name)+"(?:[[:space:]_.-].*)?$"))
	}
	return patterns
}()

// allFilesNames has each app's pattern for the published name, without its extension, of FileTypes art that draws every
// file type the app opens, listed or not. Ignoring case, and in any regular expression syntax, it is ^<App>[ _.-]files$.
// <App> is the app's name as craftName reads it: the name itself, or ArtCraft[ _-]*Launcher and Craft[ _-]*Anything for
// the two names artists may split. So exactly one ASCII space, underscore, dot or hyphen comes before the label "files".
// A format label, as in PhotoCraft-PSD, does not match, nor does a second separator, as in "PhotoCraft - files". Windows
// reads the catalog's source names itself and must match the same names.
var allFilesNames = func() map[string]*regexp.Regexp {
	patterns := map[string]*regexp.Regexp{}
	for _, name := range craftNames {
		patterns[name] = regexp.MustCompile("(?i)^" + craftSpelling(name) + "[ _.-]files$")
	}
	return patterns
}()

func checksum(b []byte) string { v := sha256.Sum256(b); return hex.EncodeToString(v[:]) }
func craftName(stem string) string {
	if excluded.MatchString(stem) {
		return ""
	}
	for i, re := range craftPatterns {
		if re.MatchString(stem) {
			return craftNames[i]
		}
	}
	return ""
}
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
	if ext != ".png" && ext != ".svg" && ext != ".ico" && ext != ".webp" {
		return pack{}, asset{}, false
	}
	stem := strings.TrimSuffix(filename, suffix)
	doc := parts[len(parts)-2] == "FileTypes"
	depth := len(parts)
	key := ""
	appFiles := false
	if doc {
		depth--
		k := "." + strings.ToLower(strings.TrimLeft(stem, "."))
		for _, f := range l.formats {
			if f.Key == k {
				key = k
				break
			}
		}
		// In FileTypes, an extension names one format. Any other name that starts with an
		// app, such as PhotoCraft-PSD, is that app's icon for every file type it opens.
		if key == "" {
			key = craftName(stem)
			appFiles = true
		}
	} else {
		key = craftName(stem)
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
	file := strings.TrimPrefix(key, ".")
	if appFiles {
		file += "-files"
	}
	canonical := path.Join(path.Dir(source), file+ext)
	return pack{ID: group + "/" + name, Name: name, Author: author}, asset{Source: source, Key: key, File: canonical, Document: doc, AppFiles: appFiles}, true
}

// appLevel reports whether list puts a file in AppFileIcons: an app's art in FileTypes, or an app icon of a Komplett pack.
func (a asset) appLevel(documents bool) bool { return a.AppFiles || (documents && !a.Document) }

// allFiles reports whether this file opts its app in: art for the app in FileTypes, published under the name
// allFilesNames gives, such as PhotoCraft-files.png.
func (a asset) allFiles() bool {
	name := path.Base(a.Source)
	re, ok := allFilesNames[a.Key]
	return a.AppFiles && ok && re.MatchString(strings.TrimSuffix(name, path.Ext(name)))
}

// unlistedFileIconApps lists, sorted, the apps whose app-level file art opts in (see allFiles) in every file, whatever
// its format. Files left out of AppFileIcons, such as a second PNG of two merged folders, count too.
func unlistedFileIconApps(assets []asset, documents bool) []string {
	explicit := map[string]bool{}
	for _, a := range assets {
		if a.appLevel(documents) {
			all, seen := explicit[a.Key]
			explicit[a.Key] = a.allFiles() && (all || !seen)
		}
	}
	var apps []string
	for app, all := range explicit {
		if all {
			apps = append(apps, app)
		}
	}
	sort.Strings(apps)
	return apps
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
	l.latest.Packs = l.visiblePacks(l.latest.Packs)
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
	return l, nil
}

func (l *library) visiblePacks(packs map[string]pack) map[string]pack {
	flat, merged := packs[modernFlat]
	if !merged {
		flat, merged = l.seed.Packs[modernFlat]
	}
	if !merged {
		return packs
	}
	// Keep the seed intact. Its entries name the files as they are published.
	visible := maps.Clone(packs)
	visible[modernFlat] = flat
	for _, id := range modernFlatVariants {
		delete(visible, id)
	}
	return visible
}

func (p pack) signature() string {
	keys := make([]string, 0, len(p.Assets))
	for _, a := range p.Assets {
		keys = append(keys, a.File+"\t"+a.Blob)
	}
	sort.Strings(keys)
	return checksum([]byte(strings.Join(keys, "\n")))
}

// Old receipts include the original directory in their cache signature. Compare
// the files inside the pack without changing that signature or moving artwork.
func (p pack) sameArtwork(other pack) bool {
	if p.ID == other.ID {
		return p.signature() == other.signature()
	}
	if len(p.Assets) != len(other.Assets) {
		return false
	}
	type file struct {
		name     string
		document bool
	}
	blobs := make(map[file]string, len(p.Assets))
	for _, a := range p.Assets {
		blobs[file{path.Base(a.File), a.Document}] = a.Blob
	}
	for _, a := range other.Assets {
		if blobs[file{path.Base(a.File), a.Document}] != a.Blob {
			return false
		}
	}
	return true
}

func (l *library) currentID(id string) string {
	if _, merged := l.latest.Packs[modernFlat]; merged && slices.Contains(modernFlatVariants, id) {
		return modernFlat
	}
	return id
}

// previousIDs lists the packs a pack replaced. Each of them was published in the folder its ID names, with the file names
// the pack has now.
func (l *library) previousIDs(id string) []string {
	if _, merged := l.latest.Packs[modernFlat]; merged && id == modernFlat {
		return modernFlatVariants
	}
	return nil
}
// webpReadable reports whether the app running the helper reads WebP pack artwork: it sets BETTERICON_WEBP_READABLE to 1
// when it does. The helper decodes nothing itself; downloads and the downloaded state follow this answer.
func webpReadable() bool { return os.Getenv("BETTERICON_WEBP_READABLE") == "1" }

// itemKey names the icon a file draws: files whose names differ only in their extension are one icon in several formats.
func itemKey(file string) string { return strings.TrimSuffix(file, path.Ext(file)) }

func isWebP(file string) bool { return strings.EqualFold(path.Ext(file), ".webp") }

// twins lists the icons of a pack published as WebP and in another format too.
func (p pack) twins() map[string]bool {
	webp, other, both := map[string]bool{}, map[string]bool{}, map[string]bool{}
	for _, a := range p.Assets {
		if isWebP(a.File) {
			webp[itemKey(a.File)] = true
		} else {
			other[itemKey(a.File)] = true
		}
	}
	for key := range webp {
		if other[key] {
			both[key] = true
		}
	}
	return both
}

// downloadAssets lists the files a download fetches: one twin per icon. Where the app reads WebP, a PNG gives way to its
// WebP twin; where it can't, a WebP gives way to the other files of its icon. Every other file is fetched as it is.
func (p pack) downloadAssets(webp bool) []asset {
	twins := p.twins()
	var wanted []asset
	for _, a := range p.Assets {
		if twins[itemKey(a.File)] {
			ext := strings.ToLower(path.Ext(a.File))
			if (webp && ext == ".png") || (!webp && ext == ".webp") {
				continue
			}
		}
		wanted = append(wanted, a)
	}
	return wanted
}

// present reports whether a downloaded file is there: a regular file, not empty.
func present(file string) bool {
	info, err := os.Lstat(file)
	return err == nil && info.Mode().IsRegular() && info.Size() > 0
}

// filesPresent reports whether a download of the pack is complete. Of twins a download fetches one (downloadAssets), so
// such an icon needs one of its other files, or its WebP where the app reads WebP. Every other file must be there.
func (l *library) filesPresent(p pack) bool {
	root := filepath.Join(l.state, "downloads", p.signature())
	twins := p.twins()
	usable, webp := map[string]bool{}, map[string]bool{}
	for _, a := range p.Assets {
		here, key := present(filepath.Join(root, a.File)), itemKey(a.File)
		if !twins[key] {
			if !here {
				return false
			}
			continue
		}
		usable[key] = usable[key] || (here && !isWebP(a.File))
		webp[key] = webp[key] || (here && isWebP(a.File))
	}
	readable := webpReadable()
	for key, ok := range usable {
		if !ok && !(readable && webp[key]) {
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

type localPack struct {
	pack
	root, status string
}

func (l *library) localArtwork(target pack, previous []string, saved map[string]pack) localPack {
	var fallback localPack
	for _, id := range append([]string{target.ID}, previous...) {
		var copies []localPack
		if p, ok := saved[id]; ok {
			copies = append(copies, localPack{p, filepath.Join(l.state, "downloads", p.signature()), "Downloaded"})
		}
		for _, copy := range copies {
			if target.sameArtwork(copy.pack) {
				return copy
			}
			if fallback.root == "" {
				fallback = copy
				fallback.status = "Update available"
			}
		}
	}
	return fallback
}

func (l *library) list() []view {
	saved := l.acquired()
	available := map[string]pack{}
	for id, p := range saved {
		available[id] = p
	}
	for id, p := range l.latest.Packs {
		available[id] = p
	}
	result := make([]view, 0, len(available))
	for id, p := range available {
		if l.currentID(id) != id {
			continue
		}
		v := view{ID: id, Name: p.Name, Author: p.Author, Status: "Download", Icons: map[string]string{}, FileIcons: map[string]string{}, AppFileIcons: map[string]string{}}
		v.PreviousIDs = l.previousIDs(id)
		_, v.HasPreview = l.previews[id]
		_, v.HasFilePreview = l.previews[id+fileSet]
		// A pack is listed for apps when it draws app icons and for files when it draws file artwork.
		documents := strings.HasPrefix(id, documentPacks)
		for _, a := range p.Assets {
			if a.Document || documents {
				v.CanFiles = true
			} else {
				v.CanApps = true
			}
		}
		local := l.localArtwork(p, v.PreviousIDs, saved)
		if local.root != "" {
			v.Status = local.status
			// Prefer WebP, then PNG, then SVG, then ICO when an artist supplies several formats.
			rank := map[string]int{".webp": 0, ".png": 1, ".svg": 2, ".ico": 3}
			assets := slices.Clone(local.Assets)
			// Of two files in one format, the one listed last wins, as before.
			slices.Reverse(assets)
			slices.SortStableFunc(assets, func(a, b asset) int { return rank[path.Ext(a.File)] - rank[path.Ext(b.File)] })
			for _, a := range assets {
				if _, ok := rank[path.Ext(a.File)]; !ok {
					continue
				}
				files := v.Icons
				if a.appLevel(documents) {
					files = v.AppFileIcons
				} else if a.Document {
					files = v.FileIcons
				}
				// The first file of an item goes into its map. One file of each other format follows it, best first. A
				// download fetches one of an icon's twins, so only files on this computer are listed.
				file := filepath.Join(local.root, filepath.FromSlash(a.File))
				if !present(file) {
					continue
				}
				chosen, taken := files[a.Key]
				if !taken {
					files[a.Key] = file
					continue
				}
				// A second file in a format the key already has is left out, as before. Two packs merged
				// under one name, or a Komplett app icon beside its app's file art, can share a key.
				sameFormat := func(other string) bool { return filepath.Ext(other) == filepath.Ext(file) }
				if sameFormat(chosen) || slices.ContainsFunc(v.Fallbacks[chosen], sameFormat) {
					continue
				}
				if v.Fallbacks == nil {
					v.Fallbacks = map[string][]string{}
				}
				v.Fallbacks[chosen] = append(v.Fallbacks[chosen], file)
			}
		}
		// The opt-in is a file's published name, which a download's signature leaves out. So the catalog answers, unless
		// the download is older: AppFileIcons then lists the downloaded files, under the names they were published with.
		named := p.Assets
		if v.Status == "Update available" {
			named = local.Assets
		}
		v.UnlistedFileIconApps = unlistedFileIconApps(named, documents)
		result = append(result, v)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].ID < result[j].ID })
	return result
}
