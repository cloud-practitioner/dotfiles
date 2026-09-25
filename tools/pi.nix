# Pi's npm release, as installed by https://pi.dev/install.sh. The installer
# takes the release's package.json and package-lock.json from pi.dev's
# installer API and runs `npm ci --ignore-scripts` on them. tools/pi/ holds
# those two files, written by update.sh, which adds the hashes of Pi's own
# packages that the lock leaves out. The lock's integrity hashes then pin every
# package, so Nix installs the same dependency closure, run on the nixpkgs
# Node.js.
{ lib, stdenvNoCC, importNpmLock, nodejs, makeBinaryWrapper, source }:

let
  nodeModules = importNpmLock.buildNodeModules {
    npmRoot = ./pi;
    inherit nodejs;
    # Like the installer, never run the dependencies' install scripts.
    derivationArgs.npmRebuildFlags = [ "--ignore-scripts" ];
  };
in
stdenvNoCC.mkDerivation {
  pname = "pi";
  inherit (source) version;

  dontUnpack = true;
  dontBuild = true;

  nativeBuildInputs = [ makeBinaryWrapper ];

  # npm links bin/pi with a shebang patched to the nixpkgs Node.js. `pi update`
  # refuses to replace a read-only install no package manager owns, and
  # skipping the version check keeps Pi from nagging about the pin.
  installPhase = ''
    runHook preInstall
    makeBinaryWrapper "${nodeModules}/node_modules/.bin/pi" "$out/bin/pi" \
      --set PI_SKIP_VERSION_CHECK 1
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    HOME="$TMPDIR" "$out/bin/pi" --version | grep -Fx "${source.version}"
  '';

  meta = {
    description = "Pi coding agent CLI (vendor npm release)";
    homepage = "https://pi.dev";
    license = lib.licenses.mit;
    inherit (nodejs.meta) platforms;
    mainProgram = "pi";
  };
}
