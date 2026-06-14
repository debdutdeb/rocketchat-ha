Explaining running Rocket.Chat in HA across different kubernetes clusters.

This guide uses `k3d` or `k3s` to be specific to spin up the clusters.

`cilium` is used as the service mesh of choice.

### Quick start

Make sure `direnv` is installed <https://direnv.net/>. 

```sh
direnv allow . # installs cilium cli to _bin and adds to PATH
make clusters{,-connect} # create two clusters, look at cluster1.yaml and cluster2.yaml for the respective configurations, then connects both through cilium mesh
```

Check status using 
```sh
make cilium-status cilium-mesh-status
```

Optionally test connectivity (not just that all the stuff is *running*, making sure if all are talking to each other and working)
```sh
make cilium-connectivity-test # can take a long time
```


#### References:
1. <https://sandstorm.de/blog/posts/running-cilium-in-k3s-and-k3d-lightweight-kubernetes-on-mac-os-for-development>
2. <https://docs.cilium.io/en/stable/gettingstarted/k8s-install-default/#k8s-install-quick>