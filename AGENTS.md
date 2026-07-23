# AGENTS

Conventions every agent working in this repository must follow.

## Single control session (most important)

The headset exposes exactly **one** RFCOMM control channel. `Perch.app` and
`perch-probe` both open it, so running two control clients at once hangs the
second one. Coordinate through `tools/control-lock.sh`:

- Before launching either, acquire the lock; release it after stopping.
  `app-start` / `app-stop` / `probe` wrap acquire and release for you.
- If `status` reports BUSY, do not launch — find out who holds the lock first.
- Never stop or take over another owner's running session without `force`,
  and use `force` only deliberately, after coordinating.

## General rules

- Never hardcode device-specific values. Features, band counts, presets, and
  modes are all read from the device-declared capabilities.
- Never write Bluetooth addresses, user names, local paths, or device unit
  names into code, logs, docs, or the lock files.
- Multiple agents may edit this repository concurrently. If the build fails in
  code you did not touch, it may be another agent's work in progress — leave
  their code alone and verify your own change against the UI-independent
  targets (TandemCore / TandemSession) instead.
