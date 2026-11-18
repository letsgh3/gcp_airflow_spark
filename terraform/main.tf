terraform {
  required_version = ">= 1.5"

  # State w GCS. Bucket i prefix przekazywane przy init (nie w kodzie):
  #   terraform init -backend-config="bucket=<TF_STATE_BUCKET>" -backend-config="prefix=<TF_STATE_PREFIX>"
  backend "gcs" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  dag_bucket = "${var.project_id}-${var.course_name}-dags"
  # join token zapisywany tutaj po init mastera, workerzy go pobierają
  join_bucket = "${var.project_id}-${var.course_name}-bootstrap"
}

resource "google_project_service" "apis" {
  for_each = toset([
    "compute.googleapis.com",
    "storage.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
  ])
  service            = each.key
  disable_on_destroy = false
}
