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
cat >"$workdir/all.do" <<'EOF'
#!/usr/bin/env mshell
[redo-ifchange.msh target2.txt]!
"all" wl
EOF
cat >"$workdir/always.txt.do" <<'EOF'
#!/usr/bin/env mshell
[redo-always.msh]!
"always target" wl
EOF
cat >"$workdir/always-parent.txt.do" <<'EOF'
#!/usr/bin/env mshell
[redo-ifchange.msh always.txt]!
`always.txt` readFile w
EOF

run_redo() {
  (
    cd "$workdir"
    PATH="$repo_root/msh:$PATH" XDG_DATA_HOME="$data_home" msh "$repo_root/msh/redo.msh" "$@"
  )
}

db_query() {
  sqlite3 "$data_home/redo-msh/redo.sqlite3" "$1"
}

PATH="$repo_root/msh:$PATH" XDG_DATA_HOME="$data_home" msh "$repo_root/msh/redo.msh" root "$workdir" >/dev/null
root_list=$(PATH="$repo_root/msh:$PATH" XDG_DATA_HOME="$data_home" msh "$repo_root/msh/redo.msh" root list)
expect_eq "$root_list" "$workdir" "registered root list"
(
  cd "$workdir"
  PATH="$repo_root/msh:$PATH" XDG_DATA_HOME="$data_home" msh "$repo_root/msh/redo.msh" root remove . >/dev/null
)
empty_root_list=$(PATH="$repo_root/msh:$PATH" XDG_DATA_HOME="$data_home" msh "$repo_root/msh/redo.msh" root list)
expect_eq "$empty_root_list" "" "root list after removal"
PATH="$repo_root/msh:$PATH" XDG_DATA_HOME="$data_home" msh "$repo_root/msh/redo.msh" root "$workdir" >/dev/null

run_redo 2>"$workdir/first.err"
all_output=$(cat "$workdir/all")
expect_eq "$all_output" "all" "default all target output"
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

run_redo always-parent.txt 2>"$workdir/always-first.err"
always_parent_output=$(cat "$workdir/always-parent.txt")
expect_eq "$always_parent_output" "always target" "initial always-parent output"
always_first_err=$(cat "$workdir/always-first.err")
if [[ "$always_first_err" != *"rebuilt always.txt"* ]] || [[ "$always_first_err" != *"rebuilt always-parent.txt"* ]]; then
  fail "expected always target and parent to rebuild on first run"
fi

run_redo always-parent.txt 2>"$workdir/always-second.err"
always_second_err=$(cat "$workdir/always-second.err")
if [[ "$always_second_err" != *"rebuilt always.txt"* ]] || [[ "$always_second_err" != *"rebuilt always-parent.txt"* ]]; then
  fail "expected always target and parent to rebuild on second run"
fi

always_dep=$(db_query "select group_concat(source, '|') from (select source from Deps where base = '$base_sql' and target = 'always.txt' and kind = 'always' and phase = 'stable' order by source);")
expect_eq "$always_dep" "//ALWAYS" "redo-always stable dependency"

mkdir -p "$workdir/nested"
cp "$fixture_dir/target.txt.do" "$workdir/nested/"
cp "$fixture_dir/target2.txt.do" "$workdir/nested/"
cp "$fixture_dir/target2.msh" "$workdir/nested/"
(
  cd "$workdir/nested"
  PATH="$repo_root/msh:$PATH" XDG_DATA_HOME="$data_home" msh "$repo_root/msh/redo.msh" target2.txt >/dev/null 2>"$workdir/nested.err"
)
nested_output=$(cat "$workdir/nested/target2.txt")
expect_eq "$nested_output" $'Target contents new 2\nNEW LINE2' "nested target output under project root"
nested_err=$(cat "$workdir/nested.err")
case "$nested_err" in
  *"rebuilt nested/target2.txt"*) ;;
  *) fail "nested target under project root should rebuild the nested target" ;;
esac

mkdir "$workdir/subdir"
(
  cd "$workdir/subdir"
  PATH="$repo_root/msh:$PATH" XDG_DATA_HOME="$data_home" msh "$repo_root/msh/redo.msh" ../target2.txt
) 2>"$workdir/subdir.err"
if [[ -s "$workdir/subdir.err" ]]; then
  fail "subdirectory invocation should resolve to the same target without rebuilding"
fi

printf '%s\n' '#!/usr/bin/env mshell' '"Target contents from do change" wl' >"$workdir/target.txt.do"

run_redo target2.txt 2>"$workdir/do-change.err"
do_change_output=$(cat "$workdir/target2.txt")
expect_eq "$do_change_output" $'Target contents from do change\nNEW LINE2' "rebuild output after target do-file change"

do_change_err=$(cat "$workdir/do-change.err")
if [[ "$do_change_err" != *"rebuilt target.txt"* ]] || [[ "$do_change_err" != *"rebuilt target2.txt"* ]]; then
  fail "expected both target.txt and target2.txt to rebuild after target do-file change"
fi

printf '%s\n' '#!/usr/bin/env mshell' '`target.txt` readFile w' '"UPDATED" wl' >"$workdir/target2.msh"

run_redo target2.txt 2>"$workdir/third.err"
third_output=$(cat "$workdir/target2.txt")
expect_eq "$third_output" $'Target contents from do change\nUPDATED' "incremental rebuild output"

third_err=$(cat "$workdir/third.err")
case "$third_err" in
  *"rebuilt target2.txt"*) ;;
  *) fail "expected target2.txt rebuild after dependency change" ;;
esac

changed_uptodate=$(db_query "select uptodate from Files where base = '$base_sql' and name = 'target2.txt';")
expect_eq "$changed_uptodate" "n" "target2.txt uptodate after dependency change rebuild"

set +e
missing_output=$( (
  cd "$workdir"
  PATH="$repo_root/msh:$PATH" XDG_DATA_HOME="$data_home" msh "$repo_root/msh/redo.msh" aasdfasdfasdf
) 2>&1 )
missing_rc=$?
set -e
expect_eq "$missing_rc" "111" "missing target exit code"
case "$missing_output" in
  *"No such target and no build script found for aasdfasdfasdf"*) ;;
  *) fail "missing target should report a clear error" ;;
esac

printf 'smoke: ok\n'
