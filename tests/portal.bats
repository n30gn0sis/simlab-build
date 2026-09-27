#!/usr/bin/env bats
#
# r770-portal.sh installs the analyst portal's nginx config, htpasswd and the
# offline MkDocs build, so what matters most is: apply never reloads onto a
# broken config, a second apply changes nothing, and verify never puts the
# analyst password on curl's command line.
#
# docker, nginx, systemctl, curl, ss, tar, chgrp and id are all stubs backed
# by a state directory ($S). cp/mkdir/ln/rm/chmod/cmp/diff/date/readlink are
# the real tools (they only ever touch paths under $BATS_TEST_TMPDIR).
#
#   $S/calls           every mutating call (docker/nginx/systemctl/tar/chgrp), one per line
#   $S/argv            every curl invocation's argv, one per line (password-argv guard)
#   $S/nginx_t_rc      exit code for `nginx -t` (default 0)
#   $S/ss_output       canned `ss -H -ltnp` output (default: only nginx on :443)
#   $S/code_<site>_noauth   HTTP code curl returns for <site> with no -K (default 401)
#   $S/code_<site>_creds    HTTP code curl returns for <site> with -K -   (default 200)

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-portal.sh"
    BIN="$BATS_TEST_TMPDIR/bin"; REAL="$BATS_TEST_TMPDIR/real"
    export S="$BATS_TEST_TMPDIR/state"
    mkdir -p "$BIN" "$REAL" "$S"
    for t in bash env cat sed awk grep tr cp mv mkdir ls date head tail rm cmp diff \
             chmod ln readlink mktemp dirname basename stat; do
        p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$REAL/$t"
    done
    TEST_PATH="$BIN:$REAL"

    export PORTAL_SITE="$BATS_TEST_TMPDIR/site"
    export PORTAL_NGINX_DIR="$BATS_TEST_TMPDIR/nginx"
    export PORTAL_WWW="$BATS_TEST_TMPDIR/www"
    export PORTAL_MALCOLM_HTPASSWD="$BATS_TEST_TMPDIR/malcolm-htpasswd"
    export PORTAL_MKDOCS_IMAGE="fake-mkdocs:latest"
    export FAKE_UID=0
    unset PORTAL_SITES

    # -- source tree, shaped like config/ + docs/analyst-wiki/ --
    mkdir -p "$PORTAL_SITE/config/nginx/snippets" "$PORTAL_SITE/config/portal" \
             "$PORTAL_SITE/config/docs" "$PORTAL_SITE/docs/analyst-wiki"
    echo 'auth_basic snippet' > "$PORTAL_SITE/config/nginx/snippets/lab-auth.conf"
    echo 'tls snippet'        > "$PORTAL_SITE/config/nginx/snippets/lab-tls.conf"
    echo 'server { portal }'  > "$PORTAL_SITE/config/nginx/portal.lab.conf"
    echo 'server { malcolm }' > "$PORTAL_SITE/config/nginx/malcolm.lab.conf"
    echo 'server { docs }'    > "$PORTAL_SITE/config/nginx/docs.lab.conf"
    echo '<html>portal</html>' > "$PORTAL_SITE/config/portal/index.html"
    echo 'site_name: test'    > "$PORTAL_SITE/config/docs/mkdocs.yml"
    echo '# index'            > "$PORTAL_SITE/docs/analyst-wiki/index.md"
    echo '# access'           > "$PORTAL_SITE/docs/analyst-wiki/access.md"

    # -- preconditions apply checks for --
    mkdir -p "$PORTAL_NGINX_DIR/ssl"
    echo cert > "$PORTAL_NGINX_DIR/ssl/lab.crt"
    echo key  > "$PORTAL_NGINX_DIR/ssl/lab.key"
    echo ca   > "$PORTAL_NGINX_DIR/ssl/ca.crt"
    echo 'analyst:$apr1$hash' > "$PORTAL_MALCOLM_HTPASSWD"

    stub id        'echo "$FAKE_UID"'
    stub chgrp     'echo "chgrp $*" >> "$S/calls"'
    stub systemctl 'echo "systemctl $*" >> "$S/calls"'

    # tar: fakes a real archive by copying the directory tree into a
    # "<archive>.contents/" shadow dir on -czf, and copying it back on -xzf.
    # Good enough to prove a genuine backup/restore round trip in tests.
    stub tar '
echo "tar $*" >> "$S/calls"
mode=""; dir=""; file=""; name=""
i=0; args=("$@")
while [ "$i" -lt "${#args[@]}" ]; do
    a="${args[$i]}"
    case "$a" in
        -C)   i=$((i + 1)); dir="${args[$i]}" ;;
        -czf) mode=c; i=$((i + 1)); file="${args[$i]}" ;;
        -xzf) mode=x; i=$((i + 1)); file="${args[$i]}" ;;
        *)    name="$a" ;;
    esac
    i=$((i + 1))
done
case "$mode" in
    c) mkdir -p "$file.contents"; cp -a "$dir/$name" "$file.contents/" ;;
    x) [ -d "$file.contents" ] || exit 1
       mkdir -p "$dir"
       cp -a "$file.contents/." "$dir/" ;;
    *) exit 1 ;;
esac'

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

    stub docker '
echo "docker $*" >> "$S/calls"
hostdir=""; prev=""
for a; do
    [ "$prev" = "-v" ] && hostdir="${a%%:*}"
    prev="$a"
done
[ -n "$hostdir" ] || { echo "docker stub: no -v arg" >&2; exit 1; }
[ -f "$S/docker_rc" ] && exit "$(cat "$S/docker_rc")"
mkdir -p "$hostdir/site"
echo "<html>built docs</html>" > "$hostdir/site/index.html"'

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
    # (default 401 / 200). -K - reads the netrc-style config from stdin; the
    # password lands there, not in argv, and we capture that stdin for the
    # never-in-argv test.
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

# ── plan ─────────────────────────────────────────────────────────────────────

@test "plan is read-only and reports what apply would do" {
    run portal plan
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS    running as root"* ]]
    [[ "$output" == *"INSTALL             $PORTAL_NGINX_DIR/snippets/lab-auth.conf"* ]]
    [[ "$output" == *"INSTALL             $PORTAL_NGINX_DIR/sites-available/portal.lab.conf"* ]]
    [[ "$output" == *"BUILD               $PORTAL_WWW/docs"* ]]
    no_mutations
    [ ! -e "$PORTAL_NGINX_DIR/snippets" ]
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

# ── apply: refusals ─────────────────────────────────────────────────────────

@test "apply refuses a non-root user" {
    FAKE_UID=1000 run portal apply
    [ "$status" -eq 1 ]
    [[ "$output" == *"REFUSE  must run as root"* ]]
    no_mutations
}

@test "apply refuses when the CA certs are missing" {
    rm "$PORTAL_NGINX_DIR/ssl/lab.crt" "$PORTAL_NGINX_DIR/ssl/lab.key"
    run portal apply
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"REFUSE  missing CA-issued file(s):"* ]]
    [[ "$output" == *"lab.crt"* ]]
    [[ "$output" == *"lab.key"* ]]
    no_mutations
}

@test "apply refuses when the Malcolm htpasswd is missing" {
    rm "$PORTAL_MALCOLM_HTPASSWD"
    run portal apply
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"REFUSE  missing $PORTAL_MALCOLM_HTPASSWD"* ]]
    no_mutations
}

@test "apply takes no arguments" {
    run portal apply --bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"apply takes no arguments"* ]]
    no_mutations
}

# ── apply: happy path ────────────────────────────────────────────────────────

@test "apply installs exactly the three vhosts and their symlinks" {
    run portal apply
    echo "$output"; cat "$S/calls"
    [ "$status" -eq 0 ]

    [ "$(find "$PORTAL_NGINX_DIR/sites-available" -type f | wc -l)" -eq 3 ]
    for s in portal malcolm docs; do
        [ -f "$PORTAL_NGINX_DIR/sites-available/$s.lab.conf" ]
        [ -L "$PORTAL_NGINX_DIR/sites-enabled/$s.lab.conf" ]
        [ "$(readlink "$PORTAL_NGINX_DIR/sites-enabled/$s.lab.conf")" = "../sites-available/$s.lab.conf" ]
    done
    [ "$(find "$PORTAL_NGINX_DIR/sites-enabled" -type l | wc -l)" -eq 3 ]

    [ -f "$PORTAL_NGINX_DIR/snippets/lab-auth.conf" ]
    [ -f "$PORTAL_NGINX_DIR/snippets/lab-tls.conf" ]
    cmp -s "$PORTAL_SITE/config/portal/index.html" "$PORTAL_WWW/portal/index.html"

    grep -q '^nginx -t$' "$S/calls"
    grep -q '^systemctl reload nginx$' "$S/calls"
    [[ "$output" == *"DONE    nginx reloaded"* ]]
}

@test "the installed htpasswd is mode 0640 and chgrp'd to www-data" {
    run portal apply
    [ "$status" -eq 0 ]
    cmp -s "$PORTAL_MALCOLM_HTPASSWD" "$PORTAL_NGINX_DIR/lab.htpasswd"
    [ "$(stat -c %a "$PORTAL_NGINX_DIR/lab.htpasswd")" = "640" ]
    grep -qF "chgrp www-data $PORTAL_NGINX_DIR/lab.htpasswd" "$S/calls"
}

@test "docs are built offline with --network none, and installed under www" {
    run portal apply
    echo "$output"; cat "$S/calls"
    [ "$status" -eq 0 ]
    grep -q '^docker run --rm --network none -v ' "$S/calls"
    grep -q -- '--network none' "$S/calls"
    grep -qF "fake-mkdocs:latest build" "$S/calls"
    [ -f "$PORTAL_WWW/docs/index.html" ]
    grep -qF 'built docs' "$PORTAL_WWW/docs/index.html"
}

@test "a second apply is a no-op with no reload" {
    run portal apply
    [ "$status" -eq 0 ]
    : > "$S/calls"
    run portal apply
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already installed  $PORTAL_NGINX_DIR/snippets/lab-auth.conf"* ]]
    [[ "$output" == *"already installed  $PORTAL_NGINX_DIR/sites-available/portal.lab.conf"* ]]
    [[ "$output" == *"already installed  $PORTAL_NGINX_DIR/sites-enabled/portal.lab.conf"* ]]
    [[ "$output" == *"already installed  $PORTAL_WWW/docs"* ]]
    [[ "$output" == *"DONE    no changes — nginx not reloaded"* ]]
    ! grep -q 'systemctl reload' "$S/calls"
    grep -q '^nginx -t$' "$S/calls"
}

@test "changing one vhost source triggers exactly one INSTALL and a reload" {
    portal apply
    : > "$S/calls"
    echo 'server { portal v2 }' > "$PORTAL_SITE/config/nginx/portal.lab.conf"
    run portal apply
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"INSTALL             $PORTAL_NGINX_DIR/sites-available/portal.lab.conf"* ]]
    [[ "$output" == *"already installed  $PORTAL_NGINX_DIR/sites-available/malcolm.lab.conf"* ]]
    grep -q 'systemctl reload nginx' "$S/calls"
}

# ── apply: nginx -t failure ─────────────────────────────────────────────────

@test "an nginx -t failure restores the backup and never reloads" {
    echo 1 > "$S/nginx_t_rc"
    run portal apply
    echo "$output"; cat "$S/calls" 2>/dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL    nginx -t failed"* ]]
    [[ "$output" == *"fake config error"* ]]
    [[ "$output" == *"restored from"* ]]
    ! grep -q 'systemctl reload' "$S/calls"

    # the backup/restore round trip actually reverted the tree: none of this
    # apply's new files survive.
    [ ! -e "$PORTAL_NGINX_DIR/snippets/lab-auth.conf" ]
    [ ! -e "$PORTAL_NGINX_DIR/sites-enabled/portal.lab.conf" ]
    [ ! -e "$PORTAL_NGINX_DIR/lab.htpasswd" ]

    # the pre-existing ssl/ directory (present before apply ran) is back too.
    [ -f "$PORTAL_NGINX_DIR/ssl/lab.crt" ]
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
    ! grep -q '^ss ' "$S/calls"
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
    [[ "$output" == *"FAIL"* ]]
    [[ "$output" == *"not owned by nginx"* ]]
}

@test "verify refuses a lone --user without --password-file" {
    run portal verify --host 192.0.2.9 --cacert "$PORTAL_NGINX_DIR/ssl/ca.crt" --user analyst
    [ "$status" -eq 1 ]
    [[ "$output" == *"must be given together"* ]]
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
