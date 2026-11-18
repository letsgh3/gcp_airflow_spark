#!/bin/bash
set -euo pipefail

PROJECT_ID=${1:-""}
if [[ -z "$PROJECT_ID" ]]; then
  echo "Użycie: $0 <gcp-project-id>"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/../terraform"

echo "UWAGA: To usunie cały klaster i dane kursu!"
read -r -p "Wpisz 'kasuj' żeby potwierdzić: " CONFIRM
[[ "$CONFIRM" != "kasuj" ]] && echo "Anulowano." && exit 0

: "${TF_STATE_BUCKET:?Ustaw TF_STATE_BUCKET (bucket ze state Terraform)}"

cd "$TF_DIR"
terraform init \
  -backend-config="bucket=$TF_STATE_BUCKET" \
  -backend-config="prefix=${TF_STATE_PREFIX:-airflow-spark/terraform}"
terraform destroy -var="project_id=$PROJECT_ID" -auto-approve
echo "Klaster usunięty."
