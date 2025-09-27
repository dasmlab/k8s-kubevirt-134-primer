# K3s + KubeVirt Installer Guide

This installer provisions a `k3s` cluster pinned to Kubernetes `v1.34.1+k3s1`, then layers on KubeVirt and Containerized Data Importer components for virtualization workloads. It supports both single-node labs and multi-node clusters.

## Prerequisites

- Linux host(s) with hardware virtualization (VT-x/AMD-V) enabled.
- Root or sudo access.
- Basic utilities: `curl`, `tar`, `ssh` (for cluster mode).
- Optional: passwordless SSH from the control plane host to workers (see below).

### Preparing SSH and Sudo Access (Cluster Mode)

1. Generate or reuse an SSH key on the control-plane host and copy it to each worker:
   ```bash
   ssh-keygen -t ed25519 -C "k3s-cluster" # if needed
   ssh-copy-id user@worker-01
   ssh-copy-id user@worker-02
   ```
2. Enable passwordless sudo on each worker for the deploying user. Add the following line with `visudo` (replace `user` accordingly):
   ```
   user ALL=(ALL) NOPASSWD:ALL
   ```
3. If `sshd_config` has `PasswordAuthentication no`, ensure the key copy occurs before disabling password auth or temporarily set `PasswordAuthentication yes` and reload `sshd` to allow `ssh-copy-id`.

These steps allow the installer to run remote `curl | sudo sh -` commands without prompting for passwords.

## Running the Installer

### Single Node (default)

```
cd setup/installer
sudo ./install.sh [--node-name my-node]
```

### Multi-Node Cluster

Prepare a nodes file listing worker SSH targets (`setup/installer/nodelist.sample.txt` shows the format):

```
# nodes.txt
ubuntu@worker-01 worker-01
ubuntu@worker-02 worker-02
```

Run the installer on the control-plane host:

```
sudo ./install.sh --mode cluster --node-name cp-00 --nodes-file nodes.txt --control-host 192.168.1.23
```

If `--control-host` is omitted the script uses the first IP from `hostname -I`. Export `SSH_OPTS` to customize SSH flags (e.g., alternate key path).

A successful run shows `k3s` installation (skipped if already present), KubeVirt operator deployment, and CDI deployment. Highlight the KubeVirt sections in the terminal transcript (thin outline suggested) to emphasize the virtualization add-on steps:

![Successful installer run with KubeVirt highlights](../../docs/images/installer-success.png)

## Post-Install Validation

Confirm the cluster and KubeVirt components with:

```
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get nodes
kubectl get pods -A
virtctl version --client
```

The expected output shows KubeVirt control plane pods in the `kubevirt` namespace and CDI pods in `cdi`:

![kubectl get pods -A and get nodes after install](../../docs/images/kubectl-status.png)

## Inspecting Delivered CRDs

KubeVirt ships an extensive set of CRDs covering VM lifecycle, migrations, snapshots, and data import operations. After installation, capture the list with:

```
kubectl get customresourcedefinitions.apiextensions.k8s.io | grep kubevirt
```

An example run (highlight the KubeVirt CRDs) is shown below:

![kubectl get CRDs showing KubeVirt resources](../../docs/images/kubevirt-crds.png)

## Cleanup

To tear down the environment when finished:

```
/usr/local/bin/k3s-killall.sh
/usr/local/bin/k3s-uninstall.sh
```

## Next Steps

- Walk through the feature labs under `features/` starting with [`134-kubevirt-integration`](../../features/134-kubevirt-integration).
- Dive deeper into each CRD and accompanying workflows in that directory’s README and manifests.
