#!/usr/bin/env bash

kind delete cluster || true

REPO_ROOT=$(git rev-parse --show-toplevel)
cd $REPO_ROOT

make build
docker tag weaveworks/flagger:latest test/flagger:latest
make loadtester-build
kind create cluster --wait 5m --image kindest/node:v1.16.9
./test/e2e-skipper.sh
./test/e2e-skipper-tests.sh

# port forward prometheus UI to localhost:9090
kubectl port-forward $(kubectl get pods -l=app=flagger-prometheus -o name -n flagger-system | head -n 1) 9090:9090 -n flagger-system
