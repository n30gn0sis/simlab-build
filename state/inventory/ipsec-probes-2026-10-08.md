# IPsec scenario probes O3 / O4 / O5 / O9 — staging VM 9771, 2026-10-08/09 (UTC)

Plan: `docs/superpowers/plans/2026-10-07-ipsec-scenarios-plan.md` Task 14. Spec: `docs/superpowers/specs/2026-10-07-ipsec-scenarios-design.md` §15 open questions.
Run from the Claude session over SSH to `ubuntu@192.168.4.26` (VM 9771, started 2026-10-09 04:54 UTC after the operator stopped 9770). Repo on the VM fast-forwarded to `910dd44` (the Part A merge) via a git bundle. Docker 29.8.1. Internet-connected staging; nothing here touches the R770.

| Probe | Disposition |
|---|---|
| O3 save-keys in noble packages | **ABSENT** — built from Ubuntu's own `strongswan` source package in a Dockerfile builder stage (below). A second defect found while verifying: `save-keys.conf` was nested wrongly and the plugin never loaded. Both fixed in the repo with bats cases. |
| O4 GNS3 Docker-node behaviour | **Deferred to Part C IP3** (needs the GNS3 server). The Compose layout's `docker cp <node>:/gt/.` path is exercised by Task 15. |
| O5 containerized MPLS | **PASS** — `mpls_router`/`mpls_iptunnel` load on the VM's kernel 7.0.0-34-generic; the bundled FRR 10.7.1 container accepts `--sysctl net.mpls.platform_labels=1000`, zebra+ldpd start, `show mpls status` → `MPLS support enabled: yes`. W3 may use FRR for P/PE. |
| O9 CHR key visibility | **Deferred to IP6 on the R770** (needs a QEMU boot of the CHR image; not spent on the staging VM). |

## O3 — save-keys

Command (plan Task 14, verbatim):

```
docker run --rm ubuntu:24.04 bash -c 'apt-get update -qq && apt-get install -y -qq strongswan-charon strongswan-swanctl libstrongswan-extra-plugins libcharon-extra-plugins >/dev/null && ls /usr/lib/ipsec/plugins/ | grep -i save; dpkg -l strongswan-charon | tail -1; /usr/lib/ipsec/charon --version 2>&1 | head -1'
```

Output:

```
plugins:
ii  strongswan-charon 5.9.13-2ubuntu4.24.04.5 amd64        strongSwan Internet Key Exchange daemon
Linux strongSwan 5.9.13
dpkg-query: no path found matching pattern /usr/lib/ipsec/plugins/libstrongswan-save-keys.so
```

`apt-file search save-keys` across noble (+updates, +security) matches only `php-doc`; the strongswan binary packages are `strongswan strongswan-charon strongswan-starter charon-systemd network-manager-strongswan strongswan-nm strongswan-pki strongswan-swanctl libcharon-extauth-plugins libstrongswan libstrongswan-standard-plugins strongswan-libcharon libcharon-extra-plugins libstrongswan-extra-plugins` — none ships the plugin. **Absent.**

### Fallback taken (differs from the plan's checkinstall route)

Instead of rebuilding and replacing the whole strongSwan package set, `images/ipsec-ss/Dockerfile` gained a builder stage that compiles **only the plugin** from `apt-get source strongswan` — Ubuntu's own source package, the same `5.9.13-2ubuntu4.24.04.5` the runtime binaries come from, fetched through apt's signed index (no new version pin, no new trust root, nothing added to `manual/`). Configure flags: `--disable-defaults --enable-charon --enable-save-keys --enable-ikev2 --enable-nonce --enable-random --enable-pem --enable-x509` (`--enable-openssl` dropped: it only adds a libssl-dev build dependency the plugin does not need). The runtime stage copies `libstrongswan-save-keys.so` (158000 bytes) into `/usr/lib/ipsec/plugins/` and **fails the build** if `dpkg-parsechangelog -S Version` of the source differs from `dpkg-query -W -f='${Version}' strongswan-charon` of the installed binary.

Proof in the built image (`localhost/lab/ipsec-ss:o3test`, 212 MB):

```
src=5.9.13-2ubuntu4.24.04.5 bin=5.9.13-2ubuntu4.24.04.5
-rw-r--r-- 1 root root 158000 Oct  9 05:03 /usr/lib/ipsec/plugins/libstrongswan-save-keys.so
```

charon run with `--cap-add NET_ADMIN`, `/gt/charon.log` (the image's filelog):

```
Oct  9 05:15:08 00[LIB] loaded plugins: charon save-keys test-vectors ldap pkcs11 aes rc2 sha2 sha1 md5 mgf1 rdrand random nonce x509 revocation constraints pubkey pkcs1 pkcs7 pkcs12 pgp dnskey sshkey pem gcrypt pkcs8 fips-prf gmp curve25519 chapoly xcbc cmac hmac kdf ctr ccm ntru drbg curl attr kernel-netlink resolve socket-default forecast farp vici updown eap-identity eap-aka eap-md5 eap-gtc eap-dynamic eap-radius eap-tls eap-ttls eap-peap eap-tnc xauth-eap xauth-pam tnc-tnccs dhcp lookip error-notify certexpire led addrblock unity counters
```

Option names verified against the source's `conf/plugins/save-keys.opt`: `charon.plugins.save-keys.{load,esp,ike,wireshark_keys}`; the plugin writes `ikev1_decryption_table`, `ikev2_decryption_table` and `esp_sa` into `wireshark_keys` — the file name `scen-check` X7 reads. Whether keys are actually written for a live SA is proven by Task 15 (S1, X7), not here.

### Defect found: `save-keys.conf` nesting

First build with the plugin present still showed no `save-keys` in `loaded plugins`. Cause: the distro's `/etc/strongswan.conf` is

```
charon {
	load_modular = yes
	plugins {
		include strongswan.d/charon/*.conf
	}
}
include strongswan.d/*.conf
```

so a file under `strongswan.d/charon/` must be the bare `save-keys { … }` block. The repo's file wrapped it in `charon { plugins { … } }`, which resolves to `charon.plugins.charon.plugins.save-keys` and leaves `load` at its default `no`. `logging.conf` is installed as `strongswan.d/charon-logging.conf` (top-level include) and its `charon { filelog { … } }` wrapper is correct — it was already writing `/gt/charon.log`. Fixed: `images/ipsec-ss/strongswan.d/save-keys.conf` is now the bare block; `tests/ipsec-ss.bats` pins both nestings and the Dockerfile's builder stage.

## O5 — containerized MPLS

```
$ sudo modprobe mpls_router; sudo modprobe mpls_iptunnel; echo "modprobe exit $?"; lsmod | grep -E '^mpls'
modprobe exit 0
mpls_gso               12288  0
mpls_iptunnel          16384  0
mpls_router            45056  1 mpls_iptunnel
```

FRR container (bundled `quay.io/frrouting/frr:10.7.1`), minimal `/etc/frr/{daemons (zebra=yes ldpd=yes),frr.conf,vtysh.conf}` mounted, `--cap-add NET_ADMIN --cap-add SYS_ADMIN --sysctl net.mpls.platform_labels=1000`:

```
$ vtysh -c 'show mpls table' -c 'show mpls status'
MPLS support enabled: yes
rc=0
… WATCHFRR: ldpd state -> up : connect succeeded
… WATCHFRR: all daemons up, doing startup-complete notify
$ sysctl net.mpls.platform_labels
net.mpls.platform_labels = 1000
$ ls /proc/sys/net/mpls/
conf  default_ttl  ip_ttl_propagate  platform_labels
```

`show mpls table` printed nothing (empty table, no error). Without `/etc/frr/daemons` the image's `docker-start` starts no daemons and vtysh reports `zebra is not running` — the scenario node configs must ship a `daemons` file (W3's `isp1/daemons` pattern already does). **PASS.** The modules were loaded on the VM for the probe only; they are not persisted.

## Not probed here

- **O4** — GNS3 is not deployed on this VM; recorded as deferred to IP3 per the plan.
- **O9** — CHR under QEMU; deferred to IP6 per the plan.
- **R1** (Docker `FORWARD DROP` + `br_netfilter`) is a Task 15 step, not a Task 14 probe. Observed at boot: `-P FORWARD DROP`, `br_netfilter` not loaded (only `xfrm_user`/`xfrm_algo` present).

## Residue on the VM

Containers/images left for inspection: `o3build2` (exited; the first prototype build), image `o3img` (its commit) and `localhost/lab/ipsec-ss:o3test`; `~/o3/`, `~/o5/`. The VM's repo checkout carries the two fixed files uncommitted until the Part A commit ships to it via the next git bundle.
