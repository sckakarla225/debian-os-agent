# Debian 13 OS Agent Harness

Kernel internals TUI assistant. Develop in Cursor on macOS; build and run on a Debian 13 OrbStack VM.

## Prerequisites (macOS)

- Rust/Cargo (optional for local edits; required only if you also `cargo run` locally)
- `rsync` (preinstalled on macOS)
- OrbStack with the `debian-13-vm` machine running
- SSH via OrbStack: `ssh debian-13-vm@orb` (see `orbctl ssh`)

## Debian 13 VM Setup (via OrbStack)

From your Mac:

```bash
# via ssh
ssh -t debian-13-vm@orb
# via orbstack
orb -m debian-13-vm
```

Then on the VM, install cargo + build reqs:

```bash
sudo apt update
sudo apt install -y build-essential pkg-config curl rsync

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"

rustc --version
cargo --version
mkdir -p ~/debian-os-agent
exit
```

## Dev Setup

Edit files locally, then:

```bash
make sync    # push sources to ~/debian-os-agent on the VM
make check   # compile-check on Debian
make run     # sync + cargo run on Debian (TUI; press Ctrl+Q to quit)
make shell   # SSH into the VM project directory
```

`make run` uses `ssh -t` so the Ratatui TUI gets a real terminal.

Do **not** sync `target/` — build artifacts stay on the VM.

## OrbStack notes

| Detail | Value |
|--------|--------|
| Machine | `debian-13-vm` |
| SSH (preferred) | `ssh debian-13-vm@orb` |
| Domain | `debian-13-vm.orb.local` |
| IP | `<IPV4_ADDR_HERE>` |

Prefer `debian-13-vm@orb` over the `.orb.local` hostname — that is OrbStack’s built-in SSH path and uses its key (`orbctl ssh`).

Override the Makefile defaults if needed:

```bash
make run VM=debian-13-vm@orb REMOTE_DIR=~/debian-os-agent
```
