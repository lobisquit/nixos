# everything phony
MAKEFLAGS += --always-make

default: switch-self

switch-%:
	nixos-rebuild switch --flake .#$* --target-host root_$*

test-%:
	nixos-rebuild test --flake .#$* --target-host root_$*

clean-%:
	ssh root_$* 'nix-env --profile /nix/var/nix/profiles/system --delete-generations +2'
	ssh root_$* 'nix-env --profile /nix/var/nix/profiles/system --list-generations'
	nixos-rebuild boot --flake .#$* --target-host root_$*
	ssh root_$* 'nix-store --gc'

switch-self:
	sudo nixos-rebuild switch --flake '.#'

test-self:
	sudo nixos-rebuild test --flake '.#'

clean-self:
	sudo nix-env --profile /nix/var/nix/profiles/system --delete-generations +2
	sudo nix-env --profile /nix/var/nix/profiles/system --list-generations
#	sudo rm -rf /nix/var/nix/gcroots/auto/*
#	find ~ -name "result" -type l -exec readlink {} \; | grep "^/nix/store"
#	find ~ -name "result" -type l -delete
#	nix-shell -p home-manager --command 'home-manager expire-generations "-30 days"'
	sudo nix-collect-garbage -d
	sudo nixos-rebuild boot --flake '.#'

update:
	nix flake update

# Retention of the remote (B2) backups of all hosts, with the admin
# credentials only (the hosts can only add snapshots): no server needs to
# be reachable. Pass ARGS=--dry-run to see what would be removed.
prune_remote:
	scripts/restic_prune_remote.sh $(ARGS)

# Browse the remote (B2) backups of all hosts, read-only, in a private
# temporary folder of this PC, with the admin credentials only: no server
# needs to be reachable. Ctrl-C unmounts. ARGS are passed to restic mount
# (e.g. ARGS="--host nasus --tag Documenti").
mount_remote:
	scripts/restic_mount_remote.sh $(ARGS)

no-uncommitted-changes:
	@git diff --quiet

auto_upgrade-%: no-uncommitted-changes update
	git add flake.lock
	git commit -m 'Update $*' --allow-empty
	make switch-$*
	make clean-$*
