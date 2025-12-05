#!/usr/bin/env bash
# Uninstall / cleanup helper for the ha-calico-kube-vip lab.
# Default behavior: kubeadm reset, remove Kubernetes data dirs, kubeconfigs, and kube-vip manifests.
# Optional FULL_RESET=1 also removes KVM helper packages on Debian/Ubuntu hosts.

set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "[ERROR] This script must be run as root (sudo)." >&2
  exit 1
fi

log_info() {
  echo "[INFO] $*"
}

log_warn() {
  echo "[WARN] $*" >&2
}

KUBE_DIR=${KUBE_DIR:-/etc/kubernetes}

log_info "Resetting Kubernetes cluster with kubeadm"
if command -v kubeadm >/dev/null 2>&1; then
  kubeadm reset -f || log_warn "kubeadm reset failed, continuing"
else
  log_warn "kubeadm not found, skipping kubeadm reset"
fi

log_info "Removing Kubernetes data directories"
for dir in /etc/kubernetes /var/lib/etcd /var/lib/kubelet /var/lib/cni /etc/cni/net.d; do
  if [[ -e "$dir" ]]; then
    rm -rf "$dir" || log_warn "Failed to remove $dir"
  fi
done

log_info "Flushing iptables and IPVS state"
if command -v iptables >/dev/null 2>&1; then
  iptables -F || log_warn "iptables -F failed"
  iptables -t nat -F || log_warn "iptables -t nat -F failed"
  iptables -t mangle -F || log_warn "iptables -t mangle -F failed"
  iptables -X || log_warn "iptables -X failed"
else
  log_warn "iptables not found, skipping iptables cleanup"
fi
if command -v ipvsadm >/dev/null 2>&1; then
  ipvsadm -C || log_warn "ipvsadm -C failed"
fi

cleanup_user_kubeconfig() {
  local user="$1"
  [[ -z "$user" ]] && return
  local home
  home=$(getent passwd "$user" | cut -d: -f6)
  [[ -z "$home" ]] && return
  local kube_dir="$home/.kube"
  local kube_conf="$kube_dir/config"
  if [[ -f "$kube_conf" ]] && [[ $(stat -c %U "$kube_conf") == "$user" ]]; then
    if grep -q "certificate-authority-data" "$kube_conf" && grep -q "server:" "$kube_conf"; then
      log_info "Removing lab kubeconfig for user $user"
      rm -f "$kube_conf" || log_warn "Failed to remove $kube_conf"
    fi
  fi
  if [[ -d "$kube_dir" ]]; then
    if [[ -z $(ls -A "$kube_dir" 2>/dev/null) ]]; then
      rmdir "$kube_dir" || true
    fi
  fi
}

log_info "Cleaning admin kubeconfig copies created by the lab"
declare -A seen_users=()
if [[ -n "${SUDO_USER:-}" ]]; then
  seen_users["$SUDO_USER"]=1
fi
if [[ -n "${USER:-}" ]]; then
  seen_users["$USER"]=1
fi
for user in "${!seen_users[@]}"; do
  cleanup_user_kubeconfig "$user"
done

log_info "Removing kube-vip cloud provider manifests"
kube_vip_dir="$KUBE_DIR/addons/kube_vip_cloud_provider"
rm -f "$kube_vip_dir/kube-vip-cloud-controller.yaml" || true
rm -f "$kube_vip_dir/kube-vip-configmap.yaml" || true
if [[ -d "$kube_vip_dir" ]]; then
  if [[ -z $(ls -A "$kube_vip_dir" 2>/dev/null) ]]; then
    rmdir "$kube_vip_dir" || true
  fi
fi

log_info "Removing lab-specific KVM modules-load config"
kvm_conf="/etc/modules-load.d/kvm.conf"
if [[ -f "$kvm_conf" ]]; then
  trimmed=$(sed -e 's/\r$//' "$kvm_conf" | sed '/^#/d;/^$/d')
  if [[ "$trimmed" == $'kvm\nkvm_intel' || "$trimmed" == $'kvm\nkvm_amd' ]]; then
    rm -f "$kvm_conf" || log_warn "Failed to remove $kvm_conf"
    log_info "KVM modules-load config from lab removed. KVM packages remain installed; remove them manually if you do not need them."
  else
    log_warn "KVM modules-load config differs from lab defaults, leaving untouched"
  fi
else
  log_info "No lab-specific KVM modules-load config found"
fi

if [[ "${FULL_RESET:-0}" == "1" ]]; then
  log_info "FULL_RESET mode: removing KVM packages"
  if [[ -r /etc/os-release ]] && grep -qiE 'debian|ubuntu' /etc/os-release; then
    apt-get remove -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils || log_warn "Failed to remove some KVM packages"
  else
    log_warn "FULL_RESET requested but OS is not Debian/Ubuntu; skipping package removal"
  fi
fi

log_info "Cleanup completed"
