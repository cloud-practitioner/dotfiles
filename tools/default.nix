# herdr, Claude Code, and Pi, built from each vendor's own release downloads -
# the artifacts their curl installers fetch - instead of nixpkgs builds, so the
# workstation and the devcontainer run the same pinned binaries.
# sources.json holds the pins (version, URL, and the vendor-published SHA-256);
# bump them all with `nix run .#update-tools` (update.sh).
{ lib, callPackage }:

let
  sources = lib.importJSON ./sources.json;
in
{
  claude-code = callPackage ./claude-code.nix { source = sources.claude-code; };
  herdr = callPackage ./herdr.nix { source = sources.herdr; };
  pi = callPackage ./pi.nix { source = sources.pi; };
}
