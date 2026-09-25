# herdr as its vendor's curl installer installs it, instead of the nixpkgs
# build, so every Linux home profile gets the same pinned version.
# sources.json holds the pin (version, URL, and vendor-published SHA-256);
# bump it with `nix run .#update-tools` (update.sh). Claude Code, Pi, and the
# GitHub Copilot CLI are not pinned here: home.nix installs them unpinned with
# pnpm (node-tools.sh).
{ lib, callPackage }:

let
  sources = lib.importJSON ./sources.json;
in
{
  herdr = callPackage ./herdr.nix { source = sources.herdr; };
}
