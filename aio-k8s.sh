#!/bin/bash

usage () {
  echo "Usage:"
  echo "   ./master.sh <HOST_IP>"
  exit 1
}

docker_login () {

        echo "Dockerhub uname:"
        read DOCKER_UNAME
        echo ""Dockerhub passwd:
        read -s DOCKER_PASSWD
        if [ -z "$DOCKER_UNAME" ]; then
                echo "Docker user name is not provided. Skip Docker Hub login"
        else
                docker logout
                docker login -u $DOCKER_UNAME -p $DOCKER_PASSWD
        fi

}

enable_k8s_cli () {
	echo "---> Enabling kubectl CLI"
	mkdir -p $HOME/.kube
	rm -rf $HOME/.kube/*
	sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
	sudo chown $(id -u):$(id -g) $HOME/.kube/config
}

save_info () {
echo	
echo "---> Save cluster info"
sleep 1
read -p "Cluster master's IP address: " MASTER_IP
read -p "Cluster join TOKEN: " CLUSTER_TOKEN
read -p "Cluster discovery-token-ca-cert-hash: " CLUSTER_CERT
mkdir -p $HOME/k8s
echo "kubeadm join $MASTER_IP:6443 --token $CLUSTER_TOKEN --discovery-token-ca-cert-hash $CLUSTER_CERT" > $HOME/k8s/info

}

dns_configure () {
echo
echo "---> Configure systemd DNS conf"

sed -i '/\[Service\]/a Environment="KUBELET_EXTRA_ARGS=--resolv-conf=\/run\/systemd\/resolve\/resolv.conf"' /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
systemctl daemon-reload
service kubelet restart
kubectl delete pod -n kube-system `kubectl get pod -n kube-system|grep "coredns"|awk '{print $1}'`
sleep 3
}

install_calico () {
	echo "---> Install Calico"
	docker pull docker.io/calico/node:v3.19.1 
	docker pull docker.io/calico/cni:v3.19.1
	docker pull docker.io/calico/pod2daemon-flexvol:v3.19.1
	docker pull docker.io/calico/typha:v3.19.1
	docker pull docker.io/calico/kube-controllers:v3.19.1

	sleep 1
	kubectl create -f https://docs.projectcalico.org/manifests/tigera-operator.yaml
	kubectl create -f https://docs.projectcalico.org/manifests/custom-resources.yaml
	sleep 5
	kubectl wait --timeout=20s --for=condition=ready pod -l k8s-app=calico-kube-controllers -n calico-system
	#wait until calico is running
}

install_MetalLB () {
echo "---> Install MetalLB"
sleep 1
cd /root; mkdir metalLB; cd metalLB
wget https://raw.githubusercontent.com/google/metallb/v0.8.1/manifests/metallb.yaml
kubectl apply -f ./metallb.yaml
sleep 5
#configMap
echo "---> create and apply configmap for metalLB"
touch metalLB_conf.yaml
cat <<EOF >./metalLB_conf.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: metallb-system
  name: config
data:
  config: |
    address-pools:
    - name: default
      protocol: layer2
      addresses:
      - ${HOST_IP%.*}.244-${HOST_IP%.*}.254
EOF

	kubectl apply -f ./metalLB_conf.yaml
	sleep 3
}

cli_alias () {
echo "---> Customise kubectl CLI alias"
sleep 2
cat <<-'EOF'>>/root/.bashrc
alias kt='kubectl'
alias ktp='kubectl get pod -o wide'
alias kts='kubectl get svc -o wide'
alias ktd='kubectl get deployment -o wide'
alias ktn='kubectl get node -o wide'
alias ktv='kubectl get pv -o wide'
alias ktvc='kubectl get pvc -o wide'
PS1="\[\033[32m\][\u@\h \w]:\[\033[37m\]"
EOF

#source $HOME/.bashrc
}

#AIO deployment summary

summary () {
	echo "------------------------------------------------------"
	echo "------------- K8S AIO deployment summary -------------"
	echo "------------------------------------------------------"
	echo "---> Installed Git"
	echo "---> Installed Docker CE"
	echo "---> Installed kubeadm, kubectl, kubelet"
	echo "---> Installed Calico CNI"
	echo "---> Created and ran an example \"hello\" service "
	echo "---> Customised P1 prompt style and created kubectl alias"
}

hello_example () {
cat <<EOF > /root/k8s/tutum-hello-service.yaml
---
kind: Service
apiVersion: v1
metadata:
  name: tutum-hello-service
spec:
  selector:
    app: tutum-hello
  ports:
    - protocol: "TCP"
      # Port accessible inside cluster
      port: 8081
      # Port to forward to inside the pod
      targetPort: 80
      # Port accessible outside cluster
      nodePort: 30001
  type: NodePort
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tutum-hello-deployment
spec:
  selector:
    matchLabels:
      app: tutum-hello
  replicas: 1
  template:
    metadata:
      labels:
        app: tutum-hello
    spec:
      #hostNetwork: true
      containers:
        - name: my-tutum-hello
          image: tutum/hello-world
          ports:
            - containerPort: 80
EOF

kubectl apply -f /root/k8s/tutum-hello-service.yaml
echo "---> Deploying an example service: tutum-hello"
sleep 5
#kubectl wait --timeout=10s --for=condition=ready pod -l app=tutum-hello
#curl $HOST_IP:30001

}

ubuntu_example () {
cat <<EOF > /root/k8s/ubuntu-service.yaml
---
kind: Service
apiVersion: v1
metadata:
  name: ubuntu-fe
spec:
  selector:
    app: ubuntu
  ports:
    - name: ssh
      protocol: "TCP"
      # Port accessible inside cluster
      port: 422
      # Port to forward to inside the pod
      targetPort: ssh-port
      # Port accessible outside cluster
      nodePort: 30022
    - name: tcp
      protocol: "TCP"
      # Port accessible inside cluster
      port: 471
      # Port to forward to inside the pod
      targetPort: tcp-port
      # Port accessible outside cluster
      nodePort: 30071
    - name: udp
      protocol: "UDP"
      # Port accessible inside cluster
      port: 473
      # Port to forward to inside the pod
      targetPort: udp-port
      # Port accessible outside cluster
      nodePort: 30073
  type: NodePort  #LoadBalancer
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ubuntu
  labels:
    app: ubuntu
spec:
  selector:
    matchLabels:
      app: ubuntu
  replicas: 1
  template:
    metadata:
      labels:
        app: ubuntu
    spec:
      containers:
      - name: ubuntu
        image: gitlab-registry.eps.surrey.ac.uk/noc/ubuntu:ping
        command: ["sh", "-c", "while true; do sleep 3600; done"]
        ports:
        - name: ssh-port
          containerPort: 22
        - name: tcp-port
          containerPort: 71
        - name: udp-port
          containerPort: 73
        imagePullPolicy: IfNotPresent
      restartPolicy: Always

EOF
kubectl apply -f /root/k8s/ubuntu-service.yaml
echo "---> Deploying an example service: ubuntu"
sleep 5
#kubectl wait --timeout=10s --for=condition=ready pod -l app=ubuntu
kubectl exec `kubectl get pod |grep "ubuntu"|awk '{print $1}'` -- ping -c3 google.com
sleep 3
}

#check argument
if [ $# -eq 1 ]
then
	if [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
	then
		echo "Argument checking: success"
		HOST_IP=$1
	else
		echo "Argument checking: failed"
		echo -n "The argument \""; echo -n $1; echo "\" is not in IP4 format: 255.255.255.255"
		exit 1
fi
else
	echo "The script takes 1 argument only"
	usage
fi


# update system
apt update -y; apt dist-upgrade -y
mkdir -p /root/k8s
# check docker installation
echo "---> Install Docker"
apt-get remove docker docker-engine docker.io containerd runc



apt install -y curl gnupg2 lsb-release apt-transport-https ca-certificates
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
#curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
#sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
echo \
  "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
sudo apt install -y containerd.io docker-ce docker-ce-cli
mkdir -p /etc/systemd/system/docker.service.d

# Create daemon json config file
sudo tee /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF

#uncomment DNS setting for Docker to use
sed -i '/--dns 8.8.8.8/s/^#//g' /etc/default/docker 
# Start and enable Services
sudo systemctl daemon-reload 
sudo systemctl restart docker
sudo systemctl enable docker


DOCKER_VERSION="$(docker version|grep -m1 "Version"|awk '{print $2}')"
if [ $? -eq 0 ]
then
	echo -n "The current Docker version is: "; echo $DOCKER_VERSION 
	echo "Suggested Docker version 18.09 and above."
	sleep 2
else
	echo "Install Docker CE"
	sleep 1
#	apt install -y docker.io apt-transport-https curl
#	systemctl enable docker.service
fi
sleep 2
#install git
apt install git

# enable SSH tunnel
apt install -y openssh-server
echo "PermitTunnel yes">> /etc/ssh/sshd_config
service sshd restart

#preparation
echo "---> Turn off swap"
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
swapoff -a

sleep 1

#install k8s
echo "---> Install k8s"; sleep 1
#curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg
echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee /etc/apt/sources.list.d/kubernetes.list

#echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee /etc/apt/sources.list.d/kubernetes.list

apt update; apt dist-upgrade -y
apt install -y kubelet kubeadm kubectl --allow-change-held-packages
apt-mark hold kubelet kubeadm kubectl
#

#echo "Environment=\"cgroup-driver=systemd/cgroup-driver=cgroupfs\"" >> /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
echo "Do you need to reset k8s?"
select yn in "Yes" "No"; do
    case $yn in
        Yes ) echo;echo "----> For a known issue of kubelet reset, you have to run \"kubeadm reset\" manually. Exit..."; break;;
        No ) echo "Skip k8s reset";break;;
    esac
done
sleep 1

#mkdir kube-cluster
cat <<EOF > /root/k8s/kubeadm-controlplane-config.yaml
---
apiVersion: kubeadm.k8s.io/v1beta2
kind: ClusterConfiguration
kubernetesVersion: v1.21.0
apiServer:
  certSANs:
  - "${HOST_IP}"
controlPlaneEndpoint: ${HOST_IP}:6443
networking:
  podSubnet: 192.168.0.0/16
---
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
cgroupDriver: systemd

EOF

echo "---> Initialise k8s cluster: kubeadm init"
kubeadm init --config=/root/k8s/kubeadm-controlplane-config.yaml --upload-certs
#save_info

enable_k8s_cli
#configure systemd DNS
dns_configure
#label aio node
kubectl label nodes $HOSTNAME kubernetes.io/role=aio

#untaint the aio node
kubectl taint nodes $HOSTNAME node-role.kubernetes.io/master-
#kubectl taint nodes $HOSTNAME key:NoSchedule-

#enable cli alias
echo "Do you wish to add kubectl alias into .bashrc?"
select yn in "Yes" "No"; do
    case $yn in
        Yes ) cli_alias; source $HOME/.bashrc;  break;;
        No ) echo "Skip adding kubect alias";break;;
    esac
done
sleep 1

#install CNI
docker_login
if [ $? -eq 0 ]; then
        echo "Login is successful"
else
        echo "Docker Hub Login NOT successful. Please try again"
        docker_login
        if [ $? -eq 0 ]; then
                echo "Login is successful"
        else
                echo "Docker Hub login failed. Please use correct username and password to try again. Exit..."
                exit 1
        fi
fi

install_calico
#wait for calico to be ready
kubectl wait --for=condition=available --timeout=5s deployment/calico-kube-controllers -n calico-system
kubectl get pod -n calico-system
#install metal LB
#install_MetalLB
sleep 5


#summary
summary

sleep 3
echo
echo "------> Do you wish to deploy example services?"
select svc in "hello" "ubuntu" "both" "neither"; do
    case $svc in
        hello ) 
		hello_example 
		break
		;;
        ubuntu ) 
		ubuntu_example 
		break
		;;
        both ) 
		hello_example 
		ubuntu_example 
		curl $HOST_IP:30001
		break
		;;
        neither ) 
		echo "Skip deploying tutum-hello service"
		break
		;;
    esac
done
kubectl get node
NODE_STATUS=$(kubectl get node|grep "$HOSTNAME"|awk '{print $2}')
if [ $NODE_STATUS = "Ready" ]; then
        echo "Congratulations! Cluster node is added successfully."
fi

exit 1