#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="kasten-io"
SECRET_NAME="k10-s3-secret"

DEFAULT_ENDPOINT="http://192.168.1.130:9000"
DEFAULT_BUCKET="kasten"
DEFAULT_PROFILE_NAME="minio"

echo "=============================================="
echo "  Kasten K10 - Crear Profile S3 (MinIO)"
echo "=============================================="
echo

# ---------------------------
# Función para leer con default
# ---------------------------

read_with_default() {
  local prompt="$1"
  local default="$2"
  local input

  read -rp "${prompt} [ENTER para usar '${default}']: " input

  if [[ -z "$input" ]]; then
    echo "$default"
  else
    echo "$input"
  fi
}

# ---------------------------
# Leer datos del usuario
# ---------------------------

ENDPOINT=$(read_with_default "Endpoint MinIO (con puerto)" "$DEFAULT_ENDPOINT")
BUCKET_NAME=$(read_with_default "Nombre del bucket" "$DEFAULT_BUCKET")
PROFILE_NAME=$(read_with_default "Nombre del profile" "$DEFAULT_PROFILE_NAME")

echo
echo "Resumen utilizado:"
echo "  Endpoint:  ${ENDPOINT}"
echo "  Bucket:    ${BUCKET_NAME}"
echo "  Profile:   ${PROFILE_NAME}"
echo

read -rp "Access Key S3: " ACCESS_KEY
read -rp "Secret Key S3: " SECRET_KEY

if [[ -z "$ACCESS_KEY" || -z "$SECRET_KEY" ]]; then
  echo "[ERROR] Las credenciales no pueden estar vacías."
  exit 1
fi

echo
echo "[INFO] Creando/actualizando Secret ${SECRET_NAME} en ${NAMESPACE}..."

sudo kubectl create secret generic "${SECRET_NAME}" \
  --namespace "${NAMESPACE}" \
  --type secrets.kanister.io/aws \
  --from-literal=aws_access_key_id="${ACCESS_KEY}" \
  --from-literal=aws_secret_access_key="${SECRET_KEY}" \
  --dry-run=client -o yaml | sudo kubectl apply -f -

echo "[OK] Secret listo."
echo

# ---------------------------
# Crear YAML del Profile
# ---------------------------

YAML_FILE="profile-${PROFILE_NAME}.yaml"
echo "[INFO] Generando ${YAML_FILE}..."

cat << EOF > "${YAML_FILE}"
apiVersion: config.kio.kasten.io/v1alpha1
kind: Profile
metadata:
  name: ${PROFILE_NAME}
  namespace: ${NAMESPACE}
spec:
  locationSpec:
    type: ObjectStore
    objectStore:
      endpoint: "${ENDPOINT}"
      name: "${BUCKET_NAME}"
      objectStoreType: S3
      skipSSLVerify: true
    credential:
      secretType: AwsAccessKey
      secret:
        apiVersion: v1
        kind: secret
        name: ${SECRET_NAME}
        namespace: ${NAMESPACE}
  type: Location
EOF

echo "[OK] YAML generado en:"
echo "  ${YAML_FILE}"
echo

# ---------------------------
# Aplicar perfil en Kasten
# ---------------------------

echo "[INFO] Aplicando profile en Kasten..."
sudo kubectl apply -f "${YAML_FILE}"

echo
echo "[INFO] Profiles en '${NAMESPACE}':"
sudo kubectl get profiles.config.kio.kasten.io -n "${NAMESPACE}"

echo
echo "======================================================="
echo " ✔ PROCESO COMPLETADO"
echo " Profile:  ${PROFILE_NAME}"
echo " Bucket:   ${BUCKET_NAME}"
echo " Endpoint: ${ENDPOINT}"
echo " Namespace:${NAMESPACE}"
echo " Secret:   ${SECRET_NAME}"
echo " YAML:     ${YAML_FILE}"
echo "======================================================="

