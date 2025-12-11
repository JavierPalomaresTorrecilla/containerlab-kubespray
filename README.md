## Deploy a Production Ready Kubernetes Cluster

![Kubernetes Logo](https://raw.githubusercontent.com/kubernetes-sigs/kubespray/master/docs/img/kubernetes-logo.png)

This repository builds on [kubespray](https://github.com/kubernetes-sigs/kubespray) to provide a reproducible lab environment that uses Calico, kube-vip, optional kube-vip cloud provider automation, and lab cleanup tooling. If you need the full Kubespray documentation, refer to [kubespray.io](https://kubespray.io) or join [#kubespray on the Kubernetes Slack](https://kubernetes.slack.com).

## Overview

1. Automates a highly available Kubernetes cluster using the inventory at `inventory/ha-calico-kube-vip/inventory.ini` (three control-plane nodes, worker nodes, Calico CNI, kube-vip for both API and LoadBalancer VIPs).
2. Wires cluster-specific overrides under `inventory/ha-calico-kube-vip/group_vars/` to enable kube-vip services, kube-vip cloud provider IPAM, KVM preflight checks, and other lab tweaks.
3. Provides `scripts/uninstall.sh` and `playbooks/uninstall.yml` to tear down the lab, validate that no Kubernetes components remain, and optionally remove KVM packages.

## Requirements

### Host requirements

1. Linux control host (tested on Ubuntu 24.04) with outbound SSH access to every node listed in the inventory.
2. SSH access to the lab nodes as the Ansible SSH user defined in `inventory/ha-calico-kube-vip/inventory.ini` (`ansible_ssh_user=ubuntu` by default).
3. Nodes sized to run Kubernetes (2 vCPU/4 GB RAM minimum recommended).

### Software requirements on the Ansible control host

1. `git` to clone this repository.
2. Python 3.10+ (system package `python3`) with `venv` support.

### KVM requirements

The lab assumes KVM acceleration. Verify virtualization support and module availability before deploying:

```bash
lsmod | grep kvm || echo "kvm kernel module not loaded"
egrep -c '(vmx|svm)' /proc/cpuinfo
```

On Ubuntu hosts, install the typical packages and enable libvirt:

```bash
sudo apt update
sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils
sudo systemctl enable --now libvirtd
```

The `roles/kvm_preflight` role verifies CPU virtualization flags, `/dev/kvm`, and loaded modules before the Kubernetes installation begins.

#### Optional: verify KVM preflight on workers

The `kvm_preflight` role runs automatically whenever `kvm_preflight_enabled: true` in the inventory (the `inventory/ha-calico-kube-vip` scenario already sets it). To confirm the play is present you can list the playbook tags and grep for the KVM entry:

```bash
# List plays and tags for this scenario
source .venv/bin/activate
ansible-playbook \
  -i inventory/ha-calico-kube-vip/inventory.ini \
  playbooks/cluster.yml \
  --limit k8s_cluster \
  --become --list-tags | grep -i "KVM preflight" || true
```

Expected output (if wired correctly):
`play #N (kube_node): Run KVM preflight checks on worker nodes  TAGS: []`, which confirms the worker validation step is part of the standard `cluster.yml` run.

## Python virtual environment and Ansible dependencies

All commands assume you are inside a virtualenv located at the repository root.

```bash
cd containerlab-kubespray

python3 -m venv .venv
source .venv/bin/activate
```

Install the required tooling inside the virtualenv:

```bash
# Upgrade pip
python -m pip install --upgrade pip

# Pin ansible-core to the required version
python -m pip install --force-reinstall "ansible-core==2.17.3"

# Required Ansible collections
ansible-galaxy collection install community.general
ansible-galaxy collection install kubernetes.core
ansible-galaxy collection install community.crypto
ansible-galaxy collection install ansible.utils

# Python libraries used by the playbooks
python -m pip install jmespath
python -m pip install netaddr
```

If the repository later adds `requirements.txt` or `requirements.yml`, prefer those, but the commands above are the tested setup.

## Repository setup and inventory

Clone and enter the repository, then activate the virtualenv:

```bash
git clone <repo-url>
cd containerlab-kubespray
source .venv/bin/activate
```

The default lab inventory lives at `inventory/ha-calico-kube-vip/inventory.ini` and defines:

1. `k8s_cluster` – all Kubernetes hosts.
2. `kube_control_plane` – the three control-plane nodes.
3. `kube_node` – worker nodes.

Update hostnames, IP addresses, and `ansible_ssh_user` in this file to reflect your lab environment. Additional tunables sit under `inventory/ha-calico-kube-vip/group_vars/`.

## Deploying the Kubernetes lab cluster

Run the main playbook from the repo root:

```bash
ansible-playbook \
  -i inventory/ha-calico-kube-vip/inventory.ini \
  playbooks/cluster.yml \
  --limit k8s_cluster \
  --become
```

This playbook:

1. Performs host bootstrap, version checks, and KVM preflight validation.
2. Installs container runtime, etcd, Kubernetes control plane, and joins worker nodes.
3. Configures Calico networking, Multus (if enabled), kube-vip for control-plane and service VIPs, and the kube-vip cloud provider IPAM.
4. Copies `/etc/kubernetes/admin.conf` into `/home/{{ ansible_user }}/.kube/config` on every control-plane host using `remote_src: true`, ensures the directory is `0700`, the file is `0600`, and removes `/root/.kube/config` so the SSH user owns the default kubeconfig.

> Note: kube-vip is responsible for the control-plane virtual IP and optional bare-metal LoadBalancer addresses. For details on VIP configuration and the external kubeconfig, see [Kube-vip integration (virtual IPs)](#kube-vip-integration-virtual-ips) and [External access via kube-vip](#external-access-via-kube-vip).

## Kube-vip integration (virtual IPs)

This lab uses [kube-vip](https://kube-vip.io/) to provide a virtual IP (VIP) for the Kubernetes control plane and to implement bare metal type `LoadBalancer` services without an external cloud provider.

### Control plane virtual IP

- The virtual IP for the API server is configured via `kube_vip_enabled: true` and `kube_vip_address` in `inventory/sample/cluster/k8s-cluster.yml`.
- The VIP must be an unused address on the same Layer 2 network as the control plane nodes. In the default GEANT lab, it is `192.168.123.200`.
- `kube_vip_interface` must match the Linux network interface that is connected to that network on the control plane node (for example `ens3` or `eth0`). You can verify this with `ip addr`.
- A kube-vip pod runs on the control plane node and answers ARP for the VIP. If you deploy multiple control plane nodes, kube-vip will use leader election so that only one node advertises the VIP at a time and the API endpoint stays reachable.

### LoadBalancer services on bare metal

- `kube_vip_cloud_provider_enabled: true` turns on the kube-vip cloud provider and allows you to create `type: LoadBalancer` services on bare metal.
- The IP range used for `LoadBalancer` services is configured via `kube_vip_cloud_provider_lb_ip_range`, for example `192.168.123.201-192.168.123.205`.
- All addresses in this range must belong to the same subnet as the nodes and must not be used by any other host or device.
- When you create a `LoadBalancer` service, kube-vip allocates one of these IPs, advertises it on the network, and forwards traffic to the selected service endpoints inside the cluster.

### Notes and troubleshooting

- You do not need an extra VM for the VIP. The VIP is a shared IP that is announced by the kube-vip pod running on a control plane node.
- If the `kube-vip` pod is in `CrashLoopBackOff`, first check that:
  - `kube_vip_interface` matches an existing interface name on the host.
  - The VIP configured in `kube_vip_address` belongs to the correct subnet and is not already in use.
  - The IP range configured in `kube_vip_cloud_provider_lb_ip_range` is inside the same subnet and does not overlap with other static assignments.

## External access via kube-vip

Kube-vip exposes the Kubernetes API server on the virtual IP defined by `kube_vip_address`, meaning clients can always talk to the cluster through that VIP instead of relying on the physical control-plane node address. To make this smoother, the repository includes an optional post-install play that derives an external kubeconfig pointing directly at the VIP. The feature is disabled by default so you can opt in per-inventory when you want persistent external access.

### Enabling external kubeconfig generation

Enable the flag in `inventory/ha-calico-kube-vip/group_vars/k8s_cluster/k8s-cluster.yml` (or your inventory-specific file):

```yaml
# Configure external kubeconfig for kube-vip (post-install convenience)
configure_external_kubeconfig: true
```

Then run the tagged play (this can be executed on an already-provisioned cluster):

```bash
ansible-playbook \
  -i inventory/ha-calico-kube-vip/inventory.ini \
  playbooks/cluster.yml \
  --become \
  --tags external_kubeconfig
```

The play is idempotent; if the external kubeconfig already points to `kube_vip_address`, nothing is changed.

### Using the generated external kubeconfig

After the play runs:

- The standard admin kubeconfig for the current user remains at `~/.kube/config`.
- A VIP-aware kubeconfig is created at `~/.kube/config-external` with `server: https://<kube_vip_address>:6443` (value taken from `kube_vip_address` in `k8s-cluster.yml`).

Test connectivity with:

```bash
kubectl --kubeconfig ~/.kube/config-external get nodes
```

> **Warning:** `~/.kube/config-external` grants full API access. Share it only with trusted users and rotate credentials if it is ever exposed.

## Verifying the cluster

From a control-plane host logged in as the Ansible SSH user:

```bash
ssh ubuntu@kubecp-1
kubectl get nodes
kubectl get pods -n kube-system
```

Expected output: all control-plane and worker nodes appear in `Ready` state once CNI and core components finish reconciling.

#### Host /etc/hosts sanity (Ubuntu 24.04)

Some Ubuntu 24.04 images omit hostname mappings in `/etc/hosts`, which breaks Calico readiness even though the node reports `Ready`.

**Symptoms**

- `calico-node` DaemonSet pod remains `0/1` and restarts repeatedly on the worker.
- `kubectl describe pod` shows events such as:

```
calico/node is not ready: felix is not ready: Get "http://localhost:9099/readiness": dial tcp: lookup localhost on 8.8.8.8:53: no such host
```

**Check and fix on each node**

```bash
hostname
cat /etc/hosts
getent hosts localhost "$(hostname)"
```

Ensure `/etc/hosts` contains both localhost and the node hostname, for example:

```
127.0.0.1   localhost
::1         localhost ip6-localhost ip6-loopback

192.168.123.164   kubecp-1
192.168.123.184   kubeworker-1
```

After correcting `/etc/hosts`, restart the DaemonSet pod so it picks up the fix:

```bash
kubectl -n kube-system delete pod -l k8s-app=calico-node -o name
```

The worker’s `calico-node` pod should move to `1/1` Running once local hostname resolution is healthy.

## Uninstalling the lab

Tear-down uses the bundled script and playbook. Run either mode from the repo root while the virtualenv is active:

Standard cleanup (keeps KVM packages):

```bash
ansible-playbook \
  -i inventory/ha-calico-kube-vip/inventory.ini \
  playbooks/uninstall.yml \
  --tags uninstall_standard
```

Full reset (also removes `qemu-kvm`, `libvirt-daemon-system`, `libvirt-clients`, `bridge-utils` on Debian/Ubuntu by exporting `FULL_RESET=1`):

```bash
ansible-playbook \
  -i inventory/ha-calico-kube-vip/inventory.ini \
  playbooks/uninstall.yml \
  --tags uninstall_full_reset
```

`scripts/uninstall.sh` performs:

1. `kubeadm reset -f` when present, followed by removal of `/etc/kubernetes`, `/var/lib/kubelet`, `/var/lib/etcd`, `/var/lib/cni`, `/etc/cni/net.d`.
2. iptables filter/nat/mangle flushes and IPVS cleanup.
3. Removal of lab-created kubeconfig copies in each user home and optional pruning of empty `~/.kube` directories.
4. Deletion of kube-vip cloud provider manifests under `${KUBE_DIR:-/etc/kubernetes}/addons/kube_vip_cloud_provider`.
5. Removal of `/etc/modules-load.d/kvm.conf` if it matches the lab-created content.
6. **FULL_RESET mode** additionally removes the KVM package set on Debian/Ubuntu systems.

After the uninstall command, `playbooks/uninstall.yml` verifies that `kubectl` cannot talk to an API server, Kubernetes systemd units are stopped, and the core directories are absent on every node.

## Re-deploying after uninstall

Once uninstall completes without asserts, rerun the deployment command from the “Deploying the Kubernetes lab cluster” section. The playbook recreates kubeconfigs under `/home/{{ ansible_user }}/.kube/` automatically, so no manual steps are required.

## Troubleshooting

1. **`You need to install "jmespath" prior to running json_query filter`** – ensure `python -m pip install jmespath` was executed inside `.venv` before running Ansible.
2. **`Invalid plugin FQCN (community.crypto.x509_certificate_info)`** – rerun `ansible-galaxy collection install community.crypto` inside the virtualenv.
3. **Permission denied when reading `/etc/kubernetes/admin.conf`** – confirm your inventory’s `ansible_ssh_user` has passwordless sudo (or supply `--ask-become-pass`) and re-run with `--become`; the copy task relies on root access plus `remote_src: true`.
4. **KVM checks fail (missing `vmx/svm` or `/dev/kvm`)** – verify BIOS virtualization options are enabled and that `kvm_intel` or `kvm_amd` are loaded (`lsmod | grep kvm`). If needed, set `kvm_preflight_auto_install: true` in the inventory to let the playbook install modules on Debian/Ubuntu.
