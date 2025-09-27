# K3s + KubeVirt Installer Guide

This installer provisions a single-node `k3s` cluster pinned to Kubernetes `v1.34.1+k3s1`, then layers on KubeVirt and Containerized Data Importer components for virtualization workloads.

## Prerequisites

- Linux host with hardware virtualization (VT-x/AMD-V) enabled.
- Root or sudo access.
- Basic utilities: `curl`, `tar`.

## Running the Installer

```bash
cd setup/installer
sudo ./install.sh
```

A successful run shows `k3s` installation (skipped if already present), KubeVirt operator deployment, and CDI deployment. Highlight the KubeVirt sections in the terminal transcript (thin outline suggested) to emphasize the virtualization add-on steps:

![Successful installer run with KubeVirt highlights](../../docs/images/installer-success.png)

## Post-Install Validation

Confirm the cluster and KubeVirt components with:

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get pods -A
kubectl get nodes
```

The expected output shows KubeVirt control plane pods in the `kubevirt` namespace and CDI pods in `cdi`:

![kubectl get pods -A and get nodes after install](../../docs/images/kubectl-status.png)

## Inspecting Delivered CRDs

KubeVirt ships an extensive set of CRDs covering VM lifecycle, migrations, snapshots, and data import operations. After installation, capture the list with:

```bash
kubectl get customresourcedefinitions.apiextensions.k8s.io | grep kubevirt
```

An example run (highlight the KubeVirt CRDs) is shown below:

![kubectl get CRDs showing KubeVirt resources](../../docs/images/kubevirt-crds.png)

## Cleanup

To tear down the environment when finished:

```bash
/usr/local/bin/k3s-killall.sh
/usr/local/bin/k3s-uninstall.sh
```

## Next Steps

- Walk through the feature labs under `features/` starting with [`134-kubevirt-integration`](../../features/134-kubevirt-integration).
- Dive deeper into each CRD and accompanying workflows in that directory’s README and manifests.
