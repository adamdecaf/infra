package go_test

import (
	"testing"
	"time"
)

func TestForbidigo_Sleep(t *testing.T) {
	// Direct calls have to be whitelisted
	time.Sleep(time.Second) //nolint:forbidigo

	// other functions can be called sleep, but we prevent time.Sleep calls
	s := &sleeper{}
	s.sleep(time.Second)
}

type sleeper struct{}

func (*sleeper) sleep(length time.Duration) {
	time.Sleep(length) //nolint:forbidigo
}
