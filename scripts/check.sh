#!/usr/bin/env bash
set -euo pipefail

sigil_sha=15beabc44aff08a0566abe3405d722e35b9b8aa5
# sigil-db 核（ADR 0045）。段 2 は db/ の型付き関係 API とトランザクション API だけを使う。
sigil_db_sha=9483e36f08c35bfc62b3beeb008a531887506037
stash_sha=7dfcf15b24251d80904f8d54e54b735652b89303
rust_version=1.100.0
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT

fetch_pinned() {
  local url=$1 sha=$2 dir=$3
  git init -q "$dir"
  git -C "$dir" fetch --no-tags --depth=1 "$url" "$sha"
  git -C "$dir" checkout --detach FETCH_HEAD
  test "$(git -C "$dir" rev-parse HEAD)" = "$sha"
  test -z "$(git -C "$dir" status --porcelain --untracked-files=all)"
}

# The compiler embeds both the standard library and the native core.
sigil_root=${SIGIL_SOURCE:-"$scratch/sigil"}
if [[ -z ${SIGIL_SOURCE:-} ]]; then
  fetch_pinned https://github.com/goodnasubi/sigil.git "$sigil_sha" "$sigil_root"
fi
test "$(git -C "$sigil_root" rev-parse HEAD)" = "$sigil_sha"
test -z "$(git -C "$sigil_root" status --porcelain --untracked-files=all)"

db_root=${SIGIL_DB_CORE:-"$scratch/sigil-db"}
if [[ -z ${SIGIL_DB_CORE:-} ]]; then
  fetch_pinned https://github.com/goodnasubi/sigil-db.git "$sigil_db_sha" "$db_root"
fi
test "$(git -C "$db_root" rev-parse HEAD)" = "$sigil_db_sha"
test -z "$(git -C "$db_root" status --porcelain --untracked-files=all)"

stash_root=${SIGIL_STASH_KV:-"$scratch/sigil-stash-kv"}
if [[ -z ${SIGIL_STASH_KV:-} ]]; then
  fetch_pinned https://github.com/goodnasubi/sigil-stash-kv.git "$stash_sha" "$stash_root"
fi
test "$(git -C "$stash_root" rev-parse HEAD)" = "$stash_sha"
test -z "$(git -C "$stash_root" status --porcelain --untracked-files=all)"

cd "$sigil_root"
rustup toolchain install "$rust_version" --profile minimal --component rustfmt --component clippy
cargo +"$rust_version" fmt --check
cargo +"$rust_version" clippy --locked --all-targets -- -D warnings
cargo +"$rust_version" build --locked --release --bin sigil
cargo_target=${CARGO_TARGET_DIR:-target}
sigil="$cargo_target/release/sigil"

# The compiler only reads modules below its root, and a symlink that leaves the root is rejected,
# so the pinned core's db/ is copied next to this repository's modules in a scratch root.
root="$scratch/root"
mkdir -p "$root"
cp -R "$db_root/db" "$root/db"
mkdir -p "$root/stash"
cp "$stash_root"/stash/{memory,persistent}.sigil "$root/stash/"
cp "$repo_root"/sigil/*.sigil "$root/"

"$sigil" fmt --check "$repo_root"/sigil/*.sigil
"$sigil" test --ct --root "$root" --manifest "$repo_root/Sigil.toml"

run_entry() {
  local entry=$1 label=$2 evaluator native
  "$sigil" check --root "$root" "$root/$entry.sigil"
  evaluator=$("$sigil" run --root "$root" "$root/$entry.sigil" main | tail -n 1)
  if [[ "$evaluator" != 0 ]]; then
    printf '%s: evaluator test failed (%s)\n' "$label" "$evaluator" >&2
    exit 1
  fi
  "$sigil" build --root "$root" "$root/$entry.sigil" main -o "$scratch/$entry"
  native=$("$scratch/$entry" | tail -n 1)
  if [[ "$native" != 0 ]]; then
    printf '%s: native test failed (%s)\n' "$label" "$native" >&2
    exit 1
  fi
  printf '%s: evaluator and native tests passed.\n' "$label"
}

run_entry stage_one_test "Stage 1 core"
run_entry stage_two_throttle_test "Stage 2 throttle"
run_entry stage_two_users_test "Stage 2 users and login"
run_entry stage_two_recovery_test "Stage 2 interruption and recovery"
run_entry stage_two_cli_test "Stage 2 CLI commands"
run_entry stage_three_sessions_test "Stage 3 persistent sessions"

# Smoke test of the real command line: argument reading, exit codes and the output of the native executable.
# The one `register` below uses the full 100,000 iterations of the production setting.
cli="$scratch/rune-cli"
"$sigil" build --raw-argv --root "$root" "$root/rune_cli.sigil" main -o "$cli"
dir="$scratch/cli-users"
password='correct horse battery'
expect_exit() {
  local want=$1
  shift
  local got=0
  "$@" >"$scratch/cli.out" 2>&1 || got=$?
  if [[ $got -ne $want ]]; then
    printf 'CLI smoke test: expected exit %s, got %s: %s\n' "$want" "$got" "$*" >&2
    cat "$scratch/cli.out" >&2
    exit 1
  fi
  if grep -qF -- "$password" "$scratch/cli.out"; then
    printf 'CLI smoke test: the password appeared in the output\n' >&2
    exit 1
  fi
}
expect_exit 2 "$cli"
expect_exit 2 "$cli" register "--dir=$dir" --user=alice
expect_exit 0 env RUNE_AUTH_PASSWORD="$password" "$cli" register "--dir=$dir" --user=alice
grep -Eq '^u[0-9a-f]{32}$' "$scratch/cli.out"
expect_exit 4 env RUNE_AUTH_PASSWORD="$password" "$cli" register "--dir=$dir" --user=alice
expect_exit 5 env RUNE_AUTH_PASSWORD="$password" "$cli" register "--dir=$dir" --user='Bad Name'
expect_exit 0 "$cli" bump-generation "--dir=$dir" --user=alice
test "$(cat "$scratch/cli.out")" = 1
expect_exit 0 "$cli" disable "--dir=$dir" --user=alice
expect_exit 3 "$cli" disable "--dir=$dir" --user=ghost
expect_exit 2 "$cli" bogus "--dir=$dir" --user=alice
printf 'CLI smoke test passed.\n'
printf 'Stage 1 through stage 3 evaluator and native tests passed.\n'
