#!/usr/bin/env bash

# sets up sops in current git repository

git config --local filter.sops.smudge "./sops/sops.sh smudge %f"
git config --local filter.sops.clean "./sops/sops.sh clean %f"
git config --local filter.sops.required true
git config --local diff.sops.textconv "./sops/sops.sh textconv"

# also set the private key path via something like
# git config --local diff.age.private_key "~/.config/age/keys.txt"
git config age.private-key "/etc/age/enrico.txt"
