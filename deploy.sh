#!/bin/bash
# exit if any command fails
set -e

#Create CA and gluu keys/certificates if they don't exist
mkdir -p ./certs
if [ ! -f ./certs/RootCA.key ]
then
  echo "Creating RootCA.key"
  openssl genrsa -des3 -out ./certs/RootCA.key 2048
else
  echo "RootCA.key already exists... skipping"
fi

if [ ! -f ./certs/RootCA.pem ]
then
  echo "Creating RootCA.pem"
  openssl req -x509 -new -nodes -key ./certs/RootCA.key -sha256 -days 1825 -out ./certs/RootCA.pem \
  -subj "/C=US/ST=IN/L=Indianapolis/O=Salesforce/OU=VIPS/CN=RootCA.local"
else
  echo "RootCA.pem already exists... skipping"
fi

if [ ! -f ./certs/ou.key ]
then
  echo "Creating ou.key"
  openssl genrsa -out ./certs/ou.key 2048
else
  echo "ou.key already exists... skipping"
fi

if [ ! -f ./certs/ou.pem ]
then
  echo "Creating ou.csr"
  openssl req -new -key ./certs/ou.key -out ./certs/ou.csr -subj "/C=US/ST=IN/L=Indianapolis/O=Salesforce/OU=VIPS/CN=k8sou.local.dev"
  cat << EOF > ./certs/ou.ext
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = k8sou.local.dev
DNS.2 = k8sdb.local.dev
EOF

  echo "Creating ou.pem"
  openssl x509 -req -in ./certs/ou.csr -CA ./certs/RootCA.pem -CAkey ./certs/RootCA.key -CAcreateserial -sha256 -days 1825 -out ./certs/ou.pem -extfile ./certs/ou.ext
else
  echo "ou.pem already exists... skipping"
fi

# Validate the gluu/CA
#TODO

# Create chain.pem
if [ ! -f ./certs/chain.pem ]
then
  echo "Creating the chain"
  cat ./certs/ou.pem ./certs/RootCA.pem > ./certs/chain.pem
else
  echo "chain.pem already exists... skipping"
fi

# Add/update temelo helm repo
echo "Updating helm repos"
helm repo add tremolo https://nexus.tremolo.io/repository/helm/
helm repo update

# Check for minikube
if [ ! "$(which minikube)" ]
then
  echo "minikube isn't installed."
  echo "Install with 'brew install minikube'"
  exit
else
  echo "minikube found... checking status."

  if [ "$(minikube status -o json | jq -r .Host)" == "Running" ]
  then
    echo "minikube is running."
  else
    echo "Copying ./certs/RootCA.pem to ~/.minikube/certs/"
    cp ./certs/RootCA.pem ~/.minikube/certs/
    echo "minikube isn't running.  Starting now..."
    minikube start --kubernetes-version='1.21.13' \
    --driver=vmware --memory 8192 --cpus 4 \
    --extra-config=apiserver.oidc-issuer-url=https://k8sou.local.dev/auth/idp/k8sIdp \
    --extra-config=apiserver.oidc-client-id=kubernetes \
    --extra-config=apiserver.oidc-username-claim=sub \
    --extra-config=apiserver.oidc-groups-claim=groups \
    --extra-config=apiserver.oidc-username-prefix=oidc: \
    --extra-config=apiserver.oidc-ca-file=/etc/ssl/certs/cacert.pem \
    --embed-certs
    minikube addons enable ingress
  fi
fi

# Install the k8s dashboard
echo "Installing k8s dashboard"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.5.0/aio/deploy/recommended.yaml

if [ ! -f ./ouctl ]
then
  echo "Getting ouctl from https://nexus.tremolo.io/repository/ouctl/ouctl-0.0.2-macos"
  wget -O ouctl --quiet https://nexus.tremolo.io/repository/ouctl/ouctl-0.0.2-macos
  chmod +x ./ouctl
else
  echo "ouctl already exists... skipping"
fi

if [ ! -f ./openunison-default.yaml ]
then
  echo "Getting values.yaml from https://openunison.github.io/assets/yaml/openunison-default.yaml"
  wget https://openunison.github.io/assets/yaml/openunison-default.yaml --quiet
else
  echo "openunison-default.yaml already exists... skipping"
fi

# update values.yaml for local deploy
# Replacements
sed  "
s/k8sou.apps.ou.tremolo.dev/k8sou.local.dev/
s/k8sdb.apps.ou.tremolo.dev/k8sdb.local.dev/
s|k8s_url:.*|k8s_url: https://$(minikube ip):8443|
s/createIngressCertificate: true/createIngressCertificate: false/
s/#saml:/saml:/
s|#  idp_url:.*|  idp_url: \"https://portal.apps.tremolo.io/idp-test/metadata/0c7e8a27-5e34-4d48-82df-b078a766f06b\"|
" openunison-default.yaml > values.yaml

# Removals
sed -i "" "/- name: ldaps/,+1d" values.yaml

# Additions
sed -i "" "/trusted_certs:/a\\
  - name: unison-ca
" values.yaml

sed -i "" "/  - name: unison-ca/a\\
    pem_b64: CERT_CHAIN_BASE64
" values.yaml

# Replacements
sed  -i "" "
s|pem_b64: CERT_CHAIN_BASE64|pem_b64: $(base64 ./certs/chain.pem)|
" values.yaml

# Create namespace and tls secret
if [ ! "$(kubectl get namespace openunison)" ]
then
  kubectl create namespace openunison
else
  echo openunison namespace already exists... skipping
fi

if [ ! "$(kubectl get secret -n openunison ou-tls-certificate)" ]
then
  kubectl create secret tls ou-tls-certificate --cert=./certs/chain.pem --key=./certs/ou.key -n openunison
else
  echo ou-tls-certificate secret already exists... skipping
fi

# Update coredns configmap to include hosts entries that will resolve lookups internal to k8s, for the
# k8sou and k8sdb to the IP address of the ingress-nginx-controller service.
# Patch the coredns configmap (instead of manual kubectl edit configmaps -n kube-system coredns)

# Get the IP for the svc
ingress_svc=$(kubectl get service -n ingress-nginx ingress-nginx-controller -o json | jq -r '.spec.clusterIP')
# Get the initial corefile
corefile=$(kubectl get configmaps -n kube-system coredns -o json | jq -r .data.Corefile)
# Update $corefile with the dns entries
corefile=$(sed "/hosts/a\\
       $ingress_svc k8sdb.local.dev
" <<< "$corefile")

corefile=$(sed "/hosts/a\\
       $ingress_svc k8sou.local.dev
" <<< "$corefile")

./ouctl install-auth-portal values.yaml

# Create role bindings (1 restricted and 1 admin)

# Display the xml metadata on the screen
echo; echo
echo "You'll need the followiing medadata for your SAML2 provider (probably)."
echo
curl -k https://k8sou.local.dev/auth/forms/saml2_rp_metadata.jsp
echo; echo
