# CLAUDE.md

Ten plik zawiera wskazówki dla Claude Code (claude.ai/code) przy pracy z kodem w tym repozytorium.

## Opis projektu

Infrastruktura kursu Apache Airflow na samodzielnie postawionym Kubernetesie (kubeadm) na VM-kach w GCP.
Nie jest to GKE ani Cloud Composer: Terraform tworzy goły Compute Engine, a cały klaster i aplikacje
stawiają skrypty startowe VM-ek.

Przepływ wdrożenia:

1. `terraform/` tworzy VPC, firewall, NAT, buckety GCS, service account, 1 master (`europe-west1-b`, publiczne IP)
   i 2 workery (`europe-west4-a`, `europe-central2-a`, bez publicznego IP).
2. `terraform/vms.tf` wstrzykuje `scripts/master-init.sh` / `scripts/worker-join.sh` jako `startup-script`
   w metadata VM, a parametry (hasła, buckety, lista analityków) jako klucze `tf_*`.
   Skrypty odczytują je z metadata serwera (`curl $META/tf_...`), nie z `.env`.
3. `master-init.sh` (~800 linii, log w `/var/log/master-init.log`, kończy się `SETUP ZAKOŃCZONY`):
   kubeadm init → Calico → local-path-provisioner → PostgreSQL 15 → Helm: Airflow (slot GREEN),
   JupyterHub, kube-prometheus-stack, Loki, OTel Collector → konta analityk01–16 z rolami RBAC.
   Token `kubeadm join` trafia do bucketu bootstrap w GCS.
4. `worker-join.sh` pobiera join command z GCS i dołącza node do klastra.

Kluczowe konsekwencje:

- **Zmiana w `scripts/master-init.sh` lub `scripts/worker-join.sh` zmienia metadata VM** → Terraform
  zaktualizuje instancje, a skrypt wykona się przy następnym starcie VM. Traktuj te pliki jak infrastrukturę.
- Wersje chartów Helm są przypięte w dwóch miejscach i muszą być zgodne:
  `master-init.sh` (`--version`) oraz `scripts/green-blue-switch.sh` (`CHART_VERSION`).
  Airflow chart `1.15.0` / Airflow `2.9.1`, JupyterHub `3.3.7`, kube-prometheus-stack `61.3.0`,
  loki-stack `2.10.2`, opentelemetry-collector `0.97.1`.
- Airflow działa w modelu green-blue: `helm/airflow/values-{green,blue}.yaml` + Service
  `k8s/airflow/service-active.yaml` (NodePort 30080), którego selector `slot` wskazuje aktywny slot.
  Przełączanie: `scripts/green-blue-switch.sh`.
- DAG-i: `dags/` w repo to przykłady; w klastrze DAG-i pochodzą z bucketu
  `{project}-airflow-spark-dags/dags/{username}/` (izolacja per analityk przez `access_control`).

## Struktura

| Katalog | Zawartość |
|---------|-----------|
| `terraform/` | GCP: `main.tf` (provider, API), `network.tf`, `vms.tf`, `gcs.tf`, `variables.tf`, `outputs.tf` |
| `scripts/` | `deploy.sh`/`destroy.sh` (wrappery Terraform), skrypty startowe VM, `green-blue-switch.sh` |
| `helm/` | values dla Airflow (green/blue), JupyterHub, monitoringu |
| `k8s/` | surowe manifesty: Service przełączający, PrometheusRules |
| `dags/` | przykładowe DAG-i Airflow 2.9 |
| `notebooks/` | helper integracji JupyterHub ↔ Airflow |

## Polecenia: lint i walidacja (bezpieczne, uruchamiaj lokalnie)

Te same kroki uruchamia `.github/workflows/lint.yml` na każdym PR do `main` (bez sekretów; reusable przez
`workflow_call`). Wersje narzędzi są przypięte w `env:` workflow — lokalnie używaj tych samych.
Konfiguracja: `ruff.toml` (py311, reguły E/W/F/I/UP, bez E501), `.tflint.hcl` (preset recommended + plugin Google),
`.yamllint.yaml` (relaxed, bez limitu długości linii).

```bash
# Terraform
terraform -chdir=terraform fmt -check -recursive -diff
terraform -chdir=terraform init -backend=false
terraform -chdir=terraform validate
(cd terraform && tflint --init --config ../.tflint.hcl && tflint --config ../.tflint.hcl)

# Skrypty bash (w tym skrypty startowe VM)
for f in scripts/*.sh; do bash -n "$f"; done
shellcheck --severity=warning scripts/*.sh

# Python (DAG-i, notebooks, stress_test.py)
ruff check .            # ruff check --fix . naprawia m.in. kolejność importów

# YAML (values Helm, manifesty k8s, workflow)
yamllint helm/ k8s/ .github/

# Helm — render values Airflow względem przypiętego chartu (wersja = master-init.sh / green-blue-switch.sh)
helm repo add apache-airflow https://airflow.apache.org
helm template t apache-airflow/airflow --version 1.15.0 -f helm/airflow/values-green.yaml > /dev/null
helm template t apache-airflow/airflow --version 1.15.0 -f helm/airflow/values-blue.yaml > /dev/null
```

Zmieniając wersję chartu Airflow, zaktualizuj ją w trzech miejscach: `master-init.sh`, `green-blue-switch.sh`
i `AIRFLOW_CHART_VERSION` w `lint.yml`.

Jeśli narzędzie nie jest zainstalowane, napisz to wprost zamiast pomijać krok po cichu.

## Polecenia: odczyt stanu (tylko read-only)

```bash
terraform -chdir=terraform plan -var="project_id=$PROJECT_ID"   # tylko podgląd, nigdy apply
terraform -chdir=terraform output
./scripts/green-blue-switch.sh status                           # aktywny slot, wersje, gotowość
kubectl get nodes -o wide
kubectl get pods -A
kubectl get svc airflow-active -n airflow -o jsonpath='{.spec.selector.slot}'
helm list -A
kubectl logs -n airflow -l component=scheduler --tail=100
ssh ubuntu@<MASTER_IP> tail -n 200 /var/log/master-init.log
```

## Zasady

### Zmiany infrastruktury wyłącznie przez GitHub Actions

- **Nie uruchamiaj lokalnie** poleceń zmieniających infrastrukturę: `terraform apply`, `terraform destroy`,
  `./scripts/deploy.sh`, `./scripts/destroy.sh`, `helm install/upgrade/uninstall`,
  `kubectl apply/patch/delete/scale`, `./scripts/green-blue-switch.sh switch|deploy|rollback`,
  `gcloud compute ... create/delete`, `gsutil cp/rm` do bucketów kursu.
  Egzekwuje to blokada w `.claude/settings.json` (patrz niżej).
- Zmiana infrastruktury = zmiana w kodzie → branch → pull request do `main` → lint i review w CI →
  merge → wdrożenie z `main` przez GitHub Actions po zatwierdzeniu przez człowieka (environment z required reviewers).
- Lokalnie wolno tylko lintować, walidować i czytać stan (sekcje wyżej).
- Nie commituj sekretów: `.env`, `*.tfstate`, kluczy, `*-secret.yaml`. Hasła trafiają do Terraform jako zmienne
  (`-var` / sekrety GitHub Actions), nigdy jako wartości w plikach.

### Wdrożenie: `.github/workflows/deploy.yml`

- Uruchamiany ręcznie (`workflow_dispatch`), tylko z `main` (job `guard`). Inputy `run_apply` i `run_smoke_test`
  są domyślnie wyłączone — domyślny run to lint (reusable `lint.yml`) + `terraform plan`.
- `apply` działa w environment `production` z required reviewers — **człowiek zatwierdza każde wdrożenie**.
- Uwierzytelnienie do GCP: Workload Identity Federation (bez kluczy JSON).
- Parametry: projekt i hasła jako `TF_VAR_*` (`vars.GCP_PROJECT_ID`, `secrets.*_PASSWORD`), klucz SSH jako
  `TF_VAR_ssh_public_key` z `vars.SSH_PUBLIC_KEY`. Lokalnie `ssh_public_key` jest puste → fallback na plik
  `ssh_pub_key_path`; brak obu zatrzymuje plan (`precondition` na masterze).
- State: `backend "gcs" {}` w `terraform/main.tf`; bucket i prefix tylko przez `-backend-config`
  (`vars.TF_STATE_BUCKET`, `vars.TF_STATE_PREFIX`, domyślnie `airflow-spark/terraform`).
  Lokalnie (`deploy.sh`/`destroy.sh`) z `TF_STATE_BUCKET`/`TF_STATE_PREFIX` w `.env`. Lint używa `init -backend=false`.
- Migracja wcześniejszego lokalnego state (jednorazowo, wykonuje **administrator** przed pierwszym uruchomieniem CI,
  nie Claude Code): utworzyć bucket z wersjonowaniem, potem
  `terraform -chdir=terraform init -migrate-state -backend-config="bucket=..." -backend-config="prefix=..."`
  i sprawdzić `terraform plan` (oczekiwane: brak zmian poza ewentualnym kluczem SSH).

### Blokada wdrożeń w Claude Code (`.claude/settings.json`)

`permissions.deny` w `.claude/settings.json` (commitowany do repo, wyjątek `!.claude/settings.json`
w `.gitignore`; `.claude/settings.local.json` pozostaje ignorowany) blokuje:

| Obszar | Zablokowane | Dozwolone (odczyt/walidacja) |
|--------|-------------|------------------------------|
| Terraform | `apply`, `destroy`, `import`, `taint`/`untaint`, `force-unlock`, `state rm/mv/push/replace-provider`, `workspace delete` — także z `-chdir=...` | `init`, `fmt`, `validate`, `plan`, `output`, `show`, `state list/show` |
| gcloud | `create`, `delete`, `update`, `patch`, `deploy`, `start/stop/reset/resize`, `enable/disable`, `add-*`/`remove-*`/`set-*`, `cp/mv/rm/rsync` | `list`, `describe`, `get-*`, `config list` |
| gsutil | `cp`, `mv`, `rm`, `rsync`, `mb`, `rb`, `setmeta`, `acl`, `iam`, `lifecycle`, `versioning` (także po `-m`) | `ls`, `cat`, `du`, `stat` |
| kubectl | `apply`, `create`, `delete`, `patch`, `replace`, `scale`, `edit`, `set`, `label`, `annotate`, `rollout`, `cordon/drain/taint`, `exec`, `cp`, `run`, `expose` (także po `-n ns`) | `get`, `describe`, `logs`, `top`, `explain`, `diff` |
| Helm | `install`, `upgrade`, `uninstall`/`delete`, `rollback` | `list`, `status`, `template`, `lint`, `repo add/update` |
| Skrypty | `deploy.sh`, `destroy.sh` w każdej formie: `./scripts/...`, `scripts/...`, ścieżka bezwzględna, `bash`/`sh`/`source` | odczyt plików narzędziem Read |
| green/blue | `green-blue-switch.sh deploy`, `switch`, `rollback` | `green-blue-switch.sh status` |
| Sekrety | odczyt/edycja `.env` (Read, Edit, `cat .env`, `source .env`, `< .env`) | `.env.example` |

Uwagi:

- Wzorce kończą się `*` bez spacji (np. `terraform apply*`), więc łapią też polecenia bez argumentów końcowych.
- Claude Code sprawdza każde podpolecenie osobno, więc `cd terraform && terraform apply` też jest blokowane.
- Odmowa uprawnień oznacza: **nie obchodź blokady** (inny wrapper, `eval`, skrypt tymczasowy) — przygotuj zmianę
  w kodzie i PR, a wdrożenie wykona GitHub Actions.
- Zmiana `.claude/settings.json` to zmiana zasad bezpieczeństwa — tylko przez PR z review.

### Conventional Commits

Wiadomości commitów i tytuły PR-ów w formacie [Conventional Commits](https://www.conventionalcommits.org/):

```
<typ>(<zakres>): <opis w trybie rozkazującym>
```

- Typy: `feat`, `fix`, `docs`, `chore`, `refactor`, `ci`, `test`, `perf`, `build`, `revert`.
- Zakresy dopasowane do repo: `terraform`, `scripts`, `helm`, `k8s`, `dags`, `monitoring`, `ci`, `claude`.
- Zmiana łamiąca (np. wymagająca odtworzenia VM lub migracji bazy Airflow): `!` po typie/zakresie
  i stopka `BREAKING CHANGE: ...`.
- Przykłady: `feat(helm): add blue slot resources`, `fix(scripts): retry kubeadm join on GCS timeout`,
  `ci: add terraform plan workflow`, `docs(claude): add lint commands to CLAUDE.md`.

### Praca z gałęziami

- Nie commituj bezpośrednio do `main`. Każde zadanie = osobny branch + pull request do `main`.
- Przed PR uruchom lint dla zmienionych obszarów.
