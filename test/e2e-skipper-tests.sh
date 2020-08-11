#!/usr/bin/env bash

# This script runs e2e tests for Canary initialization, analysis and promotion
# Prerequisites: Kubernetes Kind and Skipper ingress controller

set -o errexit

REPO_ROOT=$(git rev-parse --show-toplevel)

echo '>>> Creating test namespace'
kubectl create namespace test || true
echo '>>> service canary'
kubectl apply -f ${REPO_ROOT}/test/e2e-skipper-test-ingress.yaml
echo '>>> Initialising canary'
kubectl apply -f ${REPO_ROOT}/test/e2e-workload.yaml

echo '>>> Installing load tester'
kubectl apply -k ${REPO_ROOT}/kustomize/tester
kubectl -n test rollout status deployment/flagger-loadtester

echo '>>> Create canary CRD'
cat <<EOF | kubectl apply -f -
apiVersion: flagger.app/v1beta1
kind: Canary
metadata:
  name: podinfo
  namespace: test
spec:
  provider: skipper
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: podinfo
  ingressRef:
    apiVersion: networking.k8s.io/v1beta1
    kind: Ingress
    name: podinfo
  progressDeadlineSeconds: 60
  service:
    # service name (defaults to targetRef.name)
    name: podinfo
    # ClusterIP port number
    port: 80
    # container port name or number (optional)
    targetPort: 9898
    # port name can be http or grpc (default http)
    portName: http
    # add all the other container ports
    # to the ClusterIP services (default false)
    portDiscovery: false
  analysis:
    interval: 15s
    threshold: 5
    maxWeight: 40
    stepWeight: 20
    metrics:
    - name: request-success-rate
      interval: 1m
      # minimum req success rate (non 5xx responses)
      # percentage (0-100)
      thresholdRange:
        min: 99
    - name: request-duration
      interval: 1m
      # maximum req duration P99
      # milliseconds
      thresholdRange:
        max: 500
    webhooks:
      - name: gate
        type: confirm-rollout
        url: http://flagger-loadtester.test/gate/approve
      - name: acceptance-test
        type: pre-rollout
        url: http://flagger-loadtester.test/
        timeout: 10s
        metadata:
          type: bash
          cmd: "curl -sd 'test' http://podinfo-canary/token | grep token"
      - name: "load test"
        type: rollout
        url: http://flagger-loadtester.test/
        timeout: 5s
        metadata:
          type: cmd
          cmd: "hey -z 10m -q 10 -c 2 -host app.example.com http://skipper-ingress.kube-system"
          logCmdOutput: "true"
EOF

echo '>>> Waiting for primary to be ready'
retries=50
count=0
ok=false
until ${ok}; do
  kubectl -n test get canary/podinfo | grep 'Initialized' && ok=true || ok=false
  sleep 5
  count=$(($count + 1))
  if [[ ${count} -eq ${retries} ]]; then
    kubectl -n flagger-system logs deployment/flagger
    echo "No more retries left"
    exit 1
  fi
done

echo '✔ Canary initialization test passed'

echo '>>> Triggering canary deployment'
kubectl -n test set image deployment/podinfo podinfod=stefanprodan/podinfo:3.1.1

echo '>>> Waiting for canary promotion'
retries=50
count=0
ok=false
failed=false
until ${ok}; do
  kubectl -n test get canary/podinfo | grep 'Failed' && failed=true || failed=false
  if ${failed}; then
    kubectl -n flagger-system logs deployment/flagger
    echo "Canary failed!"
    exit 1
  fi
  kubectl -n test describe deployment/podinfo-primary | grep '3.1.1' && ok=true || ok=false
  sleep 10
  kubectl -n flagger-system logs deployment/flagger --tail 1
  count=$(($count + 1))
  if [[ ${count} -eq ${retries} ]]; then
    kubectl -n test describe deployment/podinfo
    kubectl -n test describe deployment/podinfo-primary
    kubectl -n flagger-system logs deployment/flagger
    echo "No more retries left"
    exit 1
  fi
done

echo '>>> Waiting for canary finalization'
retries=50
count=0
ok=false
until ${ok}; do
  kubectl -n test get canary/podinfo | grep 'Succeeded' && ok=true || ok=false
  sleep 5
  count=$(($count + 1))
  if [[ ${count} -eq ${retries} ]]; then
    kubectl -n flagger-system logs deployment/flagger
    echo "No more retries left"
    exit 1
  fi
done

echo '✔ Canary promotion test passed'
