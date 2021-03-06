variable "namespace" {}

variable "stage" {
  description = "Sub-Name of this traefik instance - e.g. alpha/beta"
}

variable "instances" {
  default = 1
}

variable "traefik_config_filepath" {
  description = "Filepath for YAML of Traefik config"
}

variable "nginx_config_filepath" {
  description = "Filepath for nginx config"
}

variable "nginx_default_config_filepath" {
  description = "Filepath for nginx default.conf"
}

variable "nginx_tag" {
  default = "1.19"
}

variable "nginx_exporter_tag" {
  default = "0.4.2"
}

variable "traefik_tag" {
  default = "v2.4"
}

variable "capacity" {
  default = "1Gi"
}

variable "resources_cpu_limit" {
  default = "1000m"
}

variable "resources_mem_limit" {
  default = "1024Mi"
}

variable "resources_cpu_request" {
  default = "100m"
}

variable "resources_mem_request" {
  default = "256Mi"
}
