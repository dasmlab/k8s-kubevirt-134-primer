# Kubernetes 1.34 Exploration Lab

This repository captures a lightweight lab environment for exploring the Kubernetes 1.34.x release using a single-node `k3s` deployment. It also includes guided labs for notable features introduced in both Kubernetes 1.34 and 1.33, with a special focus on enabling KubeVirt to run virtual machines on top of the cluster.

## Getting Started

- Target platform: pre-provisioned Linux host with a single NIC and outbound internet access.
- Installer entry point: `setup/installer/install.sh`
- Result: local `k3s` cluster pinned to Kubernetes 1.34.1, pre-loaded with KubeVirt components for VM workloads.

To bootstrap the cluster:

1. Inspect and optionally customize `setup/installer/install.sh` (proxy settings, air-gapped registries, etc.).
2. Run the script as root or with sudo privileges:
   ```bash
   sudo /home/dasm/k8s-134-installer/setup/installer/install.sh
   ```
3. Verify node, control-plane, and KubeVirt components come up healthy as instructed by the script output.

## Feature Exploration Index

| Feature | Version | Summary | Link | Blog Link |
| --- | --- | --- | --- | --- |
| KubeVirt Virtualization Add-on | 1.34 | Extend the cluster with KubeVirt operator and CRDs to schedule virtual machines alongside containers. | [features/134-kubevirt-integration](features/134-kubevirt-integration) | [Medium](https://medium.com/@danielsmith_81273/taking-kubevirt-and-k8s-1-34-1-33-for-a-ride-8ad3eba255bb) |
| Gateway API Consistency Updates | 1.34 | Unifies status conditions and cross-namespace referencing rules as Gateway API matures. | [features/134-gateway-api-consistency](features/134-gateway-api-consistency) | TBD |
| KMS Provider v2 Enhancements | 1.34 | Improves envelope encryption performance and observability for secrets at rest. | [features/134-kms-v2-enhancements](features/134-kms-v2-enhancements) | TBD |
| Resilient Autoscaling Signals | 1.34 | Expands Horizontal Pod Autoscaler signal integration for responsive scaling under fluctuating workloads. | [features/134-resilient-autoscaling](features/134-resilient-autoscaling) | TBD |
| Dynamic Resource Allocation GA | 1.33 | Enables workloads to request specialized hardware resources via dynamic resource claims. | [features/133-dynamic-resource-allocation](features/133-dynamic-resource-allocation) | TBD |
| Node Swap Support (Beta) | 1.33 | Allows controlled swap usage on nodes, improving memory overcommit flexibility. | [features/133-node-swap-support](features/133-node-swap-support) | TBD |
| Volume Attributes Class | 1.33 | Introduces reusable policies for storage driver attributes via the CSI Volume Attributes Class API. | [features/133-volume-attributes-class](features/133-volume-attributes-class) | TBD |

Each feature directory contains:

- A dedicated README with context, diagrams, and step-by-step experiments.
- CRDs and manifests required for hands-on exploration.
- Notes on validation steps and cleanup.

## Project Layout

- `features/` – Scenario-specific lab materials for Kubernetes 1.33–1.34 features.
- `setup/` – Cluster provisioning scripts and configuration, including installer entry point.

Feel free to open an issue or submit a PR with additional features you’d like to explore or improvements to the existing guides.



