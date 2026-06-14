SHELL := /bin/bash
UNAME_S := $(shell uname -s)
INSTALL_CILIUM_DEPS := generate-ca
ifeq ($(UNAME_S),Darwin)
INSTALL_CILIUM_DEPS := prepare-clusters generate-ca
endif

cilium-cgroupv2:
	@mkdir -p /run/cilium/cgroupv2
	@mount -t cgroup2 none /run/cilium/cgroupv2
	@mount --make-shared /run/cilium/cgroupv2/

config:
	@kustomize build clusters/cluster1 -o cluster1.yaml
	@kustomize build clusters/cluster2 -o cluster2.yaml

clusters: config
	@k3d cluster create -c cluster1.yaml
	@k3d cluster create -c cluster2.yaml
	@k3d kubeconfig merge cluster1 cluster2 -o kube.yaml
	
# for macos
prepare-clusters:
	@for container in $(shell docker ps -q --filter "name=k3d-cluster"); do \
		docker exec $$container mount bpffs -t bpf /sys/fs/bpf; \
		docker exec $$container mount --make-shared /sys/fs/bpf; \
		docker exec $$container mkdir -p /run/cilium/cgroupv2; \
		docker exec $$container mount -t cgroup2 none /run/cilium/cgroupv2; \
		docker exec $$container mount --make-shared /run/cilium/cgroupv2; done
	
generate-ca:
	@echo "Generating a shared Root CA for the ClusterMesh..."
	@mkdir -p certs
	@openssl req -x509 -newkey rsa:4096 -nodes -keyout certs/ca.key -out certs/ca.crt -days 3650 \
		-subj "/CN=Cilium-ClusterMesh-Root-CA" 2>/dev/null
	
install-cilium: $(INSTALL_CILIUM_DEPS)
	# start from 1 because 0 is reserved, the error said so I don't know what its reserved for
	@id=1; nodeport=32379; \
	for cluster in $(shell kubectl --kubeconfig kube.yaml config get-contexts -o name); do \
	  echo "Seeding shared CA and installing Cilium on $$cluster..."; \
	  cilium install --version 1.19.3 --kubeconfig kube.yaml --context $$cluster \
	  	--set cluster.id=$$id --set cluster.name=$$(echo $$cluster | sed 's/k3d-//') \
	  	--set tls.ca.cert="$$(cat certs/ca.crt | base64 | tr -d '\n')" \
	  	--set tls.ca.key="$$(cat certs/ca.key | base64 | tr -d '\n')" \
		--set clustermesh.apiserver.service.type=NodePort \
		--set clustermesh.apiserver.service.nodePort=$$nodeport \
	  	--set tls.enabled=true; \
	  id=$$((id+1)); nodeport=$$((nodeport+1)); done
	
cilium-enable-hubble:
	@for cluster in $(shell kubectl --kubeconfig kube.yaml config get-contexts -o name); do \
		cilium hubble enable --kubeconfig kube.yaml --context $$cluster; done
	
cilium-status:
	@for cluster in $(shell kubectl --kubeconfig kube.yaml config get-contexts -o name); do \
		cilium status --kubeconfig kube.yaml --context $$cluster --wait; done
	
cilium-mesh-status:
	@for cluster in $(shell kubectl --kubeconfig kube.yaml config get-contexts -o name); do \
		cilium clustermesh status --kubeconfig kube.yaml --context $$cluster --wait; done
	
cilium-connectivity-test:
	@for cluster in $(shell kubectl --kubeconfig kube.yaml config get-contexts -o name); do \
		cilium connectivity test --kubeconfig kube.yaml --context $$cluster; done
	
cilium-enable-mesh:
	@for cluster in $(shell kubectl --kubeconfig kube.yaml config get-contexts -o name); do \
		cilium clustermesh enable --kubeconfig kube.yaml --context $$cluster --service-type NodePort; done
	
clusters-connect: install-cilium cilium-status cilium-enable-mesh cilium-mesh-status clusters-connect-only

clusters-connect-only:
	@clusters=($(shell kubectl --kubeconfig kube.yaml config get-contexts -o name)); \
		echo "Connecting $${clusters[0]} to $${clusters[1]}"; \
		cilium clustermesh connect $${clusters[0]} $${clusters[1]} --kubeconfig kube.yaml

downclusters:
	@k3d cluster stop -c cluster1.yaml
	@k3d cluster stop -c cluster2.yaml
	
destroyclusters:
	@k3d cluster delete -c cluster1.yaml
	@k3d cluster delete -c cluster2.yaml
	@rm -rf certs {kube,cluster{1,2}}.yaml

help:
	@echo "Usage: make <target>"
	@echo "Targets:"
	@echo "  clusters: Create clusters"
	@echo "  downclusters: Down clusters"
	@echo "  destroyclusters: Destroy clusters"
	@echo "  prepare-clusters: Prepare clusters for cilium"
	@echo "  install-cilium: Install cilium on clusters"
	@echo "  enable-cilium-hubble: Enable Hubble on clusters"
	@echo "  cilium-status: Check status of cilium on clusters"
	@echo "  cilium-connectivity-test: Test connectivity of cilium on clusters (can take a long time)"
	@echo "  cilium-enable-mesh: Enable clustermesh on clusters"
	@echo "  cilium-enable-hubble: Enable Hubble on clusters"
	@echo "  help: Show this help message"

.PHONY: config clusters downclusters destroyclusters help cilium-cgroupv2 prepare-clusters install-cilium cilium-enable-mesh cilium-enable-hubble cilium-status cilium-connectivity-test