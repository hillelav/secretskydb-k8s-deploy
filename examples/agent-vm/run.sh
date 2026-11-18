#!/usr/bin/env bash
#
# SecretSkyDB deployment assets — Copyright (c) 2026 SECRETSKYDB LTD.
# This script is licensed under the Apache License, Version 2.0. The SecretSkyDB
# Software it deploys is proprietary and governed by the SecretSkyDB End User License
# Agreement (https://www.secretskydb.com/eula). Contact: support@secretskydb.com
#
# An AI agent on SecretSkyDB with a self-hosted model, on one Google Cloud VM. Run from a laptop.
#
#   ./run.sh up            create the VM, install SecretSkyDB (your Marketplace order), a local
#                          model server and the agent, load the sample data
#   ./run.sh chat          talk to the agent; it asks before it changes any data
#   ./run.sh ask "..."     one question, one answer, read-only (ask --write "..." allows changes)
#   ./run.sh test          the built-in question set with pass / fail (reloads the sample data)
#   ./run.sh audit [n]     the last n records of the agent's audit trail (default 30)
#   ./run.sh status        VM, SecretSkyDB licence, model and data checks
#   ./run.sh ssh           a shell on the VM
#   ./run.sh stop | start  pause the VM (only its disk is charged) and resume it
#   ./run.sh down          delete the VM and its disk (stops all charges)
#
# Before `up`: buy SecretSkyDB on Google Cloud Marketplace, then on the product page click
# Configure → "Deploy via command line" → Download service account key. The file
# (service-account-key.yaml) identifies your order; SecretSkyDB usage is metered hourly against it.
#
# Everything runs on the VM: SecretSkyDB (proxy, cache, three share stores) on a single-node
# Kubernetes, the model server (Ollama) and the agent. The model and the agent talk to nothing
# outside the VM. No port is opened to the internet; this script reaches the VM over SSH.
#
# Environment (defaults shown):
#   KEY_FILE=~/Downloads/service-account-key.yaml   the reporting key of your order
#   PROJECT=<gcloud default project>   ZONE=us-central1-a   VM=ssdb-agent
#                                      (if the zone has no capacity, `up` tries the region's other zones)
#   GPU=0                              GPU=1: a VM with one NVIDIA L4 (g2-standard-8) and a larger
#                                      model; answers in seconds. Needs L4 quota in the zone.
#   MACHINE=n2-standard-8              8 vCPU / 32 GB, no GPU: answers take 60-90 s (g2-standard-8 with GPU=1)
#   DISK_GB=60                         (100 with GPU=1)
#   MODEL=qwen2.5:7b                   any Ollama model that supports tool calls (qwen2.5:14b with GPU=1)
#   EMBED_MODEL=all-minilm             any Ollama embedding model
#   SSH_FLAGS=                         extra flags for gcloud compute ssh/scp, e.g. --tunnel-through-iap
#   AUTO_APPROVE=false                 skip the confirmation prompts
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
KEY_FILE="${KEY_FILE:-$HOME/Downloads/service-account-key.yaml}"
PROJECT="${PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
# the zone of the VM is remembered next to this script, so later commands find it
ZONE_FILE="$HERE/.zone"
ZONE="${ZONE:-$(cat "$ZONE_FILE" 2>/dev/null || echo us-central1-a)}"
VM="${VM:-ssdb-agent}"
GPU="${GPU:-0}"
IMAGE_FAMILY=ubuntu-2404-lts-amd64; IMAGE_PROJECT=ubuntu-os-cloud
if [ "$GPU" = "1" ]; then
  MACHINE="${MACHINE:-g2-standard-8}"; DISK_GB="${DISK_GB:-100}"; MODEL="${MODEL:-qwen2.5:14b}"
  # Google's Ubuntu 24.04 image with the NVIDIA driver already installed. (On the plain Ubuntu
  # image the driver has to be compiled for the running kernel, and that build fails on new kernels.)
  IMAGE_FAMILY=common-cu129-ubuntu-2404-nvidia-580; IMAGE_PROJECT=deeplearning-platform-release
fi
MACHINE="${MACHINE:-n2-standard-8}"
DISK_GB="${DISK_GB:-60}"
MODEL="${MODEL:-qwen2.5:7b}"
EMBED_MODEL="${EMBED_MODEL:-all-minilm}"
SSH_FLAGS="${SSH_FLAGS:-}"
AUTO_APPROVE="${AUTO_APPROVE:-false}"
REMOTE_DIR="ssdb-agent"

B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'
step(){ printf "%b\n" "${B}▸ $*${N}"; }
die(){ printf "%b\n" "${R}✗ $*${N}" >&2; exit 1; }
confirm(){ [ "$AUTO_APPROVE" = "true" ] && return 0; read -r -p "$1 [y/N] " a; [ "${a:-}" = y ] || [ "${a:-}" = Y ]; }

GC=(gcloud compute --project "$PROJECT")
# shellcheck disable=SC2086
vm_ssh(){ "${GC[@]}" ssh "$VM" --zone "$ZONE" $SSH_FLAGS "$@"; }
# shellcheck disable=SC2086
vm_scp(){ "${GC[@]}" scp --zone "$ZONE" $SSH_FLAGS "$@"; }
vm_status(){ "${GC[@]}" instances describe "$VM" --zone "$ZONE" --format='value(status)' 2>/dev/null || true; }
agent(){ printf '%s' "$REMOTE_DIR/venv/bin/python $REMOTE_DIR/examples/agent-vm/agent.py"; }

preflight(){
  command -v gcloud >/dev/null || die "gcloud not found. Install the Google Cloud CLI: https://cloud.google.com/sdk/docs/install"
  gcloud auth print-access-token >/dev/null 2>&1 || die "gcloud is not logged in. Run: gcloud auth login"
  [ -n "$PROJECT" ] || die "no project. Set PROJECT=... or run: gcloud config set project PROJECT_ID"
}

need_running(){
  preflight
  [ "$(vm_status)" = "RUNNING" ] || die "VM $VM is not running in $PROJECT/$ZONE. Run: ./run.sh up"
}

cmd_up(){
  preflight
  [ -s "$KEY_FILE" ] || die "reporting key not found: $KEY_FILE
  Download it from the SecretSkyDB product page: Configure → Deploy via command line → Download service account key,
  then run: KEY_FILE=/path/to/service-account-key.yaml ./run.sh up"
  head -c1 "$KEY_FILE" | grep -q '{' && die "KEY_FILE is a raw JSON key; the product page gives a Kubernetes Secret (service-account-key.yaml)"
  [ -d "$REPO/chart/secretskydb/templates" ] || die "chart not found under $REPO (run from a checkout of this repository)"

  local st; st="$(vm_status)"
  echo
  echo "  project   $PROJECT        zone $ZONE"
  echo "  VM        $VM ($MACHINE, ${DISK_GB} GB disk)$([ -n "$st" ] && echo "  — exists, $st")"
  echo "  order     reporting key $KEY_FILE"
  echo "  model     $MODEL (chat), $EMBED_MODEL (embeddings), served on the VM by Ollama"
  echo
  echo "  Charges: the VM (Compute Engine, about $([ "$GPU" = "1" ] && echo 0.9 || echo 0.4) USD an hour for this machine) and SecretSkyDB"
  echo "  usage on your Marketplace order, both until you run ./run.sh down."
  echo
  confirm "Proceed?" || exit 1

  local errf; errf="$(mktemp)"
  if [ -z "$st" ]; then
    # a zone can be out of capacity for a machine type (common for GPUs): try its neighbours
    local region="${ZONE%-*}" z made=""
    local others; others="$("${GC[@]}" zones list --filter="region:$region AND status:UP" --format='value(name)' 2>/dev/null | sort | tr '\n' ' ')"
    for z in "$ZONE" $others; do
      [ "$z" = "$ZONE" ] && [ -n "$made" ] && continue
      step "creating VM $VM in $z"
      if "${GC[@]}" instances create "$VM" --zone "$z" --machine-type "$MACHINE" \
           --image-family "$IMAGE_FAMILY" --image-project "$IMAGE_PROJECT" \
           --boot-disk-size "${DISK_GB}GB" --boot-disk-type pd-balanced \
           --maintenance-policy TERMINATE --labels purpose=ssdb-agent >/dev/null 2>"$errf"; then
        made=1; ZONE="$z"; break
      fi
      grep -q "ZONE_RESOURCE_POOL_EXHAUSTED\|does not exist in zone\|not available in zone" "$errf" \
        || die "could not create the VM: $(grep -v '^WARNING\|Disk size\|^ - \|^$' "$errf" | head -5)"
      echo "  no capacity for $MACHINE in $z"
      made=0
    done
    [ "$made" = 1 ] || die "no zone of $region has capacity for $MACHINE right now. Try another region (ZONE=us-east1-b, us-west4-a, europe-west4-a or us-central1-a), or run without GPU=1: slower, but always available."
    echo "$ZONE" > "$ZONE_FILE"
  elif [ "$st" != "RUNNING" ]; then
    step "starting VM $VM"
    "${GC[@]}" instances start "$VM" --zone "$ZONE" >/dev/null
  fi

  step "waiting for SSH"
  local i
  for i in $(seq 1 30); do
    vm_ssh --command true >/dev/null 2>&1 && break
    [ "$i" = 30 ] && die "cannot SSH to $VM. If your network blocks port 22 try: SSH_FLAGS=--tunnel-through-iap ./run.sh up"
    sleep 6
  done

  step "copying the chart, the installer, the agent and the reporting key"
  local tmp; tmp="$(mktemp -d)"; trap "rm -rf '$tmp'" EXIT   # expanded now: tmp is local and gone when the trap fires
  # macOS tar adds "._name" metadata files and extended headers; Helm reads every file under
  # templates/ and fails on them
  COPYFILE_DISABLE=1 tar -C "$REPO" --exclude '._*' --exclude '.DS_Store' --exclude '__pycache__' \
    -czf "$tmp/bundle.tgz" chart scripts/install-onprem.sh examples/agent-vm
  vm_ssh --command "mkdir -p $REMOTE_DIR && chmod 700 $REMOTE_DIR"
  vm_scp "$tmp/bundle.tgz" "$VM:$REMOTE_DIR/bundle.tgz" >/dev/null
  vm_scp "$KEY_FILE" "$VM:$REMOTE_DIR/service-account-key.yaml" >/dev/null
  vm_ssh --command "cd $REMOTE_DIR && rm -rf chart scripts examples && tar -xzf bundle.tgz 2>/dev/null && rm bundle.tgz && chmod 600 service-account-key.yaml"

  step "installing on the VM (Kubernetes, SecretSkyDB, model server, agent): 10-15 minutes"
  # The install runs detached on the VM and this script follows its log, so a dropped SSH
  # connection does not interrupt it; the loop reconnects and continues from where it was.
  vm_ssh --command "cd $REMOTE_DIR && rm -f setup.rc && : > setup.log && (nohup sh -c \"MODEL='$MODEL' EMBED_MODEL='$EMBED_MODEL' GPU='$GPU' bash examples/agent-vm/vm-setup.sh; echo \\\$? > setup.rc\" >> setup.log 2>&1 &) ; sleep 1"
  local seen=0 chunk rc=""
  while :; do
    chunk="$(vm_ssh --command "cd $REMOTE_DIR && tail -n +$((seen + 1)) setup.log; echo; echo RC=\$(cat setup.rc 2>/dev/null)" 2>/dev/null || true)"
    rc="$(printf '%s\n' "$chunk" | sed -n 's/^RC=//p' | tail -1)"
    chunk="$(printf '%s\n' "$chunk" | sed '$d' | sed '$d')"
    if [ -n "$chunk" ]; then printf '%s\n' "$chunk" | grep -v 'debconf:' || true; seen=$((seen + $(printf '%s\n' "$chunk" | wc -l))); fi
    [ -n "$rc" ] && break
    sleep 15
  done
  [ "$rc" = "0" ] || die "the install on the VM failed (exit $rc). Full log on the VM: ~/$REMOTE_DIR/setup.log   (./run.sh ssh)"

  echo
  printf "%b\n" "${G}${B}Ready.${N}"
  echo "  ./run.sh chat                      talk to the agent"
  echo "  ./run.sh ask \"Is water damage from a burst pipe covered, and does Dana Levi have an open claim?\""
  echo "  ./run.sh test                      the built-in question set"
  echo "  ./run.sh down                      delete the VM when you are done"
}

cmd_chat(){ need_running; vm_ssh -- -t "$(agent) chat"; }

cmd_ask(){
  local w=""
  if [ "${1:-}" = "--write" ]; then w="--write "; shift; fi
  [ $# -ge 1 ] || die 'usage: ./run.sh ask [--write] "your question"'
  need_running
  # the question travels base64-encoded so quotes and Hebrew survive the two shells
  local q; q="$(printf '%s' "$*" | base64 | tr -d '\n')"
  vm_ssh --command "$(agent) ask ${w}--b64 $q"
}

cmd_test(){ need_running; vm_ssh --command "$(agent) test"; }

cmd_audit(){
  need_running
  case "${1:-30}" in ''|*[!0-9]*) die "usage: ./run.sh audit [number of records]";; esac
  vm_ssh --command "$(agent) audit ${1:-30}"
}

cmd_stop(){
  preflight
  [ "$(vm_status)" = "RUNNING" ] || { echo "VM $VM is not running."; exit 0; }
  if "${GC[@]}" instances describe "$VM" --zone "$ZONE" --format='value(machineType)' | grep -q '/g2-'; then
    echo "${Y}This VM has a GPU. A stopped VM gives its GPU back, and the zone may have none free when you"
    echo "start it again; then the only way back is ./run.sh down and GPU=1 ./run.sh up (15 minutes).${N}"
    confirm "Stop anyway?" || exit 1
  fi
  "${GC[@]}" instances stop "$VM" --zone "$ZONE" >/dev/null
  echo "Stopped. Only the disk is charged now. Resume with ./run.sh start, remove with ./run.sh down."
}

cmd_start(){
  preflight
  [ -n "$(vm_status)" ] || die "VM $VM does not exist in $PROJECT/$ZONE. Run: ./run.sh up"
  local errf; errf="$(mktemp)"
  if ! "${GC[@]}" instances start "$VM" --zone "$ZONE" >/dev/null 2>"$errf"; then
    grep -q "STOCKOUT\|does not have enough resources\|ZONE_RESOURCE_POOL_EXHAUSTED" "$errf" \
      && die "zone $ZONE has no free capacity for this machine right now. Try again later, or rebuild in a zone
  that has capacity: ./run.sh down, then ./run.sh up (GPU=1 ./run.sh up for a GPU VM); up tries the region's zones."
    die "could not start the VM: $(head -5 "$errf")"
  fi
  step "waiting for SecretSkyDB and the model server"
  local i
  for i in $(seq 1 40); do
    vm_ssh --command "$(agent) check" >/dev/null 2>&1 && break
    [ "$i" = 40 ] && die "the VM is up but the check does not pass yet. See: ./run.sh status"
    sleep 10
  done
  vm_ssh --command "$(agent) check"
}

cmd_status(){
  preflight
  local st; st="$(vm_status)"
  echo "VM $VM in $PROJECT/$ZONE: ${st:-does not exist}"
  [ "$st" = "RUNNING" ] || exit 0
  vm_ssh --command "bash $REMOTE_DIR/examples/agent-vm/vm-setup.sh licence; $(agent) check"
}

cmd_ssh(){ need_running; vm_ssh; }

cmd_down(){
  preflight
  local st; st="$(vm_status)"
  [ -n "$st" ] || { echo "VM $VM does not exist in $PROJECT/$ZONE. Nothing to delete."; exit 0; }
  echo "This deletes VM $VM and its disk in $PROJECT/$ZONE, with all the data on it."
  confirm "Delete?" || exit 1
  "${GC[@]}" instances delete "$VM" --zone "$ZONE" --quiet
  rm -f "$ZONE_FILE"
  printf "%b\n" "${G}Deleted. SecretSkyDB metering for this deployment stops with the VM.${N}"
}

case "${1:-}" in
  up)     cmd_up ;;
  chat)   cmd_chat ;;
  ask)    shift; cmd_ask "$@" ;;
  test)   cmd_test ;;
  audit)  shift; cmd_audit "$@" ;;
  stop)   cmd_stop ;;
  start)  cmd_start ;;
  status) cmd_status ;;
  ssh)    cmd_ssh ;;
  down)   cmd_down ;;
  *)      sed -n '8,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
