Rocket.Chat deployment, in a highly available architecture.

This guide is to illutrate the concepts behind a Rocket.Chat deployment in a highly available architecture. Most of the "high availability" concepts are achieved through infrastucture.

For hands-on experimentation this repo contains many pre written configurations for use.

This guide uses `k3d` or `k3s` to be specific to spin up the clusters.

Each cluster needs its own pod and service cidr.

For cross cluster communication, some sort of mesh implementation is required, I will be using `cilium` as the service mesh of choice.

Make sure `direnv` is installed <https://direnv.net/>. Run `direnv allow .` to set up the environment. Binaries are installed to `_bin` and added to `PATH`.

Also set up [k3d with image caching](https://github.com/RocketChat/k3d-with-registry) for quick turnarounds across iterations.

### Tl; Dr;

```sh
# same command if also want to redo the whole process
make destroyclusters clusters{,-connect} cilium-mesh-status nats-{install,restart,server-list} rocketchat-install
```

### High availability from infrastructure's perspective

In simple words, we need to have standby or redundant copies of the application running across multiple nodes across multiple availability blocks.

Availability blocks can be different locations in the same region or across multiple regions.

One common configuration is across multiple Kubernetes clusters in different availability blocks.

### High availability from application's perspective

Rocket.Chat uses
- MongoDB for data storage
- NATS for IPC

This guide does not cover MongoDB HA. To test this repo, you need to have a MongoDB cluster ready (HA or not).

Since our Helm chart deploys NATS and it's part of the application's IPC layer, an *example* NATS HA cluster setup is shown. You are free to approach it however else you want to.

Putting both together, we need all rocketchat processes to be able to communicate with one another through NATS, therefore each nats process needs to do the same for itself/its cluster members.

### Quick start

Create two Kubernetes clusters

```sh
make clusters
```

This simulates two clusters in two availability blocks.

Now establish network routing at pod level between the two clusters, for this we'll use cilium cni mesh.
```sh
make clusters-connect
```

Since on the same host, this will use `NodePort` and sharing the same bridge network to route the traffic. For production it depends on your network setup. E.g. using a VPN, private link if on AWS, simple physical line, etc.

Check if the clusters are connected by running:
```sh
make cilium-mesh-status cluster-connect-verify
```

This spins up an `nginx` pod on one cluster, attempts to connect to it from the other cluster.

Install nats, check cluster size
```sh
make nats-install nats-server-list
```

It'll install 3 instance nats cluster on each Kubernetes cluster. The output should be something like
```
╭────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╮
│                                                     Server Overview                                                    │
├─────────┬─────────┬──────┬─────────┬────┬───────┬───────┬────────┬─────┬─────────┬───────┬───────┬──────┬────────┬─────┤
│ Name    │ Cluster │ Host │ Version │ JS │ Conns │ Subs  │ Routes │ GWs │ Mem     │ CPU % │ Cores │ Slow │ Uptime │ RTT │
├─────────┼─────────┼──────┼─────────┼────┼───────┼───────┼────────┼─────┼─────────┼───────┼───────┼──────┼────────┼─────┤
│ nats2-1 │ nats-ha │ 0    │ 2.14.2  │ no │ 1     │ 330   │     18 │   0 │ 21 MiB  │ 0     │    16 │ 0    │ 30m55s │ 1ms │
│ nats1-1 │ nats-ha │ 0    │ 2.14.2  │ no │ 0     │ 330   │     18 │   0 │ 20 MiB  │ 1     │    16 │ 0    │ 31m40s │ 1ms │
│ nats2-2 │ nats-ha │ 0    │ 2.14.2  │ no │ 0     │ 330   │     19 │   0 │ 21 MiB  │ 0     │    16 │ 0    │ 31m7s  │ 1ms │
│ nats2-0 │ nats-ha │ 0    │ 2.14.2  │ no │ 0     │ 330   │     18 │   0 │ 20 MiB  │ 0     │    16 │ 0    │ 30m44s │ 1ms │
│ nats1-0 │ nats-ha │ 0    │ 2.14.2  │ no │ 0     │ 330   │     20 │   0 │ 21 MiB  │ 0     │    16 │ 0    │ 31m28s │ 1ms │
│ nats1-2 │ nats-ha │ 0    │ 2.14.2  │ no │ 0     │ 330   │     17 │   0 │ 21 MiB  │ 0     │    16 │ 0    │ 31m52s │ 1ms │
├─────────┼─────────┼──────┼─────────┼────┼───────┼───────┼────────┼─────┼─────────┼───────┼───────┼──────┼────────┼─────┤
│         │ 1       │ 6    │         │ 0  │ 1     │ 1,980 │      X │     │ 124 MiB │       │       │ 0    │        │     │
╰─────────┴─────────┴──────┴─────────┴────┴───────┴───────┴────────┴─────┴─────────┴───────┴───────┴──────┴────────┴─────╯

╭────────────────────────────────────────────────────────────────────────────╮
│                              Cluster Overview                              │
├─────────┬────────────┬───────────────────┬───────────────────┬─────────────┤
│ Cluster │ Node Count │ Outgoing Gateways │ Incoming Gateways │ Connections │
├─────────┼────────────┼───────────────────┼───────────────────┼─────────────┤
│ nats-ha │          6 │                 0 │                 0 │           1 │
├─────────┼────────────┼───────────────────┼───────────────────┼─────────────┤
│         │          6 │                 0 │                 0 │           1 │
╰─────────┴────────────┴───────────────────┴───────────────────┴─────────────╯
```

Total 6 instances.

At this point we are ready to deploy Rocket.Chat. Using our helm chart values
```yaml
nats:
  enabled: false
  existingSecret:
    name: nats-conn
    key: connectionString
microservices:
  enabled: true

ingress:
  enabled: true

existingMongodbSecret: mongodb-conn

host: rocketchat.internal
mongodb: {enabled: false}
persistence: {enabled: false }
```

Use the following command to deploy Rocket.Chat:
```sh
make rocketchat-install
```

Using external `NATS` and `MongoDB`.

Add a host entry to your `/etc/hosts` file to resolve `rocketchat.internal` to `127.0.0.1`. Rocket.Chat should be accessible at `http://rocketchat.internal:8001` AND `https://rocketchat.internal:8003`, each routing to the instance of the respective cluster but part of the same "Rocket.Chat Install".

A Loadbalancer will point to both clusters' entrypoints and balance traffic between them. If one region falls, or one cluster falls, the Loadbalancer will automatically route traffic to the other cluster.

#### References:
1. <https://sandstorm.de/blog/posts/running-cilium-in-k3s-and-k3d-lightweight-kubernetes-on-mac-os-for-development>
2. <https://docs.cilium.io/en/stable/gettingstarted/k8s-install-default/#k8s-install-quick>
3. <https://docs.cilium.io/en/stable/installation/kind/#cluster-mesh>
4. <https://docs.cilium.io/en/stable/installation/k3s/#install-cilium>
