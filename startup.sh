#!/bin/bash
#kind create cluster --config kind-calico.yaml
kubectl create ns router

# Kubevirt
export VERSION=$(curl -s https://api.github.com/repos/kubevirt/kubevirt/releases | grep tag_name | grep -v -- '-rc' | sort -r | head -1 | awk -F': ' '{print $2}' | sed 's/,//' | xargs)
echo $VERSION
kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/${VERSION}/kubevirt-operator.yaml
kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/${VERSION}/kubevirt-cr.yaml
sleep 5
kubectl get kubevirt.kubevirt.io/kubevirt -n kubevirt
sleep 5
while test -z "$(kubectl get kubevirt.kubevirt.io/kubevirt -n kubevirt -o=jsonpath='{.status.phase}')";
do
  kubectl get kubevirt.kubevirt.io/kubevirt -n kubevirt -o=jsonpath='{.status.phase}'
done
echo "Waiting 60s"
sleep 60
while test $(kubectl get kubevirt.kubevirt.io/kubevirt -n kubevirt -o=jsonpath="{.status.phase}") != Deployed;
do
 sleep 10
 echo -n .
done

export VERSION=$(curl -s https://github.com/kubevirt/containerized-data-importer/releases/latest | grep -o "v[0-9]\.[0-9]*\.[0-9]*")
echo "CDI Version: $VERSION"
kubectl apply -f https://github.com/kubevirt/containerized-data-importer/releases/download/$VERSION/cdi-operator.yaml
kubectl apply -f https://github.com/kubevirt/containerized-data-importer/releases/download/$VERSION/cdi-cr.yaml
sleep 5

#kubectl patch -n kubevirt kubevirt kubevirt --type='json' -p='[{"op": "add", "path": "/spec/configuration/developerConfiguration/featureGates/0", "value": "Macvtap" }]'

## Multus
kubectl apply -f https://raw.githubusercontent.com/intel/multus-cni/master/deployments/multus-daemonset.yml
sleep 5

# koko
#export VERSION=$(curl -s https://api.github.com/repos/redhat-nfvpe/koko/releases | grep tag_name | grep -v -- '-rc' | sort -r | head -1 | awk -F': ' '{print $2}' | sed 's/,//' | xargs)
#curl -L -o koko https://github.com/redhat-nfvpe/koko/releases/download/${VERSION}/koko_${VERSION#v}_linux_amd64
#chmod +x koko
#sudo ./koko -d kind-worker,eth1 -d kind-worker2,eth1

# cni
export VERSION=$(curl -s https://api.github.com/repos/containernetworking/plugins/releases | grep tag_name | grep -v -- '-rc' | sort -r | head -1 | awk -F': ' '{print $2}' | sed 's/,//' | xargs)
export VERSION_OVS=$(curl -s https://api.github.com/repos/k8snetworkplumbingwg/ovs-cni/releases | grep tag_name | grep -v -- '-rc' | sort -r | head -1 | awk -F': ' '{print $2}' | sed 's/,//' | xargs)
cat << EOF | kubectl apply -f -
---
kind: ConfigMap
apiVersion: v1
metadata:
  name: cni-install-sh
  namespace: kube-system
data:
  install_cni.sh: |
    cd /tmp
    wget https://github.com/containernetworking/plugins/releases/download/${VERSION}/cni-plugins-linux-amd64-${VERSION}.tgz
    cd /host/opt/cni/bin
    tar xvfzp /tmp/cni-plugins-linux-amd64-${VERSION}.tgz
    wget https://github.com/k8snetworkplumbingwg/ovs-cni/releases/download/${VERSION_OVS}/ovs
    chmod +x ovs
    sleep infinite
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: install-cni-plugins
  namespace: kube-system
  labels:
    name: cni-plugins
spec:
  selector:
    matchLabels:
      name: cni-plugins
  template:
    metadata:
      labels:
        name: cni-plugins
    spec:
      hostNetwork: true
      nodeSelector:
        kubernetes.io/arch: amd64
      tolerations:
      - operator: Exists
        effect: NoSchedule
      containers:
      - name: install-cni-plugins
        image: alpine
        command: ["/bin/sh", "/scripts/install_cni.sh"]
        resources:
          requests:
            cpu: "100m"
            memory: "50Mi"
          limits:
            cpu: "100m"
            memory: "50Mi"
        securityContext:
          privileged: true
        volumeMounts:
        - name: cni-bin
          mountPath: /host/opt/cni/bin
        - name: scripts
          mountPath: /scripts
      volumes:
        - name: cni-bin
          hostPath:
            path: /opt/cni/bin
        - name: scripts
          configMap:
            name: cni-install-sh
            items:
            - key: install_cni.sh
              path: install_cni.sh
EOF
sleep 5
cat <<EOF | kubectl apply -f -
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: ovs-net-1
  namespace: router
  annotations:
    k8s.v1.cni.cncf.io/resourceName: ovs-cni.network.kubevirt.io/br1
spec:
  config: '{
      "cniVersion": "0.4.0",
      "type": "ovs",
      "bridge": "br1",
      "vlan": 100,
      "ipam": {
        "type": "host-local",
        "ranges": [
         [ {
           "subnet": "10.10.0.0/24",
           "rangeStart": "10.10.0.20",
           "rangeEnd": "10.10.0.50",
           "gateway": "10.10.0.254"
         } ]
        ]
      }
    }'
EOF
cat <<EOF | kubectl apply -f -
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: macvlan-conf-1
  namespace: router
spec:
  config: '{
            "cniVersion": "0.3.0",
            "type": "macvlan",
            "mode": "bridge",
            "ipam": {
                "type": "host-local",
                "ranges": [
                    [ {
                         "subnet": "10.10.0.0/16"
                    } ]
                ]
            }
        }'
EOF
#          "master": "eth0",
#                         "rangeStart": "10.10.1.20",
#                         "rangeEnd": "10.10.3.50",
#                         "gateway": "10.10.0.254"
cat <<EOF | kubectl apply -f -
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: br-conf-1
  namespace: router
spec:
  config: '{
            "cniVersion": "0.3.1",
            "type": "bridge",
            "bridge": "bridge0",
            "isDefaultGateway": false,
            "ipMasq": false,
            "ipam": {
                "type": "host-local",
                "ranges": [ [ {
                  "subnet": "10.10.0.0/16",
                  "gateway": "10.10.0.2"
                } ] ]
            }
        }'
EOF
cat <<EOF | kubectl apply -f -
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: br-wan-conf-1
  namespace: router
spec:
  config: '{
            "cniVersion": "0.3.1",
            "type": "bridge",
            "bridge": "wanbr0",
            "isDefaultGateway": true,
            "ipMasq": true,
            "ipam": {
                "type": "host-local",
                "ranges": [ [ {
                  "subnet": "10.11.0.0/16",
                  "gateway": "10.11.0.254"
                } ] ]
            }
        }'
EOF
exit

# VMs
./deploy.sh
