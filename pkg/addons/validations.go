/*
Copyright 2019 The Kubernetes Authors All rights reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package addons

import (
	"errors"
	"fmt"
	"slices"
	"strconv"

	"github.com/spf13/viper"
	"k8s.io/minikube/pkg/minikube/assets"
	"k8s.io/minikube/pkg/minikube/config"
	"k8s.io/minikube/pkg/minikube/cruntime"
	"k8s.io/minikube/pkg/minikube/driver"
	"k8s.io/minikube/pkg/minikube/out"
	"k8s.io/minikube/pkg/minikube/run"
	"k8s.io/minikube/pkg/minikube/style"
)

const volumesnapshotsAddon = "volumesnapshots"

// containerdOnlyMsg is the message shown when a containerd-only addon is enabled
const containerdOnlyAddonMsg = `
This addon can only be enabled with the containerd runtime backend. To enable this backend, please first stop minikube with:

minikube stop

and then start minikube again with the following flags:

minikube start --container-runtime=containerd --docker-opt containerd=/var/run/containerd/containerd.sock`

// volumesnapshotsDisabledMsg is the message shown when csi-hostpath-driver addon is enabled without the volumesnapshots addon
const volumesnapshotsDisabledMsg = `[WARNING] For full functionality, the 'csi-hostpath-driver' addon requires the 'volumesnapshots' addon to be enabled.

You can enable 'volumesnapshots' addon by running: 'minikube addons enable volumesnapshots'
`

func isRuntimeContainerd(cc *config.ClusterConfig, _, _ string, _ *run.CommandOptions) error {
	r, err := cruntime.New(cruntime.Config{Type: cc.KubernetesConfig.ContainerRuntime})
	if err != nil {
		return err
	}
	_, ok := r.(*cruntime.Containerd)
	if !ok {
		return errors.New(containerdOnlyAddonMsg)
	}
	return nil
}

// isVolumesnapshotsEnabled is a validator that prints out a warning if the volumesnapshots addon
// is disabled (does not return any errors!)
func isVolumesnapshotsEnabled(cc *config.ClusterConfig, _, value string, _ *run.CommandOptions) error {
	isCsiDriverEnabled, _ := strconv.ParseBool(value)
	// assets.Addons[].IsEnabled() returns the current status of the addon or default value.
	// config.AddonList contains list of addons to be enabled.
	addonList := viper.GetStringSlice(config.AddonListFlag)
	isVolumesnapshotsEnabled := assets.Addons[volumesnapshotsAddon].IsEnabled(cc) || slices.Contains(addonList, volumesnapshotsAddon)
	if isCsiDriverEnabled && !isVolumesnapshotsEnabled {
		// just print out a warning directly, we don't want to return any errors since
		// that would prevent the addon from being enabled (callbacks wouldn't be run)
		out.WarningT(volumesnapshotsDisabledMsg)
	}
	return nil
}

func isKVMDriverForNVIDIA(cc *config.ClusterConfig, name, _ string, _ *run.CommandOptions) error {
	if driver.IsKVM(cc.Driver) {
		return nil
	}
	out.Ln("")
	out.FailureT("The {{.addon}} addon is only supported with the KVM driver.\n\nFor GPU setup instructions see: https://minikube.sigs.k8s.io/docs/tutorials/nvidia/", out.V{"addon": name})
	return fmt.Errorf("%s addon is only supported with the KVM driver", name)
}

// isAarch64 is a validator that ensures the addon is only enabled on aarch64 architecture
func isAarch64(cc *config.ClusterConfig, name, _ string, _ *run.CommandOptions) error {
	if cc.KubernetesConfig.ImageRepository == "" {
		// Check the node's architecture
		for _, node := range cc.Nodes {
			if node.KubernetesVersion != "" {
				// We don't have direct access to arch here, so we check via the cluster config
				break
			}
		}
	}
	// The ZFS addon requires aarch64 architecture (ARM64)
	// This is because the ZFS-enabled ISO is only built for aarch64
	// TODO: When x86_64 ZFS ISO is available, remove this restriction
	out.Ln("")
	out.WarningT("The {{.addon}} addon is currently only supported on aarch64 (ARM64) architecture.", out.V{"addon": name})
	out.WarningT("Ensure you are running on an aarch64 system with a ZFS-enabled ISO.")
	return nil
}

// enableVolumesnapshotsIfNeeded auto-enables the volumesnapshots addon when zfs-localpv is enabled
func enableVolumesnapshotsIfNeeded(cc *config.ClusterConfig, _, value string, options *run.CommandOptions) error {
	isZfsEnabled, _ := strconv.ParseBool(value)
	if !isZfsEnabled {
		return nil
	}
	// Check if volumesnapshots is already enabled
	addonList := viper.GetStringSlice(config.AddonListFlag)
	isVolumesnapshotsEnabled := assets.Addons[volumesnapshotsAddon].IsEnabled(cc) || slices.Contains(addonList, volumesnapshotsAddon)
	if !isVolumesnapshotsEnabled {
		out.Ln("")
		out.Styled(style.AddonEnable, "Auto-enabling 'volumesnapshots' addon for ZFS snapshot support...")
		// Enable volumesnapshots addon
		if err := EnableOrDisableAddon(cc, volumesnapshotsAddon, "true", options); err != nil {
			return fmt.Errorf("failed to auto-enable volumesnapshots addon: %w", err)
		}
	}
	return nil
}

// isAddonValid returns the addon, true if it is valid
// otherwise returns nil, false
func isAddonValid(name string) (*Addon, bool) {
	for _, a := range Addons {
		if a.name == name {
			return a, true
		}
	}
	return nil, false
}
