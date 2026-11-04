package ptyhost

import "unicode/utf8"

// splitUTF8 splits b into the longest prefix that does not end in the middle
// of a multi-byte UTF-8 sequence, and the incomplete tail (at most 3 bytes)
// that must be held back until the next pty read completes it. node-pty
// decodes pty output with a streaming StringDecoder, so a character split
// across two reads still arrives intact in onData; this reproduces that.
// Invalid bytes are not held back: they are complete (if invalid) and become
// U+FFFD when the string is JSON-encoded, as StringDecoder would make them.
func splitUTF8(b []byte) (complete, tail []byte) {
	// Look at most 3 bytes back for the start of the last sequence.
	for i := len(b) - 1; i >= 0 && i >= len(b)-utf8.UTFMax+1; i-- {
		c := b[i]
		if c < 0x80 {
			return b, nil // ASCII: everything is complete
		}
		if c >= 0xC0 { // a leading byte
			if utf8.FullRune(b[i:]) {
				return b, nil
			}
			return b[:i], b[i:]
		}
		// continuation byte: keep looking for its leader
	}
	return b, nil
}

// utf8Stream carries the held-back tail between reads.
type utf8Stream struct{ tail []byte }

// push returns the decodable part of tail+chunk (as a string) and keeps the
// new incomplete tail. The returned string may be empty.
func (u *utf8Stream) push(chunk []byte) string {
	var buf []byte
	if len(u.tail) > 0 {
		buf = append(u.tail, chunk...)
	} else {
		buf = chunk
	}
	complete, tail := splitUTF8(buf)
	u.tail = append([]byte(nil), tail...)
	return string(complete)
}

// flush returns whatever is still held back (an incomplete sequence at the
// end of the stream; it becomes U+FFFD on encoding, like StringDecoder.end).
func (u *utf8Stream) flush() string {
	s := string(u.tail)
	u.tail = nil
	return s
}
