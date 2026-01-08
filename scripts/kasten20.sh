#!/usr/bin/env bash
# Instalación "all-in-one" para homeLab o demo:
# validaciones -> helm -> k3s -> longhorn -> borrar local-path -> mysql -> kasten

#Proximos pasos
# Agregar espera luego de instalar Longhorn para que todos los pods queden en running.
# Cambiar el mysql por el pacman para tener app + db

echo "La idea del siguiente script es poder desarrollar la solución Veeam Kasten en un ambiente demo."
echo "Si se realizan todos los pasos, es posible poder tener configurado un ambiente con App Mob + B&R + DRP"
echo "Se utiliza el CSI Longhorn ya que tiene manejo automatico de creación de PV+PVC"
echo "Espero que te sea útil! Cualquier duda / consulta me puedes escribir"
echo "Enjoy!"
echo "#"
echo "#"
echo "#"
echo "#"
echo " "


set -euo pipefail

# ------------------------------
# Variables
# ------------------------------
K10_DEFAULT_VERSION="8.0.14"
K3S_KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
K10_PRIMER_BASE_URL="https://docs.kasten.io/downloads"

# ------------------------------
# Funciones auxiliares (mismo estilo que kasten.sh)
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
  command -v "$cmd" >/dev/null 2>&1
}

wait_for_nodes_ready() {
  echo "Esperando a que el/los nodos de K3s estén en estado Ready..."
  until kubectl --kubeconfig "$K3S_KUBECONFIG" get nodes >/dev/null 2>&1; do
    echo "  Aún no responde el API Server de K3s, reintentando en 5s..."
    sleep 5
  done

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

wait_for_longhorn() {
  echo "Esperando que los pods de Longhorn estén Ready (hasta 300s)..."
  kubectl --kubeconfig "$K3S_KUBECONFIG" wait --for=condition=Ready pod --all -n longhorn-system --timeout=300s || {
    echo "No todos los pods de Longhorn llegaron a Ready. Revisar con:"
    echo "kubectl --kubeconfig $K3S_KUBECONFIG -n longhorn-system get pods"
  }

  echo "Pods en longhorn-system:"
  kubectl --kubeconfig "$K3S_KUBECONFIG" -n longhorn-system get pods

  echo "StorageClasses disponibles:"
  kubectl --kubeconfig "$K3S_KUBECONFIG" get storageclass
}

wait_for_snapshot_controller() {
  echo "Esperando snapshot-controller Ready (hasta 120s)..."
  kubectl --kubeconfig "$K3S_KUBECONFIG" wait --for=condition=Ready pod -l app=snapshot-controller -n kube-system --timeout=120s || {
    echo "⚠ snapshot-controller no llegó a Ready aún. Revisar con:"
    echo "   kubectl --kubeconfig $K3S_KUBECONFIG get pods -n kube-system | grep snapshot"
  }

  echo "Pods relacionados a snapshot en kube-system:"
  kubectl --kubeconfig "$K3S_KUBECONFIG" get pods -n kube-system | grep snapshot || echo "  (puede tardar unos segundos en aparecer)"
}


validate_environment() {
  echo "==========================================="
  echo " Instalación All-in-One (K3s + Longhorn + MySQL + Kasten)"
  echo "==========================================="
  echo

  if [[ "$EUID" -ne 0 ]]; then
    echo "Por favor ejecuta este script como root, por ejemplo:"
    echo "  sudo bash $0"
    exit 1
  fi

  if ! check_cmd lsb_release; then
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
  read -r -p "IP que se utilizara para acceder a Kasten (NodePort) [${IP_CANDIDATE}]: " SERVER_IP
  SERVER_IP="${SERVER_IP:-$IP_CANDIDATE}"

  echo
  echo "Resumen:"
  echo "  - Usuario dueño de kubeconfig: $KUBE_USER ($KUBE_HOME)"
  echo "  - IP para acceder a Kasten (NodePort): $SERVER_IP"
  echo

  if ! ask_yes_no "¿Confirmás continuar con estas opciones?" "y"; then
    echo "Instalación cancelada por el usuario."
    exit 0
  fi
}

install_helm() {
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
}

install_k3s() {
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
}

configure_kubeconfig_for_user() {
  if ask_yes_no "¿Deseas configurar ~/.kube/config para el usuario $KUBE_USER?" "y"; then
    echo "Creando el directorio ~/.kube si no existe..."
    mkdir -p "$KUBE_HOME/.kube"
    chown -R "$KUBE_USER":"$KUBE_USER" "$KUBE_HOME/.kube"

    echo "Exportando kubeconfig desde K3s a $KUBE_HOME/.kube/config..."
    KUBECONFIG="$K3S_KUBECONFIG" kubectl config view --raw > "$KUBE_HOME/.kube/config"
    chown "$KUBE_USER":"$KUBE_USER" "$KUBE_HOME/.kube/config"

    mkdir -p /root/.kube
    KUBECONFIG="$K3S_KUBECONFIG" kubectl config view --raw > /root/.kube/config

    echo "✅ kubeconfig configurado para $KUBE_USER y root."
  fi
}

install_longhorn_keep_as_is() {
  if ask_yes_no "¿Deseas instalar Longhorn?" "y"; then
    echo "Instalando dependencias (open-iscsi, nfs-common)..."
    apt-get update -y
    apt-get install -y open-iscsi nfs-common
    systemctl enable iscsid
    systemctl start iscsid

    echo "Instalando Longhorn..."
    kubectl --kubeconfig "$K3S_KUBECONFIG" apply -f https://raw.githubusercontent.com/longhorn/longhorn/master/deploy/longhorn.yaml

    wait_for_longhorn
  else
    echo "⏭ Saltando instalación de Longhorn."
  fi
}

install_snapshot_crds_and_class_keep_as_is() {
  if ask_yes_no "¿Deseas instalar CRDs de CSI Snapshot + snapshot-controller + VolumeSnapshotClass?" "y"; then
    echo "Instalando CRDs de CSI Snapshot..."
    kubectl --kubeconfig "$K3S_KUBECONFIG" apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml
    kubectl --kubeconfig "$K3S_KUBECONFIG" apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml
    kubectl --kubeconfig "$K3S_KUBECONFIG" apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml

    echo "Instalando snapshot-controller..."
    kubectl --kubeconfig "$K3S_KUBECONFIG" apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml
    kubectl --kubeconfig "$K3S_KUBECONFIG" apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml

    wait_for_snapshot_controller

    echo "Creando VolumeSnapshotClass para Longhorn..."
    cat << 'EOF' > /tmp/longhorn-snapclass.yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: longhorn-snapclass
  annotations:
    k10.kasten.io/is-snapshot-class: "true"
driver: driver.longhorn.io
deletionPolicy: Delete
parameters:
  type: snap
EOF

    kubectl --kubeconfig "$K3S_KUBECONFIG" apply -f /tmp/longhorn-snapclass.yaml

    echo "VolumeSnapshotClass actuales:"
    kubectl --kubeconfig "$K3S_KUBECONFIG" get volumesnapshotclass
    echo "#####"
    echo "#####"

    echo "Validando que exista longhorn-snapclass..."
    echo "#####"
    kubectl --kubeconfig "$K3S_KUBECONFIG" get volumesnapshotclass longhorn-snapclass >/dev/null 2>&1 || {
      echo "❌ No se encontró VolumeSnapshotClass 'longhorn-snapclass'."
      exit 1
    }

    echo "Validando anotación k10.kasten.io/is-snapshot-class=true..."
    echo "#####"
    ANNOTATION_VALUE=$(kubectl --kubeconfig "$K3S_KUBECONFIG" get volumesnapshotclass longhorn-snapclass -o jsonpath='{.metadata.annotations.k10\.kasten\.io/is-snapshot-class}' || echo "")
    if [[ "$ANNOTATION_VALUE" != "true" ]]; then
      echo "❌ La VolumeSnapshotClass 'longhorn-snapclass' no tiene la anotación k10.kasten.io/is-snapshot-class=true."
      exit 1
    fi
    echo "Snapshot CRDs + Controller + VolumeSnapshotClass listos."
  else
    echo "Saltando Snapshot CRDs/Controller/VolumeSnapshotClass."
  fi
}

remove_local_path_and_set_longhorn_default() {
  if ask_yes_no "¿Deseas borrar el StorageClass local-path y dejar solo Longhorn (y setearlo default)?" "y"; then
    echo "Desmarcando local-path como default (si existe)..."
    kubectl --kubeconfig "$K3S_KUBECONFIG" patch storageclass local-path \
      -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' >/dev/null 2>&1 || true

    echo "Borrando StorageClass local-path (si existe)..."
    kubectl --kubeconfig "$K3S_KUBECONFIG" delete storageclass local-path >/dev/null 2>&1 || true

    echo "Marcando Longhorn como StorageClass default..."
    kubectl --kubeconfig "$K3S_KUBECONFIG" patch storageclass longhorn \
      -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' >/dev/null 2>&1 || {
        echo "No pude setear 'longhorn' como default. Verificá que exista el storageclass 'longhorn'."
        kubectl --kubeconfig "$K3S_KUBECONFIG" get storageclass || true
        exit 1
      }

    echo "✅ StorageClasses actuales:"
    kubectl --kubeconfig "$K3S_KUBECONFIG" get storageclass
  else
    echo "⏭ Saltando eliminación de local-path."
  fi
}

install_mysql_keep_as_is() {
  if ask_yes_no "¿Deseas instalar MySQL (namespace mysqlong)?" "y"; then
    echo "Creando namespace 'mysqlong' (si no existe)..."
    if kubectl --kubeconfig "$K3S_KUBECONFIG" get namespace mysqlong >/dev/null 2>&1; then
      echo "✅ Namespace 'mysqlong' ya existe, se reutiliza."
    else
      kubectl --kubeconfig "$K3S_KUBECONFIG" create namespace mysqlong
    fi

    echo "Creando PVC para MySQL en namespace 'mysqlong'..."
    cat << 'EOF' > /tmp/mysql-pv-long.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mysql-pv-claim
  namespace: mysqlong
spec:
  storageClassName: longhorn
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 20Gi
EOF
    kubectl --kubeconfig "$K3S_KUBECONFIG" apply -f /tmp/mysql-pv-long.yaml

    echo "Esperando que el PVC mysql-pv-claim esté Bound (hasta 120s)..."
    kubectl --kubeconfig "$K3S_KUBECONFIG" wait --for=jsonpath='{.status.phase}'=Bound pvc/mysql-pv-claim -n mysqlong --timeout=120s || {
      echo "❌ El PVC 'mysql-pv-claim' no llegó a estado Bound."
      kubectl --kubeconfig "$K3S_KUBECONFIG" get pvc -n mysqlong || true
      exit 1
    }

    echo "Creando Service + Deployment de MySQL (ClusterIP, MySQL 8.0)..."
    cat << 'EOF' > /tmp/mysql-deploy-long.yaml
apiVersion: v1
kind: Service
metadata:
  name: mysql
  namespace: mysqlong
spec:
  type: ClusterIP
  ports:
    - port: 3306
      targetPort: 3306
  selector:
    app: mysql
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mysql
  namespace: mysqlong
spec:
  selector:
    matchLabels:
      app: mysql
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: mysql
    spec:
      containers:
      - name: mysql
        image: mysql:8.0
        env:
        - name: MYSQL_ROOT_PASSWORD
          value: password
        ports:
        - containerPort: 3306
          name: mysql
        volumeMounts:
        - name: mysql-persistent-storage
          mountPath: /var/lib/mysql
      volumes:
      - name: mysql-persistent-storage
        persistentVolumeClaim:
          claimName: mysql-pv-claim
EOF
    kubectl --kubeconfig "$K3S_KUBECONFIG" apply -f /tmp/mysql-deploy-long.yaml

    echo "Esperando rollout completo del Deployment mysql (hasta 180s)..."
    kubectl --kubeconfig "$K3S_KUBECONFIG" rollout status deployment/mysql -n mysqlong --timeout=180s || {
      echo "❌ El Deployment 'mysql' no pudo completar el rollout correctamente."
      kubectl --kubeconfig "$K3S_KUBECONFIG" get pods -n mysqlong || true
      exit 1
    }

    echo "Pods en el namespace 'mysqlong':"
    kubectl --kubeconfig "$K3S_KUBECONFIG" get pods -n mysqlong

    echo "Esperan do que MySQL esté listo para aceptar conexiones..."
MYSQL_POD=$(kubectl --kubeconfig "$K3S_KUBECONFIG" -n mysqlong get pod -l app=mysql -o jsonpath='{.items[0].metadata.name}')

for i in {1..30}; do
  if kubectl --kubeconfig "$K3S_KUBECONFIG" exec -n mysqlong "$MYSQL_POD" -- \
       mysql -u root -ppassword -e "SELECT 1;" >/dev/null 2>&1; then
    echo "✅ MySQL responde correctamente."
    break
  fi
  echo "  MySQL aún no responde, reintentando en 5s... ($i/30)"
  sleep 5
done

if ! kubectl --kubeconfig "$K3S_KUBECONFIG" exec -n mysqlong "$MYSQL_POD" -- \
     mysql -u root -ppassword -e "SHOW DATABASES;" >/dev/null 2>&1; then
  echo "❌ MySQL no respondió luego de esperar. Revisar logs:"
  kubectl --kubeconfig "$K3S_KUBECONFIG" logs -n mysqlong "$MYSQL_POD"
  exit 1
fi

    echo "✅ MySQL listo y validado."
  else
    echo "⏭ Saltando instalación de MySQL."
  fi
}

install_kasten_last() {
  echo
  echo "------------------------------"
  echo "### Kasten ### "
  echo "------------------------------"
  echo

  if ! ask_yes_no "¿Deseas instalar Kasten K10 ahora (último paso del script)?" "y"; then
    echo "⏭ Saltando instalación de Kasten."
    return 0
  fi

  # Repo Helm Kasten
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

  # jq 
  if ask_yes_no "¿Deseas instalar el paquete 'jq' (recomendado)?" "y"; then
    echo "Instalando jq..."
    apt-get update -y
    apt-get install -y jq
  fi

  # Namespace
  if ask_yes_no "¿Deseas crear el namespace 'kasten-io'?" "y"; then
    if kubectl --kubeconfig "$K3S_KUBECONFIG" get ns kasten-io >/dev/null 2>&1; then
      echo "✅ Namespace 'kasten-io' ya existe."
    else
      echo "Creando namespace 'kasten-io'..."
      kubectl --kubeconfig "$K3S_KUBECONFIG" create ns kasten-io
    fi
  fi

  # Preflight 
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

  # Instalación K10
  if helm --kubeconfig "$K3S_KUBECONFIG" -n kasten-io list 2>/dev/null | grep -q "^k10"; then
    echo "⚠ Ya existe un release 'k10' en el namespace 'kasten-io'. No se instalará de nuevo."
  else
    echo "Instalando Kasten K10:"
    echo "  helm install k10 kasten/k10 --namespace kasten-io --kubeconfig $K3S_KUBECONFIG"
    helm install k10 kasten/k10 --namespace kasten-io --kubeconfig "$K3S_KUBECONFIG"
  fi

  wait_for_kasten_pods

  # Exponer gateway
  if ask_yes_no "¿Deseas configurar el servicio 'gateway' de Kasten como NodePort y utilizar el puerto 8080?" "y"; then
    if ! kubectl --kubeconfig "$K3S_KUBECONFIG" -n kasten-io get svc gateway >/dev/null 2>&1; then
      echo "❌ No se encontró el servicio 'gateway' en el namespace 'kasten-io'."
      echo "   Revisa que la instalación de Kasten se haya completado correctamente."
    else
      echo "Configurando gateway: NodePort, externalIPs=$SERVER_IP, http:8080->8000..."
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
    echo "   kubectl --kubeconfig $K3S_KUBECONFIG -n kasten-io edit svc gateway"
  fi

  echo
  echo "==========================================="
  echo "Instalación y configuración finalizadas."
  echo "Si configuraste el servicio gateway como NodePort con puerto 8080,"
  echo "deberías poder acceder a la consola de Kasten en:"
  echo "  http://${SERVER_IP}:8080/k10/#"
  echo "==========================================="
  echo "Listo. Ya tenes instalado Kasten, valida el acceso."
  echo "Happy to help - MJ."
}


# ------------------------------
# MAIN - orden de ejecución
# ------------------------------
validate_environment
install_helm
install_k3s
configure_kubeconfig_for_user
install_longhorn_keep_as_is
install_snapshot_crds_and_class_keep_as_is
remove_local_path_and_set_longhorn_default
install_mysql_keep_as_is
install_kasten_last
