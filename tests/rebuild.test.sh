#!/usr/bin/env bash
set -eu

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMPDIR="$ROOT" dotfiles_test_tmproot rebuild
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/home"
export HOME="$TMP_ROOT/home"
export TRACE="$TMP_ROOT/argv"
export PATH="$TMP_ROOT/bin:/usr/bin:/bin"
export BASH_ENV="$TMP_ROOT/bash-env"
export MOCK_OS=Linux NIX_STATUS=0 DOCKER_STATUS=1

cat >"$BASH_ENV" <<'EOF'
[() {
  if [[ $# == 3 && $1 == -f && $2 == /.dockerenv && $3 == ']' ]]; then
    return "$DOCKER_STATUS"
  fi
  builtin [ "$@"
}
EOF
cat >"$TMP_ROOT/bin/uname" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  -s) printf '%s\n' "$MOCK_OS" ;;
  -m) printf '%s\n' "$MOCK_ARCH" ;;
  *) exit 99 ;;
esac
EOF
cat >"$TMP_ROOT/bin/whoami" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' test-user
EOF
cat >"$TMP_ROOT/bin/nix" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$TRACE"
exit "$NIX_STATUS"
EOF
cat >"$TMP_ROOT/installed-home-manager" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' installed-cli >"$TRACE"
exit 97
EOF
cat >"$TMP_ROOT/bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$TRACE"
EOF
chmod +x "$TMP_ROOT/bin/"* "$TMP_ROOT/installed-home-manager"

for installed in yes no; do
  if [ "$installed" = yes ]; then
    cp "$TMP_ROOT/installed-home-manager" "$TMP_ROOT/bin/home-manager"
  else
    rm "$TMP_ROOT/bin/home-manager"
  fi
  for MOCK_ARCH in x86_64 aarch64 arm64; do
    export MOCK_ARCH
    case "$MOCK_ARCH" in
      x86_64) system=x86_64-linux ;;
      *) system=aarch64-linux ;;
    esac
    for profile in workstation docker remote codespaces; do
      unset REMOTE_CONTAINERS CODESPACES
      DOCKER_STATUS=1
      prefix=container-
      case "$profile" in
        workstation) prefix= ;;
        docker) DOCKER_STATUS=0 ;;
        remote) export REMOTE_CONTAINERS=1 ;;
        codespaces) export CODESPACES=1 ;;
      esac
      rm -f "$TRACE"
      bash "$ROOT/rebuild.sh" || fail "$installed/$MOCK_ARCH/$profile: rebuild failed"
      expected=$(printf '%s\n' run --inputs-from "$HOME/.dotfiles" home-manager -- switch --flake \
        "$HOME/.dotfiles#test-user@${prefix}${system}")
      [ "$(<"$TRACE")" = "$expected" ] || fail "$installed/$MOCK_ARCH/$profile: wrong CLI arguments"
      [ "$(readlink -f "$HOME/.dotfiles")" = "$ROOT" ] || fail "rebuild did not link the repo"
    done
  done
  pass "locked CLI without backup, home-manager installed=$installed, all Linux targets"
done

export NIX_STATUS=23
if bash "$ROOT/rebuild.sh"; then
  fail "Nix switch failure was ignored"
else
  status=$?
  [ "$status" -eq 23 ] || fail "Nix switch failure status was not preserved"
fi
pass "Nix switch failure propagates"

export MOCK_ARCH=riscv64
rm -f "$TRACE"
if bash "$ROOT/rebuild.sh" >"$TMP_ROOT/unsupported-output" 2>&1; then
  fail "unsupported CPU was accepted"
fi
[ ! -e "$TRACE" ] || fail "unsupported CPU invoked a switch"
pass "unsupported CPU stops before switching"

export MOCK_OS=Darwin
bash "$ROOT/rebuild.sh" || fail "Darwin rebuild failed"
expected=$(printf '%s\n' darwin-rebuild switch --flake "$HOME/.dotfiles#mac")
[ "$(<"$TRACE")" = "$expected" ] || fail "Darwin switch changed"
pass "Darwin still uses sudo darwin-rebuild"
