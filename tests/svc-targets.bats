#!/usr/bin/env bats
# svc-targets generators: fixed HTTP payload and DNS config must be reproducible.

setup() {
    DIR="$BATS_TEST_DIRNAME/../images/svc-targets"
}

@test "gen-fixed.sh produces a 1 MiB file with the same sha256 every time" {
    G="$DIR/gen-fixed.sh"
    "$G" "$BATS_TEST_TMPDIR/a"; "$G" "$BATS_TEST_TMPDIR/b"
    [ "$(stat -c %s "$BATS_TEST_TMPDIR/a")" -eq 1048576 ]
    [ "$(sha256sum < "$BATS_TEST_TMPDIR/a")" = "$(sha256sum < "$BATS_TEST_TMPDIR/b")" ]
}

@test "gen-dnsmasq.sh writes the static lines and 50 host address lines" {
    "$DIR/gen-dnsmasq.sh" "$BATS_TEST_TMPDIR/d.conf"
    for l in no-resolv no-hosts log-queries 'address=/svc.site-b.lab/10.200.2.20'; do
        grep -qxF "$l" "$BATS_TEST_TMPDIR/d.conf"
    done
    [ "$(grep -c '^address=/host[0-9]*\.site-b\.lab/' "$BATS_TEST_TMPDIR/d.conf")" -eq 50 ]
    grep -qxF 'address=/host1.site-b.lab/10.200.2.2' "$BATS_TEST_TMPDIR/d.conf"
    grep -qxF 'address=/host50.site-b.lab/10.200.2.51' "$BATS_TEST_TMPDIR/d.conf"
    ! grep -q synth-domain "$BATS_TEST_TMPDIR/d.conf"
}

@test "gen-dnsmasq.sh output is identical across runs" {
    "$DIR/gen-dnsmasq.sh" "$BATS_TEST_TMPDIR/a"; "$DIR/gen-dnsmasq.sh" "$BATS_TEST_TMPDIR/b"
    cmp "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
}
