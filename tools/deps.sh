# shellcheck shell=bash
# tools/deps.sh — Dependency Finder.
#
# Which repos use a library matching your keywords (e.g. "sdk", "@aws-sdk/*", "firebase")?
# Reads the dependency manifests on one branch of every repo (package.json, pom.xml,
# build.gradle, go.mod, requirements.txt, …) and optionally searches the source code.
#
# GitLab APIs used (all read-only):
#   GET /projects/:id                                       default branch
#   GET /projects/:id/repository/tree?recursive=true&ref=   find manifest files
#   GET /projects/:id/repository/files/:path?ref=           manifest content (base64)
#   GET /projects/:id/search?scope=blobs&search=&ref=       optional source code search
#
# Manifest parsing lives in tools/deps-parse.jq. Repo input is shared with the
# Branch & Committer Report: BC_TARGETS → bc_expand_targets.

TOOL_DP_NAME="Dependency Finder"

DP_RESULTS="USED CODE_ONLY NOT_FOUND NO_MANIFEST ERROR"

# path → manifest type (null = not a manifest). Vendored / installed folders are skipped.
DP_JQ_FTYPE='
def ftype: (split("/") | last) as $b
  | if test("(^|/)(node_modules|vendor|bower_components|\\.git|Pods|\\.venv|venv|site-packages|\\.gradle)/") then null
    elif $b == "package.json" then "npm"
    elif $b == "composer.json" then "composer"
    elif ($b | test("^requirements.*\\.txt$")) or test("(^|/)requirements/[^/]+\\.txt$") then "pip"
    elif $b == "Pipfile" then "pipfile"
    elif $b == "pyproject.toml" then "pyproject"
    elif $b == "setup.py" then "setuppy"
    elif $b == "go.mod" then "gomod"
    elif $b == "Gemfile" then "gem"
    elif $b == "Podfile" then "pod"
    elif $b == "pom.xml" then "maven"
    elif $b == "build.gradle" or $b == "build.gradle.kts" then "gradle"
    elif ($b | test("\\.versions\\.toml$")) then "gradlecat"
    elif $b == "build.sbt" then "sbt"
    elif ($b | test("\\.(csproj|fsproj|vbproj)$")) or $b == "Directory.Packages.props" then "nuget"
    elif $b == "packages.config" then "nugetcfg"
    elif $b == "Cargo.toml" then "cargo"
    elif $b == "pubspec.yaml" then "pub"
    else null end;'

dp_defaults() {
  bc_defaults
  DP_KEYWORDS=""
  DP_REF=""
  DP_CODE=0
  DP_OUT=""
  DP_WORKERS=6
  DP_MAX_TREE=20000
  DP_MAX_FILES=300
  DP_MAX_HITS=50
  DP_ROWS=60
}

# "sdk, @aws-sdk/*" → [{kw, re}]. No * or ? = "name contains"; with them = glob on the whole name.
_dp_kw_json() {
  local k re
  while IFS= read -r k; do
    k=$(_sc_trim "$k")
    [ -z "$k" ] && continue
    case "$k" in
      *[*?]*) re=$(_sc_glob_re "$k") ;;
      *) re=$(printf '%s' "$k" | sed -e 's/[][\.^$+(){}|*?]/\\&/g') ;;
    esac
    jq -nc --arg k "$k" --arg r "$re" '{kw: $k, re: $r}'
  done < <(printf '%s\n' "$1" | tr ',' '\n') | jq -sc .
}

_dp_icon() {
  case "$1" in
    USED) printf '%s✔%s' "$CG" "$RST" ;;
    CODE_ONLY) printf '%s◆%s' "$CY" "$RST" ;;
    NOT_FOUND) printf '%s·%s' "$DIM" "$RST" ;;
    NO_MANIFEST) printf '%s–%s' "$DIM" "$RST" ;;
    *) printf '%s!%s' "$CR" "$RST" ;;
  esac
}

# ---------- worker (one process per repo, run in parallel via bc_run_tasks) ----------
dp_worker() {
  local i="$1" line host path err out d pid defb ref n k term tree_trunc=0 files_trunc=0 mf mt
  line=$(awk -F'\t' -v i="$i" '$1 == i' "$DP_WORK/tasks.tsv")
  host=$(printf '%s' "$line" | cut -f2); path=$(printf '%s' "$line" | cut -f3); err=$(printf '%s' "$line" | cut -f4)
  path=$(_bc_strip_prefix "$path" "$host")
  out="$DP_WORK/r/$(printf '%05d' "$i").json"
  d="$DP_WORK/w$i"; mkdir -p "$d"

  _dp_fail() { jq -n --arg p "$path" --arg e "$1" '{project: $p, result: "ERROR", error: $e}' >"$out"; rm -rf "$d"; echo "$i" >>"$DP_WORK/done"; }
  [ -n "$err" ] && { _dp_fail "$err"; return 0; }
  api_get "/projects/$(_uri "$path")" "$d/project.json" || { _dp_fail "$API_ERROR"; return 0; }
  pid=$(jq -r '.id' "$d/project.json")
  defb=$(jq -r '.default_branch // empty' "$d/project.json")
  ref="${DP_REF:-$defb}"
  : >"$d/manifests.jsonl"; : >"$d/deps.jsonl"; echo '[]' >"$d/hits.json"

  if [ -n "$ref" ]; then
    # 1) manifests anywhere in the tree of the branch
    if api_get_all "/projects/$pid/repository/tree?recursive=true&ref=$(_uri "$ref")" "$d/tree.json" "$DP_MAX_TREE"; then
      tree_trunc=$API_TRUNCATED
      jq -c "$DP_JQ_FTYPE"' .[] | select(.type == "blob") | {path, type: (.path | ftype)} | select(.type != null)' \
        "$d/tree.json" >"$d/mlist.jsonl"
      n=$(sed -n '$=' "$d/mlist.jsonl"); n=${n:-0}
      [ "$n" -gt "$DP_MAX_FILES" ] && files_trunc=1
      head -n "$DP_MAX_FILES" "$d/mlist.jsonl" | while IFS= read -r line; do
        mf=$(printf '%s' "$line" | jq -r '.path'); mt=$(printf '%s' "$line" | jq -r '.type')
        if api_get "/projects/$pid/repository/files/$(_uri "$mf")?ref=$(_uri "$ref")" "$d/f.json" &&
          jq -r '.content | @base64d' "$d/f.json" >"$d/f.txt" 2>/dev/null; then
          jq -Rs -c --arg type "$mt" -f "$GLB_ROOT/tools/deps-parse.jq" "$d/f.txt" >"$d/f.deps"
          jq -c --arg f "$mf" '.[] + {file: $f}' "$d/f.deps" >>"$d/deps.jsonl"
          jq -nc --arg f "$mf" --arg t "$mt" --slurpfile x "$d/f.deps" '{path: $f, type: $t, dependencies: ($x[0] | length)}' >>"$d/manifests.jsonl"
        else
          jq -nc --arg f "$mf" --arg t "$mt" --arg e "$API_ERROR" '{path: $f, type: $t, dependencies: 0, error: $e}' >>"$d/manifests.jsonl"
        fi
      done
    else
      printf 'tree: %s' "$API_ERROR" >"$d/note"
    fi

    # 2) optional: source code search per keyword (GitLab search API, rate-limited)
    if [ "$DP_CODE" = 1 ]; then
      printf '%s' "$DP_KW_JSON" | jq -r '.[].kw' | while IFS= read -r k; do
        term=$(printf '%s' "$k" | tr -d '*?')
        [ -z "$term" ] && continue
        if api_get_all "/projects/$pid/search?scope=blobs&search=$(_uri "$term")&ref=$(_uri "$ref")" "$d/s.json" "$DP_MAX_HITS"; then
          jq -c --arg k "$k" --arg t "$term" '[.[] | {keyword: $k, path, line: .startline,
              text: ((.data // "") | split("\n") | (map(select(ascii_downcase | contains($t | ascii_downcase))) | first) // .[0] // "" | gsub("^\\s+|\\s+$"; "") | .[:160])}]' \
            "$d/s.json" >"$d/s.hits"
          jq -s 'add' "$d/hits.json" "$d/s.hits" >"$d/h.tmp" && mv "$d/h.tmp" "$d/hits.json"
        else
          printf '%scode search: %s' "$([ -s "$d/note" ] && printf '; ')" "$API_ERROR" >>"$d/note"
        fi
      done
    fi
  fi

  jq -n --slurpfile p "$d/project.json" --slurpfile m "$d/manifests.jsonl" --slurpfile deps "$d/deps.jsonl" \
    --slurpfile h "$d/hits.json" --argjson kws "$DP_KW_JSON" --arg ref "$ref" \
    --argjson tt "$tree_trunc" --argjson ft "$files_trunc" --argjson maxf "$DP_MAX_FILES" --arg note "$(cat "$d/note" 2>/dev/null)" '
    $p[0] as $p
    | ([$deps[] as $d | $kws[] as $k | select($d.name | test($k.re; "i")) | $d + {keyword: $k.kw}]
       | group_by([.file, .name, .version, .scope]) | map(.[0] + {keyword: (map(.keyword) | unique | join(", "))})
       | sort_by(.name, .file)) as $matches
    | ($h[0] // []) as $hits
    | {
        project: $p.path_with_namespace, id: $p.id, web_url: $p.web_url, ref: (if $ref == "" then null else $ref end),
        result: (if ($matches | length) > 0 then "USED"
                 elif ($hits | length) > 0 then "CODE_ONLY"
                 elif $ref == "" or ($m | length) == 0 then "NO_MANIFEST"
                 else "NOT_FOUND" end),
        manifests: $m, dependencies_total: ($deps | length),
        matches: $matches, code_hits: $hits,
        note: ([(if $ref == "" then "Empty repository (no default branch)" else empty end),
                (if $tt == 1 then "File tree truncated (very large repo) — some manifests may be missed" else empty end),
                (if $ft == 1 then "Only the first \($maxf) manifests were read" else empty end),
                (if $note != "" then $note else empty end)] | join("; ") | if . == "" then null else . end),
        error: null
      }' >"$out" 2>"$d/jq.err" || _dp_fail "parse: $(head -c 200 "$d/jq.err")"
  rm -rf "$d"
  echo "$i" >>"$DP_WORK/done"
}

# ---------- run ----------
dp_run() {
  local t0=$SECONDS report outdir
  DP_WORK="$GLB_TMP/dp"
  rm -rf "$DP_WORK"; mkdir -p "$DP_WORK/r"
  BC_WORK="$DP_WORK"
  DP_KW_JSON=$(_dp_kw_json "$DP_KEYWORDS")
  [ "$(printf '%s' "$DP_KW_JSON" | jq 'length')" -gt 0 ] || { ui_err "Enter at least one library keyword."; return 1; }

  ui_title "Finding dependencies" "keywords: $DP_KEYWORDS · branch: ${DP_REF:-default branch}$([ "$DP_CODE" = 1 ] && printf ' · + code search') · $GLB_URL"
  bc_expand_targets
  BC_N=${#BC_T_PATH[@]}
  if [ "$BC_N" -eq 0 ]; then ui_err "No valid repos to scan."; return 1; fi

  export DP_WORK DP_KW_JSON DP_REF DP_CODE DP_MAX_TREE DP_MAX_FILES DP_MAX_HITS DP_JQ_FTYPE GLB_ROOT GLB_TIMEOUT GLB_VERSION
  bc_run_tasks "$DP_WORK" __dp_project "$DP_WORKERS" "repos scanned"

  report="$DP_WORK/report.json"
  cat "$DP_WORK"/r/*.json | jq -s --arg gen "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg ver "$GLB_VERSION" --arg gl "$GLB_URL" \
    --argjson kws "$DP_KW_JSON" --arg ref "$DP_REF" --argjson code "$DP_CODE" --arg order "$DP_RESULTS" \
    --argjson dur "$((SECONDS - t0))" '
    ($order | split(" ") | to_entries | map({(.value): .key}) | add) as $o
    | {
        tool: "deps", gitlabbox_version: $ver, generated_at: $gen, duration_seconds: $dur, gitlab_url: $gl,
        options: {keywords: [$kws[].kw], branch: (if $ref == "" then "default branch" else $ref end), code_search: ($code == 1)},
        summary: ({repos_total: length}
          + (reduce ($order | split(" "))[] as $r ({}; .[$r | ascii_downcase] = 0))
          + (group_by(.result) | map({(.[0].result | ascii_downcase): length}) | add // {})
          + {libraries_found: ([.[].matches[]? | [.eco, .name]] | unique | length)}),
        libraries: ([.[] | .project as $p | .matches[]? | . + {project: $p}]
          | group_by([.eco, .name])
          | map({eco: .[0].eco, name: .[0].name, keyword: .[0].keyword,
                 repos: (map(.project) | unique | length), versions: (map(.version // "—") | unique),
                 projects: (map(.project) | unique)})
          | sort_by(-.repos, .name)),
        repositories: sort_by($o[.result], .project)
      }' >"$report"

  outdir="${DP_OUT:-$GLB_ROOT/reports}"
  if [ "$outdir" != - ]; then
    outdir=$(make_report_dir "$outdir" deps "$(_bc_scope)") || { ui_err "Cannot create a report folder."; return 1; }
    jq . "$report" >"$outdir/report.json"
    dp_to_csv "$report" >"$outdir/report.csv"
  else
    jq . "$report"
  fi

  dp_print_tables "$report"
  dp_summary_box "$report" "$([ "$outdir" != - ] && printf '%s' "$outdir")"
  DP_LAST_DIR="$outdir"
  [ "$(jq '.summary.error' "$report")" -eq 0 ]
}

# One sheet: a row per matched library (and per code hit); repos without a match get one row.
dp_to_csv() { # REPORT_JSON
  jq -r '
    ["project","result","keyword","ecosystem","library","version","scope","file","line","file_url","branch","note"],
    (.repositories[] | . as $r
      | ($r.web_url // "") as $w | ($r.ref // "") as $ref
      | def url($f): if $w == "" or $f == null then null else "\($w)/-/blob/\($ref)/\($f)" end;
      if (($r.matches // []) | length) + (($r.code_hits // []) | length) == 0 then
        [$r.project, $r.result, null, null, null, null, null, null, null, null, $r.ref, ($r.note // $r.error)]
      else
        ($r.matches[]? | [$r.project, $r.result, .keyword, .eco, .name, .version, .scope, .file, null, url(.file), $r.ref, $r.note]),
        ($r.code_hits[]? | . as $h | [$r.project, $r.result, $h.keyword, "source", $h.text, null, "code", $h.path, $h.line,
                            (url($h.path) | if . then "\(.)#L\($h.line // 1)" else . end), $r.ref, $r.note])
      end)
    | @csv' "$1"
}

dp_print_tables() { # REPORT_JSON
  local f="$1" n shown=0 r p libs note
  n=$(jq '.libraries | length' "$f")
  if [ "$n" -gt 0 ]; then
    ui_title "Libraries found" "$n libraries · sorted by number of repos"
    printf '  %s%-10s %-48s %5s  %s%s\n' "$B" "ECOSYSTEM" "LIBRARY" "REPOS" "VERSIONS" "$RST" >&2
    jq -r '.libraries[] | [.eco, .name, .repos, (.versions | join(", ") | .[:60])] | @tsv' "$f" | head -n "$DP_ROWS" |
      while IFS=$'\t' read -r r p libs note; do
        [ "${#p}" -gt 48 ] && p="…${p: -47}"
        printf '  %-10s %-48s %5s  %s%s%s\n' "$r" "$p" "$libs" "$DIM" "$note" "$RST" >&2
      done
    [ "$n" -gt "$DP_ROWS" ] && ui_hint "… $((n - DP_ROWS)) more in report.csv"
  fi
  n=$(jq '.repositories | length' "$f")
  ui_title "Per repo"
  printf '  %s   %-48s %-11s %s%s\n' "$B" "PROJECT" "RESULT" "MATCHES" "$RST" >&2
  while IFS=$'\t' read -r r p libs note; do
    shown=$((shown + 1))
    if [ "$shown" -gt "$DP_ROWS" ]; then ui_hint "… $((n - DP_ROWS)) more in report.csv"; break; fi
    [ "${#p}" -gt 48 ] && p="…${p: -47}"
    printf '  %s %-48s %-11s %s%s%s%s\n' "$(_dp_icon "$r")" "$p" "$r" "$libs" "${note:+  $DIM}" "$note" "$([ -n "$note" ] && printf '%s' "$RST")" >&2
  done < <(jq -r '.repositories[] | [.result, .project,
      ((((.matches // []) | map("\(.name)\(if .version then "@" + .version else "" end)") | unique)
        + (if ((.code_hits // []) | length) > 0 then ["\(.code_hits | length) code hit(s)"] else [] end))
       | join(", ") | if . == "" then "—" else .[:90] end),
      ((.note // .error // "") | .[:70])] | @tsv' "$f")
}

dp_summary_box() { # REPORT_JSON [DIR]
  local f="$1" lines=()
  lines+=("  ${DIM}Keywords    ${RST} $(jq -r '.options.keywords | join(", ")' "$f") ${DIM}· branch: $(jq -r '.options.branch' "$f")$(jq -r 'if .options.code_search then " · + code search" else "" end' "$f")${RST}")
  lines+=("  ${DIM}Repos       ${RST} $(jq -r '.summary.repos_total' "$f") scanned")
  lines+=("$(_dp_icon USED) ${DIM}Using       ${RST} $(jq -r '.summary.used' "$f") ${DIM}(a matching library in a manifest)${RST}")
  [ "$(jq '.options.code_search' "$f")" = true ] &&
    lines+=("$(_dp_icon CODE_ONLY) ${DIM}Code only   ${RST} $(jq -r '.summary.code_only' "$f") ${DIM}(keyword in the code, not in a manifest)${RST}")
  lines+=("$(_dp_icon NOT_FOUND) ${DIM}Not found   ${RST} $(jq -r '.summary.not_found' "$f")")
  lines+=("$(_dp_icon NO_MANIFEST) ${DIM}No manifest ${RST} $(jq -r '.summary.no_manifest' "$f")")
  [ "$(jq '.summary.error' "$f")" -gt 0 ] && lines+=("$(_dp_icon ERROR) ${DIM}Errors      ${RST} $(jq -r '.summary.error' "$f")")
  lines+=("  ${DIM}Libraries   ${RST} $(jq -r '.summary.libraries_found' "$f") distinct")
  lines+=("  ${DIM}Duration    ${RST} $(ui_duration "$(jq -r '.duration_seconds // 0' "$f")")")
  [ -n "$2" ] && lines+=("  ${DIM}Report      ${RST} ${CC}$(_bc_tilde "$2")/report.csv${RST} ${DIM}+ report.json${RST}")
  ui_nl
  ui_box "Dependency check" "${lines[@]}"
}

dp_view_report() { # REPORT_JSON
  dp_defaults
  ui_title "$(basename "$(dirname "$1")")" "generated $(jq -r '.generated_at' "$1")"
  dp_print_tables "$1"
  dp_summary_box "$1" "$(dirname "$1")"
}

# ---------- interactive ----------
dp_interactive() {
  local k
  dp_defaults
  ui_title "$TOOL_DP_NAME" "Which repos use a library matching your keywords?"
  ui_nl
  if [ "$(cfg_count)" -eq 0 ] && [ -z "${GITLAB_TOKEN:-}${GL_TOKEN:-}" ]; then
    ui_warn "No GitLab connection yet."
    ui_confirm "Set up a connection now?" y || return
    setup_wizard || return
    ui_nl
  fi
  pick_profile "Which connection?" include_env || return
  BC_PROFILE="$PICKED_PROFILE"
  bc_prepare_profile || return
  bc_pick_source || return

  ui_nl
  ui_hint "Library keywords, comma-separated, case-insensitive."
  ui_hint "A plain word matches any library whose name contains it: sdk → aws-sdk, @aws-sdk/client-s3, firebase-admin-sdk …"
  ui_hint "With * it must match the whole name: @aws-sdk/*  ·  com.google.firebase:*"
  while :; do
    ui_input DP_KEYWORDS "Library keywords" "$DP_KEYWORDS"
    [ "$(_dp_kw_json "$DP_KEYWORDS" | jq 'length')" -gt 0 ] && break
    ui_warn "Enter at least one keyword."
  done
  UI_HINTS=("Each repo's default branch (usually main / master)" "e.g. master, develop — repos without it show NO_MANIFEST")
  ui_select k "Which branch?" "Default branch (recommended)" "A specific branch" || return
  [ "$k" = 1 ] && while :; do ui_input DP_REF "Branch" "master"; [ -n "$DP_REF" ] && break; done
  UI_HINTS=("Manifests only: package.json, pom.xml, build.gradle, go.mod, requirements.txt, … (fast, with versions)"
    "Also find the keyword in source files (imports, vendored SDKs). Uses the GitLab search API: slower and rate-limited")
  ui_select k "What to scan?" "Dependency manifests (recommended)" "Manifests + source code search" || return
  DP_CODE=$k
  ui_input DP_OUT "Output folder" "$GLB_ROOT/reports" path

  ui_nl
  ui_box "Ready to run" \
    "${DIM}Connect ${RST} $(profile_label "$BC_PROFILE")" \
    "${DIM}Repos   ${RST} $BC_SRC_LABEL" \
    "${DIM}Keywords${RST} $DP_KEYWORDS" \
    "${DIM}Branch  ${RST} ${DP_REF:-default branch}" \
    "${DIM}Scan    ${RST} manifests$([ "$DP_CODE" = 1 ] && printf ' + source code search')" \
    "${DIM}Output  ${RST} $(_bc_tilde "$DP_OUT")"
  ui_nl
  UI_HINTS=("" "Answer all questions again" "Back to the main menu")
  ui_select k "Go?" "🚀 Run it!" "✏️  Start over" "✖  Cancel" || return
  case "$k" in 1) dp_interactive; return ;; 2) return ;; esac

  dp_run
  ui_nl
  UI_HINTS=("" "Open in Finder / file manager" "")
  ui_select k "Next?" "← Back to the main menu" "📂 Open the report folder" "Quit" || return
  case "$k" in
    1) if command -v open >/dev/null; then open "$DP_LAST_DIR"; else xdg-open "$DP_LAST_DIR" >/dev/null 2>&1; fi ;;
    2) exit 0 ;;
  esac
}

# ---------- flag mode / CLI ----------
dp_usage() {
  cat >&2 <<EOF
${B}$TOOL_DP_NAME${RST} — which repos use a library matching your keywords?

${B}Usage${RST}
  ./gitlabbox.sh deps -k KEYWORDS [repo source] [options]

${B}Repo source${RST} (combinable, same as the Branch & Committer Report)
    -r, --repo LIST          path / ID / URL, comma-separated
    -f, --file FILE          .txt file, one repo per line (group:xxx = a whole group)
    -g, --group LIST         every project in these groups + subgroups (comma-separated)
    -a, --account SCOPE      every repo your account can access: member · owned · reporter · developer · maintainer · all
        --mine               = --account member
        --repo-filter GLOB   filter group/account results, e.g. 'backend/*,*-svc'
        --include-archived   include archived projects

${B}Options${RST}
    -k, --keywords LIST      library keywords, comma-separated, case-insensitive (required)
                               plain word = name contains it (sdk → aws-sdk, @aws-sdk/client-s3, …)
                               with * / ? = glob on the whole name (@aws-sdk/*, com.google.firebase:*)
        --ref BRANCH         scan this branch instead of each repo's default branch (e.g. master)
        --code               also search the source code (GitLab search API: slower, rate-limited)
        --max-tree N         max files listed per repo (default $DP_MAX_TREE)
        --max-files N        max manifests read per repo (default $DP_MAX_FILES)
    -p, --profile NAME       connection profile
    -w, --workers N          parallel repos (default 6)
    -o, --out DIR            parent folder (→ DIR/<date>_deps_<scope>/report.csv + report.json), or '-' for JSON on stdout

${B}Manifests read${RST}
    npm package.json · composer.json · requirements*.txt · Pipfile · pyproject.toml · setup.py · go.mod
    Gemfile · Podfile · pom.xml · build.gradle(.kts) · *.versions.toml · build.sbt · *.csproj / packages.config
    Cargo.toml · pubspec.yaml   (direct dependencies; node_modules/, vendor/ … are skipped)

${B}Examples${RST}
    ./gitlabbox.sh deps -g my-org -k sdk
    ./gitlabbox.sh deps --mine -k 'firebase,@aws-sdk/*' --ref master
    ./gitlabbox.sh deps -f repos.txt -k midtrans --code
    ./gitlabbox.sh deps -g my-org -k sdk -o - | jq -r '.libraries[] | "\(.repos)\t\(.name)"'

Exit code: 0 = ok · 3 = some repos could not be read.
EOF
}

dp_cli() {
  dp_defaults
  while [ $# -gt 0 ]; do
    case "$1" in
      --*=*) set -- "${1%%=*}" "${1#*=}" "${@:2}"; continue ;;
    esac
    bc_source_opt "$@"
    case $? in 0) shift "$BC_OPT_SHIFT"; continue ;; 2) return 1 ;; esac
    case "$1" in
      -h | --help) dp_usage; return 0 ;;
      -p | --profile) BC_PROFILE="$2"; shift 2 ;;
      -k | --keywords) DP_KEYWORDS="$2"; shift 2 ;;
      --ref) DP_REF="$2"; shift 2 ;;
      --code) DP_CODE=1; shift ;;
      --max-tree) _bc_is_int "$2" && [ "$2" -ge 1 ] || { ui_err "--max-tree must be a number"; return 1; }; DP_MAX_TREE="$2"; shift 2 ;;
      --max-files) _bc_is_int "$2" && [ "$2" -ge 1 ] || { ui_err "--max-files must be a number"; return 1; }; DP_MAX_FILES="$2"; shift 2 ;;
      -w | --workers) _bc_is_int "$2" && [ "$2" -ge 1 ] || { ui_err "--workers must be at least 1"; return 1; }; DP_WORKERS="$2"; shift 2 ;;
      -o | --out) DP_OUT="$2"; shift 2 ;;
      -*) ui_err "Unknown option: $1"; dp_usage; return 1 ;;
      *) BC_TARGETS+=("$1"); shift ;;
    esac
  done
  if [ -z "$DP_KEYWORDS" ]; then ui_err "Give at least one library keyword with -k."; dp_usage; return 1; fi
  if [ "${#BC_TARGETS[@]}" -eq 0 ]; then ui_err "No repos given."; dp_usage; return 1; fi
  bc_prepare_profile || return 1
  dp_run || return 3
}
