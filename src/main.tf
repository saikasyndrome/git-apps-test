variable "project_id" {}
variable "project_number" {}
variable "region" { default = "asia-northeast1" }
variable "installation_id" { type = number }
variable "repo_uri" { type = string }
variable "github_pat_secret_id" { type = string }

# 콘솔 GitHub App으로 등록한 저장소 연결
variable "console_repository" {
  type = string
}

# 1. 기존 PAT 시크릿 조회 (생성하지 않음)
data "google_secret_manager_secret_version" "github_pat" {
  project = var.project_id
  secret  = var.github_pat_secret_id
}

# 2. Cloud Build Service Agent에 접근 권한
resource "google_secret_manager_secret_iam_member" "cb_agent" {
  project   = var.project_id
  secret_id = var.github_pat_secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:service-${var.project_number}@gcp-sa-cloudbuild.iam.gserviceaccount.com"
}

# 3. 커넥션
resource "google_cloudbuildv2_connection" "github" {
  project  = var.project_id
  location = var.region
  name     = "github-connection"

  github_config {
    app_installation_id = var.installation_id
    authorizer_credential {
      oauth_token_secret_version = data.google_secret_manager_secret_version.github_pat.name
    }
  }

  depends_on = [google_secret_manager_secret_iam_member.cb_agent]
}

# 4. 레포 연결
resource "google_cloudbuildv2_repository" "repo" {
  project           = var.project_id
  location          = var.region
  name              = "my-repo"
  parent_connection = google_cloudbuildv2_connection.github.id
  remote_uri        = var.repo_uri
}

# 5. 빌드용 서비스 계정 (트리거 생성 시 필수)
resource "google_service_account" "cloudbuild" {
  project      = var.project_id
  account_id   = "cloudbuild-test"
  display_name = "Cloud Build test"
}

resource "google_project_iam_member" "cloudbuild_logs" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.cloudbuild.email}"
}

resource "google_project_iam_member" "cloudbuild_act_as" {
  project = var.project_id
  role    = "roles/iam.serviceAccountUser"
  member  = "serviceAccount:${google_service_account.cloudbuild.email}"
}

# 6. 트리거: PAT 연결 (github-connection / my-repo)
resource "google_cloudbuild_trigger" "pat" {
  project         = var.project_id
  location        = var.region
  name            = "trigger-pat"
  filename        = "cloudbuild.yaml"
  service_account = google_service_account.cloudbuild.id

  repository_event_config {
    repository = google_cloudbuildv2_repository.repo.id
    push {
      branch = "^main$"
    }
  }

  depends_on = [
    google_project_iam_member.cloudbuild_logs,
    google_project_iam_member.cloudbuild_act_as,
  ]
}

# 7. 트리거: 콘솔 GitHub App 연결 (test / saikasyndrome-git-apps-test)
resource "google_cloudbuild_trigger" "github_app" {
  project         = var.project_id
  location        = var.region
  name            = "trigger-github-app"
  filename        = "cloudbuild.yaml"
  service_account = google_service_account.cloudbuild.id

  repository_event_config {
    repository = var.console_repository
    push {
      branch = "^main$"
    }
  }

  depends_on = [
    google_project_iam_member.cloudbuild_logs,
    google_project_iam_member.cloudbuild_act_as,
  ]
}
