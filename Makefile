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
	sudo nix-store --gc
	sudo nixos-rebuild boot --flake '.#'

update:
	nix flake update

no-uncommitted-changes:
	@git diff --quiet

auto_upgrade: no-uncommitted-changes update
	git add flake.lock
	git commit -m 'Update'
	make switch
	make clean
