#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
fixture_dir="$repo_root/msh/test/1"

fail() {
  printf 'smoke: %s\n' "$*" >&2
  exit 1
}

expect_eq() {
  local actual=$1
  local expected=$2
  local label=$3
  if [[ "$actual" != "$expected" ]]; then
    fail "$label: expected [$expected], got [$actual]"
  fi
}

sql_quote() {
  printf '%s' "$1" | sed "s/'/''/g"
}

workdir=$(mktemp -d /tmp/mredo-smoke-work.XXXXXX)
data_home=$(mktemp -d /tmp/mredo-smoke-xdg.XXXXXX)
base_sql=$(sql_quote "$workdir")

cp "$fixture_dir/target.txt.do" "$workdir/"
cp "$fixture_dir/target2.txt.do" "$workdir/"
cp "$fixture_dir/target2.msh" "$workdir/"

run_redo() {
  (
    cd "$workdir"
    XDG_DATA_HOME="$data_home" msh "$repo_root/msh/redo.msh" "$@"
  )
}

db_query() {
  sqlite3 "$data_home/redo-msh/redo.sqlite3" "$1"
}

XDG_DATA_HOME="$data_home" msh "$repo_root/msh/redo.msh" root "$workdir" >/dev/null
root_list=$(XDG_DATA_HOME="$data_home" msh "$repo_root/msh/redo.msh" root list)
expect_eq "$root_list" "$workdir" "registered root list"
(
  cd "$workdir"
  XDG_DATA_HOME="$data_home" msh "$repo_root/msh/redo.msh" root remove . >/dev/null
)
empty_root_list=$(XDG_DATA_HOME="$data_home" msh "$repo_root/msh/redo.msh" root list)
expect_eq "$empty_root_list" "" "root list after removal"
XDG_DATA_HOME="$data_home" msh "$repo_root/msh/redo.msh" root "$workdir" >/dev/null

run_redo target2.txt 2>"$workdir/first.err"
initial_output=$(cat "$workdir/target2.txt")
expect_eq "$initial_output" $'Target contents new 2\nNEW LINE2' "initial build output"

initial_deps=$(db_query "select group_concat(source, '|') from (select source from Deps where base = '$base_sql' and target = 'target2.txt' and phase = 'stable' order by source);")
expect_eq "$initial_deps" "target.txt|target2.msh|target2.txt.do" "stable deps after first build"

run_redo target2.txt 2>"$workdir/second.err"
if [[ -s "$workdir/second.err" ]]; then
  fail "second build should be clean"
fi

clean_uptodate=$(db_query "select uptodate from Files where base = '$base_sql' and name = 'target2.txt';")
expect_eq "$clean_uptodate" "y" "target2.txt uptodate after clean rebuild"

mkdir "$workdir/subdir"
(
  cd "$workdir/subdir"
  XDG_DATA_HOME="$data_home" msh "$repo_root/msh/redo.msh" ../target2.txt
) 2>"$workdir/subdir.err"
if [[ -s "$workdir/subdir.err" ]]; then
  fail "subdirectory invocation should resolve to the same target without rebuilding"
fi

printf '%s\n' '#!/usr/bin/env mshell' '`target.txt` readFile w' '"UPDATED" wl' >"$workdir/target2.msh"

run_redo target2.txt 2>"$workdir/third.err"
third_output=$(cat "$workdir/target2.txt")
expect_eq "$third_output" $'Target contents new 2\nUPDATED' "incremental rebuild output"

third_err=$(cat "$workdir/third.err")
case "$third_err" in
  *"rebuilt target2.txt"*) ;;
  *) fail "expected target2.txt rebuild after dependency change" ;;
esac

changed_uptodate=$(db_query "select uptodate from Files where base = '$base_sql' and name = 'target2.txt';")
expect_eq "$changed_uptodate" "n" "target2.txt uptodate after dependency change"

printf 'smoke: ok\n'
