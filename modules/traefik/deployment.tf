resource "kubernetes_deployment" "traefik" {
  metadata {
    name = "traefik-${var.stage}"
    namespace = var.namespace
    labels = {
      app = "traefik"
    }
  }
  spec {
    replicas = var.instances
    selector {
      match_labels = {
        app = "traefik"
      }
    }
    template {
      metadata {
        labels = {
          app = "traefik"
        }
      }
      spec {
        affinity {
          pod_anti_affinity {
            required_during_scheduling_ignored_during_execution {
              label_selector {
                match_expressions {
                  key      = "app"
                  operator = "In"
                  values   = ["traefik"]
                }
              }
              topology_key = "kubernetes.io/hostname"
            }
          }
        }
        service_account_name = "traefik"
        termination_grace_period_seconds = 30
        container {
          image = "nginx:${var.nginx_tag}"
          image_pull_policy = "Always"
          name = "nginx"
          args = [
            "nginx", "-c", "/opt/nginx/nginx.conf"
          ]
          volume_mount {
            name = "nginx-conf"
            mount_path = "/opt/nginx/"
          }
          volume_mount {
            name = "nginx-temp"
            mount_path = "/var/cache/nginx/"
          }
          volume_mount {
            name = "nginx-www"
            mount_path = "/usr/share/nginx/www/"
          }
          port {
            container_port = 8080
            name = "http"
            protocol = "TCP"
          }
        }
        container {
          image = "nginx/nginx-prometheus-exporter:${var.nginx_exporter_tag}"
          image_pull_policy = "Always"
          name = "nginx-exporter"
          args = [
            "-nginx.scrape-uri=http://localhost:8080/stub_status",
          ]
          port {
            container_port = 9113
            name = "metrics"
            protocol = "TCP"
          }
          resources {
            limits {
              cpu    = "100m"
              memory = "50Mi"
            }
            requests {
              cpu    = "50m"
              memory = "25Mi"
            }
          }
          readiness_probe {
            http_get {
              path = "/metrics"
              port = 9113
            }
            initial_delay_seconds = 1
            period_seconds        = 5
          }
          liveness_probe {
            http_get {
              path = "/metrics"
              port = 9113
            }
            initial_delay_seconds = 1
            period_seconds        = 5
          }
          security_context {
            read_only_root_filesystem = true
            run_as_non_root = true
            run_as_user = 65534
          }
        }
        container {
          # image = "traefik:${var.traefik_tag}"
          image = var.image
          image_pull_policy = "Always"
          name = "traefik"
          args = [
            "--configfile=/etc/traefik/traefik.yaml",
          ]
          volume_mount {
            name = "traefik-config"
            mount_path = "/etc/traefik/"
          }
          volume_mount {
            name = "traefik-${var.stage}-acme"
            mount_path = "/opt/traefik/"
          }
          port {
            container_port = 80
            name = "proxy"
            protocol = "TCP"
          }
          port {
            container_port = 8081
            name = "dashboard"
            protocol = "TCP"
          }
        }
        volume {
          name = "traefik-config"
          config_map {
            name = "traefik-${var.stage}-config"
            items {
              key = "traefik.yaml"
              path = "traefik.yaml"
            }
          }
        }
        volume {
          name = "traefik-${var.stage}-acme"
          persistent_volume_claim {
            claim_name = "traefik-${var.stage}-acme"
          }
        }
        volume {
          name = "nginx-conf"
          config_map {
            name = "traefik-${var.stage}-nginx-config"
            items {
              key = "nginx.conf"
              path = "nginx.conf"
            }
            items {
              key = "default.conf"
              path = "conf.d/default.conf"
            }
          }
        }
        volume {
          name = "nginx-temp"
          empty_dir {}
        }
        volume {
          name = "nginx-www"
          config_map {
            name = "traefik-${var.stage}-nginx-config"
            items {
              key = "metrics"
              path = "metrics"
            }
            items {
              key = "index.html"
              path = "index.html"
            }
          }
        }
        restart_policy = "Always"
      }
    }
  }
}
