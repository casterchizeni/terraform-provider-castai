data "aws_caller_identity" "current" {}

provider "castai" {
  api_token = var.castai_api_token
  api_url   = var.castai_api_url
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      # This requires the awscli to be installed locally where Terraform is executed.
      args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.cluster_region]
    }
  }
}


resource "castai_eks_cluster" "this" {
  account_id = data.aws_caller_identity.current.account_id
  region     = var.cluster_region
  name       = var.cluster_name

  delete_nodes_on_disconnect = var.delete_nodes_on_disconnect
  assume_role_arn            = var.readonly ? null : aws_iam_role.assume_role.arn
}

resource "castai_eks_user_arn" "castai_user_arn" {
  cluster_id = castai_eks_clusterid.cluster_id.id
}

resource "castai_eks_clusterid" "cluster_id" {
  account_id   = data.aws_caller_identity.current.account_id
  region       = var.cluster_region
  cluster_name = var.cluster_name
}


resource "helm_release" "castai_agent" {
  name             = "castai-agent"
  repository       = "https://castai.github.io/helm-charts"
  chart            = "castai-agent"
  namespace        = "castai-agent"
  create_namespace = true
  cleanup_on_fail  = true

  set {
    name  = "provider"
    value = "eks"
  }
  set_sensitive {
    name  = "apiKey"
    value = castai_eks_cluster.this.cluster_token
  }

  # Required until https://github.com/castai/helm-charts/issues/135 is fixed.
  set {
    name  = "createNamespace"
    value = "false"
  }
  dynamic "set" {
    for_each = var.castai_api_url != "" ? [var.castai_api_url] : []
    content {
      name  = "apiURL"
      value = var.castai_api_url
    }
  }
}

resource "castai_node_configuration" "this" {
  count      = var.readonly ? 0 : 1
  cluster_id = castai_eks_cluster.this.id

  name           = "default"
  disk_cpu_ratio = 0
  min_disk_size  = 100
  subnets        = module.vpc.private_subnets
  eks {
    security_groups = [
      module.eks.cluster_security_group_id,
      module.eks.node_security_group_id,
    ]
    instance_profile_arn = aws_iam_instance_profile.castai_instance_profile.arn
  }
}

resource "castai_node_configuration_default" "this" {
  count            = var.readonly ? 0 : 1
  cluster_id       = castai_eks_cluster.this.id
  configuration_id = castai_node_configuration.this[0].id
}

resource "castai_node_template" "non_critical_nodes" {
  cluster_id       = castai_eks_cluster.this.id
  name             = "non-critical-nodes"
  is_default       = false
  is_enabled       = true

  # Labels must match Deployment's nodeSelector
  custom_labels = {
    critical = "no"
    env      = "staging"
    team     = "developers"
  }

  constraints {
    on_demand = true
    spot      = false
    min_cpu   = 2
    max_cpu   = 16
    min_memory = 4096
    max_memory = 32768
    azs = ["us-east-2a", "us-east-2b", "us-east-2c"]

    # Allow more instance families to fit workloads
    instance_families {
      include = ["c5", "m5", "r5"]
    }

    
  }

}


resource "castai_node_template" "default_by_castai" {
  cluster_id       = castai_eks_cluster.this.id
  name             = "default-by-castai"
  is_default       = true
  is_enabled       = true
  configuration_id = castai_node_configuration.this[0].id  # Link to node configuration
  should_taint     = false  # Set to true if you want taints on nodes

  custom_labels = {
    critical = "yes"
    env  = "staging"
    team = "developers"
  }


  constraints {
    on_demand                                   = true
    spot                                        = false
    use_spot_fallbacks                          = true
    fallback_restore_rate_seconds               = 300
    enable_spot_diversity                       = true
    spot_diversity_price_increase_limit_percent = 20
    spot_interruption_predictions_enabled       = true
    spot_interruption_predictions_type          = "aws-rebalance-recommendations"
    compute_optimized_state                     = "disabled"
    storage_optimized_state                     = "disabled"
    is_gpu_only                                 = false
    min_cpu                                     = 2
    max_cpu                                     = 8
    min_memory                                  = 4096
    max_memory                                  = 32768
    #architectures                               = ["amd64"]
    azs                                         = ["us-east-2a", "us-east-2b"]
    burstable_instances                         = "disabled"
    customer_specific                           = "disabled"

    instance_families {
      include = ["c5","m5","r5"]
    }  

  }
}

resource "helm_release" "castai_cluster_controller" {
  count            = var.readonly ? 0 : 1
  name             = "cluster-controller"
  repository       = "https://castai.github.io/helm-charts"
  chart            = "castai-cluster-controller"
  namespace        = "castai-agent"
  create_namespace = true
  cleanup_on_fail  = true
  wait             = true

  set {
    name  = "castai.clusterID"
    value = castai_eks_cluster.this.id
  }

  dynamic "set" {
    for_each = var.castai_api_url != "" ? [var.castai_api_url] : []
    content {
      name  = "castai.apiURL"
      value = var.castai_api_url
    }
  }

  set_sensitive {
    name  = "castai.apiKey"
    value = castai_eks_cluster.this.cluster_token
  }

  depends_on = [helm_release.castai_agent]

  lifecycle {
    ignore_changes = [version]
  }
}

resource "castai_autoscaler" "castai_autoscaler_policy" {
  cluster_id = castai_eks_cluster.this.id

  autoscaler_settings {
    enabled                                 = true
    is_scoped_mode                          = false
    node_templates_partial_matching_enabled = true

    unschedulable_pods {
      enabled = true
    }

    cluster_limits {
      enabled = true

      cpu {
        min_cores = 1
        max_cores = 10
      }
    }

    node_downscaler {
      enabled = true

      empty_nodes {
        enabled       = true
        delay_seconds = 90
      }

      evictor {
        enabled                                = true
        dry_run                                = false
        aggressive_mode                        = false
        scoped_mode                            = false
        cycle_interval                         = "60s"
        node_grace_period_minutes              = 10
        pod_eviction_failure_back_off_interval = "30s"
        ignore_pod_disruption_budgets          = false
      }
    }
  }
}