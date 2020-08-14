#!/usr/bin/env bash

set -o errexit

REPO_ROOT=$(git rev-parse --show-toplevel)

echo '>>> Loading Flagger image'
kind load docker-image test/flagger:latest

echo '>>> Installing Skipper Ingress, Flagger and Prometheus'
# use kustomize to avoid compatibility issues:
# https://github.com/kubernetes-sigs/kustomize/issues/2390
# Skipper will throw an Prometheus warning which can be ignored:
# https://github.com/weaveworks/flagger/issues/664

# installing kustomize if not installed
if ! command -v kustomize &> /dev/null; then
    echo "kustomize not found, installing"
    kustomize_ver=3.8.0 && \
    kustomize_url=https://github.com/kubernetes-sigs/kustomize/releases/download && \
    curl -sL ${kustomize_url}/kustomize%2Fv${kustomize_ver}/kustomize_v${kustomize_ver}_linux_amd64.tar.gz | tar xz
    chmod +x kustomize
    sudo mv kustomize /usr/local/bin/kustomize
    kustomize version
fi

kustomize build ${REPO_ROOT}/kustomize/skipper | kubectl apply -f -

kubectl rollout status deployment/skipper-ingress -n kube-system
kubectl rollout status deployment/flagger-prometheus -n flagger-system

kubectl -n flagger-system set image deployment/flagger flagger=test/flagger:latest

kubectl -n flagger-system rollout status deployment/flagger
