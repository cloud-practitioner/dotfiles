# herdr's release binary, as installed by https://herdr.dev/install.sh.
# The pin's url and sha256 come verbatim from the release manifest
# (https://herdr.dev/latest.json, recorded as `checksums` in sources.json).
# The binary is static, so it runs from the store unpatched. It refuses
# `herdr update` for /nix/store installs; home/.config/herdr/config.toml turns
# off its background version check.
{ lib, stdenvNoCC, fetchurl, installShellFiles, source }:

let
  inherit (stdenvNoCC.hostPlatform) system;
  platform = source.platforms.${system} or (throw "herdr: no pinned release for ${system}");
in
stdenvNoCC.mkDerivation {
  pname = "herdr";
  inherit (source) version;

  src = fetchurl { inherit (platform) url sha256; };

  dontUnpack = true;
  dontBuild = true;

  nativeBuildInputs = [ installShellFiles ];

  installPhase = ''
    runHook preInstall
    install -Dm755 "$src" "$out/bin/herdr"
    installShellCompletion --cmd herdr \
      --bash <("$out/bin/herdr" completion bash) \
      --zsh <("$out/bin/herdr" completion zsh)
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    "$out/bin/herdr" --version | grep -Fx "herdr ${source.version}"
  '';

  meta = {
    description = "Agent multiplexer that lives in your terminal (vendor release binary)";
    homepage = "https://herdr.dev";
    license = lib.licenses.asl20;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = builtins.attrNames source.platforms;
    mainProgram = "herdr";
  };
}
