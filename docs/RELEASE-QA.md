# Release acceptance record

Candidate: 0.1.0 (1), local uncommitted development tree.
Built on 2026-09-27 using Swift 6.3.3 / SDK 26.5, arm64, macOS 26.3.
All human/hardware checks below remain unverified until run on the packaged artifact.

| Check | Environment | Result / evidence |
| --- | --- | --- |
| Swift tests | arm64, macOS 26.3 | PASS: 51 passed, 0 failed; 1 opt-in Codex performance benchmark skipped |
| Optimized build and mounted DMG verification | arm64, macOS 26.3 | PASS: release build, arm64, macOS 14.2 deployment target, bundle seal, DMG checksum/mount, Applications link, icon and instructions |
| Artifact checksum and source consistency | Local checkout | PASS: SHA256SUMS; source unchanged during tests/build; SOURCE-SHA256SUMS rechecked |
| GitHub workflow | Public macOS runner | Added, not executed remotely |
| Browser download → Finder install → launch | Fresh account | Not run |
| Permission grants/denials and recovery | Fresh account | Not run |
| macOS 14.2 / 15 / 26 | Test Macs or VMs | Not run |
| External display, Spaces, sleep/wake | Test hardware | Not run |
| Music and optional Spotify authentication | Test account | Not run |
| Screenshots, routing, clipboard and Trash | Test account | Not run |
| Live Claude/Codex, opt-outs and cleanup | Test account | Not run |
| Upgrade and permission renewal | Previous installed build | Not run |
| Extended CPU/memory/log observation | Test hardware | Not run |
| Uninstall | Test account | Not run |
| License and third-party asset review | Maintainer | Pending |

Full steps: [PUBLISH.md](../PUBLISH.md). Do not turn an unverified row into a pass
based only on unit tests or successful packaging.

Artifacts: `build/releases/Notch-0.1.0-1-arm64/`. See accompanying build info and checksums.
The source tree includes ongoing session-monitoring work; this is a local candidate, not a tagged public release.
