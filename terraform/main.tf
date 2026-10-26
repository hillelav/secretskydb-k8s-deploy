# SecretSkyDB deployment assets — Copyright (c) 2026 SECRETSKYDB LTD.
# This module is licensed under the Apache License, Version 2.0. The SecretSkyDB Software
# it prepares the shares for is proprietary and governed by the SecretSkyDB End User License
# Agreement (https://www.secretskydb.com/eula). Contact: support@secretskydb.com

# Provision the SecretSkyDB share data plane and the Kubernetes Secret the chart
# consumes. Turnkey: `terraform apply` creates the three AlloyDB instances (one
# sub-threshold share per Google Cloud region), generates all passwords, and
# writes the `secretskydb-alloydb-shares` Secret (hosts + passwords) into the
# target cluster/namespace. Then `mpdev install` / `helm install` just runs.
#
#   terraform init
#   terraform apply -var project_id=<proj> -var network=<vpc-self-link> \
#     -var k8s_namespace=secretskydb
#
# NOTE: AlloyDB is managed Postgres — no C extensions and no 2PC PREPARE. The
# chart's bootstrap Job creates the `ssdb` database and installs the pure-SQL
# ssdb_ff_inner_product() UDF; nothing here needs the extension.
#
# Kubernetes provider auth: defaults to your current kubeconfig context
# (KUBE_CONFIG_PATH / ~/.kube/config). Point it at the GKE Enterprise / on-prem
# cluster where the app is deployed. Set create_k8s_secret=false to only create
# the AlloyDB instances and emit the hosts as outputs.

terraform {
  required_providers {
    google     = { source = "hashicorp/google", version = ">= 5.0" }
    random     = { source = "hashicorp/random", version = ">= 3.5" }
    kubernetes = { source = "hashicorp/kubernetes", version = ">= 2.23" }
  }
}

variable "project_id" { type = string }
variable "deletion_protection" {
  type    = bool
  default = true
}
variable "regions" {
  type    = list(string)
  default = ["europe-west1", "australia-southeast1", "asia-southeast1"]
}
# Full self-link of the VPC that has Private Services Access configured for AlloyDB,
# e.g. projects/<proj>/global/networks/<vpc>. The GKE pod reaches the shares over
# this network (private IP / PSC).
variable "network" { type = string }
variable "k8s_namespace" {
  type    = string
  default = "secretskydb"
}
variable "share_secret_name" {
  type    = string
  default = "secretskydb-alloydb-shares"
}
variable "create_k8s_secret" {
  type    = bool
  default = true
}
# When true, provision Private Services Access on the VPC (a /16 allocation + the
# servicenetworking peering) that AlloyDB requires. Leave false if your VPC already
# has PSA configured (most existing prod VPCs do).
variable "manage_psa" {
  type    = bool
  default = false
}
# Optional per-region DB user (separation of duty / distinct custodians). Regions
# not listed default to "postgres". The user is written into the shares Secret and
# consumed by the proxy, so no chart edit is needed to use distinct users.
variable "share_users" {
  type    = map(string)
  default = {}
}

provider "google" { project = var.project_id }

# ---- passwords (generated; never checked in) --------------------------------
resource "random_password" "share" {
  for_each = toset(var.regions)
  length   = 24
  special  = false
}
resource "random_password" "proxy" {
  length  = 24
  special = false
}
resource "random_password" "cache" {
  length  = 24
  special = false
}

# Stable share letter per region: share-a / share-b / share-c (index order).
locals {
  share_letters = { for i, r in var.regions : r => format("share-%s", substr("abcdefghij", i, 1)) }
  # Per-region DB user (distinct custodians), defaulting to "postgres".
  share_user = { for r in var.regions : r => lookup(var.share_users, r, "postgres") }
}

# ---- Private Services Access (optional) -------------------------------------
# AlloyDB reaches the VPC over a private services peering. Provision it here when
# manage_psa=true (fresh VPC); otherwise assume it already exists.
resource "google_compute_global_address" "psa" {
  count         = var.manage_psa ? 1 : 0
  project       = var.project_id
  name          = "secretskydb-psa-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = var.network
}
resource "google_service_networking_connection" "psa" {
  count                   = var.manage_psa ? 1 : 0
  network                 = var.network
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa[0].name]
}

# ---- AlloyDB: one sub-threshold share per region ----------------------------
resource "google_alloydb_cluster" "share" {
  for_each   = toset(var.regions)
  cluster_id = "secretskydb-${local.share_letters[each.value]}"
  location   = each.value
  # The provider refuses to destroy a protected cluster: set -var deletion_protection=false,
  # `terraform apply`, then `terraform destroy` (a share holds one of three sub-threshold shares).
  deletion_protection = var.deletion_protection

  network_config { network = var.network }

  initial_user {
    user     = local.share_user[each.value]
    password = random_password.share[each.value].result
  }
  # Allow `terraform destroy` to remove the cluster (and its instances/backups)
  # without a manual pre-step.
  deletion_policy = "FORCE"
  # Ensure PSA exists before AlloyDB tries to peer (only when we manage it).
  depends_on = [google_service_networking_connection.psa]
  # automated_backup_policy / continuous_backup_config give point-in-time backups
  # (the "Google Cloud share store handles storage and PITR" claim). Left to the
  # customer's retention policy; enable as needed.
}

resource "google_alloydb_instance" "share" {
  for_each      = google_alloydb_cluster.share
  cluster       = each.value.name
  instance_id   = "primary"
  instance_type = "PRIMARY"
  machine_config { cpu_count = 2 }
}

# ---- the Kubernetes Secret the chart consumes -------------------------------
# Keys: proxy, cache; share-a/b/c (passwords); share-a/b/c-host (private IPs);
# share-a/b/c-user (DB users — distinct custodians when share_users is set).
provider "kubernetes" {}

resource "kubernetes_secret_v1" "shares" {
  count = var.create_k8s_secret ? 1 : 0
  metadata {
    name      = var.share_secret_name
    namespace = var.k8s_namespace
  }
  type = "Opaque"
  data = merge(
    {
      proxy = random_password.proxy.result
      cache = random_password.cache.result
    },
    { for r in var.regions : local.share_letters[r] => random_password.share[r].result },
    { for r in var.regions : "${local.share_letters[r]}-host" => google_alloydb_instance.share[r].ip_address },
    { for r in var.regions : "${local.share_letters[r]}-user" => local.share_user[r] },
  )
}

output "share_hosts" {
  value = { for r in var.regions : local.share_letters[r] => google_alloydb_instance.share[r].ip_address }
}
output "share_secret" {
  value = var.create_k8s_secret ? "${var.k8s_namespace}/${var.share_secret_name}" : "(not created)"
}
