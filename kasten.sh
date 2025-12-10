#!/usr/bin/env bash
# Script para instalar K3s + Kasten K10 en Ubuntu 22.04 o superior

set -euo pipefail

K10_DEFAULT_VERSION="8.0.7"
K3S_KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
K10_PRIMER_BASE_URL="https://docs.kasten.io/downloads"

# ------------------------------
# Funciones auxiliares
# ------------------------------

ask_yes_no() {
  local prompt="$1"
  local default="${2:-y}" # y/n

  local suffix="[y/N]"
  [[ "$default" == "y" ]] && suffix="[Y/n]"

  while true; do
    read -r -p "$prompt $suffix " reply
    reply="${reply:-$default}"
    case "$reply" in
      [Yy]* ) return 0 ;;
      [Nn]* ) return 1 ;;
      * ) echo "Por favor responde 'y' o 'n'." ;;
    esac
  done
}

check_cmd() {
  local cmd="$1"
  if command -v "$cmd" >/dev/null 2>&1; then
    return 0
  else
    return 1
  fi
}

wait_for_nodes_ready() {
  echo "Esperando a que el/los nodos de K3s estén en estado Ready..."
  until kubectl --kubeconfig "$K3S_KUBECONFIG" get nodes >/dev/null 2>&1; do
    echo "  Aún no responde el API Server de K3s, reintentando en 5s..."
    sleep 5
  done

  # Espera adicional a que el nodo esté Ready
  until kubectl --kubeconfig "$K3S_KUBECONFIG" get nodes | grep -q " Ready"; do
    kubectl --kubeconfig "$K3S_KUBECONFIG" get nodes
    echo "  El nodo todavía no está Ready, reintentando en 5s..."
    sleep 5
  done

  echo "✅ Nodo(s) de K3s en estado Ready."
}

wait_for_kasten_pods() {
  echo "Esperando a que los pods de Kasten estén en estado Running/Ready..."
  while true; do
    NOT_READY=$(kubectl --kubeconfig "$K3S_KUBECONFIG" -n kasten-io get pods --no-headers 2>/dev/null | awk '$3 != "Running" && $3 != "Completed" {print}')
    if [[ -z "$NOT_READY" ]]; then
      kubectl --kubeconfig "$K3S_KUBECONFIG" -n kasten-io get pods
      echo "✅ Todos los pods de Kasten parecen estar running."
      break
    else
      kubectl --kubeconfig "$K3S_KUBECONFIG" -n kasten-io get pods || true
      echo "  Aún hay pods que no estan listos, reintentando en 5s..."
      sleep 5
    fi
  done
}

# ------------------------------
# Validaciones iniciales
# ------------------------------

if [[ "$EUID" -ne 0 ]]; then
  echo "Por favor ejecuta este script como root, por ejemplo:"
  echo "  sudo bash $0"
  exit 1
fi

if ! command -v lsb_release >/dev/null 2>&1; then
  echo "Instalando lsb-release para detectar versión de Ubuntu..."
  apt-get update -y
  apt-get install -y lsb-release
fi

UBUNTU_VERSION="$(lsb_release -rs || echo "desconocida")"
if [[ "$UBUNTU_VERSION" != 22.* ]]; then
  echo "⚠ Atención: este script está pensado para Ubuntu 22.x o superior, pero detecté: $UBUNTU_VERSION"
  if ! ask_yes_no "¿Deseas continuar de todas formas?" "n"; then
    exit 1
  fi
fi

DEFAULT_USER="${SUDO_USER:-$USER}"
read -r -p "Usuario Linux dueño de ~/.kube [${DEFAULT_USER}]: " KUBE_USER
KUBE_USER="${KUBE_USER:-$DEFAULT_USER}"

if ! id "$KUBE_USER" >/dev/null 2>&1; then
  echo "❌ El usuario '$KUBE_USER' no existe en el sistema."
  exit 1
fi

KUBE_HOME=$(eval echo "~$KUBE_USER")
if [[ ! -d "$KUBE_HOME" ]]; then
  echo "❌ No se encontró el home del usuario $KUBE_USER en $KUBE_HOME"
  exit 1
fi

IP_CANDIDATE="$(hostname -I 2>/dev/null | awk '{print $1}')"
read -r -p "IP que se utilizara para acceder a Kasten [${IP_CANDIDATE}]: " SERVER_IP
SERVER_IP="${SERVER_IP:-$IP_CANDIDATE}"

echo
echo "Resumen:"
echo "  - Usuario dueño de kubeconfig: $KUBE_USER ($KUBE_HOME)"
echo "  - IP para acceder a Kasten (si es NodePort debe ser la misma que el servidor): $SERVER_IP"
echo

if ! ask_yes_no "¿Confirmás continuar con estas opciones?" "y"; then
  echo "Instalación cancelada por el usuario."
  exit 0
fi

# ------------------------------
# Paso 1: Instalar / validar K3s
# ------------------------------

if ask_yes_no "¿Deseas instalar/verificar K3s?" "y"; then
  if check_cmd k3s; then
    echo "✅ K3s ya está instalado (se encontró el comando 'k3s')."
  else
    echo "Instalando K3s (curl -sfL https://get.k3s.io | sh)..."
    curl -sfL https://get.k3s.io | sh -
  fi

  wait_for_nodes_ready
else
  echo "⏭ Saltando instalación de K3s (asumiendo que ya existe un clúster y KUBECONFIG=$K3S_KUBECONFIG es válido)."
fi

# ------------------------------
# Paso 2: Instalar / validar Helm
# ------------------------------

if ask_yes_no "¿Deseas instalar/verificar Helm 3?" "y"; then
  if check_cmd helm; then
    echo "✅ Helm ya está instalado."
  else
    echo "Instalando Helm 3..."
    curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash
  fi
else
  echo "⏭ Saltando instalación de Helm."
fi

# ------------------------------
# Paso 3: Configurar kubeconfig para el usuario
# ------------------------------

if ask_yes_no "¿Deseas configurar ~/.kube/config para el usuario $KUBE_USER?" "y"; then
  echo "Creando el directorio ~/.kube si no existe..."
  mkdir -p "$KUBE_HOME/.kube"
  chown -R "$KUBE_USER":"$KUBE_USER" "$KUBE_HOME/.kube"

  echo "Exportando kubeconfig desde K3s a $KUBE_HOME/.kube/config..."
  KUBECONFIG="$K3S_KUBECONFIG" kubectl config view --raw > "$KUBE_HOME/.kube/config"
  chown "$KUBE_USER":"$KUBE_USER" "$KUBE_HOME/.kube/config"

  # Opcional: también dejar kubeconfig para root
  mkdir -p /root/.kube
  KUBECONFIG="$K3S_KUBECONFIG" kubectl config view --raw > /root/.kube/config

  echo "✅ kubeconfig configurado para $KUBE_USER y root."
fi

# ------------------------------
# Paso 4: Helm repo Kasten + jq
# ------------------------------

if ask_yes_no "¿Deseas agregar/actualizar el repositorio Helm de Kasten?" "y"; then
  if helm repo list 2>/dev/null | grep -q "^kasten"; then
    echo "Repositorio 'kasten' ya existe, ejecutando 'helm repo update'..."
    helm repo update
  else
    echo "Agregando repositorio Helm de Kasten..."
    helm repo add kasten https://charts.kasten.io
    helm repo update
  fi
fi

if ask_yes_no "¿Deseas instalar el paquete 'jq' (recomendado)?" "y"; then
  echo "Instalando jq..."
  apt-get update -y
  apt-get install -y jq
fi

# ------------------------------
# Paso 5: Namespace kasten-io
# ------------------------------

if ask_yes_no "¿Deseas crear el namespace 'kasten-io'?" "y"; then
  if kubectl --kubeconfig "$K3S_KUBECONFIG" get ns kasten-io >/dev/null 2>&1; then
    echo "✅ Namespace 'kasten-io' ya existe."
  else
    echo "Creando namespace 'kasten-io'..."
    kubectl --kubeconfig "$K3S_KUBECONFIG" create ns kasten-io
  fi
fi

# ------------------------------
# Paso 6: Ejecutar K10 preflight
# ------------------------------

if ask_yes_no "¿Deseas ejecutar el script pre-flight check --> k10_primer.sh ?" "y"; then
  read -r -p "Versión de Kasten para el primer [${K10_DEFAULT_VERSION}]: " K10_PRIMER_VERSION
  K10_PRIMER_VERSION="${K10_PRIMER_VERSION:-$K10_DEFAULT_VERSION}"

  PRIMER_URL="${K10_PRIMER_BASE_URL}/${K10_PRIMER_VERSION}/tools/k10_primer.sh"
  echo "Descargando k10_primer desde: $PRIMER_URL"
  curl -s "$PRIMER_URL" -o /tmp/k10_primer.sh
  chmod +x /tmp/k10_primer.sh

  echo "Ejecutando k10_primer.sh ..."
  KUBECONFIG="$K3S_KUBECONFIG" /tmp/k10_primer.sh || {
    echo "⚠ El script devolvió algún error. Revisa la salida anterior."
  }
fi

# ------------------------------
# Paso 7: Instalar Kasten K10 con Helm
# ------------------------------

if ask_yes_no "¿Deseas instalar Kasten K10 utilizando Helm?" "y"; then
  if helm --kubeconfig "$K3S_KUBECONFIG" -n kasten-io list 2>/dev/null | grep -q "^k10"; then
    echo "⚠ Ya existe un release 'k10' en el namespace 'kasten-io'. No se instalará de nuevo."
  else
    echo "Instalando Kasten K10:"
    echo "  helm install k10 kasten/k10 --namespace kasten-io --kubeconfig $K3S_KUBECONFIG"
    helm install k10 kasten/k10 --namespace kasten-io --kubeconfig "$K3S_KUBECONFIG"
  fi

  wait_for_kasten_pods
fi

# ------------------------------
# Paso 8: Exponer gateway por NodePort + puerto 8080
# ------------------------------

if ask_yes_no "¿Deseas configurar el servicio 'gateway' de Kasten como NodePort y utilizar el puerto 8080?" "y"; then
  if ! kubectl --kubeconfig "$K3S_KUBECONFIG" -n kasten-io get svc gateway >/dev/null 2>&1; then
    echo "❌ No se encontró el servicio 'gateway' en el namespace 'kasten-io'."
    echo "   Revisa que la instalación de Kasten se haya completado correctamente."
  else
    echo "Configurando tipo de servicio a NodePort, externalIPs con la IP configurada y el puerto http 8080..."

    kubectl --kubeconfig "$K3S_KUBECONFIG" -n kasten-io patch svc gateway \
      --type='merge' \
      -p "{
            \"spec\": {
              \"type\": \"NodePort\",
              \"externalIPs\": [\"$SERVER_IP\"],
              \"ports\": [
                {
                  \"name\": \"http\",
                  \"protocol\": \"TCP\",
                  \"port\": 8080,
                  \"targetPort\": 8000
                }
              ]
            }
          }"

    echo "✅ Servicio gateway actualizado:"
    kubectl --kubeconfig "$K3S_KUBECONFIG" -n kasten-io get svc gateway -o wide
  fi
else
  echo "⏭ Saltando configuración automática del servicio gateway."
  echo "   Si lo deseas, puedes editarlo manualmente con:"
  echo "     kubectl -n kasten-io edit svc gateway"
fi



# ------------------------------
# Paso 9: Mostrar URL de acceso
# ------------------------------

echo
echo "==========================================="
echo "Instalación y configuración finalizadas."
echo "Si configuraste el servicio gateway como NodePort con puerto 8080,"
echo "deberías poder acceder a la consola de Kasten en:   http://${SERVER_IP}:8080/k10/# "
echo
echo "==========================================="
echo "Listo. Ya tenes instalado Kasten, valida el acceso."
echo "Happy to help - MJ."


