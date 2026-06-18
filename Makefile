SHELL := /bin/bash
UNAME_S := $(shell uname -s)
INSTALL_CILIUM_DEPS := generate-ca
ifeq ($(UNAME_S),Darwin)
INSTALL_CILIUM_DEPS := prepare-clusters generate-ca
endif

LIST_CLUSTERS := clusters=($$(kubectl --kubeconfig kube.yaml config get-contexts -o name)); cluster1=$${clusters[0]}; cluster2=$${clusters[1]};
FOR_EACH_CLUSTER := kubectl --kubeconfig kube.yaml config get-contexts -o name | while read -r cluster; do

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
		docker exec $$container mount --make-shared /sys/fs/bpf; done

generate-ca:
	@echo "Generating a shared Root CA for the ClusterMesh..."
	@mkdir -p certs
	@openssl req -x509 -newkey rsa:4096 -nodes -keyout certs/ca.key -out certs/ca.crt -days 3650 \
		-subj "/CN=Cilium-ClusterMesh-Root-CA" 2>/dev/null

# --set clustermesh.apiserver.service.type=NodePort \
# --set clustermesh.apiserver.service.nodePort=$$nodeport; \
.PHONY: install-cilium
install-cilium: $(INSTALL_CILIUM_DEPS)
	# start from 1 because 0 is reserved, the error said so I don't know what its reserved for
	@id=1; cidrs=([1]="10.100.32.0/19" [2]="10.200.32.0/19"); \
	kubectl --kubeconfig kube.yaml config get-contexts -o name | while read -r cluster; do \
	  echo "Seeding shared CA and installing Cilium on $$cluster..."; \
	  cilium install --kubeconfig kube.yaml --context $$cluster \
	  	--set cluster.id=$$id --set cluster.name=$$(echo $$cluster | sed 's/k3d-//') \
		--set ipam.operator.clusterPoolIPv4PodCIDRList=$${cidrs[$$id]} \
		--set kubeProxyReplacement=true \
		--set ipam.mode=kubernetes \
		--set tls.ca.cert="$$(cat certs/ca.crt | base64 | tr -d '\n')" \
		--set tls.ca.key="$$(cat certs/ca.key | base64 | tr -d '\n')" \
		--set cgroup.autoMount.enabled=false \
		--set cgroup.hostRoot=/sys/fs/cgroup \
		--set tls.enabled=true; \
	  id=$$((id+1)); done

cilium-enable-hubble:
	@kubectl --kubeconfig kube.yaml config get-contexts -o name| while read -r cluster; do \
		cilium hubble enable --kubeconfig kube.yaml --context $$cluster; done

cilium-status:
	@kubectl --kubeconfig kube.yaml config get-contexts -o name| while read -r cluster; do \
		cilium status --kubeconfig kube.yaml --context $$cluster --wait; done

cilium-mesh-status:
	@kubectl --kubeconfig kube.yaml config get-contexts -o name | while read -r cluster; do \
		cilium clustermesh status --kubeconfig kube.yaml --context $$cluster --wait; done

cilium-connectivity-test:
	@kubectl --kubeconfig kube.yaml config get-contexts -o name | while read -r cluster; do \
		cilium connectivity test --kubeconfig kube.yaml --context $$cluster; done

cilium-enable-mesh:
	@kubectl --kubeconfig kube.yaml config get-contexts -o name | while read -r cluster; do \
		cilium clustermesh enable --kubeconfig kube.yaml --context $$cluster --service-type NodePort; done

clusters-connect: install-cilium cilium-status cilium-enable-mesh cilium-mesh-status clusters-connect-only cilium-mesh-status clusters-connect-verify

clusters-connect-only:
	@clusters=($(shell kubectl --kubeconfig kube.yaml config get-contexts -o name)); \
		echo "Connecting $${clusters[0]} to $${clusters[1]}"; \
		cilium clustermesh connect \
			--context "$${clusters[0]}" \
			--destination-context "$${clusters[1]}" \
			--kubeconfig kube.yaml

clusters-connect-verify:
	@true; \
	$(LIST_CLUSTERS) \
		kubectl apply -f manifests/web.yaml --context $$cluster1; \
		kubectl apply -f manifests/service.yaml --context $$cluster1; \
		kubectl apply -f manifests/service.yaml --context $$cluster2; \
		kubectl --kubeconfig kube.yaml --context $$cluster1 rollout status deployment/web --timeout=60s; \
		count=0; \
		while ! kubectl --kubeconfig kube.yaml --context $$cluster2 \
			run mesh-client -it --rm \
			--image=curlimages/curl --restart=Never -- \
			curl -vvv http://web; do \
				echo "[ERROR][$$count] $$cluster2 failed to reach nginx running on $$cluster1"; \
				count=$$((count+1)); \
				if ((count==10)); then echo "[ERROR] exhausted max retry attempts (5)"; else sleep 5s; continue; fi; \
				exit 1; done; \
		echo "[SUCCESS] $$cluster2 reached nginx running on $$cluster1"; \
		kubectl delete -f manifests/web.yaml --context $$cluster1; \
		kubectl delete -f manifests/service.yaml --context $$cluster1; \
		kubectl delete -f manifests/service.yaml --context $$cluster2

downclusters:
	@k3d cluster stop -c cluster1.yaml
	@k3d cluster stop -c cluster2.yaml

destroyclusters:
	@k3d cluster delete -c cluster1.yaml
	@k3d cluster delete -c cluster2.yaml
	@rm -rf certs {kube,cluster{1,2}}.yaml

nats-install:
	@true; \
	$(LIST_CLUSTERS) \
	kubectl apply -f manifests/nats-service.yaml --kubeconfig kube.yaml --context $$cluster1; \
	kubectl apply -f manifests/nats-service.yaml --kubeconfig kube.yaml --context $$cluster2
	@id=1; \
	$(FOR_EACH_CLUSTER) \
	helm upgrade nats$$id nats --repo https://nats-io.github.io/k8s/helm/charts -n nats --create-namespace \
		-f values/nats.yaml --install --kube-context $$cluster --kubeconfig kube.yaml; id=$$((id+1)); done

nats-uninstall:
	@id=1; \
	$(FOR_EACH_CLUSTER) \
	helm uninstall nats$$id -n nats --kube-context $$cluster --kubeconfig kube.yaml; kubectl delete namespace nats --kubeconfig kube.yaml --context $$cluster; id=$$((id+1)); done

nats-restart:
	@id=1; \
	$(FOR_EACH_CLUSTER) \
	kubectl rollout restart sts nats$$id -n nats --kubeconfig kube.yaml --context $$cluster && kubectl rollout status sts nats$$id -n nats --kubeconfig kube.yaml --context $$cluster; id=$$((id+1)); done

nats-expose-1:
	@true; \
	$(LIST_CLUSTERS) \
	kubectl port-forward --context $$cluster1 --kubeconfig kube.yaml svc/nats1 -n nats 4222:4222
nats-expose-2:
	@true; \
	$(LIST_CLUSTERS) \
	kubectl port-forward --context $$cluster2 --kubeconfig kube.yaml svc/nats2 -n nats 4222:4222

nats-server-list:
	@id=1; \
	$(FOR_EACH_CLUSTER) \
	kubectl exec deploy/nats$$id-box -n nats --kubeconfig kube.yaml --context $$cluster -- nats server list --user admin --password adminpassword; id=$$((id+1)); done

rocketchat-install:
	@:; \
	if [[ -z "$$MONGODB_URL" ]]; then echo "[ERROR] MONGODB_URL environment variable needs to be set"; exit 1; fi; \
	$(FOR_EACH_CLUSTER) \
	envsubst < manifests/mongodb-conn-secret.yaml | kubectl --kubeconfig kube.yaml --context $$cluster apply -f -; \
	kubectl --kubeconfig kube.yaml --context $$cluster apply -f manifests/nats-conn-secret.yaml; \
	helm upgrade --install --repo https://rocketchat.github.io/helm-charts rocketchat rocketchat -f values/rocketchat.yaml --namespace rocketchat --create-namespace --kubeconfig kube.yaml --kube-context $$cluster; done

rocketchat-uninstall:
	@:; \
	$(FOR_EACH_CLUSTER) \
	helm uninstall rocketchat --namespace rocketchat --kubeconfig kube.yaml --kube-context $$cluster; \
	kubectl --kubeconfig kube.yaml --context $$cluster delete namespace rocketchat || :; done

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

.PHONY: config clusters downclusters destroyclusters help cilium-cgroupv2 prepare-clusters install-cilium cilium-enable-mesh cilium-enable-hubble cilium-status cilium-connectivity-test install-cilium clusters-connect-verify nats-install nats-uninstall nats-expose-1 nats-expose-2 nats-restart nats-server-list rocketchat-install
