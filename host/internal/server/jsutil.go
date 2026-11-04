package server

import (
	"errors"
	"fmt"
	"io/fs"
	"math"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"unicode"
	"unicode/utf8"

	"golang.org/x/sys/unix"
)

// Small helpers that reproduce JavaScript/node semantics the server.js
// handlers rely on, so the JSON they produce is identical.

// truthy is JS truthiness for a decoded JSON value.
func truthy(v any) bool {
	switch x := v.(type) {
	case nil:
		return false
	case bool:
		return x
	case float64:
		return x != 0 && !math.IsNaN(x)
	case int:
		return x != 0
	case string:
		return x != ""
	default:
		return true // objects and arrays, even empty ones
	}
}

// jsNumber formats a float64 like Number.prototype.toString for the usual
// range.
func jsNumber(f float64) string {
	if f == math.Trunc(f) && math.Abs(f) < 1e21 {
		return strconv.FormatFloat(f, 'f', -1, 64)
	}
	return strconv.FormatFloat(f, 'g', -1, 64)
}

// jsString is String(v) for a decoded JSON value.
func jsString(v any) string {
	switch x := v.(type) {
	case nil:
		return "null"
	case bool:
		if x {
			return "true"
		}
		return "false"
	case float64:
		return jsNumber(x)
	case int:
		return strconv.Itoa(x)
	case string:
		return x
	case []any:
		parts := make([]string, len(x))
		for i, e := range x {
			if e != nil {
				parts[i] = jsString(e)
			}
		}
		return strings.Join(parts, ",")
	default:
		return "[object Object]"
	}
}

// decodeUTF8 decodes bytes the way Buffer#toString('utf8') does (WHATWG
// UTF-8 decode): each maximal invalid subpart becomes one U+FFFD.
func decodeUTF8(b []byte) string {
	if utf8.Valid(b) {
		return string(b)
	}
	var sb strings.Builder
	sb.Grow(len(b) + 8)
	for i := 0; i < len(b); {
		c := b[i]
		if c < 0x80 {
			sb.WriteByte(c)
			i++
			continue
		}
		need := 0
		lower, upper := byte(0x80), byte(0xBF)
		switch {
		case c >= 0xC2 && c <= 0xDF:
			need = 1
		case c >= 0xE0 && c <= 0xEF:
			need = 2
			if c == 0xE0 {
				lower = 0xA0
			} else if c == 0xED {
				upper = 0x9F
			}
		case c >= 0xF0 && c <= 0xF4:
			need = 3
			if c == 0xF0 {
				lower = 0x90
			} else if c == 0xF4 {
				upper = 0x8F
			}
		default:
			sb.WriteRune(utf8.RuneError)
			i++
			continue
		}
		j := i + 1
		ok := true
		for k := 0; k < need; k++ {
			if j >= len(b) || b[j] < lower || b[j] > upper {
				ok = false
				break
			}
			lower, upper = 0x80, 0xBF
			j++
		}
		if !ok { // the offending byte (if any) is reprocessed
			sb.WriteRune(utf8.RuneError)
			i = j
			continue
		}
		sb.Write(b[i:j])
		i = j
	}
	return sb.String()
}

// decodeBase64 is Buffer.from(s, 'base64'): standard and URL-safe
// alphabets, characters outside them skipped, decoding stops at '='.
func decodeBase64(s string) []byte {
	out := make([]byte, 0, len(s)*3/4+3)
	var acc uint32
	n := 0
	for i := 0; i < len(s); i++ {
		c := s[i]
		var v byte
		switch {
		case c >= 'A' && c <= 'Z':
			v = c - 'A'
		case c >= 'a' && c <= 'z':
			v = c - 'a' + 26
		case c >= '0' && c <= '9':
			v = c - '0' + 52
		case c == '+' || c == '-':
			v = 62
		case c == '/' || c == '_':
			v = 63
		case c == '=':
			i = len(s)
			continue
		default:
			continue
		}
		acc = acc<<6 | uint32(v)
		n++
		if n == 4 {
			out = append(out, byte(acc>>16), byte(acc>>8), byte(acc))
			acc, n = 0, 0
		}
	}
	switch n {
	case 2:
		out = append(out, byte(acc>>4))
	case 3:
		out = append(out, byte(acc>>10), byte(acc>>2))
	}
	return out
}

// jsExtname is node's path.extname (POSIX).
func jsExtname(p string) string {
	startDot, startPart, end := -1, 0, -1
	matchedSlash := true
	preDotState := 0
	for i := len(p) - 1; i >= 0; i-- {
		c := p[i]
		if c == '/' {
			if !matchedSlash {
				startPart = i + 1
				break
			}
			continue
		}
		if end == -1 {
			matchedSlash = false
			end = i + 1
		}
		if c == '.' {
			if startDot == -1 {
				startDot = i
			} else if preDotState != 1 {
				preDotState = 1
			}
		} else if startDot != -1 {
			preDotState = -1
		}
	}
	if startDot == -1 || end == -1 || preDotState == 0 ||
		(preDotState == 1 && startDot == end-1 && startDot == startPart+1) {
		return ""
	}
	return p[startDot:end]
}

// jsBasename is node's path.basename (trailing slashes ignored, "" for "/").
func jsBasename(p string) string {
	t := strings.TrimRight(p, "/")
	if t == "" {
		return ""
	}
	return t[strings.LastIndexByte(t, '/')+1:]
}

// jsDirname is node's path.dirname (POSIX).
func jsDirname(p string) string {
	if p == "" {
		return "."
	}
	t := strings.TrimRight(p, "/")
	if t == "" {
		return "/"
	}
	i := strings.LastIndexByte(t, '/')
	if i < 0 {
		return "."
	}
	d := strings.TrimRight(t[:i], "/")
	if d == "" {
		return "/"
	}
	return d
}

// jsJoin is node's path.join: normalized, but a trailing slash on the last
// non-empty segment survives.
func jsJoin(parts ...string) string {
	var nonEmpty []string
	for _, p := range parts {
		if p != "" {
			nonEmpty = append(nonEmpty, p)
		}
	}
	if len(nonEmpty) == 0 {
		return "."
	}
	joined := strings.Join(nonEmpty, "/")
	out := filepath.Clean(joined)
	if strings.HasSuffix(joined, "/") && out != "/" {
		out += "/"
	}
	return out
}

// errCode is err.code: the errno name for system errors.
func errCode(err error) (string, bool) {
	var errno syscall.Errno
	if errors.As(err, &errno) {
		if n := unix.ErrnoName(errno); n != "" {
			return n, true
		}
	}
	var ce *codeError
	if errors.As(err, &ce) {
		return ce.code, true
	}
	return "", false
}

// codeOrString is `err.code || String(err)`.
func codeOrString(err error) string {
	if c, ok := errCode(err); ok {
		return c
	}
	return nodeErrString(err)
}

// codeError is a non-errno error that still carries a node-style code.
type codeError struct{ code string }

func (e *codeError) Error() string { return e.code }

// nodeErrString approximates String(err) for a node fs error:
// "Error: ENOENT: no such file or directory, open '/x'".
func nodeErrString(err error) string {
	var pe *fs.PathError
	var errno syscall.Errno
	if errors.As(err, &pe) && errors.As(err, &errno) {
		if n := unix.ErrnoName(errno); n != "" {
			return fmt.Sprintf("Error: %s: %s, %s '%s'", n, errno.Error(), pe.Op, pe.Path)
		}
	}
	return "Error: " + err.Error()
}

// encodeURIComponent as in JS (on the UTF-8 encoding of s).
func encodeURIComponent(s string) string {
	const keep = "-_.!~*'()"
	var sb strings.Builder
	for _, c := range []byte(s) {
		if c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || strings.IndexByte(keep, c) >= 0 {
			sb.WriteByte(c)
		} else {
			fmt.Fprintf(&sb, "%%%02X", c)
		}
	}
	return sb.String()
}

// ---------------------------------------------------------------------------
// localeCompare(b, undefined, { sensitivity: 'base' }) approximation.
//
// node compares with ICU's root collation at primary strength. Without a
// collation table in the module (no golang.org/x/text), this reproduces it
// for what file names usually contain: ASCII in ICU's exact primary order
// (measured against node: spaces, punctuation, symbols, digits, then
// letters case-insensitively), Latin-1 letters folded to their base letter
// (é = e, ß = ss), control characters ignorable. Everything else sorts after
// the Latin letters by code point.
// ---------------------------------------------------------------------------

const asciiPrimaryOrder = " _-,;:!?.'\"()[]{}@*/\\&#%`^+<=>|~$0123456789abcdefghijklmnopqrstuvwxyz"

var asciiWeight = func() [128]int {
	var w [128]int
	for i, c := range asciiPrimaryOrder {
		w[c] = i + 1
	}
	for c := 'A'; c <= 'Z'; c++ {
		w[c] = w[c+'a'-'A']
	}
	return w
}()

// latin1Fold maps U+00C0..U+00FF to their primary base letters.
var latin1Fold = map[rune]string{
	'À': "a", 'Á': "a", 'Â': "a", 'Ã': "a", 'Ä': "a", 'Å': "a", 'Æ': "ae", 'Ç': "c",
	'È': "e", 'É': "e", 'Ê': "e", 'Ë': "e", 'Ì': "i", 'Í': "i", 'Î': "i", 'Ï': "i",
	'Ð': "d", 'Ñ': "n", 'Ò': "o", 'Ó': "o", 'Ô': "o", 'Õ': "o", 'Ö': "o", 'Ø': "o",
	'Ù': "u", 'Ú': "u", 'Û': "u", 'Ü': "u", 'Ý': "y", 'Þ': "th", 'ß': "ss",
	'à': "a", 'á': "a", 'â': "a", 'ã': "a", 'ä': "a", 'å': "a", 'æ': "ae", 'ç': "c",
	'è': "e", 'é': "e", 'ê': "e", 'ë': "e", 'ì': "i", 'í': "i", 'î': "i", 'ï': "i",
	'ð': "d", 'ñ': "n", 'ò': "o", 'ó': "o", 'ô': "o", 'õ': "o", 'ö': "o", 'ø': "o",
	'ù': "u", 'ú': "u", 'û': "u", 'ü': "u", 'ý': "y", 'þ': "th", 'ÿ': "y",
}

func collationKey(s string) []int {
	key := make([]int, 0, len(s))
	for _, r := range s {
		switch {
		case r < 0x20 || r == 0x7f:
			// ignorable
		case r < 0x80:
			key = append(key, asciiWeight[r])
		default:
			if f, ok := latin1Fold[r]; ok {
				for _, c := range f {
					key = append(key, asciiWeight[c])
				}
			} else if unicode.IsSpace(r) {
				key = append(key, asciiWeight[' '])
			} else {
				key = append(key, 1000+int(unicode.ToLower(r)))
			}
		}
	}
	return key
}

// localeCompareBase returns <0, 0, >0.
func localeCompareBase(a, b string) int {
	ka, kb := collationKey(a), collationKey(b)
	for i := 0; i < len(ka) && i < len(kb); i++ {
		if ka[i] != kb[i] {
			return ka[i] - kb[i]
		}
	}
	return len(ka) - len(kb)
}
