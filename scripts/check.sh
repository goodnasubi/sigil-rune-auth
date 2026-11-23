#!/usr/bin/env bash
set -euo pipefail

sigil_sha=ba4a5f1b7bf4764521cdef1ee60daf1819d30f81
rust_version=1.100.0
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT

# The compiler embeds both the standard library and the native core.
sigil_root=${SIGIL_SOURCE:-"$scratch/sigil"}
if [[ -z ${SIGIL_SOURCE:-} ]]; then
  git init -q "$sigil_root"
  git -C "$sigil_root" fetch --no-tags --depth=1 https://github.com/goodnasubi/sigil.git "$sigil_sha"
  git -C "$sigil_root" checkout --detach FETCH_HEAD
fi
test "$(git -C "$sigil_root" rev-parse HEAD)" = "$sigil_sha"
test -z "$(git -C "$sigil_root" status --porcelain --untracked-files=all)"

cd "$sigil_root"
rustup toolchain install "$rust_version" --profile minimal --component rustfmt --component clippy
cargo +"$rust_version" fmt --check
cargo +"$rust_version" clippy --locked --all-targets -- -D warnings
cargo +"$rust_version" build --locked --release --bin sigil
cargo_target=${CARGO_TARGET_DIR:-target}
sigil="$cargo_target/release/sigil"

root="$repo_root/sigil"
fixture="$root/stage_one_test.sigil"
"$sigil" fmt --check "$root/rune_auth.sigil" "$fixture"
"$sigil" check --root "$root" "$fixture"
eval_result=$("$sigil" run --root "$root" "$fixture" main)
if [[ "$eval_result" != 0 ]]; then
  printf 'Evaluator test failed (%s)\n' "$eval_result" >&2
  exit 1
fi
"$sigil" build --root "$root" "$fixture" main -o "$scratch/stage-one"
native_result=$("$scratch/stage-one")
if [[ "$native_result" != 0 ]]; then
  printf 'Native test failed (%s)\n' "$native_result" >&2
  exit 1
fi
printf 'Stage 1 evaluator and native tests passed.\n'
