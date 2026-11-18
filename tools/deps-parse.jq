# tools/deps-parse.jq — one dependency manifest → [{eco, name, version, scope}]
# Run with: jq -Rs --arg type TYPE -f deps-parse.jq FILE
# TYPE comes from the file name (see DP_JQ_FTYPE in tools/deps.sh). Direct dependencies only.

def trim: gsub("^\\s+|\\s+$"; "");
def unq: trim | gsub("^[\"']|[\"']$"; "");
def lines: split("\n") | map(sub("\r$"; ""));
def dep($eco; $name; $ver; $scope):
  {eco: $eco, name: ($name | trim),
   version: (if $ver == null then null else ($ver | tostring | trim | if . == "" then null else . end) end),
   scope: $scope};

# "requests[security]>=2.0; python_version<'3'" → pypi dep
def pyreq($scope):
  if test("#egg=") then [capture("#egg=(?<n>[A-Za-z0-9._\\-]+)")][0] | dep("pypi"; .n; null; $scope)
  else [capture("^\\s*(?<n>[A-Za-z0-9][A-Za-z0-9._\\-]*)\\s*(?:\\[[^\\]]*\\])?\\s*(?<v>[^;#]*)")][0]
       | if . == null then empty else dep("pypi"; .n; .v; $scope) end
  end;

# TOML: "key = value" lines inside sections whose name matches $want → [{k, v, s}]
def toml_sections($want):
  reduce lines[] as $l ({sec: "", out: []};
    . as $st
    | if ($l | test("^\\s*\\[")) then .sec = ([$l | capture("^\\s*\\[+\\s*(?<s>[^\\]]+?)\\s*\\]+")][0].s // "")
      elif ($st.sec | test($want)) then
        ([$l | capture("^\\s*[\"']?(?<k>[A-Za-z0-9_.@/\\-]+)[\"']?\\s*=\\s*(?<v>.*)$")][0]) as $m
        | if $m == null then . else .out += [$m + {s: $st.sec}] end
      else . end)
  | .out;

# TOML value → version: "1.2" · { version = "1.2", features = [...] } · { git = "..." }
def toml_ver:
  sub("\\s+#.*$"; "") | trim
  | if startswith("{") then ([capture("version\\s*=\\s*[\"'](?<v>[^\"']*)[\"']")][0].v // null) else unq end;

def npm_like($eco; $sections; $skip):
  (try fromjson catch {}) as $j
  | [$sections[] as $s | ($j[$s] // {}) | select(type == "object") | to_entries[]
     | select(.key | test($skip) | not) | dep($eco; .key; (.value | tostring); $s)];

def gomod:
  reduce lines[] as $l ({blk: false, out: []};
    ($l | sub("//.*$"; "")) as $c
    | ($l | test("//\\s*indirect")) as $ind
    | if ($c | test("^\\s*require\\s*\\(")) then .blk = true
      elif .blk and ($c | test("^\\s*\\)")) then .blk = false
      elif .blk or ($c | test("^\\s*require\\s+[^(\\s]")) then
        ([$c | capture("^\\s*(?:require\\s+)?(?<n>[^\\s]+)\\s+(?<v>v[^\\s]+)")][0]) as $m
        | if $m == null then . else .out += [dep("go"; $m.n; $m.v; (if $ind then "indirect" else "require" end))] end
      else . end)
  | .out;

def pom:
  gsub("<!--[\\s\\S]*?-->"; "") as $t
  | ([$t | scan("<properties>([\\s\\S]*?)</properties>")[0] | scan("<([A-Za-z0-9_.\\-]+)>\\s*([^<]*?)\\s*</\\1>")
      | {key: .[0], value: .[1]}] | from_entries) as $props
  | ($t | [scan("<groupId>\\s*([^<]*?)\\s*</groupId>")[0]][0]) as $own_group
  | [$t | scan("<dependency>([\\s\\S]*?)</dependency>")[0]
     | {g: ([scan("<groupId>\\s*([^<]*?)\\s*</groupId>")[0]][0]),
        a: ([scan("<artifactId>\\s*([^<]*?)\\s*</artifactId>")[0]][0]),
        v: ([scan("<version>\\s*([^<]*?)\\s*</version>")[0]][0]),
        s: ([scan("<scope>\\s*([^<]*?)\\s*</scope>")[0]][0])}
     | select(.a != null)
     | .g |= (if . == "${project.groupId}" then $own_group else . end)
     | .v |= (if . != null and test("^\\$\\{.+\\}$") then ($props[.[2:-1]] // .) else . end)
     | dep("maven"; "\(.g // "?"):\(.a)"; .v; (.s // "compile"))];

def gradle:
  [scan("(implementation|api|compile|compileOnly|runtimeOnly|testImplementation|testCompile|testRuntimeOnly|androidTestImplementation|debugImplementation|releaseImplementation|kapt|ksp|annotationProcessor|classpath)\\s*\\(?\\s*(?:platform\\s*\\(\\s*|enforcedPlatform\\s*\\(\\s*)?[\"']([^\"':\\s]+):([^\"':\\s]+)(?::([^\"'\\s]+))?[\"']")
     | dep("maven"; "\(.[1]):\(.[2])"; .[3]; .[0])]
  + [scan("group\\s*:\\s*[\"']([^\"']+)[\"']\\s*,\\s*name\\s*:\\s*[\"']([^\"']+)[\"'](?:\\s*,\\s*version\\s*:\\s*[\"']([^\"']+)[\"'])?")
     | dep("maven"; "\(.[0]):\(.[1])"; .[2]; "implementation")];

def gradle_catalog:
  ([toml_sections("^versions$")[] | {key: .k, value: (.v | toml_ver)}] | from_entries) as $vers
  | [toml_sections("^libraries$")[] | (.v | sub("\\s+#.*$"; "") | trim) as $v
     | if ($v | startswith("{")) then
         ([$v | capture("module\\s*=\\s*\"(?<m>[^\"]+)\"")][0].m
          // ([$v | capture("group\\s*=\\s*\"(?<g>[^\"]+)\"\\s*,\\s*name\\s*=\\s*\"(?<n>[^\"]+)\"")][0] | if . then "\(.g):\(.n)" else null end)) as $mod
         | ([$v | capture("version\\.ref\\s*=\\s*\"(?<r>[^\"]+)\"")][0].r) as $ref
         | select($mod != null)
         | dep("maven"; $mod; (if $ref then $vers[$ref] else ([$v | capture("version\\s*=\\s*\"(?<x>[^\"]+)\"")][0].x) end); "catalog")
       else ($v | unq | split(":")) as $p | select(($p | length) >= 2)
         | dep("maven"; "\($p[0]):\($p[1])"; $p[2]; "catalog")
       end];

def pub:
  reduce lines[] as $l ({sec: "", out: []};
    if ($l | test("^[A-Za-z_]+:")) then .sec = ($l | capture("^(?<s>[A-Za-z_]+):").s)
    elif (.sec | IN("dependencies", "dev_dependencies", "dependency_overrides")) and ($l | test("^  [A-Za-z0-9_]+:")) then
      ($l | capture("^  (?<n>[A-Za-z0-9_]+):\\s*(?<v>.*)$")) as $m
      | .out += [dep("pub"; $m.n; ($m.v | sub("\\s+#.*$"; "") | unq); .sec)]
    else . end)
  | .out;

try (
  if $type == "npm" then npm_like("npm"; ["dependencies", "devDependencies", "peerDependencies", "optionalDependencies"]; "^$")
  elif $type == "composer" then npm_like("packagist"; ["require", "require-dev"]; "^(php|ext-.*|lib-.*)$")
  elif $type == "pip" then
    [lines[] | sub("\\s+#.*$"; "") | select(test("^\\s*($|#|-)") | not) | pyreq("requirements")]
  elif $type == "pipfile" then
    [toml_sections("^(packages|dev-packages)$")[] | dep("pypi"; .k; (.v | toml_ver); .s)]
  elif $type == "pyproject" then
    [toml_sections("^tool\\.poetry\\.(dependencies|dev-dependencies|group\\..+\\.dependencies)$")[]
       | select(.k != "python") | dep("pypi"; .k; (.v | toml_ver); "poetry")]
    + [scan("(?:^|\\n)\\s*dependencies\\s*=\\s*\\[([\\s\\S]*?)\\]")[0] | scan("[\"']([^\"']+)[\"']")[0] | pyreq("project")]
  elif $type == "setuppy" then
    [scan("install_requires\\s*=\\s*\\[([\\s\\S]*?)\\]")[0] | scan("[\"']([^\"']+)[\"']")[0] | pyreq("install_requires")]
  elif $type == "gomod" then gomod
  elif $type == "gem" then
    [lines[] | [capture("^\\s*gem\\s+[\"'](?<n>[^\"']+)[\"'](?:\\s*,\\s*[\"'](?<v>[^\"']+)[\"'])?")][0]
     | select(. != null) | dep("rubygems"; .n; .v; "gem")]
  elif $type == "pod" then
    [lines[] | [capture("^\\s*pod\\s+[\"'](?<n>[^\"']+)[\"'](?:\\s*,\\s*[\"'](?<v>[^\"']+)[\"'])?")][0]
     | select(. != null) | dep("cocoapods"; .n; .v; "pod")]
  elif $type == "maven" then pom
  elif $type == "gradle" then gradle
  elif $type == "gradlecat" then gradle_catalog
  elif $type == "sbt" then
    [scan("\"([^\"]+)\"\\s*%%?%?\\s*\"([^\"]+)\"\\s*%\\s*\"([^\"]+)\"") | dep("maven"; "\(.[0]):\(.[1])"; .[2]; "sbt")]
  elif $type == "nuget" then
    [scan("<Package(?:Reference|Version)\\s+(?:Include|Update)\\s*=\\s*\"([^\"]+)\"(?:\\s+Version\\s*=\\s*\"([^\"]*)\")?")
     | dep("nuget"; .[0]; .[1]; "PackageReference")]
  elif $type == "nugetcfg" then
    [scan("<package\\s+id=\"([^\"]+)\"\\s+version=\"([^\"]+)\"") | dep("nuget"; .[0]; .[1]; "packages.config")]
  elif $type == "cargo" then
    [toml_sections("(^|\\.)(dependencies|dev-dependencies|build-dependencies)$")[] | dep("crates"; .k; (.v | toml_ver); .s)]
  elif $type == "pub" then pub
  else [] end
  | map(select(.name != "")) | unique_by([.name, .version, .scope])
) catch []
