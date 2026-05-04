# runmux

`runmux` is a lightweight Zig TUI command runner for starting, watching, stopping, and restarting multiple development processes from one terminal.

## Install / Build

```sh
zig build
```

This project targets Zig 0.16.0 and uses libvaxis for terminal rendering.

## Quick Start

```sh
zig build run -- init
zig build run -- check
zig build run -- list
zig build run -- run
```

## Commands

```sh
runmux run [--config runmux.json] [--profile dev] [--plain] [--log-dir logs] [--exit-on-critical-failure] [--theme dark|light|mono]
runmux check [--config runmux.json] [--profile dev]
runmux init [--config runmux.json]
runmux list [--config runmux.json] [--profile dev]
runmux --help
runmux --version
```

`check` validates the JSON or TOML config and selected profile without starting child processes. `list` prints the resolved process list. `run` starts autostart processes and opens the TUI. Use `run --plain` to run without the TUI and print prefixed logs; this is useful in CI and non-interactive terminals. Use `--log-dir` to write one log file per process. Use `--exit-on-critical-failure` to stop the run when a `critical` process fails. Use `--theme` to select `dark`, `light`, or `mono` TUI colors.

## Config File

The default config file is `runmux.json`. Files ending in `.toml` are accepted with the same schema.

```json
{
  "version": 1,
  "default_profile": "dev",
  "defaults": {
    "cwd": ".",
    "shell": true,
    "autostart": true,
    "restart": {
      "policy": "never",
      "max_restarts": 0,
      "delay_ms": 1000
    },
    "log": {
      "max_lines": 1000,
      "strip_ansi": true
    }
  },
  "profiles": [
    {
      "name": "dev",
      "processes": [
        {
          "name": "clock",
          "cmd": "while true; do date; sleep 1; done"
        },
        {
          "name": "stderr-demo",
          "cmd": "while true; do echo warn >&2; sleep 2; done"
        },
        {
          "name": "manual",
          "cmd": "echo manual process; sleep 5",
          "depends_on": ["clock"],
          "dependency_failure": "ignore",
          "health": {
            "argv": ["/bin/sh", "-c", "exit 0"],
            "interval_ms": 1000,
            "timeout_ms": 5000,
            "retries": 3
          },
          "autostart": false
        }
      ]
    }
  ]
}
```

Each process must set exactly one of `cmd` or `argv`. `cmd` runs through the shell by default. If `shell` is set to `false`, `cmd` must be a single executable path with no arguments; use `argv` for direct execution with arguments. Set `depends_on` to delay a process until dependencies are ready. A dependency is ready when it is running with no health check, has passed its health check, or has exited successfully. Set `dependency_failure` to `ignore`, `stop`, or `restart` to choose what happens when a dependency fails after startup.
Health checks run asynchronously and support `timeout_ms`; a timeout counts as a failed attempt and the process is stopped after `retries` is exhausted.

Equivalent TOML:

```toml
version = 1
default_profile = "dev"

[defaults]
cwd = "."
shell = true
autostart = true

[defaults.restart]
policy = "never"
max_restarts = 0
delay_ms = 1000

[defaults.log]
max_lines = 1000
strip_ansi = true

[[profiles]]
name = "dev"

[[profiles.processes]]
name = "clock"
cmd = "while true; do date; sleep 1; done"

[[profiles.processes]]
name = "manual"
cmd = "echo manual process; sleep 5"
depends_on = ["clock"]
dependency_failure = "ignore"
autostart = false

[profiles.processes.health]
argv = ["/bin/sh", "-c", "exit 0"]
interval_ms = 1000
timeout_ms = 5000
retries = 3
```

## TUI Keys

```text
Up/Down or j/k  select process
Enter           start or stop selected process
r               restart selected process
a               start all processes
x               stop all processes
Tab             switch selected/all logs
/               search logs by substring
i               send one line to selected stdin
s               cycle stream filter
f               filter logs to selected process
u               clear log filters
p               pause or resume log follow
?               help overlay
q or Ctrl+C     stop children and quit
```

## Limitations

- POSIX is the primary target. Windows uses `COMSPEC` for shell commands and Job Objects for process-tree cleanup when available.
- This is not a pseudo-terminal multiplexer; interactive child stdin is not forwarded.
- Child process stdout/stderr are piped into the TUI, so programs that require a real TTY may behave differently.
- ANSI escape sequences are stripped by default. If `log.strip_ansi` is `false`, basic SGR color/style codes are rendered safely and other escape sequences are dropped.
- POSIX child processes are started in a dedicated process group so stop/kill targets their process tree. Windows child processes are assigned to a Job Object when possible, with direct-process termination as a fallback.
- Unicode width handling is delegated to libvaxis, but complex logs can still render imperfectly in some terminals.

## Development

```sh
zig build
zig build test
zig build run -- --help
zig build run -- check --config runmux.example.json
zig build run -- list --config runmux.example.json
zig build run -- run --config runmux.example.json
zig build run -- run --plain --config testdata/plain.runmux.json
zig build run -- run --plain --config testdata/plain.runmux.json --log-dir logs
```
