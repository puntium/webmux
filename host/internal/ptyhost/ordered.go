package ptyhost

import (
	"bytes"

	"webmux/host/internal/protocol"
)

// kv / orderedObj encode a JSON object with keys in the given order, so
// frames match ptyhost.js's JSON.stringify output byte for byte (Go maps
// would sort the keys).
type kv struct {
	k string
	v any
}

type orderedObj []kv

func (o orderedObj) MarshalJSON() ([]byte, error) {
	var b bytes.Buffer
	b.WriteByte('{')
	for i, e := range o {
		if i > 0 {
			b.WriteByte(',')
		}
		kb, err := protocol.Marshal(e.k)
		if err != nil {
			return nil, err
		}
		b.Write(bytes.TrimSuffix(kb, []byte("\n")))
		b.WriteByte(':')
		vb, err := protocol.Marshal(e.v)
		if err != nil {
			return nil, err
		}
		b.Write(bytes.TrimSuffix(vb, []byte("\n")))
	}
	b.WriteByte('}')
	return b.Bytes(), nil
}

// outputFrame is the hot path; a struct keeps the field order too.
type outputFrame struct {
	Type string `json:"type"`
	Data string `json:"data"`
}
