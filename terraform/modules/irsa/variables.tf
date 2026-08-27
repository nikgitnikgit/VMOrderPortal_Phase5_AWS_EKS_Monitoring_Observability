# modules/irsa/variables.tf
variable "project_name" { type = string }
variable "environment" { type = string }
variable "oidc_provider_arn" { type = string }
variable "oidc_provider_url" { type = string } # without https://
variable "namespace" { type = string }         # devops-app
variable "s3_bucket_arn" { type = string }
variable "sns_topic_arn" { type = string }
variable "ecr_repo_arns" { type = list(string) } # scoped ECR push for Jenkins
variable "observability_namespace" {
  description = "Namespace the monitoring stack runs in (phase 5)"
  type        = string
  default     = "observability"
}
