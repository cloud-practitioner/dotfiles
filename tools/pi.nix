# Pi's standalone release build. https://pi.dev/install.sh installs the
# release its installer API reports as latest; that same GitHub release
# publishes a self-contained binary per platform and a SHA256SUMS file, and the
# pin's sha256 is that file's entry (recorded as `checksums` in sources.json).
{ lib, stdenvNoCC, fetchurl, autoPatchelfHook, makeBinaryWrapper, libxcb, source }:

let
  inherit (stdenvNoCC.hostPlatform) system;
  platform = source.platforms.${system} or (throw "pi: no pinned release for ${system}");
in
stdenvNoCC.mkDerivation {
  pname = "pi";
  inherit (source) version;

  src = fetchurl { inherit (platform) url sha256; };
  sourceRoot = "pi";

  dontBuild = true;
  # A Bun single-file executable: stripping drops the embedded app.
  dontStrip = true;

  nativeBuildInputs = [ autoPatchelfHook makeBinaryWrapper ];
  # The bundled X11 clipboard addon (native/linux/prebuilds/*/*.node).
  buildInputs = [ libxcb ];

  # The binary reads its themes, docs, and addons from beside itself, so the
  # release directory stays intact. `pi update` can't replace a standalone
  # binary, and skipping the version check keeps Pi from nagging about the pin.
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/libexec"
    cp -r . "$out/libexec/pi"
    makeBinaryWrapper "$out/libexec/pi/pi" "$out/bin/pi" \
      --set PI_SKIP_VERSION_CHECK 1
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    HOME="$TMPDIR" "$out/bin/pi" --version | grep -Fx "${source.version}"
  '';

  meta = {
    description = "Pi coding agent CLI (vendor standalone build)";
    homepage = "https://pi.dev";
    license = lib.licenses.mit;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = builtins.attrNames source.platforms;
    mainProgram = "pi";
  };
}
