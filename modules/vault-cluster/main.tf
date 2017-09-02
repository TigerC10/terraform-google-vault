# ---------------------------------------------------------------------------------------------------------------------
# THESE TEMPLATES REQUIRE TERRAFORM VERSION 0.10.3 AND ABOVE
# Why? Because we want the latest GCP updates available in https://github.com/terraform-providers/terraform-provider-google
# ---------------------------------------------------------------------------------------------------------------------

terraform {
  required_version = ">= 0.10.3"
}

# ---------------------------------------------------------------------------------------------------------------------
# CREATE A GCE MANAGED INSTANCE GROUP TO RUN VAULT
# Ideally, we would run a "regional" Managed Instance Group that spans many Zones, but the Terraform GCP provider has
# not yet implemented https://github.com/terraform-providers/terraform-provider-google/issues/45, so we settle for a
# single-zone Managed Instance Group.
# ---------------------------------------------------------------------------------------------------------------------

# Create the single-zone Managed Instance Group where Vault will run.
resource "google_compute_instance_group_manager" "vault" {
  name = "${var.cluster_name}-ig"

  base_instance_name = "${var.cluster_name}"
  instance_template  = "${data.template_file.compute_instance_template_self_link.rendered}"
  zone               = "${var.gcp_zone}"

  # Restarting a Vault server has an important consequence: The Vault server has to be manually unsealed again. Therefore,
  # the update strategy used to roll out a new GCE Instance Template must be a rolling update. But since Terraform does
  # not yet support ROLLING_UPDATE, such updates must be manually rolled out for now.
  update_strategy = "${var.instance_group_update_strategy}"

  target_pools = ["${var.instance_group_target_pools}"]
  target_size  = "${var.cluster_size}"

  depends_on = ["google_compute_instance_template.vault_public", "google_compute_instance_template.vault_private"]
}

# Create the Instance Template that will be used to populate the Managed Instance Group.
# NOTE: This Compute Instance Template is only created if var.assign_public_ip_addresses is true.
resource "google_compute_instance_template" "vault_public" {
  count = "${var.assign_public_ip_addresses}"

  name_prefix = "${var.cluster_name}"
  description = "${var.cluster_description}"

  instance_description = "${var.cluster_description}"
  machine_type         = "${var.machine_type}"

  tags = "${concat(list(var.cluster_tag_name), var.custom_tags)}"
  metadata_startup_script = "${var.startup_script}"
  metadata = "${merge(map(var.metadata_key_name_for_cluster_size, var.cluster_size), var.custom_metadata)}"

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
    preemptible = false
  }

  disk {
    boot         = true
    auto_delete  = true
    source_image = "${var.source_image}"
    disk_size_gb = "${var.root_volume_disk_size_gb}"
    disk_type    = "${var.root_volume_disk_type}"
  }

  network_interface {
    network = "${var.network_name}"
    access_config {
      # The presence of this property assigns a public IP address to each Compute Instance. We intentionally leave it
      # blank so that an external IP address is selected automatically.
      nat_ip = ""
    }
  }

  # For a full list of oAuth 2.0 Scopes, see https://developers.google.com/identity/protocols/googlescopes
  service_account {
    scopes = [
      "https://www.googleapis.com/auth/userinfo.email",
      "https://www.googleapis.com/auth/compute.readonly",
      "https://www.googleapis.com/auth/devstorage.read_write"
    ]
  }

  # Per Terraform Docs (https://www.terraform.io/docs/providers/google/r/compute_instance_template.html#using-with-instance-group-manager),
  # we need to create a new instance template before we can destroy the old one. Note that any Terraform resource on
  # which this Terraform resource depends will also need this lifecycle statement.
  lifecycle {
    create_before_destroy = true
  }
}

# Create the Instance Template that will be used to populate the Managed Instance Group.
# NOTE: This Compute Instance Template is only created if var.assign_public_ip_addresses is false.
resource "google_compute_instance_template" "vault_private" {
  count = "${1 - var.assign_public_ip_addresses}"

  name_prefix = "${var.cluster_name}"
  description = "${var.cluster_description}"

  instance_description = "${var.cluster_description}"
  machine_type = "${var.machine_type}"

  tags = "${concat(list(var.cluster_tag_name), var.custom_tags)}"
  metadata_startup_script = "${var.startup_script}"
  metadata = "${merge(map(var.metadata_key_name_for_cluster_size, var.cluster_size), var.custom_metadata)}"

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
    preemptible = false
  }

  disk {
    boot         = true
    auto_delete  = true
    source_image = "${var.source_image}"
  }

  network_interface {
    network = "${var.network_name}"
  }

  # For a full list of oAuth 2.0 Scopes, see https://developers.google.com/identity/protocols/googlescopes
  service_account {
    scopes = [
      "https://www.googleapis.com/auth/userinfo.email",
      "https://www.googleapis.com/auth/compute.readonly",
      "https://www.googleapis.com/auth/devstorage.read_write"
    ]
  }

  # Per Terraform Docs (https://www.terraform.io/docs/providers/google/r/compute_instance_template.html#using-with-instance-group-manager),
  # we need to create a new instance template before we can destroy the old one. Note that any Terraform resource on
  # which this Terraform resource depends will also need this lifecycle statement.
  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# CREATE FIREWALL RULES
# ---------------------------------------------------------------------------------------------------------------------

# Allow Vault-specific traffic within the cluster
# - This Firewall Rule may be redundant depnding on the settings of your VPC Network, but if your Network is locked down,
#   this Rule will open up the appropriate ports.
resource "google_compute_firewall" "allow_intracluster_vault" {
  name    = "${var.cluster_name}-rule-cluster"
  network = "${var.network_name}"

  allow {
    protocol = "tcp"
    ports    = [
      "${var.cluster_port}",
    ]
  }

  source_tags = ["${var.cluster_tag_name}"]
  target_tags = ["${var.cluster_tag_name}"]
}

# Specify which traffic is allowed into the Vault cluster solely for API requests
# - This Firewall Rule may be redundant depnding on the settings of your VPC Network, but if your Network is locked down,
#   this Rule will open up the appropriate ports.
# - Note that public access to your Vault cluster will only be permitted if var.assign_public_ip_addresses is true.
# - This Firewall Rule is only created if at least one source tag or source CIDR block is specified.
resource "google_compute_firewall" "allow_inboud_api" {
  count = "${length(var.allowed_inbound_cidr_blocks_api) + length(var.allowed_inbound_tags_api) > 0 ? 1 : 0}"

  name    = "${var.cluster_name}-rule-external-api-access"
  network = "${var.network_name}"

  allow {
    protocol = "tcp"
    ports    = [
      "${var.api_port}",
    ]
  }

  source_ranges = "${var.allowed_inbound_cidr_blocks_api}"
  source_tags = "${var.allowed_inbound_tags_api}"
  target_tags = ["${var.cluster_tag_name}"]
}

# ---------------------------------------------------------------------------------------------------------------------
# CREATE A GOOGLE STORAGE BUCKET TO USE AS A VAULT STORAGE BACKEND
# ---------------------------------------------------------------------------------------------------------------------

resource "google_storage_bucket" "vault_storage_backend" {
  name = "${var.cluster_name}"
  location = "${var.gcs_bucket_location}"
  storage_class = "${var.gcs_bucket_storage_class}"

  # In prod, the Storage Bucket should NEVER be emptied and deleted via Terraform unless you know exactly what you're doing.
  # However, for testing purposes, it's often convenient to destroy a non-empty Storage Bucket.
  force_destroy = "${var.gcs_bucket_force_destroy}"
}

# We deliberately avoid creating a Bucket ACL (Terraform's google_storage_bucket_acl resource) because it appears that ACLs
# are now deprecated as a way to assign permissions to a Bucket in favor of using an IAM Policy instead.

# ---------------------------------------------------------------------------------------------------------------------
# CONVENIENCE VARIABLES
# Because we've got some conditional logic in this template, some values will depend on our properties. This section
# wraps such values in a nicer construct.
# ---------------------------------------------------------------------------------------------------------------------

# The Google Compute Instance Group needs the self_link of the Compute Instance Template that's actually created.
data "template_file" "compute_instance_template_self_link" {
  # This will return the self_link of the Compute Instance Template that is actually created. It works as follows:
  # - Make a list of 1 value or 0 values for each of google_compute_instance_template.consul_servers_public and
  #   google_compute_instance_template.consul_servers_private by adding the glob (*) notation. Terraform will complain
  #   if we directly reference a resource property that doesn't exist, but it will permit us to turn a single resource
  #   into a list of 1 resource and "no resource" into an empty list.
  # - Concat these lists. concat(list-of-1-value, empty-list) == list-of-1-value
  # - Take the first element of list-of-1-value
  template = "${element(concat(google_compute_instance_template.vault_public.*.self_link, google_compute_instance_template.vault_private.*.self_link), 0)}"
}
