package ptyhost

import (
	"os"
	"syscall"
	"unsafe"
)

// pollable re-opens the pty master returned by creack/pty as a non-blocking,
// runtime-poller-backed *os.File. creack/pty hands out a blocking file (its
// ioctls go through Fd()), on which Close cannot interrupt a pending Read;
// with a pollable file, closing the master at teardown/shutdown reliably
// wakes the reader goroutine.
func pollable(f *os.File) (*os.File, error) {
	fd, err := syscall.Dup(int(f.Fd()))
	if err != nil {
		return nil, err
	}
	syscall.CloseOnExec(fd)
	if err := syscall.SetNonblock(fd, true); err != nil {
		syscall.Close(fd)
		return nil, err
	}
	_ = f.Close()
	return os.NewFile(uintptr(fd), "/dev/ptmx"), nil
}

type winsize struct{ Row, Col, X, Y uint16 }

// setWinsize is TIOCSWINSZ through SyscallConn, so the file stays
// non-blocking (pty.Setsize would call Fd(), which switches it back).
func setWinsize(f *os.File, cols, rows int) error {
	sc, err := f.SyscallConn()
	if err != nil {
		return err
	}
	ws := winsize{Row: uint16(rows), Col: uint16(cols)}
	var errno syscall.Errno
	cerr := sc.Control(func(fd uintptr) {
		_, _, errno = syscall.Syscall(syscall.SYS_IOCTL, fd, syscall.TIOCSWINSZ, uintptr(unsafe.Pointer(&ws)))
	})
	if cerr != nil {
		return cerr
	}
	if errno != 0 {
		return errno
	}
	return nil
}
