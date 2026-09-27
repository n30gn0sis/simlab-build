#!/usr/bin/env bats

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-malcolm-deploy.sh"
    BUNDLE="$BATS_TEST_TMPDIR/bundle"
    mkdir -p "$BUNDLE/malcolm"
    cat > "$BUNDLE/malcolm/image-list.txt" <<'EOF'
ghcr.io/idaholab/malcolm/arkime:0.0.0-fixture
ghcr.io/idaholab/malcolm/zeek:0.0.0-fixture
EOF
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    setup_deploy
}

# Stub the docker CLI so the suite never touches a real daemon.
stub_docker_reporting() {
    { echo '#!/usr/bin/env bash'
      echo 'if [ "$1" = "image" ] && [ "$2" = "ls" ]; then'
      for t in "$@"; do echo "  echo '$t'"; done
      echo 'fi'
      echo 'exit 0'
    } > "$BATS_TEST_TMPDIR/bin/docker"
    chmod +x "$BATS_TEST_TMPDIR/bin/docker"
}

@test "assert-tags passes when every listed tag is present" {
    stub_docker_reporting ghcr.io/idaholab/malcolm/arkime:0.0.0-fixture ghcr.io/idaholab/malcolm/zeek:0.0.0-fixture
    run "$SCRIPT" assert-tags "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "assert-tags FAILS when a tag is missing, and names it" {
    stub_docker_reporting ghcr.io/idaholab/malcolm/arkime:0.0.0-fixture
    run "$SCRIPT" assert-tags "$BUNDLE"
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"zeek:0.0.0-fixture"* ]]
}

@test "assert-tags fails loudly when image-list.txt is missing" {
    rm "$BUNDLE/malcolm/image-list.txt"
    run "$SCRIPT" assert-tags "$BUNDLE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"image-list.txt"* ]]
}

@test "a bundle directory that does not exist is rejected" {
    run "$SCRIPT" assert-tags /nonexistent
    [ "$status" -ne 0 ]
}

# --- Regressions -------------------------------------------------------------

@test "a missing image list never reports success" {
    # The subshell regression: when image_list ran inside `< <(...)`, its die()
    # exited only that subshell, the loop saw EOF, and the script printed
    # "all images present" for a bundle containing no list at all.
    rm "$BUNDLE/malcolm/image-list.txt"
    run "$SCRIPT" assert-tags "$BUNDLE"
    echo "$output"
    [[ "$output" != *"all images present"* ]]
}

@test "an image list holding only comments fails loudly" {
    printf '# nothing but a comment\n\n' > "$BUNDLE/malcolm/image-list.txt"
    run "$SCRIPT" assert-tags "$BUNDLE"
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" != *"all images present"* ]]
}

@test "a nonexistent bundle is rejected for the right reason, not merely absent tooling" {
    stub_docker_reporting ghcr.io/idaholab/malcolm/arkime:0.0.0-fixture
    run "$SCRIPT" assert-tags /nonexistent
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a directory"* ]]
}

# ═════════════════════════════════════════════════════════════════════════════
# install | configure | auth | bind-loopback | start | health | verify
#
# These run the script on an ISOLATED PATH: stubs ($BIN) first, then a fixed
# list of real read-only tools ($REAL). docker, python3, unzip, openssl, ss,
# tcpdump, curl, id, getent, runuser and chown are stubs; Malcolm's own
# auth_setup and start are fake scripts inside a fake MALCOLM_ROOT that refuse
# a root identity the way control.py does (LOGNAME/USER first, as getpass
# reads them). md() runs the script with LOGNAME=USER=root, as sudo does. The
# runuser stub records its argv and execs what follows `--` without changing
# uid; chown records its argv and the path it "chowned" ($S/chowned), which
# the stat stub then reports as owned by 1000. State lives in $S:
#   $S/argv        every stub/fake call: "<name> <argv...>", one per line
#   $S/stdin.*     what openssl / docker run / curl -K read on stdin
#   $S/ps          what `docker compose ps` prints (Name State Health)
#   $S/ss          what `ss -H -ltnp` prints
#   $S/arkime      recordsFiltered the Arkime API returns (default 0)
#   $S/zeek_writes if present, the Arkime query also makes Zeek write a log
# ═════════════════════════════════════════════════════════════════════════════

PW='Pw-7f3e9c1d-NEVER-IN-ARGV'
# Malcolm 26.08's real line (compose line 1459) has no /tcp suffix.
OPEN='    - 0.0.0.0:443:443'
LOOP='    - 127.0.0.1:8443:443'

setup_deploy() {
    BIN="$BATS_TEST_TMPDIR/bin"; export REAL="$BATS_TEST_TMPDIR/real"
    export S="$BATS_TEST_TMPDIR/state"
    export MALCOLM_ROOT="$BATS_TEST_TMPDIR/opt/malcolm"
    export MALCOLM_TMPDIR="$BATS_TEST_TMPDIR/tmp"
    export MALCOLM_POLL_SECS=0 VERIFY_CAPTURE_SECS=0 VERIFY_TIMEOUT=0
    export FAKE_UID=0
    # Malcolm's user: process.env's PUID/PGID, its passwd entry, its groups;
    # FAKE_DIR_OWNER is the uid stat reports for a data dir nobody chowned.
    export FAKE_PASSWD='ubuntu:x:1000:1000:Ubuntu:/home/ubuntu:/bin/bash'
    export FAKE_GROUPS='ubuntu adm docker'
    export FAKE_DIR_OWNER=0
    MD="$MALCOLM_ROOT/malcolm"
    mkdir -p "$BIN" "$REAL" "$S" "$MALCOLM_TMPDIR"
    for t in bash env cat sed awk grep find sort head tr basename dirname sha256sum \
             stat mkdir cp mv chmod rm date wc mktemp sleep timeout; do
        p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$REAL/$t"
    done
    TEST_PATH="$BIN:$REAL"

    PWFILE="$BATS_TEST_TMPDIR/analyst-pw"
    printf '%s\n' "$PW" > "$PWFILE"; chmod 600 "$PWFILE"
    CONF="$BATS_TEST_TMPDIR/malcolm-config.json"
    echo '{"configuration": {"autoSuricata": false}}' > "$CONF"

    # The compose file as Malcolm's installer writes it: one nginx-proxy 443
    # mapping, and the upload/pcap-monitor bind mounts in the long syntax of a
    # real 26.08 render (default config: relative ./pcap/upload).
    compose_with_upload ./pcap/upload > "$S/compose.fixture"

    stub id 'case $1 in -nG) [ "$2" = "${FAKE_PASSWD%%:*}" ] && echo "$FAKE_GROUPS" ;; *) echo "$FAKE_UID" ;; esac'
    stub getent 'echo "getent $*" >> "$S/argv"; [ "$1" = passwd ] || exit 2
IFS=: read -r _ _ u _ <<< "$FAKE_PASSWD"; [ "$2" = "$u" ] || exit 2; echo "$FAKE_PASSWD"'
    stub runuser 'echo "runuser $*" >> "$S/argv"
[ "$1" = -u ] && [ -n "$2" ] && [ "$3" = -- ] || { echo "runuser stub: unexpected argv: $*" >&2; exit 64; }
shift 3; exec "$@"'
    stub chown 'echo "chown $*" >> "$S/argv"; for a; do :; done; echo "$a" >> "$S/chowned"'
    # The password file's owner as stat reports it. Tests run as whatever user
    # bats runs as; FAKE_PW_OWNER stands in for the real owner (default root).
    export FAKE_PW_OWNER=0
    stub stat 'if [ "$1 $2" = "-c %u %a" ]; then m=$("$REAL/stat" -c %a "$3") || exit 1; echo "$FAKE_PW_OWNER $m"; exit 0; fi
if [ $# -eq 3 ] && [ "$1 $2" = "-c %u" ]; then
    while IFS= read -r o; do case "$3/" in "$o"/*) echo 1000; exit 0 ;; esac; done < <(cat "$S/chowned" 2>/dev/null)
    echo "$FAKE_DIR_OWNER"; exit 0
fi
exec "$REAL/stat" "$@"'
    stub unzip 'echo "unzip $*" >> "$S/argv"
d=""; prev=""; for a; do [ "$prev" = -d ] && d=$a; prev=$a; done
[ -f "$S/zip_empty" ] && exit 0
mkdir -p "$d/installer" && echo "# fake installer" > "$d/install.py" && : > "$d/malcolm_20260901_000000.tar.gz"'
    stub python3 'echo "python3 $*" >> "$S/argv"; echo "$PWD" > "$S/python3.cwd"
[ -f "$S/installer_noenv" ] && exit 0
mkdir -p "$MALCOLM_ROOT/malcolm/config"
echo "OPENSEARCH_JAVA_OPTS=-Xmx4g" > "$MALCOLM_ROOT/malcolm/config/opensearch.env"
printf "PUID=1000\\nPGID=1000\\n" > "$MALCOLM_ROOT/malcolm/config/process.env"
cp "$S/compose.fixture" "$MALCOLM_ROOT/malcolm/docker-compose.yml"'
    stub openssl 'echo "openssl $*" >> "$S/argv"; cat > "$S/stdin.openssl"; echo "\$1\$salt\$fakemd5hash"'
    stub docker 'echo "docker $*" >> "$S/argv"
case "$1 $2" in
  "compose ps") cat "$S/ps" 2>/dev/null; exit 0 ;;
esac
if [ "$1" = run ]; then cat > "$S/stdin.docker"; printf ":\$2y\$10\$fakebcrypthash\n\n"; exit 0; fi
exit 0'
    stub ss 'echo "ss $*" >> "$S/argv"; cat "$S/ss" 2>/dev/null'
    stub tcpdump 'echo "tcpdump $*" >> "$S/argv"
prev=""; for a; do [ "$prev" = -w ] && head -c 200 /dev/zero | tr "\0" x > "$a"; prev=$a; done'
    stub curl 'echo "curl $*" >> "$S/argv"
case " $* " in
  *" -K "*)
    cat >> "$S/stdin.curl"
    if [ -f "$S/zeek_writes" ]; then
        mkdir -p "$MALCOLM_ROOT/malcolm/zeek-logs/processed/x"; echo log > "$MALCOLM_ROOT/malcolm/zeek-logs/processed/x/conn.log"
    fi
    printf "{\"recordsTotal\":9,\"recordsFiltered\":%s,\"data\":[]}\n" "$(cat "$S/arkime" 2>/dev/null || echo 0)" ;;
esac
exit 0'
}

UPLOAD_TARGET=/var/www/upload/server/php/chroot/files

# One long-syntax bind mount entry: bind_entry SOURCE TARGET [ts]. With `ts`,
# target: comes before source:.
bind_entry() {
    printf '%s\n' '    - type: bind' '      bind:' '        create_host_path: false'
    if [ "${3:-}" = ts ]; then
        printf '      target: %s\n      source: %s\n' "$2" "$1"
    else
        printf '      source: %s\n      target: %s\n' "$1" "$2"
    fi
}

# A compose file whose upload: service bind-mounts $1 as the upload dir.
#   compose_with_upload SRC [UPLOAD_VOLUMES] [PCAP_MONITOR_VOLUMES] [INDEX_SRC]
# The optional arguments replace the upload: / pcap-monitor: volume entries
# (build them with bind_entry). pcap-monitor comes BEFORE upload:. As in a real
# render, pcap-monitor binds the upload dir's parent (pcapDir) to /pcap, and
# opensearch binds INDEX_SRC (indexDir; default ./opensearch) to its data dir.
compose_with_upload() {
    local uv=${2:-$(bind_entry "$1" "$UPLOAD_TARGET")}
    local pv=${3:-$(bind_entry "$(dirname "$1")" /pcap)}
    local iv; iv=$(bind_entry "${4:-./opensearch}" /usr/share/opensearch/data)
    cat <<EOF
services:
  nginx-proxy:
    ports:
$OPEN
  pcap-monitor:
    volumes:
$pv
  upload:
    image: x
    volumes:
$uv
  arkime:
    image: x
  opensearch:
    image: x
    volumes:
$iv
EOF
}

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$BIN/$1"; chmod +x "$BIN/$1"; }

# As sudo runs it: LOGNAME and USER say root.
md() { PATH="$TEST_PATH" LOGNAME=root USER=root "$SCRIPT" "$@" < /dev/null; }

calls() { [ -f "$S/argv" ] || { echo 0; return; }; grep -c "^$1 " "$S/argv" || true; }

# Proves the plaintext never reached any argv (stubs AND Malcolm's fakes), the
# output, or any file under $BATS_TEST_TMPDIR except the password file itself
# and the stubs' record of what they read on stdin (a pipe, by design).
no_secret_leak() {
    local hits
    if grep -rF -- "$PW" "$S/argv"; then echo "password in argv"; return 1; fi
    if [[ "$output" == *"$PW"* ]]; then echo "password in output"; return 1; fi
    hits=$(grep -rlF -- "$PW" "$BATS_TEST_TMPDIR" | grep -vxF -e "$PWFILE" | grep -v "^$S/stdin\." || true)
    if [ -n "$hits" ]; then echo "password in files: $hits"; return 1; fi
}

bundle_full() {
    echo 'ghcr.io/idaholab/malcolm/nginx-proxy:0.0.0-fixture' >> "$BUNDLE/malcolm/image-list.txt"
    echo 'zip bytes' > "$BUNDLE/malcolm/malcolm-0.0.0-fixture-docker_install.zip"
    echo 'bundle compose' > "$BUNDLE/malcolm/docker-compose.yml"
}

# A configured tree: installer, .env files (process.env with PUID/PGID, as the
# installer writes it), compose file, Malcolm's auth_setup + start. The fakes
# refuse a root identity as control.py's main does, and record the identity
# they ran with in $S/<name>.id ("USER LOGNAME HOME").
malcolm_tree() {
    mkdir -p "$MALCOLM_ROOT/scripts" "$MD/config" "$MD/scripts" "$MD/nginx" "$MD/pcap/upload" "$MD/zeek-logs"
    echo "# fake installer" > "$MALCOLM_ROOT/install.py"
    echo "X=1" > "$MD/config/opensearch.env"
    printf 'PUID=1000\nPGID=1000\n' > "$MD/config/process.env"
    cp "$S/compose.fixture" "$MD/docker-compose.yml"
    fake_control auth_setup 'u=""; prev=""; for a; do [ "$prev" = --auth-admin-username ] && u=$a; prev=$a; done
echo "$u:\$2y\$10\$x" > nginx/htpasswd'
    fake_control start 'printf "%s\n" "malcolm-arkime-1 running starting" > "$S/ps"'
}

# fake_control NAME [BODY]: $MD/scripts/NAME, guarded as control.py's main is:
# it refuses when getpass would say root (LOGNAME, USER, LNAME, USERNAME).
fake_control() {
    cat > "$MD/scripts/$1" <<EOF
#!/usr/bin/env bash
who=\${LOGNAME:-\${USER:-\${LNAME:-\${USERNAME:-}}}}
if [ "\$who" = root ] || [ -z "\$who" ]; then echo "Exception: $1 should not be run as root" >&2; exit 1; fi
echo "$1 \$*" >> "\$S/argv"; echo "\$PWD" > "\$S/$1.cwd"; echo "\$USER \$LOGNAME \$HOME" > "\$S/$1.id"
${2:-}
EOF
    chmod +x "$MD/scripts/$1"
}

healthy_ps() {
    printf '%s\n' 'malcolm-arkime-1 running healthy' 'malcolm-zeek-1 running healthy' \
        'malcolm-nginx-proxy-1 running healthy' 'malcolm-filebeat-1 running' > "$S/ps"
}

good_ss() {
    printf '%s\n' \
        'LISTEN 0 4096 127.0.0.1:8443 0.0.0.0:* users:(("docker-proxy",pid=4242,fd=7))' \
        'LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=900,fd=3))' > "$S/ss"
}

# ── install ──────────────────────────────────────────────────────────────────

@test "install unpacks the zip into MALCOLM_ROOT and copies the bundle's compose file" {
    bundle_full
    run md install "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS    installed malcolm-0.0.0-fixture-docker_install.zip"* ]]
    grep -qxF "unzip -q -o $BUNDLE/malcolm/malcolm-0.0.0-fixture-docker_install.zip -d $MALCOLM_ROOT" "$S/argv"
    [ -f "$MALCOLM_ROOT/install.py" ]
    [ ! -e "$MALCOLM_ROOT/scripts" ]
    cmp "$BUNDLE/malcolm/docker-compose.yml" "$MALCOLM_ROOT/docker-compose.yml"
}

@test "install is idempotent: a second run unzips nothing" {
    bundle_full
    md install "$BUNDLE"
    run md install "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already installed"* ]]
    [ "$(calls unzip)" -eq 1 ]
}

@test "install reports already installed when the configured tree came from the same zip" {
    bundle_full; malcolm_tree
    mkdir -p "$MALCOLM_ROOT/.r770-deploy"
    sha256sum < "$BUNDLE/malcolm/malcolm-0.0.0-fixture-docker_install.zip" | awk '{print $1}' \
        > "$MALCOLM_ROOT/.r770-deploy/install.sha256"
    run md install "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already installed"* ]]
    [ "$(calls unzip)" -eq 0 ]
}

@test "install refuses a bundled zip that differs from the installed one, and unzips nothing" {
    bundle_full; malcolm_tree
    mkdir -p "$MALCOLM_ROOT/.r770-deploy"
    echo 0000000000000000000000000000000000000000000000000000000000000000 \
        > "$MALCOLM_ROOT/.r770-deploy/install.sha256"
    cp "$MD/docker-compose.yml" "$BATS_TEST_TMPDIR/orig.yml"
    run md install "$BUNDLE"
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSE"*"different zip"*"installed: 0000000000000000000000000000000000000000000000000000000000000000"* ]]
    [[ "$output" != *"no install stamp"* ]]
    [[ "$output" == *"bundled malcolm-0.0.0-fixture-docker_install.zip: $(sha256sum < "$BUNDLE/malcolm/malcolm-0.0.0-fixture-docker_install.zip" | awk '{print $1}')"* ]]
    [[ "$output" == *"upgrading is a deliberate operator step"* ]]
    [ "$(calls unzip)" -eq 0 ]
    cmp "$MD/docker-compose.yml" "$BATS_TEST_TMPDIR/orig.yml"
}

@test "install refuses an existing install with no stamp, and unzips nothing" {
    bundle_full; malcolm_tree
    run md install "$BUNDLE"
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSE"*"no install stamp ($MALCOLM_ROOT/.r770-deploy/install.sha256)"* ]]
    [[ "$output" == *"interrupted install or a pre-script install"* ]]
    [[ "$output" == *"inspect it, then move $MALCOLM_ROOT aside before re-running install"* ]]
    [[ "$output" != *"different zip"* ]]
    [ "$(calls unzip)" -eq 0 ]
}

@test "install refuses a different zip over an unpacked, unconfigured install" {
    bundle_full; md install "$BUNDLE"
    echo 'newer zip bytes' > "$BUNDLE/malcolm/malcolm-0.0.0-fixture-docker_install.zip"
    run md install "$BUNDLE"
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSE"*"different zip"*"deliberate operator step"* ]]
    [ "$(calls unzip)" -eq 1 ]
}

@test "install refuses with no installer zip in the bundle" {
    run md install "$BUNDLE"
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSE"*"found 0"* ]]
    [ "$(calls unzip)" -eq 0 ]
}

@test "install refuses when two installer zips are present" {
    bundle_full
    echo other > "$BUNDLE/malcolm/malcolm-26.09.0-docker_install.zip"
    run md install "$BUNDLE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"found 2"* ]]
    [ "$(calls unzip)" -eq 0 ]
}

@test "install refuses when not root and touches nothing" {
    bundle_full; FAKE_UID=1000
    run md install "$BUNDLE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSE"*"root"* ]]
    [ "$(calls unzip)" -eq 0 ]
    [ ! -e "$MALCOLM_ROOT" ]
}

@test "install fails when the zip holds no install.py" {
    bundle_full; touch "$S/zip_empty"
    run md install "$BUNDLE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"FAIL"*"no install.py"* ]]
}

# ── configure ────────────────────────────────────────────────────────────────

@test "configure refuses before install and never runs python3" {
    run md configure "$CONF"
    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSE"*"not installed"* ]]
    [ "$(calls python3)" -eq 0 ]
}

@test "configure runs install.py non-interactively with the import flag and without --defaults" {
    bundle_full; md install "$BUNDLE"
    run md configure "$CONF"
    echo "$output"
    [ "$status" -eq 0 ]
    grep -qxF "python3 $MALCOLM_ROOT/install.py --non-interactive --configure --skip-splash --import-malcolm-config-file $CONF" "$S/argv"
    ! grep -q -- '--defaults' "$S/argv" || false
    [ "$(cat "$S/python3.cwd")" = "$MALCOLM_ROOT" ]
    [ "$(cat "$MALCOLM_ROOT/.r770-deploy/configure.sha256")" = "$(sha256sum < "$CONF" | awk '{print $1}')" ]
    [[ "$output" == *"run bind-loopback again"* ]]
}

@test "configure is idempotent for the same config, and re-runs when the config changes" {
    bundle_full; md install "$BUNDLE"
    md configure "$CONF"
    run md configure "$CONF"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already configured"* ]]
    [ "$(calls python3)" -eq 1 ]
    echo '{"configuration": {"autoSuricata": false, "osMemory": "8g"}}' > "$CONF"
    run md configure "$CONF"
    [ "$status" -eq 0 ]
    [ "$(calls python3)" -eq 2 ]
}

@test "configure re-runs when the stamp matches but the .env files are gone" {
    bundle_full; md install "$BUNDLE"; md configure "$CONF"
    rm "$MD"/config/*.env
    run md configure "$CONF"
    [ "$status" -eq 0 ]
    [ "$(calls python3)" -eq 2 ]
}

@test "configure falls back to scripts/install.py when there is no top-level install.py" {
    malcolm_tree
    mv "$MALCOLM_ROOT/install.py" "$MALCOLM_ROOT/scripts/install.py"
    rm "$MD"/config/*.env
    run md configure "$CONF"
    [ "$status" -eq 0 ]
    grep -q "^python3 $MALCOLM_ROOT/scripts/install.py --non-interactive" "$S/argv"
}

@test "configure FAILS when the installer exits 0 but writes no .env files" {
    bundle_full; md install "$BUNDLE"; touch "$S/installer_noenv"
    run md configure "$CONF"
    [ "$status" -ne 0 ]
    [[ "$output" == *"FAIL"*".env"* ]]
    [ ! -f "$MALCOLM_ROOT/.r770-deploy/configure.sha256" ]
}

@test "configure refuses a missing config file" {
    bundle_full; md install "$BUNDLE"
    run md configure "$BATS_TEST_TMPDIR/nope.json"
    [ "$status" -ne 0 ]
    [ "$(calls python3)" -eq 0 ]
}

# ── auth ─────────────────────────────────────────────────────────────────────

@test "auth hashes on stdin, passes only hashes to auth_setup, never leaks the password" {
    bundle_full; malcolm_tree
    run md auth "$BUNDLE" --password-file "$PWFILE"
    echo "$output"; cat "$S/argv"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS    auth"* ]]
    no_secret_leak
    # The password went to the hashers on stdin...
    grep -qxF "$PW" "$S/stdin.openssl"
    grep -qxF "$PW" "$S/stdin.docker"
    grep -qxF 'openssl passwd -1 -stdin' "$S/argv"
    grep -qxF "docker run --rm -i --pull never --network none --entrypoint htpasswd ghcr.io/idaholab/malcolm/nginx-proxy:0.0.0-fixture -niBC 10 " "$S/argv"
    # ...and auth_setup got the hashes, leading ':' and newlines stripped.
    grep -qF -- '--auth-noninteractive --auth-method basic --auth-admin-username analyst' "$S/argv"
    grep -qF -- '--auth-admin-password-openssl $1$salt$fakemd5hash --auth-admin-password-htpasswd $2y$10$fakebcrypthash --auth-generate-webcerts' "$S/argv"
    [ "$(cat "$S/auth_setup.cwd")" = "$MD" ]
    [ -s "$MD/nginx/htpasswd" ]
}

@test "auth honours --user" {
    bundle_full; malcolm_tree
    run md auth "$BUNDLE" --password-file "$PWFILE" --user alice
    [ "$status" -eq 0 ]
    grep -qF -- '--auth-admin-username alice' "$S/argv"
    no_secret_leak
}

@test "auth refuses a password file that is not mode 600, and runs nothing" {
    bundle_full; malcolm_tree; chmod 644 "$PWFILE"
    run md auth "$BUNDLE" --password-file "$PWFILE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSE"*"644"* ]]
    [ "$(calls openssl)" -eq 0 ]; [ "$(calls docker)" -eq 0 ]; [ "$(calls auth_setup)" -eq 0 ]
    no_secret_leak
}

@test "auth refuses a password file that is a symlink, and runs nothing" {
    bundle_full; malcolm_tree
    ln -s "$PWFILE" "$BATS_TEST_TMPDIR/pw-link"
    run md auth "$BUNDLE" --password-file "$BATS_TEST_TMPDIR/pw-link"
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSE"*"symlink"* ]]
    [ "$(calls openssl)" -eq 0 ]; [ "$(calls auth_setup)" -eq 0 ]
    no_secret_leak
}

@test "auth refuses a password file not owned by root, and runs nothing" {
    bundle_full; malcolm_tree; FAKE_PW_OWNER=1000
    run md auth "$BUNDLE" --password-file "$PWFILE"
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSE"*"owned by uid 1000"* ]]
    [ "$(calls openssl)" -eq 0 ]; [ "$(calls auth_setup)" -eq 0 ]
    no_secret_leak
}

@test "auth accepts a mode 400 password file" {
    bundle_full; malcolm_tree; chmod 400 "$PWFILE"
    run md auth "$BUNDLE" --password-file "$PWFILE"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS    auth"* ]]
    no_secret_leak
}

@test "auth refuses an invalid user name" {
    bundle_full; malcolm_tree
    run md auth "$BUNDLE" --password-file "$PWFILE" --user 'a b;c'
    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSE"*"invalid user name"* ]]
    [ "$(calls auth_setup)" -eq 0 ]
}

@test "auth refuses an empty password file" {
    bundle_full; malcolm_tree; : > "$PWFILE"
    run md auth "$BUNDLE" --password-file "$PWFILE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"empty"* ]]
    [ "$(calls auth_setup)" -eq 0 ]
}

@test "auth is idempotent when htpasswd exists, and --force redoes it" {
    bundle_full; malcolm_tree
    echo 'analyst:$2y$10$old' > "$MD/nginx/htpasswd"
    run md auth "$BUNDLE" --password-file "$PWFILE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already authenticated"* ]]
    [ "$(calls auth_setup)" -eq 0 ]; [ "$(calls openssl)" -eq 0 ]
    run md auth "$BUNDLE" --password-file "$PWFILE" --force
    [ "$status" -eq 0 ]
    [ "$(calls auth_setup)" -eq 1 ]
    no_secret_leak
}

@test "auth refuses before configure (no .env files)" {
    bundle_full; malcolm_tree; rm "$MD"/config/*.env
    run md auth "$BUNDLE" --password-file "$PWFILE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not configured"* ]]
    [ "$(calls auth_setup)" -eq 0 ]
}

@test "auth refuses when the image list has no nginx-proxy image" {
    malcolm_tree
    run md auth "$BUNDLE" --password-file "$PWFILE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"nginx-proxy"* ]]
    [ "$(calls openssl)" -eq 0 ]; [ "$(calls auth_setup)" -eq 0 ]
}

@test "auth FAILS when auth_setup leaves no htpasswd" {
    bundle_full; malcolm_tree
    printf '#!/usr/bin/env bash\necho "auth_setup $*" >> "$S/argv"\n' > "$MD/scripts/auth_setup"
    run md auth "$BUNDLE" --password-file "$PWFILE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"FAIL"*"htpasswd"* ]]
    no_secret_leak
}

@test "auth runs auth_setup as the PUID user via runuser, identity clean, after chowning the tree" {
    bundle_full; malcolm_tree
    run md auth "$BUNDLE" --password-file "$PWFILE"
    echo "$output"; cat "$S/argv"
    [ "$status" -eq 0 ]
    grep -qxF 'getent passwd 1000' "$S/argv"
    grep -q '^runuser -u ubuntu -- env HOME=/home/ubuntu USER=ubuntu LOGNAME=ubuntu ./scripts/auth_setup --auth-noninteractive ' "$S/argv"
    [ "$(calls runuser)" -eq 1 ]
    [ "$(cat "$S/auth_setup.id")" = "ubuntu ubuntu /home/ubuntu" ]
    [ "$(cat "$S/auth_setup.cwd")" = "$MD" ]
    # The tree is chowned to PUID:PGID once, before auth_setup runs; the
    # default binds are relative (inside $MD), so nothing else is.
    [ "$(calls chown)" -eq 1 ]
    c=$(grep -nxF "chown -R -h 1000:1000 -- $MD" "$S/argv" | cut -d: -f1)
    a=$(grep -n '^auth_setup ' "$S/argv" | cut -d: -f1)
    [ -n "$c" ]; [ -n "$a" ]; [ "$c" -lt "$a" ]
    no_secret_leak
}

@test "auth: control.py's root guard is live in the fake (sudo's LOGNAME=root refuses)" {
    # Proves the identity assertions above can fail: run the fake directly
    # with the identity sudo leaves behind.
    malcolm_tree
    run env LOGNAME=root USER=root S="$S" "$MD/scripts/auth_setup" --x
    [ "$status" -ne 0 ]
    [[ "$output" == *"should not be run as root"* ]]
}

# ── bind-loopback ────────────────────────────────────────────────────────────

@test "bind-loopback rewrites the one mapping and keeps a timestamped backup" {
    malcolm_tree
    cp "$MD/docker-compose.yml" "$BATS_TEST_TMPDIR/orig.yml"
    run md bind-loopback
    echo "$output"
    [ "$status" -eq 0 ]
    grep -qxF "$LOOP" "$MD/docker-compose.yml"
    ! grep -qF '0.0.0.0:443' "$MD/docker-compose.yml" || false
    bak=$(ls "$MD"/docker-compose.yml.bak-*)
    cmp "$bak" "$BATS_TEST_TMPDIR/orig.yml"
    # Only that line changed.
    sed 's|^    - 0\.0\.0\.0:443:443$|    - 127.0.0.1:8443:443|' "$bak" | cmp - "$MD/docker-compose.yml"
    # Round trip: reversing the one line gives back the original exactly.
    sed 's|^    - 127\.0\.0\.1:8443:443$|    - 0.0.0.0:443:443|' "$MD/docker-compose.yml" | cmp - "$BATS_TEST_TMPDIR/orig.yml"
}

@test "bind-loopback also accepts the /tcp spelling and keeps the suffix" {
    malcolm_tree
    printf '%s\n' 'services:' '  nginx-proxy:' '    ports:' '    - 0.0.0.0:443:443/tcp' > "$MD/docker-compose.yml"
    run md bind-loopback
    echo "$output"
    [ "$status" -eq 0 ]
    grep -qxF '    - 127.0.0.1:8443:443/tcp' "$MD/docker-compose.yml"
    ! grep -qF '0.0.0.0:443' "$MD/docker-compose.yml" || false
    run md bind-loopback
    [[ "$output" == *"already bound"* ]]
}

@test "bind-loopback refuses one /tcp and one bare mapping (2 matches)" {
    malcolm_tree
    echo '    - 0.0.0.0:443:443/tcp' >> "$MD/docker-compose.yml"
    cp "$MD/docker-compose.yml" "$BATS_TEST_TMPDIR/orig.yml"
    run md bind-loopback
    [ "$status" -ne 0 ]
    [[ "$output" == *"found 2"* ]]
    cmp "$MD/docker-compose.yml" "$BATS_TEST_TMPDIR/orig.yml"
}

@test "bind-loopback is idempotent: already bound, no second backup" {
    malcolm_tree
    md bind-loopback
    run md bind-loopback
    [ "$status" -eq 0 ]
    [[ "$output" == *"already bound"* ]]
    [ "$(ls "$MD"/docker-compose.yml.bak-* | wc -l)" -eq 1 ]
}

@test "bind-loopback refuses when the mapping is absent (0 matches), changing nothing" {
    malcolm_tree
    printf '%s\n' 'services:' '  nginx-proxy:' '    ports:' '    - 443:443/tcp' > "$MD/docker-compose.yml"
    cp "$MD/docker-compose.yml" "$BATS_TEST_TMPDIR/orig.yml"
    run md bind-loopback
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSE"*"found 0"* ]]
    cmp "$MD/docker-compose.yml" "$BATS_TEST_TMPDIR/orig.yml"
    ! ls "$MD"/docker-compose.yml.bak-* 2>/dev/null || false
}

@test "bind-loopback refuses two matches, changing nothing" {
    malcolm_tree
    echo "$OPEN" >> "$MD/docker-compose.yml"
    cp "$MD/docker-compose.yml" "$BATS_TEST_TMPDIR/orig.yml"
    run md bind-loopback
    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSE"*"found 2"* ]]
    cmp "$MD/docker-compose.yml" "$BATS_TEST_TMPDIR/orig.yml"
    ! ls "$MD"/docker-compose.yml.bak-* 2>/dev/null || false
}

@test "bind-loopback refuses a loopback line alongside a differently-indented 0.0.0.0:443" {
    malcolm_tree
    printf '%s\n' 'services:' "$LOOP" '      - 0.0.0.0:443:443/tcp' > "$MD/docker-compose.yml"
    run md bind-loopback
    [ "$status" -ne 0 ]
    [[ "$output" != *"already bound"* ]]
}

@test "bind-loopback refuses before install" {
    run md bind-loopback
    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSE"*"not installed"* ]]
}

# ── start ────────────────────────────────────────────────────────────────────

@test "start refuses before bind-loopback and never runs Malcolm's start" {
    malcolm_tree
    run md start
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSE"*"bind-loopback"* ]]
    [ "$(calls start)" -eq 0 ]
}

@test "start refuses while any 0.0.0.0:443 remains, even beside the loopback line" {
    malcolm_tree
    printf '%s\n' 'services:' "$LOOP" '      - 0.0.0.0:443:443/tcp' > "$MD/docker-compose.yml"
    run md start
    [ "$status" -ne 0 ]
    [[ "$output" == *"still publishes 0.0.0.0:443"* ]]
    [ "$(calls start)" -eq 0 ]
}

@test "start runs Malcolm's own start script from the malcolm dir after bind" {
    malcolm_tree; md bind-loopback
    run md start
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(calls start)" -eq 1 ]
    grep -qxF 'start --quiet' "$S/argv"
    [ "$(cat "$S/start.cwd")" = "$MD" ]
    ! grep -q '^docker compose up' "$S/argv" || false
}

@test "start is idempotent when every container is already running" {
    malcolm_tree; md bind-loopback; healthy_ps
    run md start
    [ "$status" -eq 0 ]
    [[ "$output" == *"already running"* ]]
    [ "$(calls start)" -eq 0 ]
}

@test "start honours MALCOLM_START" {
    malcolm_tree; md bind-loopback
    stub mystart 'echo "mystart $*" >> "$S/argv"'
    MALCOLM_START="mystart --logs false" run md start
    [ "$status" -eq 0 ]
    grep -qxF 'mystart --logs false' "$S/argv"
    [ "$(calls start)" -eq 0 ]
}

@test "start fails when Malcolm's start script fails" {
    malcolm_tree; md bind-loopback
    printf '#!/usr/bin/env bash\nexit 3\n' > "$MD/scripts/start"
    run md start
    [ "$status" -ne 0 ]
    [[ "$output" == *"FAIL"* ]]
}

@test "start runs Malcolm's start as the PUID user via runuser, after chowning the tree" {
    malcolm_tree; md bind-loopback; rm -f "$S/argv" "$S/chowned"
    run md start
    echo "$output"; cat "$S/argv"
    [ "$status" -eq 0 ]
    grep -qxF 'runuser -u ubuntu -- env HOME=/home/ubuntu USER=ubuntu LOGNAME=ubuntu ./scripts/start --quiet' "$S/argv"
    [ "$(cat "$S/start.id")" = "ubuntu ubuntu /home/ubuntu" ]
    [ "$(cat "$S/start.cwd")" = "$MD" ]
    c=$(grep -nxF "chown -R -h 1000:1000 -- $MD" "$S/argv" | cut -d: -f1)
    b=$(grep -n '^start ' "$S/argv" | cut -d: -f1)
    [ -n "$c" ]; [ -n "$b" ]; [ "$c" -lt "$b" ]
}

@test "start runs MALCOLM_START as the PUID user too" {
    malcolm_tree; md bind-loopback
    stub mystart 'echo "mystart $* as ${LOGNAME:-}" >> "$S/argv"'
    MALCOLM_START="mystart --logs false" run md start
    [ "$status" -eq 0 ]
    grep -qxF 'runuser -u ubuntu -- env HOME=/home/ubuntu USER=ubuntu LOGNAME=ubuntu mystart --logs false' "$S/argv"
    grep -qxF 'mystart --logs false as ubuntu' "$S/argv"
}

# ── Malcolm's user: PUID/PGID from config/process.env ────────────────────────

# refuses_both PATTERN: auth and start both REFUSE with PATTERN, and neither
# chowns anything, drops to any user, or runs Malcolm's tools or the hashers.
refuses_both() {
    run md auth "$BUNDLE" --password-file "$PWFILE"
    echo "auth: $output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSE"*$1* ]]
    run md start
    echo "start: $output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSE"*$1* ]]
    [ "$(calls runuser)" -eq 0 ]; [ "$(calls chown)" -eq 0 ]
    [ "$(calls auth_setup)" -eq 0 ]; [ "$(calls start)" -eq 0 ]
    [ "$(calls openssl)" -eq 0 ]
    ! grep -q '^docker run' "$S/argv" || false
    no_secret_leak
}

# A bound, configured tree with a clean record.
bound_tree() { bundle_full; malcolm_tree; md bind-loopback; rm -f "$S/argv" "$S/chowned"; }

@test "PUID=0 in process.env is refused by auth and start" {
    bound_tree
    printf 'PUID=0\nPGID=0\n' > "$MD/config/process.env"
    refuses_both "PUID in $MD/config/process.env is 0"
}

@test "a missing process.env is refused by auth and start" {
    bound_tree
    rm "$MD/config/process.env"
    refuses_both "no $MD/config/process.env"
}

@test "a PUID user outside the docker group is refused, with the usermod fix" {
    bound_tree
    FAKE_GROUPS='ubuntu adm'
    refuses_both "not in the docker group — add them: usermod -aG docker ubuntu"
}

@test "a PUID with no passwd entry is refused" {
    bound_tree
    FAKE_PASSWD='someone:x:1001:1001::/home/someone:/bin/bash'
    refuses_both "PUID 1000 (from $MD/config/process.env) has no passwd entry"
}

@test "a missing, non-numeric or repeated PUID, or a missing PGID, is refused" {
    bound_tree
    printf 'PGID=1000\n' > "$MD/config/process.env"
    refuses_both "PUID in $MD/config/process.env is missing"
    printf 'PUID=ubuntu\nPGID=1000\n' > "$MD/config/process.env"
    refuses_both "PUID in $MD/config/process.env is missing, repeated or not a number ('ubuntu')"
    printf 'PUID=1000\nPUID=1001\nPGID=1000\n' > "$MD/config/process.env"
    refuses_both "not a number ('1000 1001')"
    printf 'PUID=1000\n' > "$MD/config/process.env"
    refuses_both "PGID in $MD/config/process.env is missing"
}

@test "a quoted PUID/PGID with CRLF endings among other settings is accepted" {
    bound_tree
    printf 'MALCOLM_X=1\r\nPUID="1000"\r\nPGID=1000\r\nZ=2\r\n' > "$MD/config/process.env"
    run md start
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q '^runuser -u ubuntu -- ' "$S/argv"
}

@test "the \$MD chown is skipped when every entry is already PUID:PGID" {
    bound_tree
    # find -uid ... -print -quit finding nothing = the tree is already owned.
    stub find 'case " $* " in *" -uid "*) exit 0 ;; esac; exec "$REAL/find" "$@"'
    run md start
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(calls chown)" -eq 0 ]
    [ "$(calls start)" -eq 1 ]
}

# The R770 shape: pcapDir /data/pcap/raw, indexDir /data/index, absolute.
absolute_binds() {
    DATA="$BATS_TEST_TMPDIR/data"
    mkdir -p "$DATA/pcap/raw/upload" "$DATA/index"
    compose_with_upload "$DATA/pcap/raw/upload" "" "" "$DATA/index" > "$MD/docker-compose.yml"
    md bind-loopback; rm -f "$S/argv" "$S/chowned"
}

@test "root-owned pcapDir and indexDir (from the compose binds) are chowned -R before start" {
    bundle_full; malcolm_tree; absolute_binds
    grep -qxF "      source: $DATA/pcap/raw" "$MD/docker-compose.yml"
    grep -qxF "      source: $DATA/index" "$MD/docker-compose.yml"
    run md start
    echo "$output"; cat "$S/argv"
    [ "$status" -eq 0 ]
    grep -qxF "chown -R -h 1000:1000 -- $DATA/pcap/raw" "$S/argv"
    grep -qxF "chown -R -h 1000:1000 -- $DATA/index" "$S/argv"
    # The upload dir is inside pcapDir: covered by its parent, not chowned again.
    ! grep -qxF "chown -R -h 1000:1000 -- $DATA/pcap/raw/upload" "$S/argv" || false
    [ "$(calls chown)" -eq 3 ]
    b=$(grep -n '^start ' "$S/argv" | cut -d: -f1)
    last=$(grep -n '^chown ' "$S/argv" | tail -1 | cut -d: -f1)
    [ "$last" -lt "$b" ]
}

@test "the data dirs are chowned before auth_setup as well" {
    bundle_full; malcolm_tree; absolute_binds
    run md auth "$BUNDLE" --password-file "$PWFILE"
    [ "$status" -eq 0 ]
    a=$(grep -n '^auth_setup ' "$S/argv" | cut -d: -f1)
    i=$(grep -nxF "chown -R -h 1000:1000 -- $DATA/index" "$S/argv" | cut -d: -f1)
    [ -n "$i" ]; [ "$i" -lt "$a" ]
    no_secret_leak
}

@test "data dirs no longer root-owned, or absent, are left alone" {
    bundle_full; malcolm_tree; absolute_binds
    FAKE_DIR_OWNER=1000
    run md start
    [ "$status" -eq 0 ]
    [ "$(calls chown)" -eq 1 ]
    grep -qxF "chown -R -h 1000:1000 -- $MD" "$S/argv"
    rm -f "$S/argv" "$S/chowned"; FAKE_DIR_OWNER=0; rm -r "$DATA"
    printf '' > "$S/ps"
    run md start
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(calls chown)" -eq 1 ]
}

@test "a data bind source of / is refused before anything is chowned" {
    bundle_full; malcolm_tree
    compose_with_upload "$MD/pcap/upload" "" "" / > "$MD/docker-compose.yml"
    md bind-loopback; rm -f "$S/argv" "$S/chowned"
    run md start
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSE"*"is / — not chowning it"* ]]
    [ "$(calls chown)" -eq 0 ]; [ "$(calls runuser)" -eq 0 ]
}

@test "bind-loopback gives the edited compose file back its owner" {
    malcolm_tree
    run md bind-loopback
    [ "$status" -eq 0 ]
    bak=$(ls "$MD"/docker-compose.yml.bak-*)
    grep -qxF "chown --reference=$bak -- $MD/docker-compose.yml" "$S/argv"
    [ "$(calls runuser)" -eq 0 ]
}

@test "configure runs install.py as root, not via runuser" {
    bundle_full; md install "$BUNDLE"
    run md configure "$CONF"
    [ "$status" -eq 0 ]
    [ "$(calls runuser)" -eq 0 ]
    grep -qxF 'PUID=1000' "$MD/config/process.env"
}

# ── health ───────────────────────────────────────────────────────────────────

@test "health passes when all are healthy and only 127.0.0.1:8443 is published" {
    malcolm_tree; healthy_ps; good_ss
    run md health --timeout 0
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS    all 4 services running and healthy"* ]]
    [[ "$output" == *"PASS    127.0.0.1:8443 is listening"* ]]
    grep -qF "docker compose ps --all --format {{.Name}} {{.State}} {{.Health}}" "$S/argv"
    grep -qxF 'ss -H -ltnp' "$S/argv"
}

@test "health times out and lists exactly the unhealthy services" {
    malcolm_tree; good_ss
    printf '%s\n' 'malcolm-arkime-1 running starting' 'malcolm-zeek-1 running healthy' \
        'malcolm-logstash-1 exited' 'malcolm-api-1 running unhealthy' 'malcolm-filebeat-1 running' > "$S/ps"
    run md health --timeout 0
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"FAIL    not healthy after 0s"* ]]
    [[ "$output" == *"malcolm-arkime-1(running/starting)"* ]]
    [[ "$output" == *"malcolm-logstash-1(exited)"* ]]
    [[ "$output" == *"malcolm-api-1(running/unhealthy)"* ]]
    [[ "$output" != *"malcolm-zeek-1("* ]]
    [[ "$output" != *"malcolm-filebeat-1("* ]]
    [ "$(calls ss)" -eq 0 ]
}

@test "health polls until the stack settles" {
    malcolm_tree; good_ss
    echo 'malcolm-arkime-1 running starting' > "$S/ps"
    stub sleep 'n=$(cat "$S/sleeps" 2>/dev/null || echo 0); echo $((n+1)) > "$S/sleeps"; [ "$n" -ge 2 ] && echo "malcolm-arkime-1 running healthy" > "$S/ps"; exit 0'
    run md health --timeout 60
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(cat "$S/sleeps")" -eq 3 ]
}

@test "health FAILS when docker-proxy listens on 0.0.0.0:443" {
    malcolm_tree; healthy_ps; good_ss
    echo 'LISTEN 0 4096 0.0.0.0:443 0.0.0.0:* users:(("docker-proxy",pid=4243,fd=7))' >> "$S/ss"
    run md health --timeout 0
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"FAIL    Malcolm published on a wildcard 443"* ]]
}

@test "health FAILS when docker-proxy listens on [::]:443" {
    malcolm_tree; healthy_ps; good_ss
    echo 'LISTEN 0 4096 [::]:443 [::]:* users:(("docker-proxy",pid=4244,fd=7))' >> "$S/ss"
    run md health --timeout 0
    [ "$status" -ne 0 ]
    [[ "$output" == *"wildcard 443"* ]]
}

@test "health FAILS on docker-proxy on a non-loopback address, any port" {
    malcolm_tree; healthy_ps; good_ss
    echo 'LISTEN 0 4096 0.0.0.0:9200 0.0.0.0:* users:(("docker-proxy",pid=4250,fd=7))' >> "$S/ss"
    run md health --timeout 0
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"FAIL    docker-proxy published on a non-loopback address: "*"0.0.0.0:9200"* ]]
}

@test "health accepts docker-proxy on loopback addresses only" {
    malcolm_tree; healthy_ps; good_ss
    echo 'LISTEN 0 4096 [::1]:9200 [::]:* users:(("docker-proxy",pid=4251,fd=7))' >> "$S/ss"
    run md health --timeout 0
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS    127.0.0.1:8443 is listening"* ]]
    [[ "$output" != *"non-loopback"* ]]
}

@test "health wraps compose ps in a timeout" {
    malcolm_tree; healthy_ps; good_ss
    stub timeout 'echo "timeout $1" >> "$S/argv"; shift; exec "$@"'
    run md health --timeout 0
    [ "$status" -eq 0 ]
    grep -qxF 'timeout 30' "$S/argv"
}

@test "health FAILS when nothing listens on 127.0.0.1:8443" {
    malcolm_tree; healthy_ps
    echo 'LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=900,fd=3))' > "$S/ss"
    run md health --timeout 0
    [ "$status" -ne 0 ]
    [[ "$output" == *"FAIL    nothing listening on 127.0.0.1:8443"* ]]
}

@test "health accepts the portal's nginx on 0.0.0.0:443 (not docker-proxy)" {
    malcolm_tree; healthy_ps; good_ss
    echo 'LISTEN 0 511 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=77,fd=6))' >> "$S/ss"
    run md health --timeout 0
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"non-docker"* ]]
}

@test "health FAILS on a 443 wildcard listener it cannot attribute" {
    malcolm_tree; healthy_ps; good_ss
    echo 'LISTEN 0 511 0.0.0.0:443 0.0.0.0:*' >> "$S/ss"
    run md health --timeout 0
    [ "$status" -ne 0 ]
    [[ "$output" == *"no owner shown"* ]]
}

@test "health honours MALCOLM_COMPOSE" {
    malcolm_tree; good_ss
    stub docker-compose 'echo "docker-compose $*" >> "$S/argv"; echo "malcolm-zeek-1 running healthy"'
    MALCOLM_COMPOSE=docker-compose run md health --timeout 0
    [ "$status" -eq 0 ]
    grep -q '^docker-compose ps --all' "$S/argv"
    [ "$(calls docker)" -eq 0 ]
}

@test "health FAILS on an empty container list" {
    malcolm_tree; good_ss; : > "$S/ps"
    run md health --timeout 0
    [ "$status" -ne 0 ]
    [[ "$output" == *"no containers"* ]]
}

@test "health rejects a non-numeric timeout" {
    malcolm_tree
    run md health --timeout soon
    [ "$status" -ne 0 ]
}

# ── verify ───────────────────────────────────────────────────────────────────

@test "verify captures loopback, uploads it, and PASSes Arkime, Zeek and the zeek container" {
    malcolm_tree; healthy_ps; echo 12 > "$S/arkime"; touch "$S/zeek_writes"
    run md verify --password-file "$PWFILE"
    echo "$output"; cat "$S/argv"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS    capture"* ]]
    [[ "$output" == *"PASS    uploaded"* ]]
    [[ "$output" == *"PASS    arkime: 12 session(s)"* ]]
    [[ "$output" == *"PASS    zeek: new log files"* ]]
    [[ "$output" == *"PASS    zeek container: malcolm-zeek-1 running healthy"* ]]
    grep -q '^tcpdump -i lo .*-w .*\.pcap tcp port 8443$' "$S/argv"
    [ "$(grep -c '^curl -sk -o /dev/null --max-time 5 https://127.0.0.1:8443/$' "$S/argv")" -eq 5 ]
    ls "$MD"/pcap/upload/r770-verify-*.pcap
    ! ls "$MD"/pcap/upload/.*.part 2>/dev/null || false
    # Credentials reached curl on stdin (-K -), never argv.
    grep -qxF "user = \"analyst:$PW\"" "$S/stdin.curl"
    grep -q '^curl -sk --max-time 20 -K - https://127.0.0.1:8443/arkime/api/sessions' "$S/argv"
    no_secret_leak
    # The upload went to the directory the compose file names (relative ./pcap/upload).
    [[ "$output" == *"PASS    uploaded: $MD/pcap/upload/r770-verify-"* ]]
    # The temporary capture dir is cleaned up.
    [ -z "$(ls -A "$MALCOLM_TMPDIR")" ]
}

@test "verify's Arkime query is windowed to this capture, never date=1" {
    malcolm_tree; healthy_ps; echo 1 > "$S/arkime"; touch "$S/zeek_writes"
    before=$(date +%s)
    run md verify --password-file "$PWFILE"
    after=$(date +%s)
    echo "$output"
    [ "$status" -eq 0 ]
    q=$(grep '^curl -sk --max-time 20 -K - ' "$S/argv" | head -1)
    echo "$q"
    [[ "$q" != *"date="* ]]
    [[ "$q" == *"&expression=port%3D%3D8443" ]]
    start=$(sed -n 's/.*[?&]startTime=\([0-9][0-9]*\)&.*/\1/p' <<< "$q")
    stop=$(sed -n 's/.*[?&]stopTime=\([0-9][0-9]*\)&.*/\1/p' <<< "$q")
    [ -n "$start" ]
    [ -n "$stop" ]
    [ "$start" -ge $((before - 5)) ]; [ "$start" -le $((after - 5)) ]
    [ "$stop" -ge $((before + 60)) ]; [ "$stop" -le $((after + 60)) ]
}

@test "verify uploads to an absolute upload dir named by the compose file, not \$MD/pcap/upload" {
    malcolm_tree; healthy_ps; echo 1 > "$S/arkime"; touch "$S/zeek_writes"
    up="$BATS_TEST_TMPDIR/data/pcap/raw/upload"; mkdir -p "$up"
    compose_with_upload "$up" > "$MD/docker-compose.yml"
    run md verify --password-file "$PWFILE"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS    uploaded: $up/r770-verify-"* ]]
    ls "$up"/r770-verify-*.pcap
    ! ls "$MD"/pcap/upload/*.pcap 2>/dev/null || false
    no_secret_leak
}

@test "verify finds the upload bind when target: comes before source:" {
    malcolm_tree; healthy_ps; echo 1 > "$S/arkime"; touch "$S/zeek_writes"
    up="$BATS_TEST_TMPDIR/data/pcap/raw/upload"; mkdir -p "$up"
    compose_with_upload "$up" "$(bind_entry "$up" "$UPLOAD_TARGET" ts)" > "$MD/docker-compose.yml"
    grep -B1 "source: $up" "$MD/docker-compose.yml" | grep -qF "target: $UPLOAD_TARGET"
    run md verify --password-file "$PWFILE"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS    uploaded: $up/r770-verify-"* ]]
    ls "$up"/r770-verify-*.pcap
}

@test "verify finds a quoted upload source" {
    malcolm_tree; healthy_ps; echo 1 > "$S/arkime"; touch "$S/zeek_writes"
    up="$BATS_TEST_TMPDIR/data/pcap/raw/upload"; mkdir -p "$up"
    compose_with_upload "$up" "$(bind_entry "\"$up\"" "$UPLOAD_TARGET")" > "$MD/docker-compose.yml"
    grep -qxF "      source: \"$up\"" "$MD/docker-compose.yml"
    run md verify --password-file "$PWFILE"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS    uploaded: $up/r770-verify-"* ]]
    ls "$up"/r770-verify-*.pcap
}

@test "verify refuses two upload binds with the upload target, before capturing" {
    malcolm_tree; healthy_ps
    a="$BATS_TEST_TMPDIR/a"; b="$BATS_TEST_TMPDIR/b"; mkdir -p "$a" "$b"
    compose_with_upload "$a" "$(bind_entry "$a" "$UPLOAD_TARGET"; bind_entry "$b" "$UPLOAD_TARGET")" \
        > "$MD/docker-compose.yml"
    run md verify --password-file "$PWFILE"
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSE"*"$UPLOAD_TARGET"*"found 2"* ]]
    [ "$(calls tcpdump)" -eq 0 ]; [ "$(calls curl)" -eq 0 ]
    [ -z "$(ls -A "$a")" ]; [ -z "$(ls -A "$b")" ]
}

@test "verify ignores another service's bind to the upload target; the upload: service's source wins" {
    malcolm_tree; healthy_ps; echo 1 > "$S/arkime"; touch "$S/zeek_writes"
    up="$BATS_TEST_TMPDIR/data/pcap/raw/upload"; other="$BATS_TEST_TMPDIR/other"
    mkdir -p "$up" "$other"
    # pcap-monitor precedes upload: and binds a different source to the SAME target.
    compose_with_upload "$up" "" "$(bind_entry "$other" "$UPLOAD_TARGET")" > "$MD/docker-compose.yml"
    [ "$(grep -cxF "      target: $UPLOAD_TARGET" "$MD/docker-compose.yml")" -eq 2 ]
    [ "$(grep -n "source: $other" "$MD/docker-compose.yml" | cut -d: -f1)" -lt \
      "$(grep -n '^  upload:' "$MD/docker-compose.yml" | cut -d: -f1)" ]
    run md verify --password-file "$PWFILE"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS    uploaded: $up/r770-verify-"* ]]
    ls "$up"/r770-verify-*.pcap
    [ -z "$(ls -A "$other")" ]
}

@test "verify's EXIT trap kills a still-running tcpdump when a later step fails" {
    malcolm_tree; healthy_ps
    # tcpdump records its pid (the one verify holds: the stub execs sleep in
    # place) and stays up. sleep fails once that pid exists, so set -e aborts
    # verify mid-capture, before its own kill -INT, leaving only the trap.
    stub tcpdump 'echo "tcpdump $*" >> "$S/argv"; echo $$ > "$S/tcpdump.pid.tmp"; mv "$S/tcpdump.pid.tmp" "$S/tcpdump.pid"; exec "$REAL/sleep" 30'
    stub sleep 'n=0; while [ ! -s "$S/tcpdump.pid" ] && [ "$n" -lt 100 ]; do "$REAL/sleep" 0.05; n=$((n+1)); done; exit 1'
    run md verify --password-file "$PWFILE"
    echo "$output"
    pid=$(cat "$S/tcpdump.pid")
    [ -n "$pid" ]
    [ "$status" -ne 0 ]
    [ "$(calls tcpdump)" -eq 1 ]
    [[ "$output" != *"PASS    capture"* ]]
    # Give the killed process a moment to be reaped (a zombie still answers kill -0).
    for _ in $(seq 40); do kill -0 "$pid" 2>/dev/null || break; "$REAL/sleep" 0.05; done
    alive=0; kill -0 "$pid" 2>/dev/null && alive=1
    [ "$alive" -eq 1 ] && kill "$pid" 2>/dev/null   # never leave a stray process
    run kill -0 "$pid"
    [ "$status" -ne 0 ]
    [ "$alive" -eq 0 ]
    # The trap also removed the capture dir.
    [ -z "$(ls -A "$MALCOLM_TMPDIR")" ]
}

@test "verify refuses a compose file with no upload bind mount, before capturing" {
    malcolm_tree; healthy_ps
    printf '%s\n' 'services:' '  nginx-proxy:' '    ports:' "$OPEN" '  upload:' '    image: x' \
        '    volumes:' '    - type: bind' '      source: ./pcap/upload' '      target: /elsewhere' > "$MD/docker-compose.yml"
    run md verify --password-file "$PWFILE"
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSE"*"/var/www/upload/server/php/chroot/files"*"found 0"* ]]
    [ "$(calls tcpdump)" -eq 0 ]; [ "$(calls curl)" -eq 0 ]
    ! ls "$MD"/pcap/upload/*.pcap 2>/dev/null || false
}

@test "verify refuses an invalid user name" {
    malcolm_tree; healthy_ps
    run md verify --password-file "$PWFILE" --user 'x"y'
    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSE"*"invalid user name"* ]]
    [ "$(calls tcpdump)" -eq 0 ]; [ "$(calls curl)" -eq 0 ]
}

@test "verify escapes quotes and backslashes in the curl config" {
    malcolm_tree; healthy_ps; echo 1 > "$S/arkime"; touch "$S/zeek_writes"
    printf '%s\n' 'a"b\c' > "$PWFILE"
    run md verify --password-file "$PWFILE"
    [ "$status" -eq 0 ]
    grep -qxF 'user = "analyst:a\"b\\c"' "$S/stdin.curl"
}

@test "verify FAILS Arkime when no sessions show up before VERIFY_TIMEOUT" {
    malcolm_tree; healthy_ps; touch "$S/zeek_writes"
    run md verify --password-file "$PWFILE"
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"FAIL    arkime"* ]]
    [[ "$output" == *"PASS    zeek: new log files"* ]]
    no_secret_leak
}

@test "verify FAILS Zeek when no new logs appear" {
    malcolm_tree; healthy_ps; echo 3 > "$S/arkime"
    run md verify --password-file "$PWFILE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"FAIL    zeek: no new files"* ]]
    [[ "$output" == *"PASS    arkime"* ]]
    no_secret_leak
}

@test "verify FAILS when the zeek container is not healthy" {
    malcolm_tree; echo 3 > "$S/arkime"; touch "$S/zeek_writes"
    printf '%s\n' 'malcolm-arkime-1 running healthy' 'malcolm-zeek-1 restarting' 'malcolm-zeek-live-1 running healthy' > "$S/ps"
    run md verify --password-file "$PWFILE"
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"FAIL    zeek container not running+healthy: malcolm-zeek-1 restarting"* ]]
    no_secret_leak
}

@test "verify FAILS when the capture is empty and uploads nothing" {
    malcolm_tree; healthy_ps
    stub tcpdump 'echo "tcpdump $*" >> "$S/argv"; echo "tcpdump: lo: permission denied" >&2; exit 1'
    run md verify --password-file "$PWFILE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"FAIL    capture"* ]]
    ! ls "$MD"/pcap/upload/*.pcap 2>/dev/null || false
    no_secret_leak
}

@test "verify refuses a password file that is not mode 600, before capturing" {
    malcolm_tree; healthy_ps; chmod 640 "$PWFILE"
    run md verify --password-file "$PWFILE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSE"*"640"* ]]
    [ "$(calls tcpdump)" -eq 0 ]; [ "$(calls curl)" -eq 0 ]
}

@test "verify refuses when not root" {
    malcolm_tree; FAKE_UID=1000
    run md verify --password-file "$PWFILE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"root"* ]]
    [ "$(calls tcpdump)" -eq 0 ]
}

@test "verify refuses when the compose file's upload directory is missing" {
    malcolm_tree; rm -r "$MD/pcap"
    run md verify --password-file "$PWFILE"
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSE"*"upload directory $MD/pcap/upload"*"does not exist"* ]]
    [ "$(calls tcpdump)" -eq 0 ]
}

@test "unknown verb prints usage and fails" {
    run md frobnicate
    [ "$status" -ne 0 ]
    [[ "$output" == *"usage"* ]]
}
