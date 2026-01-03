# gVisor Installation on OpenShift

This directory contains the configuration files for installing gVisor on an OpenShift cluster.

## Overview

gVisor is an application kernel that provides an additional layer of isolation between running applications and the host operating system. It implements a substantial portion of the Linux system surface in Go and includes an OCI-compatible runtime called `runsc`.

## Prerequisites

- OpenShift 4.x cluster
- Cluster admin access
- Nodes with x86_64 or ARM64 architecture

## Files

| File | Description |
|------|-------------|
| `01-machineconfig-gvisor.yaml` | MachineConfig for worker nodes |
| `01-machineconfig-gvisor-master.yaml` | MachineConfig for master nodes |
| `02-runtimeclass-gvisor.yaml` | RuntimeClass definition for gVisor |
| `03-test-pod-gvisor.yaml` | Test pod using nginx |
| `04-test-simple.yaml` | Simple test pod using busybox |

## Installation Steps

### 1. Apply MachineConfig

For clusters with dedicated worker nodes:
```bash
oc apply -f 01-machineconfig-gvisor.yaml
```

For single-node or master-schedulable clusters:
```bash
oc apply -f 01-machineconfig-gvisor-master.yaml
```

**Note:** This will trigger a node restart. Wait for the MachineConfigPool to be updated:
```bash
oc wait --for=condition=Updated mcp/master --timeout=600s
# or for workers:
oc wait --for=condition=Updated mcp/worker --timeout=600s
```

### 2. Apply RuntimeClass

```bash
oc apply -f 02-runtimeclass-gvisor.yaml
```

### 3. Verify Installation

Check that runsc is installed on the node:
```bash
oc debug node/<node-name> -- chroot /host /usr/local/bin/runsc --version
```

Expected output:
```
runsc version release-20251215.0
spec: 1.1.0-rc.1
```

### 4. Test gVisor

Deploy a test pod:
```bash
oc apply -f 04-test-simple.yaml
```

Verify the container is running in gVisor sandbox:
```bash
# Get container ID
CONTAINER_ID=$(oc debug node/<node-name> -- chroot /host /usr/local/bin/runsc --root=/run/runsc list 2>/dev/null | grep gvisor-simple | awk '{print $1}')

# Check kernel version (should show gVisor's kernel 4.4.0)
oc debug node/<node-name> -- chroot /host /usr/local/bin/runsc --root=/run/runsc exec $CONTAINER_ID uname -a
```

Expected output:
```
Linux gvisor-simple 4.4.0 #1 SMP Sun Jan 10 15:06:54 PST 2016 x86_64 GNU/Linux
```

## Usage

To run a pod with gVisor, add `runtimeClassName: gvisor` to the pod spec:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-gvisor-pod
spec:
  runtimeClassName: gvisor  # Add this line
  containers:
  - name: app
    image: nginx:alpine
```

## Configuration Details

### CRI-O Configuration

The MachineConfig installs the following CRI-O configuration at `/etc/crio/crio.conf.d/99-gvisor.conf`:

```toml
[crio.runtime]
selinux = false
drop_infra_ctr = false

[crio.runtime.runtimes.runsc]
runtime_path = "/usr/local/bin/runsc"
runtime_type = "oci"
runtime_root = "/run/runsc"
```

**Important:** SELinux is disabled because gVisor does not support SELinux. gVisor provides its own sandboxing mechanism that is independent of SELinux.

### runsc Binary Installation

The MachineConfig includes a systemd unit that downloads and installs the runsc binary on first boot:
- Downloads from: `https://storage.googleapis.com/gvisor/releases/release/latest/<ARCH>/`
- Installs to: `/usr/local/bin/runsc` and `/usr/local/bin/containerd-shim-runsc-v1`

## Known Issues

### CRI-O Status Reporting

There is a known integration issue between CRI-O and gVisor where the container status may show as `RunContainerError` or `CrashLoopBackOff` even though the container is actually running successfully inside the gVisor sandbox.

To verify the container is running:
```bash
oc debug node/<node-name> -- chroot /host /usr/local/bin/runsc --root=/run/runsc list
```

Reference: [gVisor GitHub Issue #10313](https://github.com/google/gvisor/issues/10313)

### SELinux Incompatibility

gVisor does not support SELinux. The installation disables SELinux in CRI-O configuration. This affects all containers on the node, not just gVisor containers.

## Uninstallation

To remove gVisor from the cluster:

```bash
# Delete RuntimeClass
oc delete -f 02-runtimeclass-gvisor.yaml

# Delete MachineConfig (this will restart nodes)
oc delete -f 01-machineconfig-gvisor-master.yaml
oc delete -f 01-machineconfig-gvisor.yaml
```

## References

- [gVisor Official Documentation](https://gvisor.dev/docs/)
- [gVisor Installation Guide](https://gvisor.dev/docs/user_guide/install/)
- [Kubernetes RuntimeClass](https://kubernetes.io/docs/concepts/containers/runtime-class/)
- [CRI-O Configuration](https://github.com/cri-o/cri-o/blob/main/docs/crio.conf.5.md)
