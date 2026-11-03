# Agent instructions (cmdcmd)

Cursor IDE agents and cloud agents should behave as an **autonomous engineer**: take assigned work from understanding through verification and shipping, not plans or partial diffs.

## Project facts

Verified from this repository (not invented):

| | |
| --- | --- |
| **What** | **cmdcmd** — macOS menu-bar companion that opens a screenshot + prompt popup and talks to coding agents over [ACP](https://agentclientprotocol.com) (NDJSON/JSON-RPC). |
| **Stack** | Swift 6, Swift Package Manager, macOS 15+ (`Package.swift`). Optional Node for npx-based agents and the mock script. |
| **App code** | `Sources/cmdcmd/` — Swift executable target. |
| **Assets / plist** | `Resources/` (`Info.plist`, icons). |
| **Dev helpers** | `Makefile` (app bundle, DMG, run); `scripts/mock-agent.mjs` (fake ACP agent). |
| **User docs** | `README.md` — install, config (`~/.cmdcmd/config.json`), agent registry. |

### Commands (use these exact invocations)

| Goal | Command |
| --- | --- |
| Release build | `swift build -c release` |
| App bundle (default `make`) | `make` or `make bundle` |
| Run locally | `make run` |
| DMG (needs `create-dmg`) | `make dmg` |
| Clean artifacts | `make clean` |
| Mock ACP agent | `node scripts/mock-agent.mjs` (or `scripts/mock-agent.mjs` per README) |

Optional signing for distribution: `make dmg SIGN_ID="Developer ID Application: …"`.

**Tests:** No test target in `Package.swift`; no automated test suite in-repo.

**Lint / format:** No SwiftLint, SwiftFormat, or similar config found.

**CI:** No `.github/workflows` (or other CI) in this repo.

**Platform note:** Builds target macOS only. Linux cloud agents cannot run `swift build` here unless a Swift/macOS toolchain is provided; still run verification on macOS or in CI when available.

---

## Autonomous engineer workflow

### Own the task end-to-end

1. **Understand** — Read the issue/PR ask, relevant code, and README/config behavior.
2. **Plan briefly** — Short mental or written plan, then implement. Do not stop at planning or a partial diff.
3. **Implement** — Minimal, convention-matching changes; reuse existing patterns in `Sources/cmdcmd/`.
4. **Verify for real** — Install deps if needed, then run the commands in **Project facts** that apply (at minimum `swift build -c release` or `make bundle` on macOS). Fix failures and re-run until green. For UI/popup/hotkey/permission behavior, run `make run` on macOS and exercise the flow.
5. **Tests** — If you change behavior and the repo later gains tests, add or update them. Today there is no test target; do not block shipping on tests that do not exist, but do manual verification for user-visible changes.
6. **Ship** — Commit on a feature branch, push, open a PR with a clear description (what / why / how verified / assumptions / follow-ups). Watch CI if present; fix until checks pass.
7. **Report** — End with a concise summary, verification evidence, and open items.

Long-running work is fine: keep iterating until the task is **done**, not until a checkpoint. Make reasonable reversible assumptions; document them in the PR instead of pausing for approval.

### When to stop and ask the human

Only escalate for:

- Secrets, credentials, or paid API keys you cannot obtain safely
- Destructive or irreversible actions (deleting user data, force-pushing shared branches, production deploys, spending money)
- Genuinely ambiguous **product** decisions with no reasonable default

Otherwise decide, proceed, and note assumptions in the PR.

### Code hygiene

- No debug prints left behind, no commented-out code, no drive-by refactors.
- Match existing Swift style and file layout under `Sources/cmdcmd/`.
- Imports at top of file; exhaustive switches on discriminated unions where the codebase uses them.

### PR checklist

- [ ] Problem and solution stated plainly
- [ ] Verification commands run (listed) and outcomes noted
- [ ] Assumptions and follow-ups called out
- [ ] CI addressed if/when this repo adds workflows
