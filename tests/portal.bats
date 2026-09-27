#!/usr/bin/env bats
#
# r770-portal.sh installs the analyst portal's nginx config, htpasswd and the
# offline MkDocs build, so what matters most is: apply never reloads onto a
# broken config, any failure after the nginx backup puts /etc/nginx back
# byte-for-byte, the backup (it holds lab.key) is never world-readable, a
# second apply changes nothing, and verify never puts the analyst password on
# curl's command line.
#
# docker, nginx, systemctl, curl, ss, install, tar and id are stubs backed by
# a state directory ($S). tar and install log, then hand off to the real tools
# (so a backup is a genuine tarball with genuine modes and the restore is a
# genuine round trip); install drops -o/-g, which a non-root test cannot honour.
# cp/mkdir/ln/rm/mv/chmod/cmp/date/readlink/stat/mktemp/sha256sum are the real
# tools (they only ever touch paths under $BATS_TEST_TMPDIR).
#
#   $S/calls           every mutating call (docker run/nginx/systemctl/tar/install), one per line
#   $S/argv            every curl invocation's argv, one per line (password-argv guard)
#   $S/nginx_t_rc      exit code for `nginx -t` (default 0)
#   $S/reload_rc       exit code for `systemctl reload nginx` (default 0)
#   $S/active_rc       exit code for `systemctl is-active` (default 0: active)
#   $S/install_rc      when present, `install` fails with this code
#   $S/docker_rc       when present, `docker run` fails with this code
#   $S/inspect_rc      when present, `docker image inspect` fails with this code
#   $S/image_id        what `docker image inspect` reports (default sha256:fixture-1)
#   $S/ss_output       canned `ss -H -ltnp` output (default: only nginx on :443)
#   $S/code_<site>_noauth   HTTP code curl returns for <site> with no -K (default 401)
#   $S/code_<site>_creds    HTTP code curl returns for <site> with -K -   (default 200)

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-portal.sh"
    REPO="$BATS_TEST_DIRNAME/.."
    BIN="$BATS_TEST_TMPDIR/bin"; REAL="$BATS_TEST_TMPDIR/real"
    export S="$BATS_TEST_TMPDIR/state"
    mkdir -p "$BIN" "$REAL" "$S"
    for t in bash env cat sed awk grep tr cp mv mkdir ls date head tail rm cmp diff \
             chmod ln readlink mktemp dirname basename stat sha256sum sort gzip timeout; do
        p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$REAL/$t"
    done
    export REAL_TAR REAL_INSTALL
    REAL_TAR=$(command -v tar); REAL_INSTALL=$(command -v install)
    TEST_PATH="$BIN:$REAL"

    export PORTAL_SITE="$BATS_TEST_TMPDIR/site"
    export PORTAL_NGINX_DIR="$BATS_TEST_TMPDIR/nginx"
    export PORTAL_WWW="$BATS_TEST_TMPDIR/www"
    export PORTAL_MALCOLM_HTPASSWD="$BATS_TEST_TMPDIR/malcolm-htpasswd"
    export PORTAL_BACKUP_DIR="$BATS_TEST_TMPDIR/backups"
    # the install stub cannot chgrp to www-data; the file lands in our own group
    PORTAL_WWW_GROUP=$(id -gn); export PORTAL_WWW_GROUP
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"
    export FAKE_UID=0
    unset PORTAL_SITES PORTAL_MKDOCS_IMAGE
    mkdir -p "$TMPDIR"

    # -- source tree, shaped like the bundle: site/{config,docs} beside docker/ --
    mkdir -p "$PORTAL_SITE/config/nginx/snippets" "$PORTAL_SITE/config/nginx/conf.d" \
             "$PORTAL_SITE/config/portal" "$PORTAL_SITE/config/docs" \
             "$PORTAL_SITE/docs/analyst-wiki" "$BATS_TEST_TMPDIR/docker"
    echo 'auth_basic snippet' > "$PORTAL_SITE/config/nginx/snippets/lab-auth.conf"
    echo 'tls snippet'        > "$PORTAL_SITE/config/nginx/snippets/lab-tls.conf"
    echo 'headers snippet'    > "$PORTAL_SITE/config/nginx/snippets/lab-headers.conf"
    echo 'map upgrade'        > "$PORTAL_SITE/config/nginx/conf.d/lab-connection-upgrade.conf"
    echo 'server { reject }'  > "$PORTAL_SITE/config/nginx/00-default-reject.conf"
    echo 'server { portal }'  > "$PORTAL_SITE/config/nginx/portal.lab.conf"
    echo 'server { malcolm }' > "$PORTAL_SITE/config/nginx/malcolm.lab.conf"
    echo 'server { docs }'    > "$PORTAL_SITE/config/nginx/docs.lab.conf"
    echo 'server { gns3 }'    > "$PORTAL_SITE/config/nginx/gns3.lab.conf"
    echo '<html>portal</html>' > "$PORTAL_SITE/config/portal/index.html"
    echo 'site_name: test'    > "$PORTAL_SITE/config/docs/mkdocs.yml"
    echo '# index'            > "$PORTAL_SITE/docs/analyst-wiki/index.md"
    echo '# access'           > "$PORTAL_SITE/docs/analyst-wiki/access.md"
    # synthetic tags only (OWNERS.md "Fixture and example data")
    printf '%s\n' "docker.io/prom/prometheus:0.0.0-fixture" \
                  "docker.io/squidfunk/mkdocs-material:0.0.0-fixture" \
        > "$BATS_TEST_TMPDIR/docker/monitoring-image-list.txt"

    # -- preconditions apply checks for --
    mkdir -p "$PORTAL_NGINX_DIR/ssl"
    echo cert > "$PORTAL_NGINX_DIR/ssl/lab.crt"
    echo key  > "$PORTAL_NGINX_DIR/ssl/lab.key"
    echo ca   > "$PORTAL_NGINX_DIR/ssl/ca.crt"
    chmod 600 "$PORTAL_NGINX_DIR/ssl/lab.key"
    echo 'analyst:$apr1$hash' > "$PORTAL_MALCOLM_HTPASSWD"

    stub id        'echo "$FAKE_UID"'
    stub systemctl '
echo "systemctl $*" >> "$S/calls"
case "$1" in
    is-active) exit "$(cat "$S/active_rc" 2>/dev/null || echo 0)" ;;
    reload)    exit "$(cat "$S/reload_rc" 2>/dev/null || echo 0)" ;;
esac
exit 0'
    stub tar 'echo "tar $*" >> "$S/calls"; exec "$REAL_TAR" "$@"'
    stub install '
echo "install $*" >> "$S/calls"
[ -f "$S/install_rc" ] && exit "$(cat "$S/install_rc")"
args=()
while [ $# -gt 0 ]; do
    case "$1" in
        -o|-g) shift 2 ;;
        *)     args+=("$1"); shift ;;
    esac
done
exec "$REAL_INSTALL" "${args[@]}"'

    stub nginx '
echo "nginx $*" >> "$S/calls"
if [ "$1" = "-t" ]; then
    rc="$(cat "$S/nginx_t_rc" 2>/dev/null || echo 0)"
    if [ "$rc" -eq 0 ]; then
        echo "nginx: configuration file test is successful"
        exit 0
    fi
    echo "nginx: [emerg] fake config error" >&2
    exit "$rc"
fi
exit 0'

    # docker: `image inspect` is read-only and not logged. `run` writes a site
    # whose sitemap differs on every build, as real mkdocs output does.
    stub docker '
if [ "$1 $2" = "image inspect" ]; then
    [ -f "$S/inspect_rc" ] && exit "$(cat "$S/inspect_rc")"
    cat "$S/image_id" 2>/dev/null || echo "sha256:fixture-1"
    exit 0
fi
echo "docker $*" >> "$S/calls"
hostdir=""; prev=""
for a; do
    [ "$prev" = "-v" ] && hostdir="${a%%:*}"
    prev="$a"
done
[ -n "$hostdir" ] || { echo "docker stub: no -v arg" >&2; exit 1; }
[ -f "$S/docker_rc" ] && exit "$(cat "$S/docker_rc")"
mkdir -p "$hostdir/site"
echo "<html>built docs</html>" > "$hostdir/site/index.html"
date +%s%N > "$hostdir/site/sitemap.xml"'

    stub ss '
echo "ss $*" >> "$S/calls"
if [ -f "$S/ss_output" ]; then
    cat "$S/ss_output"
else
    printf "%s\n" \
        "LISTEN 0 511 0.0.0.0:443 0.0.0.0:* users:((\"nginx\",pid=100,fd=6))" \
        "LISTEN 0 511 [::]:443 [::]:* users:((\"nginx\",pid=100,fd=7))" \
        "LISTEN 0 128 127.0.0.1:22 0.0.0.0:* users:((\"sshd\",pid=1,fd=3))"
fi'

    # curl: HTTP code is chosen per-site and per-auth from $S/code_<site>_{noauth,creds}
    # (default 401 / 200). -K - reads the config from stdin; the password lands
    # there, not in argv, and we capture that stdin for the never-in-argv test.
    stub curl '
printf "%s\n" "$*" >> "$S/argv"
site=""; has_K=0
for a; do
    case "$a" in
        https://*.lab/) site="${a#https://}"; site="${site%.lab/}" ;;
        -K) has_K=1 ;;
    esac
done
if [ "$has_K" = 1 ]; then
    cat > "$S/last_stdin_$site.lab" 2>/dev/null
    code="$(cat "$S/code_${site}_creds" 2>/dev/null || echo 200)"
else
    code="$(cat "$S/code_${site}_noauth" 2>/dev/null || echo 401)"
fi
printf "%s" "$code"'
}

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$BIN/$1"; chmod +x "$BIN/$1"; }

portal() { PATH="$TEST_PATH" "$SCRIPT" "$@"; }

no_mutations() { [ ! -s "$S/calls" ] || { cat "$S/calls"; false; }; }

# snap DIR -> every path's type, mode, owner, link target, and every file's sha256
snap() {
    (cd "$1" && find . -printf '%p %y %m %u %g %l\n' | LC_ALL=C sort \
             && find . -type f -exec sha256sum {} + | LC_ALL=C sort)
}

backup_count() { find "$PORTAL_BACKUP_DIR" -type f 2>/dev/null | wc -l; }

# ── plan ─────────────────────────────────────────────────────────────────────

@test "plan is read-only and reports what apply would do" {
    run portal plan
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS    running as root"* ]]
    [[ "$output" == *"INSTALL             $PORTAL_NGINX_DIR/snippets/lab-auth.conf"* ]]
    [[ "$output" == *"INSTALL             $PORTAL_NGINX_DIR/conf.d/lab-connection-upgrade.conf"* ]]
    [[ "$output" == *"INSTALL             $PORTAL_NGINX_DIR/sites-available/00-default-reject.conf"* ]]
    [[ "$output" == *"INSTALL             $PORTAL_NGINX_DIR/sites-available/portal.lab.conf"* ]]
    [[ "$output" == *"BUILD               $PORTAL_WWW/docs"* ]]
    no_mutations
    [ ! -e "$PORTAL_NGINX_DIR/snippets" ]
    [ ! -e "$PORTAL_WWW" ]
    [ "$(backup_count)" -eq 0 ]
}

@test "no arguments means plan" {
    run portal
    [ "$status" -eq 0 ]
    [[ "$output" == *"== portal plan =="* ]]
    no_mutations
}

@test "plan reports REFUSE and a non-zero status when certs are missing, but changes nothing" {
    rm "$PORTAL_NGINX_DIR/ssl/lab.crt"
    run portal plan
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"REFUSE  $PORTAL_NGINX_DIR/ssl/lab.crt missing"* ]]
    no_mutations
}

@test "plan takes no arguments" {
    run portal plan --bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"plan takes no arguments"* ]]
}

@test "the mkdocs image comes from the bundle's monitoring image list, not a restated tag" {
    run portal plan
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"mkdocs image:     docker.io/squidfunk/mkdocs-material:0.0.0-fixture"* ]]
    # and the script itself names no mkdocs-material tag of its own
    ! grep -nE 'mkdocs-material:[A-Za-z0-9]' "$SCRIPT" || false
}

# ── apply: refusals ─────────────────────────────────────────────────────────

@test "apply refuses a non-root user" {
    FAKE_UID=1000 run portal apply
    [ "$status" -eq 1 ]
    [[ "$output" == *"REFUSE  must run as root"* ]]
    no_mutations
}

@test "apply refuses when the CA certs are missing, naming each one" {
    rm "$PORTAL_NGINX_DIR/ssl/lab.crt" "$PORTAL_NGINX_DIR/ssl/lab.key"
    run portal apply
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"REFUSE  $PORTAL_NGINX_DIR/ssl/lab.crt missing — run r770-lab-ca.sh apply first"* ]]
    [[ "$output" == *"REFUSE  $PORTAL_NGINX_DIR/ssl/lab.key missing"* ]]
    no_mutations
    [ ! -e "$PORTAL_WWW" ]
}

@test "apply refuses when the Malcolm htpasswd is missing" {
    rm "$PORTAL_MALCOLM_HTPASSWD"
    run portal apply
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"REFUSE  $PORTAL_MALCOLM_HTPASSWD missing"* ]]
    no_mutations
}

@test "apply refuses a symlinked Malcolm htpasswd before touching anything" {
    mv "$PORTAL_MALCOLM_HTPASSWD" "$BATS_TEST_TMPDIR/real-htpasswd"
    ln -s "$BATS_TEST_TMPDIR/real-htpasswd" "$PORTAL_MALCOLM_HTPASSWD"
    run portal apply
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"REFUSE  $PORTAL_MALCOLM_HTPASSWD is a symlink"* ]]
    no_mutations
    [ ! -e "$PORTAL_NGINX_DIR/lab.htpasswd" ]
}

@test "apply refuses a missing vhost source before touching anything" {
    rm "$PORTAL_SITE/config/nginx/docs.lab.conf"
    run portal apply
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"REFUSE  missing source $PORTAL_SITE/config/nginx/docs.lab.conf"* ]]
    no_mutations
    [ ! -e "$PORTAL_WWW" ]
    [ "$(backup_count)" -eq 0 ]
}

@test "apply refuses when the image list names no mkdocs image and none is set" {
    rm "$BATS_TEST_TMPDIR/docker/monitoring-image-list.txt"
    run portal apply
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"REFUSE  mkdocs image unknown"* ]]
    no_mutations
}

@test "apply refuses when the mkdocs image is not loaded" {
    echo 1 > "$S/inspect_rc"
    run portal apply
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"REFUSE  mkdocs image docker.io/squidfunk/mkdocs-material:0.0.0-fixture is not loaded"* ]]
    no_mutations
}

@test "apply takes no arguments" {
    run portal apply --bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"apply takes no arguments"* ]]
    no_mutations
}

# ── apply: happy path ────────────────────────────────────────────────────────

@test "apply installs the three vhosts plus the default-reject catch-all, and nothing else" {
    run portal apply
    echo "$output"; cat "$S/calls"
    [ "$status" -eq 0 ]

    [ "$(find "$PORTAL_NGINX_DIR/sites-available" -type f | wc -l)" -eq 4 ]
    for v in 00-default-reject.conf portal.lab.conf malcolm.lab.conf docs.lab.conf; do
        [ -f "$PORTAL_NGINX_DIR/sites-available/$v" ]
        [ -L "$PORTAL_NGINX_DIR/sites-enabled/$v" ]
        [ "$(readlink "$PORTAL_NGINX_DIR/sites-enabled/$v")" = "../sites-available/$v" ]
    done
    [ "$(find "$PORTAL_NGINX_DIR/sites-enabled" -type l | wc -l)" -eq 4 ]
    [ ! -e "$PORTAL_NGINX_DIR/sites-available/gns3.lab.conf" ]

    [ -f "$PORTAL_NGINX_DIR/snippets/lab-auth.conf" ]
    [ -f "$PORTAL_NGINX_DIR/snippets/lab-tls.conf" ]
    [ -f "$PORTAL_NGINX_DIR/snippets/lab-headers.conf" ]
    [ -f "$PORTAL_NGINX_DIR/conf.d/lab-connection-upgrade.conf" ]
    cmp -s "$PORTAL_SITE/config/portal/index.html" "$PORTAL_WWW/portal/index.html"

    grep -q '^nginx -t$' "$S/calls"
    grep -q '^systemctl reload nginx$' "$S/calls"
    [[ "$output" == *"DONE    nginx reloaded"* ]]
}

@test "the htpasswd is installed in one step at 0640 root:www-data" {
    unset PORTAL_WWW_GROUP
    run portal apply
    echo "$output"; cat "$S/calls"
    [ "$status" -eq 0 ]
    cmp -s "$PORTAL_MALCOLM_HTPASSWD" "$PORTAL_NGINX_DIR/lab.htpasswd"
    [ "$(stat -c %a "$PORTAL_NGINX_DIR/lab.htpasswd")" = "640" ]
    grep -qxF "install -m0640 -o root -g www-data $PORTAL_MALCOLM_HTPASSWD $PORTAL_NGINX_DIR/lab.htpasswd" "$S/calls"
}

@test "docs are built offline (--pull never, --network none) with the listed image, and stamped" {
    run portal apply
    echo "$output"; cat "$S/calls"
    [ "$status" -eq 0 ]
    grep -q '^docker run --rm --pull never --network none -v ' "$S/calls"
    grep -qF "docker.io/squidfunk/mkdocs-material:0.0.0-fixture build" "$S/calls"
    grep -qF 'built docs' "$PORTAL_WWW/docs/index.html"
    [ -s "$PORTAL_WWW/docs/.r770-source.sha256" ]
    [ ! -e "$PORTAL_WWW/docs.new" ]
    [ ! -e "$PORTAL_WWW/docs.old" ]
    # the build dir is gone
    [ -z "$(ls -A "$TMPDIR")" ]
}

@test "a second apply is a no-op: no rebuild, no backup, no reload" {
    run portal apply
    [ "$status" -eq 0 ]
    [ "$(backup_count)" -eq 1 ]
    : > "$S/calls"
    run portal apply
    echo "$output"; cat "$S/calls"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already installed  $PORTAL_NGINX_DIR/snippets/lab-auth.conf"* ]]
    [[ "$output" == *"already installed  $PORTAL_NGINX_DIR/sites-available/portal.lab.conf"* ]]
    [[ "$output" == *"already installed  $PORTAL_NGINX_DIR/sites-enabled/portal.lab.conf"* ]]
    [[ "$output" == *"already installed  $PORTAL_NGINX_DIR/lab.htpasswd"* ]]
    [[ "$output" == *"already installed  $PORTAL_WWW/docs"* ]]
    [[ "$output" == *"DONE    no nginx config changes — nginx not reloaded"* ]]
    [[ "$output" != *"INSTALL"* ]]
    [[ "$output" != *"BACKUP"* ]]
    ! grep -q 'systemctl reload' "$S/calls" || false
    ! grep -q '^docker run' "$S/calls" || false
    ! grep -q '^tar ' "$S/calls" || false
    grep -q '^nginx -t$' "$S/calls"
    [ "$(backup_count)" -eq 1 ]
}

@test "a changed wiki page or image rebuilds docs, without an nginx backup or reload" {
    portal apply
    : > "$S/calls"
    echo '# access v2' > "$PORTAL_SITE/docs/analyst-wiki/access.md"
    run portal apply
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"INSTALL             $PORTAL_WWW/docs"* ]]
    grep -q '^docker run' "$S/calls"
    ! grep -q 'systemctl reload' "$S/calls" || false
    [ "$(backup_count)" -eq 1 ]

    : > "$S/calls"
    echo 'sha256:fixture-2' > "$S/image_id"
    run portal apply
    [ "$status" -eq 0 ]
    [[ "$output" == *"INSTALL             $PORTAL_WWW/docs"* ]]
}

@test "changing one vhost source triggers exactly one INSTALL, a new backup and a reload" {
    portal apply
    : > "$S/calls"
    echo 'server { portal v2 }' > "$PORTAL_SITE/config/nginx/portal.lab.conf"
    run portal apply
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"INSTALL             $PORTAL_NGINX_DIR/sites-available/portal.lab.conf"* ]]
    [[ "$output" == *"already installed  $PORTAL_NGINX_DIR/sites-available/malcolm.lab.conf"* ]]
    [ "$(grep -c '^INSTALL' <<< "$output")" -eq 1 ]
    grep -q 'systemctl reload nginx' "$S/calls"
    [ "$(backup_count)" -eq 2 ]
}

# ── apply: the backup ────────────────────────────────────────────────────────

@test "the nginx backup is a 0600 tarball in a 0700 directory, and holds the key" {
    run portal apply
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(stat -c %a "$PORTAL_BACKUP_DIR")" = "700" ]
    b=$(find "$PORTAL_BACKUP_DIR" -type f)
    [ "$(stat -c %a "$b")" = "600" ]
    [[ "$output" == *"BACKUP  $b"* ]]
    tar -tzf "$b" | grep -qx 'nginx/ssl/lab.key'
}

# ── apply: failures after (and before) the backup ────────────────────────────

@test "a failed docs build changes nothing under nginx and takes no backup" {
    before=$(snap "$PORTAL_NGINX_DIR")
    echo 1 > "$S/docker_rc"
    run portal apply
    echo "$output"; cat "$S/calls"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL    mkdocs build failed"* ]]
    [ "$(snap "$PORTAL_NGINX_DIR")" = "$before" ]
    [ "$(backup_count)" -eq 0 ]
    ! grep -qE '^(tar|install|nginx|systemctl) ' "$S/calls" || false
    [ ! -e "$PORTAL_WWW/docs" ]
    [ -z "$(ls -A "$TMPDIR")" ]
}

@test "a failure mid-apply restores the prior nginx tree byte-for-byte and never reloads" {
    portal apply
    before=$(snap "$PORTAL_NGINX_DIR")
    : > "$S/calls"
    # two pending changes: the vhost installs, then the htpasswd install fails
    echo 'server { portal v2 }' > "$PORTAL_SITE/config/nginx/portal.lab.conf"
    echo 'analyst:$apr1$newhash' > "$PORTAL_MALCOLM_HTPASSWD"
    echo 1 > "$S/install_rc"
    run portal apply
    echo "$output"; cat "$S/calls"
    [ "$status" -ne 0 ]
    [[ "$output" == *"INSTALL             $PORTAL_NGINX_DIR/sites-available/portal.lab.conf"* ]]
    [[ "$output" == *"FAIL    install -m0640"* ]]
    b=$(find "$PORTAL_BACKUP_DIR" -type f -newer "$S/install_rc")
    [ -n "$b" ]
    [[ "$output" == *"RESTORE $PORTAL_NGINX_DIR restored from $b"* ]]
    [[ "$output" == *"nginx was NOT reloaded"* ]]
    [[ "$output" != *"REFUSE"* ]]
    [ "$(snap "$PORTAL_NGINX_DIR")" = "$before" ]
    ! grep -q 'systemctl reload' "$S/calls" || false
    ! grep -q '^nginx -t' "$S/calls" || false
}

@test "an nginx -t failure restores the backup and never reloads" {
    before=$(snap "$PORTAL_NGINX_DIR")
    echo 1 > "$S/nginx_t_rc"
    run portal apply
    echo "$output"; cat "$S/calls" 2>/dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL    nginx -t failed"* ]]
    [[ "$output" == *"fake config error"* ]]
    [[ "$output" == *"restored from $PORTAL_BACKUP_DIR/"* ]]
    ! grep -q 'systemctl reload' "$S/calls" || false
    # the round trip genuinely reverted the tree, pre-existing ssl/ included
    [ "$(snap "$PORTAL_NGINX_DIR")" = "$before" ]
    [ ! -e "$PORTAL_NGINX_DIR/snippets/lab-auth.conf" ]
}

@test "an nginx -t failure with nothing to change takes no backup and says so" {
    portal apply
    : > "$S/calls"
    echo 1 > "$S/nginx_t_rc"
    run portal apply
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"apply changed nothing under $PORTAL_NGINX_DIR"* ]]
    ! grep -q '^tar ' "$S/calls" || false
    [ "$(backup_count)" -eq 1 ]
}

@test "a failed reload FAILs with a start hint, and a rerun still refuses to report success while nginx is down" {
    echo 1 > "$S/reload_rc"
    echo 3 > "$S/active_rc"
    run portal apply
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL    systemctl reload nginx failed"* ]]
    [[ "$output" == *"systemctl start nginx"* ]]
    # the config passed nginx -t, so it stays installed
    [ -f "$PORTAL_NGINX_DIR/sites-available/portal.lab.conf" ]
    [[ "$output" != *"RESTORE"* ]]

    # rerun: nothing to change, but nginx is still not active
    run portal apply
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL    no nginx config changes, but nginx is not active"* ]]

    # once nginx is running, the same rerun succeeds
    rm "$S/active_rc"
    run portal apply
    [ "$status" -eq 0 ]
    [[ "$output" == *"DONE    no nginx config changes"* ]]
}

# ── nginx config in the repo ─────────────────────────────────────────────────

@test "config: the catch-all rejects unknown names on :443 (v4 and v6) and nothing claims :80 default_server" {
    f="$REPO/config/nginx/00-default-reject.conf"
    grep -qE '^\s*listen 443 ssl( http2)? default_server;' "$f"
    grep -qE '^\s*listen \[::\]:443 ssl( http2)? default_server;' "$f"
    grep -qE '^\s*ssl_reject_handshake on;' "$f"
    ! grep -rnE 'listen[^;]*\b80\b[^;]*default_server' "$REPO/config/nginx" || false
}

@test "config: no .lab vhost listens on :80 (the firewall admits 22 and 443 only)" {
    for f in "$REPO"/config/nginx/*.lab.conf; do
        ! grep -nE '^\s*listen\s+(\S*:)?80\b' "$f" || false
        ! grep -nF 'return 301 https://' "$f" || false
    done
}

@test "config: security headers come from one server-level snippet, with no add_header in the vhosts" {
    h="$REPO/config/nginx/snippets/lab-headers.conf"
    grep -qE '^add_header Strict-Transport-Security +"max-age=86400" always;' "$h"
    ! grep -qE '^add_header.*(preload|includeSubDomains)' "$h" || false
    grep -qE '^add_header X-Content-Type-Options +"nosniff" always;' "$h"
    grep -qE '^add_header X-Frame-Options +"SAMEORIGIN" always;' "$h"
    grep -qE '^add_header Referrer-Policy ' "$h"
    for s in portal malcolm docs; do
        f="$REPO/config/nginx/$s.lab.conf"
        grep -qE '^    include snippets/lab-headers.conf;' "$f"
        ! grep -qE '^\s*add_header' "$f" || false
    done
}

@test "config: \$connection_upgrade is mapped once, at http level, and malcolm.lab uses it" {
    [ "$(grep -rlE '^\s*map \$http_upgrade \$connection_upgrade' "$REPO/config/nginx" | wc -l)" -eq 1 ]
    grep -qE '^map \$http_upgrade \$connection_upgrade' "$REPO/config/nginx/conf.d/lab-connection-upgrade.conf"
    f="$REPO/config/nginx/malcolm.lab.conf"
    grep -qE '^\s*proxy_set_header Connection \$connection_upgrade;' "$f"
    ! grep -qF 'Connection "upgrade"' "$f" || false
}

# ── verify ───────────────────────────────────────────────────────────────────

@test "verify: 401 without credentials, then 200 with credentials, per site" {
    echo secret > "$BATS_TEST_TMPDIR/pw"
    run portal verify --host 192.0.2.9 --cacert "$PORTAL_NGINX_DIR/ssl/ca.crt" \
        --user analyst --password-file "$BATS_TEST_TMPDIR/pw"
    echo "$output"
    [ "$status" -eq 0 ]
    for s in portal malcolm docs; do
        [[ "$output" == *"PASS    $s.lab -> 401 without credentials"* ]]
        [[ "$output" == *"PASS    $s.lab -> 200 with credentials"* ]]
    done
    # --host given: this is an off-box run, so the listener check is skipped
    ! grep -q '^ss ' "$S/calls" 2>/dev/null || false
}

@test "verify: every curl pins the CA and the address, has timeouts, and never disables TLS checks" {
    echo secret > "$BATS_TEST_TMPDIR/pw"
    run portal verify --host 192.0.2.9 --cacert "$PORTAL_NGINX_DIR/ssl/ca.crt" \
        --user analyst --password-file "$BATS_TEST_TMPDIR/pw"
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$S/argv")" -eq 6 ]
    while IFS= read -r line; do
        [[ "$line" == *"--cacert $PORTAL_NGINX_DIR/ssl/ca.crt"* ]]
        [[ "$line" == *"--resolve "*".lab:443:192.0.2.9"* ]]
        [[ "$line" == *"--connect-timeout 5"* ]]
        [[ "$line" == *"--max-time 30"* ]]
        [[ " $line " != *" -k "* ]]
        [[ "$line" != *"--insecure"* ]]
    done < "$S/argv"
}

@test "verify escapes \\ and \" in the password for curl's config" {
    printf '%s\n' 'pa"ss\word' > "$BATS_TEST_TMPDIR/pw"
    run portal verify --host 192.0.2.9 --cacert "$PORTAL_NGINX_DIR/ssl/ca.crt" \
        --user analyst --password-file "$BATS_TEST_TMPDIR/pw"
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(cat "$S/last_stdin_portal.lab")" = 'user = "analyst:pa\"ss\\word"' ]
}

@test "verify refuses an empty password file" {
    : > "$BATS_TEST_TMPDIR/pw"
    run portal verify --host 192.0.2.9 --cacert "$PORTAL_NGINX_DIR/ssl/ca.crt" \
        --user analyst --password-file "$BATS_TEST_TMPDIR/pw"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is empty"* ]]
    [ ! -e "$S/argv" ]
}

@test "verify refuses when the password file cannot be read" {
    echo secret > "$BATS_TEST_TMPDIR/unreadable-pw"
    stub cat 'case "$*" in *unreadable-pw*) exit 1 ;; esac; exec "'"$(command -v cat)"'" "$@"'
    run portal verify --host 192.0.2.9 --cacert "$PORTAL_NGINX_DIR/ssl/ca.crt" \
        --user analyst --password-file "$BATS_TEST_TMPDIR/unreadable-pw"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"could not read the password file"* ]]
    [ ! -e "$S/argv" ]
}

@test "verify without credentials only runs the 401 checks, with a WARN" {
    run portal verify --host 192.0.2.9 --cacert "$PORTAL_NGINX_DIR/ssl/ca.crt"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS    portal.lab -> 401 without credentials"* ]]
    [[ "$output" == *"WARN    portal.lab -> no credentials given, skipping the 200 check"* ]]
    [[ "$output" != *"200 with credentials"* ]]
}

@test "verify FAILs when a site returns 200 without credentials" {
    echo secret > "$BATS_TEST_TMPDIR/pw"
    echo 200 > "$S/code_malcolm_noauth"
    run portal verify --host 192.0.2.9 --cacert "$PORTAL_NGINX_DIR/ssl/ca.crt" \
        --user analyst --password-file "$BATS_TEST_TMPDIR/pw"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL    malcolm.lab -> 200 without credentials (want 401)"* ]]
}

@test "verify FAILs when a site does not return 200 with credentials" {
    echo secret > "$BATS_TEST_TMPDIR/pw"
    echo 401 > "$S/code_docs_creds"
    run portal verify --host 192.0.2.9 --cacert "$PORTAL_NGINX_DIR/ssl/ca.crt" \
        --user analyst --password-file "$BATS_TEST_TMPDIR/pw"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL    docs.lab -> 401 with credentials (want 200)"* ]]
}

@test "verify never puts the password in curl's argv" {
    echo 'sup3r-secret' > "$BATS_TEST_TMPDIR/pw"
    run portal verify --host 192.0.2.9 --cacert "$PORTAL_NGINX_DIR/ssl/ca.crt" \
        --user analyst --password-file "$BATS_TEST_TMPDIR/pw"
    [ "$status" -eq 0 ]
    run grep -F 'sup3r-secret' "$S/argv"
    [ "$status" -ne 0 ]
    # it did travel to curl -- just via stdin, never argv
    grep -qF 'sup3r-secret' "$S/last_stdin_portal.lab"
}

@test "verify on the box (no --host) also checks that only nginx listens on :443" {
    run portal verify --cacert "$PORTAL_NGINX_DIR/ssl/ca.crt"
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q '^ss -H -ltnp$' "$S/calls"
    [[ "$output" == *"PASS    only nginx listens on :443"* ]]
}

@test "verify FAILs when something other than nginx listens on :443" {
    printf '%s\n' 'LISTEN 0 5 0.0.0.0:443 0.0.0.0:* users:(("evil",pid=9,fd=3))' > "$S/ss_output"
    run portal verify --cacert "$PORTAL_NGINX_DIR/ssl/ca.crt"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL    0.0.0.0:443 is listening but not owned by nginx"* ]]
}

@test "verify treats *:443 as a wildcard listener too" {
    printf '%s\n' 'LISTEN 0 5 *:443 *:* users:(("evil",pid=9,fd=3))' > "$S/ss_output"
    run portal verify --cacert "$PORTAL_NGINX_DIR/ssl/ca.crt"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL    *:443 is listening but not owned by nginx"* ]]
}

@test "verify refuses a lone --user without --password-file" {
    run portal verify --host 192.0.2.9 --cacert "$PORTAL_NGINX_DIR/ssl/ca.crt" --user analyst
    [ "$status" -eq 1 ]
    [[ "$output" == *"must be given together"* ]]
}

@test "verify: an option with no value fails with usage instead of looping" {
    for opt in --host --cacert --user --password-file; do
        run timeout 10 env PATH="$TEST_PATH" "$SCRIPT" verify "$opt"
        echo "$opt: $status $output"
        [ "$status" -eq 1 ]
        [[ "$output" == *"$opt needs a value"* ]]
        [[ "$output" == *"usage: r770-portal.sh verify"* ]]
    done
}

@test "verify refuses an unknown flag" {
    run portal verify --bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown argument"* ]]
}

# ── unknown verb ─────────────────────────────────────────────────────────────

@test "refuses an unknown verb" {
    run portal frobnicate
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown verb: frobnicate"* ]]
    no_mutations
}
