# herdr, Claude Code, and Pi as each vendor's curl installer installs them,
# instead of nixpkgs builds, so every Linux home profile gets the same pinned
# versions. sources.json holds the pins (version, and for the binaries the URL
# and vendor-published SHA-256; Pi's npm lock is in pi/); bump them all with
# `nix run .#update-tools` (update.sh).
{ lib, callPackage }:

let
  sources = lib.importJSON ./sources.json;
in
{
  claude-code = callPackage ./claude-code.nix { source = sources.claude-code; };
  herdr = callPackage ./herdr.nix { source = sources.herdr; };
  pi = callPackage ./pi.nix { source = sources.pi; };
}
