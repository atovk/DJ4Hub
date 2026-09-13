package mbim

import "fmt"

// fixedDoneOffset is where the info buffer begins inside a first
// COMMAND_DONE/INDICATE fragment.
const fixedDoneOffset = headerLen + fragHdrLen + uuidLen + 4 + 4 + 4

// fixedCmdOffset is where the info buffer begins inside a first COMMAND fragment.
const fixedCmdOffset = headerLen + fragHdrLen + uuidLen + 4 + 4 + 4

const (
	// maxReassembledInfoSize is an implementation guard for malformed or
	// hostile fragmented replies. Individual USB/control messages remain
	// limited by maxMessageSize in transport.go; this cap applies after
	// fragment reassembly and is intentionally larger than one transfer.
	maxReassembledInfoSize  = 1024 * 1024
	maxReassembledFragments = 4096
)

type collector struct {
	started bool
	total   uint32
	next    uint32
	service UUID
	cid     uint32
	status  uint32
	fullLen uint32
	info    []byte
}

func newCollector() *collector {
	return &collector{}
}

func (c *collector) add(b []byte) (bool, error) {
	if len(b) < headerLen+fragHdrLen {
		return false, fmt.Errorf("mbim: fragment shorter than fragment header len=%d", len(b))
	}

	total := le.Uint32(b[12:])
	current := le.Uint32(b[16:])
	if total == 0 {
		return false, fmt.Errorf("mbim: fragment total must be non-zero")
	}
	if total > maxReassembledFragments {
		return false, fmt.Errorf("mbim: fragment total %d exceeds max %d", total, maxReassembledFragments)
	}
	if current >= total {
		return false, fmt.Errorf("mbim: fragment current=%d outside total=%d", current, total)
	}
	if !c.started {
		if current != 0 {
			return false, fmt.Errorf("mbim: first fragment current=%d, want 0", current)
		}
		if len(b) < fixedDoneOffset {
			return false, fmt.Errorf("mbim: first fragment shorter than fixed fields len=%d", len(b))
		}
		copy(c.service[:], b[20:36])
		c.cid = le.Uint32(b[36:])
		c.status = le.Uint32(b[40:])
		c.fullLen = le.Uint32(b[44:])
		if c.fullLen > maxReassembledInfoSize {
			return false, fmt.Errorf("mbim: declared info length %d exceeds max %d", c.fullLen, maxReassembledInfoSize)
		}
		c.total = total
		c.next = 1
		c.started = true
		if err := c.appendInfo(b[fixedDoneOffset:]); err != nil {
			return false, err
		}
		return c.next >= c.total, nil
	}

	if total != c.total {
		return false, fmt.Errorf("mbim: fragment total changed got=%d want=%d", total, c.total)
	}
	if current != c.next {
		return false, fmt.Errorf("mbim: fragment out of order got=%d want=%d", current, c.next)
	}
	c.next++
	if err := c.appendInfo(b[headerLen+fragHdrLen:]); err != nil {
		return false, err
	}
	return c.next >= c.total, nil
}

func (c *collector) appendInfo(b []byte) error {
	if len(c.info)+len(b) > maxReassembledInfoSize {
		return fmt.Errorf("mbim: reassembled info length %d exceeds max %d", len(c.info)+len(b), maxReassembledInfoSize)
	}
	c.info = append(c.info, b...)
	return nil
}

func (c *collector) commandDone() (CommandDone, error) {
	if !c.started {
		return CommandDone{}, fmt.Errorf("mbim: collector has no data")
	}
	if int(c.fullLen) > len(c.info) {
		return CommandDone{}, fmt.Errorf("mbim: reassembled info shorter than declared length got=%d want=%d", len(c.info), c.fullLen)
	}
	info := c.info
	if int(c.fullLen) <= len(info) {
		info = info[:c.fullLen]
	}
	return CommandDone{
		Service:    c.service,
		CID:        c.cid,
		Status:     c.status,
		InfoBuffer: info,
	}, nil
}

func splitCommand(txID uint32, service UUID, cid uint32, ct CommandType, info []byte, maxControlTransfer uint32) [][]byte {
	max := int(maxControlTransfer)
	firstCap := max - fixedCmdOffset
	contCap := max - (headerLen + fragHdrLen)
	if firstCap <= 0 || contCap <= 0 || len(info) <= firstCap {
		return [][]byte{encodeCommand(txID, service, cid, ct, info)}
	}

	sizes := []int{firstCap}
	for remaining := len(info) - firstCap; remaining > 0; {
		take := contCap
		if take > remaining {
			take = remaining
		}
		sizes = append(sizes, take)
		remaining -= take
	}

	total := uint32(len(sizes))
	frags := make([][]byte, 0, len(sizes))
	pos := 0
	for i, size := range sizes {
		chunk := info[pos : pos+size]
		pos += size
		if i == 0 {
			b := make([]byte, fixedCmdOffset+size)
			putHeader(b, MessageTypeCommand, uint32(len(b)), txID)
			le.PutUint32(b[12:], total)
			le.PutUint32(b[16:], 0)
			copy(b[20:36], service[:])
			le.PutUint32(b[36:], cid)
			le.PutUint32(b[40:], uint32(ct))
			le.PutUint32(b[44:], uint32(len(info)))
			copy(b[fixedCmdOffset:], chunk)
			frags = append(frags, b)
			continue
		}

		b := make([]byte, headerLen+fragHdrLen+size)
		putHeader(b, MessageTypeCommand, uint32(len(b)), txID)
		le.PutUint32(b[12:], total)
		le.PutUint32(b[16:], uint32(i))
		copy(b[headerLen+fragHdrLen:], chunk)
		frags = append(frags, b)
	}
	return frags
}
