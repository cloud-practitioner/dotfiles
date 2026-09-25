# Claude Code's native build, as installed by https://claude.ai/install.sh.
# The pin's sha256 is the per-platform checksum from the release's
# manifest.json (recorded as `checksums` in sources.json), verbatim.
{ lib, stdenvNoCC, fetchurl, autoPatchelfHook, makeBinaryWrapper, source }:

let
  inherit (stdenvNoCC.hostPlatform) system;
  platform = source.platforms.${system} or (throw "claude-code: no pinned release for ${system}");
in
stdenvNoCC.mkDerivation {
  pname = "claude-code";
  inherit (source) version;

  src = fetchurl { inherit (platform) url sha256; };

  dontUnpack = true;
  dontBuild = true;
  # A Bun single-file executable: stripping drops the embedded app.
  dontStrip = true;

  nativeBuildInputs = [ autoPatchelfHook makeBinaryWrapper ];

  # The Nix pin is authoritative: no background auto-updates, and
  # DISABLE_UPDATES also refuses `claude update` / `claude install`, which would
  # otherwise drop a second, unpinned copy into ~/.local. Don't warn that the
  # binary isn't where install.sh would have put it.
  installPhase = ''
    runHook preInstall
    install -Dm755 "$src" "$out/libexec/claude-code/claude"
    makeBinaryWrapper "$out/libexec/claude-code/claude" "$out/bin/claude" \
      --set DISABLE_AUTOUPDATER 1 \
      --set DISABLE_UPDATES 1 \
      --set DISABLE_INSTALLATION_CHECKS 1
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    HOME="$TMPDIR" "$out/bin/claude" --version | grep -F "${source.version}"
  '';

  meta = {
    description = "Claude Code, Anthropic's agentic coding CLI (vendor native build)";
    homepage = "https://code.claude.com";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = builtins.attrNames source.platforms;
    mainProgram = "claude";
  };
}
