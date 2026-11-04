package server

import (
	"encoding/binary"
	"errors"
	"io"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// ---------------------------------------------------------------------------
// File browser API (Miller-columns widget). No sandboxing: terminals already
// expose the whole filesystem, so these endpoints match that trust level.
// ---------------------------------------------------------------------------

const (
	fsListMax        = 2000
	textPreviewBytes = 64 * 1024
	zipListMax       = 2000
	zipCdirMax       = 16 * 1024 * 1024 // central directory read cap
)

var zipExts = map[string]bool{
	"zip": true, "jar": true, "war": true, "ear": true, "whl": true, "egg": true, "epub": true,
	"xpi": true, "apk": true, "ipa": true, "nupkg": true, "vsix": true, "docx": true, "xlsx": true,
	"pptx": true, "odt": true, "ods": true, "odp": true,
}

var imageMime = map[string]string{
	"png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
	"webp": "image/webp", "bmp": "image/bmp", "svg": "image/svg+xml", "ico": "image/x-icon",
	"avif": "image/avif",
}

// resolveFsPath: absent/empty/non-string/'~' → $HOME; '~/x' → $HOME/x
// (path.join); anything else → path.resolve (relative to the cwd).
func (s *Server) resolveFsPath(p any) string {
	str, ok := p.(string)
	if !ok || str == "" || str == "~" {
		return s.home
	}
	if strings.HasPrefix(str, "~/") {
		return jsJoin(s.home, str[2:])
	}
	if filepath.IsAbs(str) {
		return filepath.Clean(str)
	}
	cwd, err := os.Getwd()
	if err != nil {
		cwd = "/"
	}
	return filepath.Join(cwd, str)
}

// paramPath is resolveFsPath(url.searchParams.get(name)).
func (s *Server) paramPath(u reqURL, name string) string {
	v, ok := u.param(name)
	if !ok {
		return s.resolveFsPath(nil)
	}
	return s.resolveFsPath(v)
}

func extOf(file string) string {
	e := jsExtname(file)
	if e == "" {
		return ""
	}
	return strings.ToLower(e[1:])
}

func errJSON(w http.ResponseWriter, err error) {
	sendJSON(w, 400, map[string]any{"error": codeOrString(err)})
}

func (s *Server) handleFsList(w http.ResponseWriter, _ *http.Request, u reqURL, _ []string) error {
	dir := s.paramPath(u, "path")
	f, err := os.Open(dir)
	if err != nil {
		errJSON(w, err)
		return nil
	}
	dirents, err := f.ReadDir(-1)
	f.Close()
	if err != nil {
		errJSON(w, err)
		return nil
	}
	type entry struct {
		Name    string `json:"name"`
		Type    string `json:"type"`
		Symlink bool   `json:"symlink,omitempty"`
	}
	entries := make([]entry, 0, len(dirents))
	for _, d := range dirents {
		e := entry{Name: d.Name(), Type: "file"}
		if d.IsDir() {
			e.Type = "dir"
		}
		if d.Type()&os.ModeSymlink != 0 {
			e.Symlink = true
			// classify by target so symlinked dirs are drillable; broken links stay files
			if st, err := os.Stat(filepath.Join(dir, d.Name())); err == nil && st.IsDir() {
				e.Type = "dir"
			}
		}
		entries = append(entries, e)
	}
	sort.SliceStable(entries, func(i, j int) bool {
		a, b := entries[i], entries[j]
		if a.Type == b.Type {
			return localeCompareBase(a.Name, b.Name) < 0
		}
		return a.Type == "dir"
	})
	truncated := len(entries) > fsListMax
	if truncated {
		entries = entries[:fsListMax]
	}
	sendJSON(w, 200, map[string]any{"path": dir, "entries": entries, "truncated": truncated})
	return nil
}

type zipEntry struct {
	Name string  `json:"name"`
	Size float64 `json:"size"`
	Dir  bool    `json:"dir"`
}

type zipListing struct {
	entries   []zipEntry
	count     float64
	truncated bool
}

var errNotZip = errors.New("not a zip")

// readZipListing reads a zip's table of contents straight from the central
// directory (nothing is inflated): the end-of-central-directory record is
// found by scanning back from the tail, its zip64 variant is honoured, and
// each central header yields { name, size, dir }. Entries are listed in
// archive order and capped at zipListMax. Returns errNotZip on anything that
// isn't a zip; the caller falls back to the binary verdict. A byte-exact
// port of server.js's parser (see the package report for why not
// archive/zip).
func readZipListing(f *os.File, fileSize int64) (*zipListing, error) {
	readAt := func(pos int64, n int64) ([]byte, error) {
		if pos < 0 || n <= 0 {
			return nil, nil
		}
		buf := make([]byte, n)
		got, err := f.ReadAt(buf, pos)
		if err != nil && !errors.Is(err, io.EOF) {
			return nil, err
		}
		return buf[:got], nil
	}
	le16 := func(b []byte, i int) uint32 { return uint32(binary.LittleEndian.Uint16(b[i:])) }
	le32 := func(b []byte, i int) uint32 { return binary.LittleEndian.Uint32(b[i:]) }
	le64 := func(b []byte, i int) float64 { return float64(binary.LittleEndian.Uint64(b[i:])) }

	// EOCD: 22 bytes + up to 64 KB of archive comment.
	tailLen := min(fileSize, 22+0xffff)
	tail, err := readAt(fileSize-tailLen, tailLen)
	if err != nil {
		return nil, err
	}
	eocd := -1
	for i := len(tail) - 22; i >= 0; i-- {
		if le32(tail, i) == 0x06054b50 {
			eocd = i
			break
		}
	}
	if eocd < 0 {
		return nil, errNotZip
	}
	count := float64(le16(tail, eocd+10))
	cdSize := float64(le32(tail, eocd+12))
	cdOffset := float64(le32(tail, eocd+16))
	if count == 0xffff || cdSize == 0xffffffff || cdOffset == 0xffffffff {
		// zip64: a locator sits right before the EOCD and points at the real record.
		loc := eocd - 20
		if loc >= 0 && le32(tail, loc) == 0x07064b50 {
			recPos := le64(tail, loc+8)
			var rec []byte
			if recPos <= math.MaxInt64/2 {
				if rec, err = readAt(int64(recPos), 56); err != nil {
					return nil, err
				}
			}
			if len(rec) == 56 && le32(rec, 0) == 0x06064b50 {
				count = le64(rec, 32)
				cdSize = le64(rec, 40)
				cdOffset = le64(rec, 48)
			}
		}
	}
	if cdOffset+cdSize > float64(fileSize) {
		return nil, errNotZip
	}
	cd, err := readAt(int64(cdOffset), int64(math.Min(cdSize, zipCdirMax)))
	if err != nil {
		return nil, err
	}
	entries := []zipEntry{}
	p := 0
	seen := 0
	for p+46 <= len(cd) && le32(cd, p) == 0x02014b50 {
		nameLen := int(le16(cd, p+28))
		extraLen := int(le16(cd, p+30))
		commentLen := int(le16(cd, p+32))
		if p+46+nameLen+extraLen+commentLen > len(cd) {
			break
		}
		size := float64(le32(cd, p+24))
		utf8Flag := le16(cd, p+8)&0x800 != 0
		rawName := cd[p+46 : p+46+nameLen]
		var name string
		if utf8Flag {
			name = decodeUTF8(rawName)
		} else { // latin1
			rs := make([]rune, len(rawName))
			for i, b := range rawName {
				rs[i] = rune(b)
			}
			name = string(rs)
		}
		if size == 0xffffffff { // zip64 extra field: uncompressed size comes first
			q := p + 46 + nameLen
			end := q + extraLen
			for q+4 <= end {
				tag := le16(cd, q)
				l := int(le16(cd, q+2))
				if tag == 0x0001 && l >= 8 {
					if q+12 > len(cd) { // Buffer#readBigUInt64LE past the end
						return nil, &codeError{"ERR_OUT_OF_RANGE"}
					}
					size = le64(cd, q+4)
					break
				}
				q += 4 + l
			}
		}
		seen++
		if len(entries) < zipListMax {
			entries = append(entries, zipEntry{Name: name, Size: size, Dir: strings.HasSuffix(name, "/")})
		}
		p += 46 + nameLen + extraLen + commentLen
	}
	return &zipListing{
		entries:   entries,
		count:     math.Max(count, float64(seen)),
		truncated: float64(seen) < count || len(entries) < seen,
	}, nil
}

// mtimeMs is node's Stats#mtimeMs: sec*1e3 + nsec/1e6.
func mtimeMs(fi os.FileInfo) float64 {
	t := fi.ModTime()
	return float64(t.Unix())*1e3 + float64(t.Nanosecond())/1e6
}

func (s *Server) handleFsPreview(w http.ResponseWriter, _ *http.Request, u reqURL, _ []string) error {
	file := s.paramPath(u, "path")
	st, err := os.Stat(file)
	if err != nil {
		errJSON(w, err)
		return nil
	}
	out := map[string]any{"size": st.Size(), "mtime": mtimeMs(st)}
	if !st.Mode().IsRegular() {
		out["kind"] = "other"
		sendJSON(w, 200, out)
		return nil
	}
	ext := extOf(file)
	if imageMime[ext] != "" {
		out["kind"] = "image"
		sendJSON(w, 200, out)
		return nil
	}
	if zipExts[ext] && st.Size() >= 22 {
		f, err := os.Open(file)
		if err != nil {
			errJSON(w, err)
			return nil
		}
		z, err := readZipListing(f, st.Size())
		f.Close()
		if err == nil {
			out["kind"] = "zip"
			out["entries"] = z.entries
			out["count"] = z.count
			out["truncated"] = z.truncated
			sendJSON(w, 200, out)
			return nil
		}
		if c, ok := errCode(err); ok {
			sendJSON(w, 400, map[string]any{"error": c})
			return nil
		}
		// not actually a zip — fall through to the text/binary sniff
	}
	f, err := os.Open(file)
	if err != nil {
		errJSON(w, err)
		return nil
	}
	defer f.Close()
	buf := make([]byte, min(st.Size(), textPreviewBytes))
	n, err := io.ReadFull(f, buf)
	if err != nil && !errors.Is(err, io.EOF) && !errors.Is(err, io.ErrUnexpectedEOF) {
		errJSON(w, err)
		return nil
	}
	head := buf[:n]
	for _, b := range head {
		if b == 0 {
			out["kind"] = "binary"
			sendJSON(w, 200, out)
			return nil
		}
	}
	out["kind"] = "text"
	out["content"] = decodeUTF8(head)
	out["truncated"] = int64(n) < st.Size()
	sendJSON(w, 200, out)
	return nil
}

// uniqueName dedupes Finder-style ("name (1).ext") on collision.
func uniqueName(dir, name string) string {
	if name == "" {
		name = "file"
	}
	base := jsBasename(name)
	ext := jsExtname(base)
	stem := base[:len(base)-len(ext)]
	candidate := base
	for i := 1; exists(filepath.Join(dir, candidate)); i++ {
		candidate = stem + " (" + strconv.Itoa(i) + ")" + ext
	}
	return candidate
}

func exists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

// Upload from the file browser (drag-drop / paste): raw body written into
// ?dir under ?name, deduped Finder-style ("name (1).ext") on collision. A
// name may contain '/' (folder drops upload each file with its relative
// path); intermediate directories are created, and only the basename is
// deduped — re-dropping a folder merges into the existing one.
func (s *Server) handleFsUpload(w http.ResponseWriter, r *http.Request, u reqURL, _ []string) error {
	dir := s.paramPath(u, "dir")
	rawName, _ := u.param("name")
	var segments []string
	for _, seg := range strings.Split(rawName, "/") {
		if seg != "" && seg != "." {
			segments = append(segments, seg)
		}
	}
	for _, seg := range segments {
		if seg == ".." {
			sendJSON(w, 400, map[string]any{"error": "invalid name"})
			return nil
		}
	}
	base := "file"
	if len(segments) > 0 {
		base = segments[len(segments)-1]
		segments = segments[:len(segments)-1]
	}
	target := filepath.Join(append([]string{dir}, segments...)...)
	data, err := readBody(w, r, uploadLimit)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(target, 0o777); err != nil {
		errJSON(w, err)
		return nil
	}
	name := uniqueName(target, base)
	if err := os.WriteFile(filepath.Join(target, name), data, 0o666); err != nil {
		errJSON(w, err)
		return nil
	}
	sendJSON(w, 200, map[string]any{"name": strings.Join(append(segments, name), "/")})
	return nil
}

// Delete / rename from the file browser. Deletes are recursive — the client
// confirms before calling; renames stay within the entry's directory.
func (s *Server) handleFsDelete(w http.ResponseWriter, r *http.Request, _ reqURL, _ []string) error {
	body, err := readJSONBody(w, r)
	if err != nil {
		return err
	}
	target := s.resolveFsPath(body.get("path"))
	if target == "/" || target == s.home {
		sendJSON(w, 400, map[string]any{"error": "refusing to delete that"})
		return nil
	}
	// fs.rmSync(target, {recursive: true}) — no force, so a missing path is ENOENT.
	if _, err := os.Lstat(target); err != nil {
		errJSON(w, err)
		return nil
	}
	if err := os.RemoveAll(target); err != nil {
		errJSON(w, err)
		return nil
	}
	sendJSON(w, 200, map[string]any{"ok": true})
	return nil
}

func (s *Server) handleFsRename(w http.ResponseWriter, r *http.Request, _ reqURL, _ []string) error {
	body, err := readJSONBody(w, r)
	if err != nil {
		return err
	}
	from := s.resolveFsPath(body.get("path"))
	name := ""
	if v := body.get("name"); truthy(v) {
		name = jsString(v)
	}
	if name == "" || name == "." || name == ".." || strings.Contains(name, "/") {
		sendJSON(w, 400, map[string]any{"error": "invalid name"})
		return nil
	}
	to := jsJoin(jsDirname(from), name)
	if to != from && exists(to) {
		sendJSON(w, 400, map[string]any{"error": "name already taken"})
		return nil
	}
	if err := os.Rename(from, to); err != nil {
		errJSON(w, err)
		return nil
	}
	sendJSON(w, 200, map[string]any{"ok": true, "name": name})
	return nil
}

// Raw file bytes (image previews load this as <img src>). With ?download=1
// the response is an attachment named after the file, so the browser saves
// it instead of showing it — the preview header's download button. Like
// server.js: always a full 200 response, no Range support.
func (s *Server) handleFsRaw(w http.ResponseWriter, _ *http.Request, u reqURL, _ []string) error {
	file := s.paramPath(u, "path")
	mime := imageMime[extOf(file)]
	dl, _ := u.param("download")
	download := dl == "1"
	st, err := os.Stat(file)
	if err != nil {
		errJSON(w, err)
		return nil
	}
	if !st.Mode().IsRegular() {
		sendJSON(w, 400, map[string]any{"error": "not a file"})
		return nil
	}
	f, err := os.Open(file)
	if err != nil {
		errJSON(w, err)
		return nil
	}
	defer f.Close()
	h := w.Header()
	if mime == "" {
		mime = "application/octet-stream"
	}
	h.Set("Content-Type", mime)
	h.Set("Content-Length", strconv.FormatInt(st.Size(), 10))
	setCORS(h)
	if download {
		name := jsBasename(file)
		// ASCII fallback for old agents, RFC 5987 form for the real name.
		var ascii strings.Builder
		for _, r := range name {
			switch {
			case r > 0xffff: // a surrogate pair: two UTF-16 units, two '_'
				ascii.WriteString("__")
			case r < 0x20 || r > 0x7e || r == '"' || r == '\\':
				ascii.WriteByte('_')
			default:
				ascii.WriteRune(r)
			}
		}
		h.Set("Content-Disposition", `attachment; filename="`+ascii.String()+`"; filename*=UTF-8''`+encodeURIComponent(name))
	}
	w.WriteHeader(200)
	_, _ = io.CopyN(w, f, st.Size())
	return nil
}
