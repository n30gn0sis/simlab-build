#!/usr/bin/env bats
#
# r770-gns3-deploy.sh installs gns3-server from the bundle's wheelhouse into a
# venv, writes gns3_server.conf with a password/JWT generated on the box, and
# publishes it through the already-existing gns3.lab nginx vhost. id, systemctl,
# useradd/usermod and openssl are stubs backed by a state dir ($S); real
# read-only-ish tools (python3, sed, install, mkdir, etc.) are the only other
# things on PATH, so a real systemd/openssl on the test host can never answer
# for it.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-gns3-deploy.sh"
    BIN="$BATS_TEST_TMPDIR/bin"; REAL="$BATS_TEST_TMPDIR/real"
    export S="$BATS_TEST_TMPDIR/state"
    export GNS3_SITE="$BATS_TEST_TMPDIR/site"
    export GNS3_VENV="$BATS_TEST_TMPDIR/venv"
    export GNS3_WHEELHOUSE="$BATS_TEST_TMPDIR/wheelhouse"
    export GNS3_CONF_DIR="$BATS_TEST_TMPDIR/gns3conf"
    export GNS3_CONF_TEMPLATE="$GNS3_SITE/config/gns3/gns3_server.conf.template"
    export GNS3_SERVICE_TEMPLATE="$GNS3_SITE/config/gns3/gns3.service.template"
    export GNS3_NGINX_DIR="$BATS_TEST_TMPDIR/nginx"
    export GNS3_NGINX_VHOST="$GNS3_SITE/config/nginx/gns3.lab.conf"
    export GNS3_USER="gns3"
    export GNS3_PROJECTS_DIR="$BATS_TEST_TMPDIR/projects"
    export GNS3_IMAGES_DIR="$BATS_TEST_TMPDIR/images"
    export GNS3_APPLIANCES_DIR="$BATS_TEST_TMPDIR/appliances"
    export GNS3_MALCOLM_CONFIG="$GNS3_SITE/config/malcolm/malcolm-config.json"
    export FAKE_UID=0
    mkdir -p "$BIN" "$REAL" "$S" "$GNS3_WHEELHOUSE" "$GNS3_SITE/config/gns3" "$GNS3_SITE/config/nginx"

    for t in bash env cat sed awk grep tr cp mv mkdir chmod rm date stat cmp install find dirname basename python3 ls chown; do
        p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$REAL/$t"
    done
    TEST_PATH="$BIN:$REAL"
    export REAL

    stub id 'echo "$FAKE_UID"'
    stub openssl 'case "$1" in rand) echo "FAKE-$2-$RANDOM" ;; *) exit 1 ;; esac'
    stub systemctl '
        printf "%s\n" "$*" >> "'"$S"'/systemctl_calls"
        case "$1" in
            is-active) exit "$(cat "'"$S"'/systemctl_active_rc" 2>/dev/null || echo 1)" ;;
            *) exit 0 ;;
        esac'
    stub useradd 'printf "%s\n" "$*" >> "'"$S"'/useradd_calls"; echo "$5" >> "'"$S"'/existing_users"; exit 0'
    stub usermod 'printf "%s\n" "$*" >> "'"$S"'/usermod_calls"; exit 0'
    stub getent 'grep -qx "$2" "'"$S"'/existing_users" 2>/dev/null && exit 0 || exit 2'
    stub chown 'printf "%s\n" "$*" >> "'"$S"'/chown_calls"; exit 0'
    stub install '
        # Track install calls; extract target file from args (usually last arg)
        printf "%s\n" "$*" >> "'"$S"'/install_calls"
        # Copy the source file to the target (handle -o and -g flags)
        local src target
        while [ $# -gt 0 ]; do
            case "$1" in
                -m|-o|-g) shift; shift ;; # Skip flag and its argument
                -*) shift ;; # Skip other flags
                *)
                    if [ -z "$src" ]; then src="$1"; else target="$1"; fi
                    shift
                    ;;
            esac
        done
        [ -n "$src" ] && [ -n "$target" ] && cp "$src" "$target"
        exit 0
    '
    stub python3 '
        if [ "$1" = "-m" ] && [ "$2" = "venv" ]; then
            mkdir -p "$3/bin"
            cat > "$3/bin/pip" << PIPSCRIPT
#!/usr/bin/env bash
exit 0
PIPSCRIPT
            chmod +x "$3/bin/pip"
            : > "$3/bin/gns3server"
            chmod +x "$3/bin/gns3server"
            exit 0
        elif [ "$1" = "-c" ]; then
            # For -c, delegate to real python3 to execute the code
            shift
            exec "$REAL/python3" -c "$@"
        else
            exit 1
        fi
    '

    echo "[Server]
host = 127.0.0.1
port = 3080
projects_path = /srv/gns3/projects
images_path = /srv/gns3/images
appliances_path = /srv/gns3/appliances
report_errors = false

[Controller]
default_admin_username = admin
default_admin_password = __PASSWORD__
jwt_secret_key = __JWT__" > "$GNS3_CONF_TEMPLATE"

    echo "[Unit]
Description=GNS3 server
[Service]
User=__GNS3_USER__
ExecStart=__GNS3_VENV__/bin/gns3server --config __GNS3_CONF_DIR__/gns3_server.conf
[Install]
WantedBy=multi-user.target" > "$GNS3_SERVICE_TEMPLATE"

    echo "server { listen 443 ssl; server_name gns3.lab; }" > "$GNS3_NGINX_VHOST"
}

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$BIN/$1"; chmod +x "$BIN/$1"; }
run_gns3() { PATH="$TEST_PATH" "$SCRIPT" "$@"; }
touch_wheel() { : > "$GNS3_WHEELHOUSE/gns3_server-3.0.6-py3-none-any.whl"; }

@test "refuses to run as a non-root user" {
    FAKE_UID=1000 run run_gns3 plan
    [ "$status" -eq 1 ]
    [[ "$output" == *"must run as root"* ]]
}

@test "plan on an empty state proposes venv install, conf write, service install, and refuses to change anything" {
    touch_wheel
    run run_gns3 plan
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CREATE  venv at $GNS3_VENV"* ]]
    [[ "$output" == *"INSTALL $GNS3_CONF_DIR/gns3_server.conf"* ]]
    [ ! -e "$GNS3_VENV" ]
    [ ! -e "$GNS3_CONF_DIR" ]
}

@test "plan refuses when the wheelhouse has no gns3-server wheel" {
    run run_gns3 plan
    [ "$status" -eq 1 ]
    [[ "$output" == *"no gns3-server wheel in $GNS3_WHEELHOUSE"* ]]
}

@test "apply creates the venv, installs gns3-server, writes conf with generated secrets, creates the user, installs the unit and vhost" {
    touch_wheel
    run run_gns3 apply
    echo "$output"
    [ "$status" -eq 0 ]
    [ -d "$GNS3_VENV" ]
    grep -q "default_admin_password = FAKE-" "$GNS3_CONF_DIR/gns3_server.conf"
    grep -q "jwt_secret_key = FAKE-" "$GNS3_CONF_DIR/gns3_server.conf"
    ! grep -q "__PASSWORD__\|__JWT__" "$GNS3_CONF_DIR/gns3_server.conf"
    grep -q -- "--system --create-home --shell /usr/sbin/nologin $GNS3_USER" "$S/useradd_calls"
    grep -q -- "-aG kvm,docker $GNS3_USER" "$S/usermod_calls"
    grep -q "enable --now gns3" "$S/systemctl_calls"
    grep -q "$GNS3_USER:$GNS3_USER $GNS3_CONF_DIR" "$S/chown_calls"
    [ -f "$GNS3_NGINX_DIR/conf.d/gns3.lab.conf" ]
}

@test "a second apply is a no-op: the password/JWT are never regenerated" {
    touch_wheel
    run_gns3 apply
    first_pass=$(grep default_admin_password "$GNS3_CONF_DIR/gns3_server.conf")
    : > "$S/useradd_calls"
    run run_gns3 apply
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already installed"* ]]
    [ "$(grep default_admin_password "$GNS3_CONF_DIR/gns3_server.conf")" = "$first_pass" ]
    [ ! -s "$S/useradd_calls" ]
}

@test "apply refuses when the venv exists but has no gns3server binary" {
    mkdir -p "$GNS3_VENV/bin"
    run run_gns3 apply
    [ "$status" -eq 1 ]
    [[ "$output" == *"looks broken, not a usable venv"* ]]
    [ ! -f "$GNS3_CONF_DIR/gns3_server.conf" ]
}

@test "verify passes when the service is active and the vhost is installed" {
    touch_wheel
    run_gns3 apply
    echo 0 > "$S/systemctl_active_rc"
    run run_gns3 verify
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS"* ]]
}

@test "verify fails when the service is not active" {
    touch_wheel
    run_gns3 apply
    echo 3 > "$S/systemctl_active_rc"
    run run_gns3 verify
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL"*"not active"* ]]
}

# ── labnet ───────────────────────────────────────────────────────────────────
#
# ip is a stub logging every invocation to $S/ip_calls and modeling bridge/
# link state in $S/links (one name per line, "up" or "down" suffix), so
# "does br-lab exist" and "is lab-mirror0 up" are real state, not guesses.

setup_labnet_ip_stub() {
    : > "$S/links"
    export S="$S"
    stub ip '
        printf "%s\n" "$*" >> "$S/ip_calls"
        case "$*" in
            *link\ show*)
                name=$(echo "$*" | awk "{for(i=1;i<=NF;i++) if(\$i==\"show\") print \$(i+1)}")
                if grep -q "^${name} up$" "$S/links" 2>/dev/null; then
                    echo "1: ${name}: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500"
                else
                    echo "1: ${name}: <BROADCAST,MULTICAST> mtu 1500"
                fi
                grep -q "^${name} " "$S/links" 2>/dev/null || exit 1
                exit 0 ;;
            *link\ add\ name\ br-lab\ type\ bridge*)
                echo "br-lab down" >> "$S/links"
                exit 0 ;;
            *link\ add*veth*peer\ name*)
                a=$(echo "$*" | sed -n "s/.*add name \([^ ]*\).*/\1/p")
                b=$(echo "$*" | sed -n "s/.*peer name \([^ ]*\).*/\1/p")
                [ -n "$a" ] && echo "$a down" >> "$S/links"
                [ -n "$b" ] && echo "$b down" >> "$S/links"
                exit 0 ;;
            *link\ set*up*)
                name=$(echo "$*" | awk "{for(i=1;i<=NF;i++) if(\$i==\"set\") print \$(i+1)}")
                [ -n "$name" ] && echo "${name} up" >> "$S/links"
                exit 0 ;;
            *link\ set*master\ br-lab*)
                exit 0 ;;
            *link\ set*type\ bridge*)
                exit 0 ;;
            *link\ set*promisc\ on*)
                exit 0 ;;
            *)
                exit 0 ;;
        esac
    '
}

@test "labnet plan on empty state proposes creating br-lab and the veth pair" {
    setup_labnet_ip_stub
    run run_gns3 labnet plan
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CREATE  bridge br-lab"* ]]
    [[ "$output" == *"CREATE  veth lab-mon0 / lab-mirror0"* ]]
}

@test "labnet apply creates the bridge in hub mode and brings both veth ends up" {
    setup_labnet_ip_stub
    run run_gns3 labnet apply
    echo "$output"; cat "$S/ip_calls"
    [ "$status" -eq 0 ]
    grep -q "link add name br-lab type bridge" "$S/ip_calls"
    grep -q "br-lab type bridge ageing_time 0" "$S/ip_calls"
    grep -q "br-lab type bridge mcast_snooping 0" "$S/ip_calls"
    grep -q "link add name lab-mon0 type veth peer name lab-mirror0" "$S/ip_calls"
    grep -q "lab-mon0.*master br-lab" "$S/ip_calls"
    grep -q "lab-mirror0.*promisc on" "$S/ip_calls"
    [[ "$output" == *"PASS"* ]]
}

@test "a second labnet apply is a no-op" {
    setup_labnet_ip_stub
    run_gns3 labnet apply
    : > "$S/ip_calls"
    run run_gns3 labnet apply
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"KEEP    bridge br-lab already exists"* ]]
    [[ "$output" == *"KEEP    veth lab-mon0/lab-mirror0 already exist"* ]]
    ! grep -q "link add" "$S/ip_calls"
}

@test "labnet verify fails when lab-mirror0 does not exist" {
    setup_labnet_ip_stub
    run run_gns3 labnet verify
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL"*"lab-mirror0"* ]]
}

@test "labnet verify passes once applied" {
    setup_labnet_ip_stub
    run_gns3 labnet apply
    run run_gns3 labnet verify
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^PASS' <<< "$output")" -ge 3 ]
}

# ── labnet malcolm-config ────────────────────────────────────────────────────

@test "malcolm-config patches captureLiveNetworkTraffic and pcapIface, nothing else" {
    mkdir -p "$GNS3_SITE/config/malcolm"
    cat > "$GNS3_SITE/config/malcolm/malcolm-config.json" <<'JSON'
{"configuration": {"captureLiveNetworkTraffic": false, "pcapIface": [], "autoZeek": true}}
JSON
    out="$BATS_TEST_TMPDIR/patched.json"
    run run_gns3 labnet malcolm-config "$out"
    echo "$output"
    [ "$status" -eq 0 ]
    run python3 -c "import json; d=json.load(open('$out'))['configuration']; print(d['captureLiveNetworkTraffic'], d['pcapIface'], d['autoZeek'])"
    [ "$output" = "True ['lab-mirror0'] True" ]
}

@test "malcolm-config refuses on a source file that isn't valid JSON" {
    mkdir -p "$GNS3_SITE/config/malcolm"
    echo "not json" > "$GNS3_SITE/config/malcolm/malcolm-config.json"
    run run_gns3 labnet malcolm-config "$BATS_TEST_TMPDIR/patched.json"
    [ "$status" -eq 1 ]
    [[ "$output" == *"could not parse"* ]]
    [ ! -e "$BATS_TEST_TMPDIR/patched.json" ]
}

@test "malcolm-config refuses when the source file is missing" {
    run run_gns3 labnet malcolm-config "$BATS_TEST_TMPDIR/patched.json"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not found"* ]]
}

@test "malcolm-config requires the output path argument" {
    mkdir -p "$GNS3_SITE/config/malcolm"
    echo '{"configuration": {}}' > "$GNS3_SITE/config/malcolm/malcolm-config.json"
    run run_gns3 labnet malcolm-config
    [ "$status" -eq 1 ]
    [[ "$output" == *"usage"* ]]
}
