#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid

git init -q -b main "$TMP/upstream"
mkdir -p "$TMP/upstream/scripts"
cp "$ROOT/audio.cpp_build" "$TMP/upstream/"
cat > "$TMP/upstream/scripts/build_linux.sh" <<'BUILD'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$BUILD_LOG"
[[ "$CUDA_HOME" == /opt/cuda && "$CUDACXX" == /opt/cuda/bin/nvcc ]]
exit "${BUILD_EXIT:-0}"
BUILD
chmod +x "$TMP/upstream/scripts/build_linux.sh"
echo /build/ > "$TMP/upstream/.gitignore"
echo base > "$TMP/upstream/shared"
git -C "$TMP/upstream" add .
git -C "$TMP/upstream" commit -qm base
git clone -q -o upstream "$TMP/upstream" "$TMP/personal"
git -C "$TMP/personal" switch -qc personal
export BUILD_LOG="$TMP/build.log"

run_build() {
    (cd /; zsh "$TMP/personal/audio.cpp_build" "$@") > "$TMP/output" 2>&1
}
expect_failure() {
    rm -f "$BUILD_LOG"
    if run_build; then
        echo "Expected failure" >&2
        exit 1
    fi
    [[ ! -e "$BUILD_LOG" ]]
}

# A clean divergent update must produce a merge and preserve personal changes.
echo personal > "$TMP/personal/local"
git -C "$TMP/personal" add local
git -C "$TMP/personal" commit -qm personal
echo upstream > "$TMP/upstream/update"
git -C "$TMP/upstream" add update
git -C "$TMP/upstream" commit -qm update
run_build --jobs 2
git -C "$TMP/personal" merge-base --is-ancestor upstream/main HEAD
[[ "$(git -C "$TMP/personal" show HEAD:local)" == personal ]]
[[ "$(git -C "$TMP/personal" rev-list --parents -n 1 HEAD | wc -w)" -eq 3 ]]
grep -Fxq fish_drama3,fish_audio "$BUILD_LOG"
grep -Fxq audiocpp_server "$BUILD_LOG"
[[ "$(tail -n 2 "$BUILD_LOG")" == $'--jobs\n2' ]]
run_build

# Dirty files, untracked files and other branches must stop before building.
echo dirty >> "$TMP/personal/shared"
expect_failure
git -C "$TMP/personal" restore shared
touch "$TMP/personal/untracked"
expect_failure
rm "$TMP/personal/untracked"
git -C "$TMP/personal" switch -q main
expect_failure
git -C "$TMP/personal" switch -q personal

# A failed fetch must not build.
git -C "$TMP/personal" remote set-url upstream "$TMP/missing"
expect_failure
git -C "$TMP/personal" remote set-url upstream "$TMP/upstream"

# Build failures keep their output directory and return an error.
mkdir -p "$TMP/personal/build"
touch "$TMP/personal/build/sentinel"
export BUILD_EXIT=7
if run_build; then exit 1; fi
[[ -e "$BUILD_LOG" && -e "$TMP/personal/build/sentinel" ]]
grep -Fq "Build failed" "$TMP/output"
unset BUILD_EXIT

# Conflicts must leave the merge available for manual resolution, without building.
echo personal > "$TMP/personal/shared"
git -C "$TMP/personal" commit -qam "personal conflict"
echo upstream > "$TMP/upstream/shared"
git -C "$TMP/upstream" commit -qam "upstream conflict"
expect_failure
[[ -n "$(git -C "$TMP/personal" diff --name-only --diff-filter=U)" ]]
git -C "$TMP/personal" rev-parse --verify MERGE_HEAD > /dev/null
grep -Fq "Resolve conflicts" "$TMP/output"
expect_failure

echo "PASS: clean merge, build arguments, dirty tree, branch, fetch/build failures, and conflicts"
