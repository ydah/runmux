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
runmux run [--config runmux.json] [--profile dev]
runmux check [--config runmux.json] [--profile dev]
runmux init [--config runmux.json]
runmux list [--config runmux.json] [--profile dev]
runmux --help
runmux --version
```

`check` validates the JSON config and selected profile without starting child processes. `list` prints the resolved process list. `run` starts autostart processes and opens the TUI.

## Config File

The default config file is `runmux.json`.

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
          "autostart": false
        }
      ]
    }
  ]
}
```

Each process must set exactly one of `cmd` or `argv`. `cmd` runs through the shell. `argv` runs directly.

## TUI Keys

```text
Up/Down or j/k  select process
Enter           start or stop selected process
r               restart selected process
a               start all processes
x               stop all processes
Tab             switch selected/all logs
p               toggle pause indicator
?               help overlay
q or Ctrl+C     stop children and quit
```

## Limitations

- POSIX is the primary MVP target. Windows behavior is separated but not complete.
- This is not a pseudo-terminal multiplexer; interactive child stdin is not forwarded.
- Child process stdout/stderr are piped into the TUI, so programs that require a real TTY may behave differently.
- ANSI escape sequences are stripped for display safety.
- Direct child processes are stopped; grandchildren may survive if the command spawns its own process tree.
- Unicode width handling is delegated to libvaxis, but complex logs can still render imperfectly in some terminals.

## Development

```sh
zig build
zig build test
zig build run -- --help
zig build run -- check --config runmux.example.json
zig build run -- list --config runmux.example.json
zig build run -- run --config runmux.example.json
```
