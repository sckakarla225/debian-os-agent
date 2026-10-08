# Simulations for Harness Testing

Simulated hardware environments for testing the harness. Each sim stands up real Debian 13 (trixie) systems that act as a specific kind of hardware, and generates kernel state to access via the harness.

The sims are kept separate from the harness code. Nothing in `sims/` depends on the harness. To use one, deploy the sim, copy the harness binary onto one of its nodes, and run it there over SSH.

Each hardware type has its own folder. A folder can hold several sims (via imported or custom libraries) that share setup and docs.

All sims run inside the `debian-13-vm` OrbStack machine described in the [root README](../README.md).

## Supported Hardware

| Hardware | Folder |
|----------|--------|
| Ethernet Switches | [`eth-switches/`](eth-switches/README.md) |