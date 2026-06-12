terraform {
  required_version = ">= 1.6.0"

  required_providers {
    # Cluster layer
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }

    # Platform layer (in-cluster installs)
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.11"
    }

    # Octopus + GitHub wiring
    octopusdeploy = {
      source  = "OctopusDeploy/octopusdeploy"
      version = "~> 1.9"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }
}
