// Package buildinfo names the build that is running, so the admin panel can
// show which version is live.
package buildinfo

import "runtime/debug"

// Version is set at build time:
//
//	go build -ldflags "-X github.com/HPTarkk/Tark/backend/internal/buildinfo.Version=20261115-1416-ec947a9"
//
// The deploy script passes its image tag (date, time and git commit).
var Version = ""

// String is Version, or else the git commit Go recorded in the binary, or
// "dev" for a build that knows neither.
func String() string {
	if Version != "" {
		return Version
	}
	if info, ok := debug.ReadBuildInfo(); ok {
		rev, dirty := "", false
		for _, s := range info.Settings {
			switch s.Key {
			case "vcs.revision":
				rev = s.Value
			case "vcs.modified":
				dirty = s.Value == "true"
			}
		}
		if len(rev) > 7 {
			rev = rev[:7]
		}
		if rev != "" {
			if dirty {
				rev += "-dirty"
			}
			return rev
		}
	}
	return "dev"
}
