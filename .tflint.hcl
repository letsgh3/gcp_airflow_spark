# TFLint — reguły ogólne Terraform + plugin Google (np. poprawność typów maszyn, regionów).
# Uruchamiaj z katalogu terraform/: tflint --init && tflint --config ../.tflint.hcl

config {
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "google" {
  enabled = true
  version = "0.30.0"
  source  = "github.com/terraform-linters/tflint-ruleset-google"
}
