# Usage:
#   make sync    # push sources to the VM
#   make run     # sync, then cargo run on Debian (interactive TUI)
#   make check   # sync, then cargo check on Debian
#   make shell   # open an interactive shell on the VM in the project dir

VM ?= debian-13-vm@orb
REMOTE_DIR ?= ~/debian-os-agent

RSYNC_EXCLUDES := --exclude target/ --exclude .git/ --exclude .DS_Store --exclude 'clab-*/'

.PHONY: sync run check shell setup-hint

sync:
	rsync -avz --inplace --delete $(RSYNC_EXCLUDES) ./ $(VM):$(REMOTE_DIR)/

run: sync
	ssh -t $(VM) 'source "$$HOME/.cargo/env" 2>/dev/null; cd $(REMOTE_DIR) && cargo run'

check: sync
	ssh -t $(VM) 'source "$$HOME/.cargo/env" 2>/dev/null; cd $(REMOTE_DIR) && cargo check'

shell:
	ssh -t $(VM) 'cd $(REMOTE_DIR) 2>/dev/null || cd ~; exec $$SHELL -l'

setup-hint:
	@echo "On the VM (one-time), run the setup commands in README.md"
	@echo "SSH host for this project: $(VM)"