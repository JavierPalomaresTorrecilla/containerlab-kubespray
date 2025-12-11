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

## Verifying the cluster

From a control-plane host logged in as the Ansible SSH user:

```bash
ssh ubuntu@kubecp-1
kubectl get nodes
kubectl get pods -n kube-system
```

To double-check using the admin kubeconfig directly:

```bash
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes
```

Expected output: all control-plane and worker nodes appear in `Ready` state once CNI and core components finish reconciling.

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
5. **Residual cluster artifacts after uninstall** – rerun `ansible-playbook ... playbooks/uninstall.yml --tags uninstall_full_reset` and review assert messages pointing to remaining services or directories.
