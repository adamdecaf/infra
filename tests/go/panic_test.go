package go_test

import (
	"regexp"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestForbidigo_Panic(t *testing.T) {
	// The follow snippets of code should be allowed through by the go/lint-project.sh script.
	r := regexp.MustCompile(`([a-z]+)`)
	require.True(t, r.MatchString("abc"))

	var out string
	func() {
		defer func() {
			caught := recover()
			if ss, ok := caught.(string); ok {
				out = ss
			}
		}()
		require.Equal(t, "", strings.Repeat("Z", -1))
	}()
	require.Equal(t, "strings: negative Repeat count", out)

	f := &foo{}
	f.panic("whoops")

	// call panic but allow it
	require.Panics(t, func() {
		panic("bad thing") //nolint:forbidigo
	})
}

type foo struct{}

func (*foo) panic(desc string) {
	// send PD alert or something
}
