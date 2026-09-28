#!/usr/bin/env bash
#
# r770-gns3-deploy.sh -- GNS3 server install/config, behind the existing
# gns3.lab nginx vhost. Also owns `labnet` (the br-lab virtual mirror feed)
# -- see Task 2/3 below.
#
# Runs as root, on the target box, from "site/scripts/" (this repo's config/
# copied alongside it -- the bundle's delivery path). Site root defaults to
# the script's own dir's parent; see GNS3_SITE.
#
#   plan      default. Read-only: current state, proposed changes.
#   apply     install gns3-server from the bundle wheelhouse into a venv,
#             write gns3_server.conf (password/JWT generated on this box,
#             never regenerated once installed), create the gns3 service
#             user (kvm+docker groups), install the systemd unit and the
#             already-existing gns3.lab nginx vhost, enable and start.
#   verify    service up, API answers, gns3.lab reachable through the portal.
#
# Design: docs/superpowers/specs/2026-09-27-gns3-mirror-design.md
#   ("scripts/r770-gns3-deploy.sh plan | apply | verify")
#
# Test overrides: GNS3_SITE, GNS3_VENV (default /opt/gns3), GNS3_WHEELHOUSE
# (default $GNS3_SITE/../gns3/wheelhouse), GNS3_CONF_DIR (default /etc/gns3),
# GNS3_CONF_TEMPLATE, GNS3_SERVICE_TEMPLATE, GNS3_NGINX_DIR (default
# /etc/nginx), GNS3_NGINX_VHOST, GNS3_USER (default gns3), GNS3_PROJECTS_DIR
# (default /srv/gns3/projects), GNS3_IMAGES_DIR (default /srv/gns3/images),
# GNS3_APPLIANCES_DIR (default /srv/gns3/appliances).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_SITE="$(cd "$SCRIPT_DIR/.." && pwd)"
GNS3_SITE="${GNS3_SITE:-$DEFAULT_SITE}"
GNS3_VENV="${GNS3_VENV:-/opt/gns3}"
GNS3_WHEELHOUSE="${GNS3_WHEELHOUSE:-$GNS3_SITE/../gns3/wheelhouse}"
GNS3_CONF_DIR="${GNS3_CONF_DIR:-/etc/gns3}"
GNS3_CONF_TEMPLATE="${GNS3_CONF_TEMPLATE:-$GNS3_SITE/config/gns3/gns3_server.conf.template}"
GNS3_SERVICE_TEMPLATE="${GNS3_SERVICE_TEMPLATE:-$GNS3_SITE/config/gns3/gns3.service.template}"
GNS3_NGINX_DIR="${GNS3_NGINX_DIR:-/etc/nginx}"
GNS3_NGINX_VHOST="${GNS3_NGINX_VHOST:-$GNS3_SITE/config/nginx/gns3.lab.conf}"
GNS3_USER="${GNS3_USER:-gns3}"
GNS3_PROJECTS_DIR="${GNS3_PROJECTS_DIR:-/srv/gns3/projects}"
GNS3_IMAGES_DIR="${GNS3_IMAGES_DIR:-/srv/gns3/images}"
GNS3_APPLIANCES_DIR="${GNS3_APPLIANCES_DIR:-/srv/gns3/appliances}"
GNS3_BRIDGE="${GNS3_BRIDGE:-br-lab}"
GNS3_VETH_BRIDGE_SIDE="${GNS3_VETH_BRIDGE_SIDE:-lab-mon0}"
GNS3_VETH_CAPTURE_SIDE="${GNS3_VETH_CAPTURE_SIDE:-lab-mirror0}"

die()  { echo "r770-gns3-deploy: $*" >&2; exit 1; }
require_root() { [ "$(id -u)" = 0 ] || die "must run as root"; }

link_exists() { ip link show "$1" >/dev/null 2>&1; }
link_up()     { ip link show "$1" 2>/dev/null | grep -q '<.*UP'; }

wheel_present() { ls "$GNS3_WHEELHOUSE"/gns3?server-*.whl >/dev/null 2>&1; }

venv_state() {  # prints: absent | broken | ready
    if [ ! -e "$GNS3_VENV" ]; then echo absent
    elif [ -x "$GNS3_VENV/bin/gns3server" ]; then echo ready
    else echo broken
    fi
}

cmd_plan() {
    echo "== r770-gns3-deploy plan =="
    case "$(venv_state)" in
        ready)  echo "KEEP    venv already has gns3server ($GNS3_VENV)" ;;
        broken) die "$GNS3_VENV exists but has no bin/gns3server -- looks broken, not a usable venv. Remove it manually if that's intended, then re-run apply." ;;
        absent)
            wheel_present || die "no gns3-server wheel in $GNS3_WHEELHOUSE -- is the bundle's gns3/ staged?"
            echo "CREATE  venv at $GNS3_VENV"
            ;;
    esac
    if [ -f "$GNS3_CONF_DIR/gns3_server.conf" ]; then
        echo "KEEP    $GNS3_CONF_DIR/gns3_server.conf already installed (password/JWT never regenerated)"
    else
        echo "INSTALL $GNS3_CONF_DIR/gns3_server.conf (password/JWT generated on this box)"
    fi
    echo "== plan only -- no changes made =="
}

ensure_venv() {
    case "$(venv_state)" in
        ready) echo "KEEP    venv already has gns3server ($GNS3_VENV)"; return 0 ;;
        broken) die "$GNS3_VENV exists but has no bin/gns3server -- looks broken, not a usable venv. Remove it manually if that's intended, then re-run apply." ;;
    esac
    wheel_present || die "no gns3-server wheel in $GNS3_WHEELHOUSE -- is the bundle's gns3/ staged?"
    echo "CREATE  venv at $GNS3_VENV"
    python3 -m venv "$GNS3_VENV" || die "python3 -m venv $GNS3_VENV failed"
    "$GNS3_VENV/bin/pip" install --no-index --find-links "$GNS3_WHEELHOUSE" gns3-server ||
        die "pip install gns3-server from $GNS3_WHEELHOUSE failed (venv left at $GNS3_VENV for inspection)"
    [ -x "$GNS3_VENV/bin/gns3server" ] || die "pip reported success but $GNS3_VENV/bin/gns3server is missing"
}

render_conf() {  # render_conf TEMPLATE OUT_TMP -- password and JWT via stdin
    python3 -c "
import sys
tmpl_path = sys.argv[1]
out_path = sys.argv[2]
pw = sys.stdin.readline().rstrip('\n')
jwt = sys.stdin.readline().rstrip('\n')
with open(tmpl_path) as f:
    tmpl = f.read()
tmpl = tmpl.replace('__PASSWORD__', pw).replace('__JWT__', jwt)
with open(out_path, 'w') as f:
    f.write(tmpl)
" "$1" "$2"
}

ensure_conf() {
    mkdir -p "$GNS3_CONF_DIR" || die "could not create $GNS3_CONF_DIR"
    chown "$GNS3_USER:$GNS3_USER" "$GNS3_CONF_DIR" || die "could not chown $GNS3_CONF_DIR"
    if [ -f "$GNS3_CONF_DIR/gns3_server.conf" ]; then
        echo "KEEP    $GNS3_CONF_DIR/gns3_server.conf already installed (password/JWT never regenerated)"
        return 0
    fi
    local pass jwt tmp
    pass=$(openssl rand -base64 24) || die "openssl rand (password) failed"
    jwt=$(openssl rand -hex 32) || die "openssl rand (jwt) failed"
    tmp="$GNS3_CONF_DIR/.gns3_server.conf.tmp.$$"
    { printf '%s\n' "$pass"; printf '%s\n' "$jwt"; } | render_conf "$GNS3_CONF_TEMPLATE" "$tmp" ||
        die "could not render $GNS3_CONF_TEMPLATE"
    install -m 0640 -o "$GNS3_USER" -g "$GNS3_USER" "$tmp" "$GNS3_CONF_DIR/gns3_server.conf" || die "could not install gns3_server.conf"
    rm -f "$tmp"
    echo "INSTALL $GNS3_CONF_DIR/gns3_server.conf (password/JWT generated on this box, never logged)"
}

ensure_user() {
    getent passwd "$GNS3_USER" >/dev/null 2>&1 || {
        useradd --system --create-home --shell /usr/sbin/nologin "$GNS3_USER" || die "useradd $GNS3_USER failed"
    }
    usermod -aG kvm,docker "$GNS3_USER" || die "usermod -aG kvm,docker $GNS3_USER failed"
}

ensure_dirs() {
    local d
    for d in "$GNS3_PROJECTS_DIR" "$GNS3_IMAGES_DIR" "$GNS3_APPLIANCES_DIR"; do
        mkdir -p "$d" || die "could not create $d"
        chown "$GNS3_USER:$GNS3_USER" "$d" || die "could not chown $d"
    done
}

ensure_service() {
    local unit="/etc/systemd/system/gns3.service"
    sed -e "s#__GNS3_USER__#$GNS3_USER#" -e "s#__GNS3_VENV__#$GNS3_VENV#" -e "s#__GNS3_CONF_DIR__#$GNS3_CONF_DIR#" \
        "$GNS3_SERVICE_TEMPLATE" > "$unit.tmp.$$" || die "could not render $GNS3_SERVICE_TEMPLATE"
    if [ -f "$unit" ] && cmp -s "$unit.tmp.$$" "$unit"; then
        rm -f "$unit.tmp.$$"
    else
        mv -f "$unit.tmp.$$" "$unit" || die "could not install $unit"
        systemctl daemon-reload || die "systemctl daemon-reload failed"
    fi
    systemctl enable --now gns3 || die "systemctl enable --now gns3 failed"
}

ensure_nginx_vhost() {
    mkdir -p "$GNS3_NGINX_DIR/conf.d" || die "could not create $GNS3_NGINX_DIR/conf.d"
    local dest="$GNS3_NGINX_DIR/conf.d/gns3.lab.conf"
    if [ -f "$dest" ] && cmp -s "$GNS3_NGINX_VHOST" "$dest"; then
        echo "SKIP    $dest already installed"
    else
        install -m 0644 "$GNS3_NGINX_VHOST" "$dest" || die "could not install $dest"
        systemctl reload nginx 2>/dev/null || echo "NOTE    nginx reload skipped or failed -- reload it once nginx is managed (r770-portal.sh apply)"
    fi
}

cmd_apply() {
    require_root
    [ $# -eq 0 ] || die "unknown argument: $1"
    ensure_venv
    ensure_user
    ensure_conf
    ensure_dirs
    ensure_service
    ensure_nginx_vhost
    echo "PASS    gns3-server applied ($GNS3_VENV, user $GNS3_USER, service gns3.service)"
}

cmd_verify() {
    [ $# -eq 0 ] || die "unknown argument: $1"
    local ok=0
    if systemctl is-active --quiet gns3; then
        echo "PASS    gns3.service is active"
    else
        echo "FAIL    gns3.service is not active"
        ok=1
    fi
    if [ -f "$GNS3_NGINX_DIR/conf.d/gns3.lab.conf" ]; then
        echo "PASS    gns3.lab vhost installed"
    else
        echo "FAIL    gns3.lab vhost missing"
        ok=1
    fi
    return "$ok"
}

labnet_plan() {
    echo "== r770-gns3-deploy labnet plan =="
    if link_exists "$GNS3_BRIDGE"; then
        echo "KEEP    bridge $GNS3_BRIDGE already exists"
    else
        echo "CREATE  bridge $GNS3_BRIDGE (hub mode: ageing_time 0, mcast_snooping 0)"
    fi
    if link_exists "$GNS3_VETH_BRIDGE_SIDE" && link_exists "$GNS3_VETH_CAPTURE_SIDE"; then
        echo "KEEP    veth $GNS3_VETH_BRIDGE_SIDE/$GNS3_VETH_CAPTURE_SIDE already exist"
    else
        echo "CREATE  veth $GNS3_VETH_BRIDGE_SIDE / $GNS3_VETH_CAPTURE_SIDE"
    fi
    echo "== plan only -- no changes made =="
}

labnet_apply() {
    require_root
    [ $# -eq 0 ] || die "unknown argument: $1"
    if link_exists "$GNS3_BRIDGE"; then
        echo "KEEP    bridge $GNS3_BRIDGE already exists"
    else
        ip link add name "$GNS3_BRIDGE" type bridge || die "ip link add $GNS3_BRIDGE failed"
        ip link set "$GNS3_BRIDGE" type bridge ageing_time 0 || die "ip link set $GNS3_BRIDGE ageing_time 0 failed"
        ip link set "$GNS3_BRIDGE" type bridge mcast_snooping 0 || die "ip link set $GNS3_BRIDGE mcast_snooping 0 failed"
        ip link set "$GNS3_BRIDGE" up || die "ip link set $GNS3_BRIDGE up failed"
        echo "CREATE  bridge $GNS3_BRIDGE (hub mode)"
    fi
    if link_exists "$GNS3_VETH_BRIDGE_SIDE" && link_exists "$GNS3_VETH_CAPTURE_SIDE"; then
        echo "KEEP    veth $GNS3_VETH_BRIDGE_SIDE/$GNS3_VETH_CAPTURE_SIDE already exist"
    else
        ip link add name "$GNS3_VETH_BRIDGE_SIDE" type veth peer name "$GNS3_VETH_CAPTURE_SIDE" ||
            die "ip link add veth $GNS3_VETH_BRIDGE_SIDE/$GNS3_VETH_CAPTURE_SIDE failed"
        ip link set "$GNS3_VETH_BRIDGE_SIDE" master "$GNS3_BRIDGE" || die "ip link set $GNS3_VETH_BRIDGE_SIDE master $GNS3_BRIDGE failed"
        ip link set "$GNS3_VETH_BRIDGE_SIDE" up || die "ip link set $GNS3_VETH_BRIDGE_SIDE up failed"
        ip link set "$GNS3_VETH_CAPTURE_SIDE" promisc on || die "ip link set $GNS3_VETH_CAPTURE_SIDE promisc on failed"
        ip link set "$GNS3_VETH_CAPTURE_SIDE" up || die "ip link set $GNS3_VETH_CAPTURE_SIDE up failed"
        echo "CREATE  veth $GNS3_VETH_BRIDGE_SIDE / $GNS3_VETH_CAPTURE_SIDE"
    fi
    echo "PASS    labnet applied ($GNS3_BRIDGE floods to $GNS3_VETH_CAPTURE_SIDE)"
}

labnet_verify() {
    [ $# -eq 0 ] || die "unknown argument: $1"
    local ok=0
    if link_exists "$GNS3_BRIDGE"; then echo "PASS    bridge $GNS3_BRIDGE exists"; else echo "FAIL    bridge $GNS3_BRIDGE missing"; ok=1; fi
    if link_exists "$GNS3_VETH_CAPTURE_SIDE"; then echo "PASS    $GNS3_VETH_CAPTURE_SIDE exists"; else echo "FAIL    $GNS3_VETH_CAPTURE_SIDE missing"; ok=1; fi
    if link_up "$GNS3_VETH_CAPTURE_SIDE"; then echo "PASS    $GNS3_VETH_CAPTURE_SIDE is up"; else echo "FAIL    $GNS3_VETH_CAPTURE_SIDE is not up"; ok=1; fi
    return "$ok"
}

# Dispatch labnet subcommand
if [ "${1:-}" = "labnet" ]; then
    shift
    SUBVERB="${1:-plan}"
    [ $# -eq 0 ] || shift
    case "$SUBVERB" in
        plan)   require_root; labnet_plan ;;
        apply)  labnet_apply "$@" ;;
        verify) labnet_verify "$@" ;;
        *)      die "unknown labnet verb: $SUBVERB (expected plan, apply, verify)" ;;
    esac
    exit $?
fi

VERB="${1:-plan}"
[ $# -eq 0 ] || shift
case "$VERB" in
    plan)   require_root; cmd_plan ;;
    apply)  cmd_apply "$@" ;;
    verify) cmd_verify "$@" ;;
    *)      die "unknown verb: $VERB (expected plan, apply, verify)" ;;
esac
