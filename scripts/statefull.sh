#!/usr/bin/env bash
set -euo pipefail

echo "============================================="
echo " CSI Driver - Longhorn + MySQL (mysqlong)"
echo "============================================="
echo

###############################################
# 0) CHEQUEOS BÁSICOS
###############################################
if ! command -v kubectl >/dev/null 2>&1; then
  echo "[ERROR] kubectl no está instalado o no está en el PATH."
  exit 1
fi

###############################################
# 1) PRE-REQUISITOS EN UBUNTU (NODO K3S)
###############################################
echo "[INFO] Instalando dependencias (open-iscsi, nfs-common)..."

sudo apt-get update
sudo apt-get install -y open-iscsi nfs-common
sudo systemctl enable iscsid
sudo systemctl start iscsid

###############################################
# 2) INSTALAR LONGHORN
###############################################
echo "[INFO] Instalando Longhorn..."

sudo kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/master/deploy/longhorn.yaml

echo "[INFO] Esperando que los pods de Longhorn estén Ready (hasta 300s)..."
sudo kubectl wait --for=condition=Ready pod --all -n longhorn-system --timeout=300s || {
  echo "[WARN] No todos los pods de Longhorn llegaron a Ready. Revisar con:"
  echo "       sudo kubectl -n longhorn-system get pods"
}

echo "[INFO] Pods en longhorn-system:"
sudo kubectl -n longhorn-system get pods

echo "[INFO] StorageClasses disponibles:"
sudo kubectl get storageclass

###############################################
# 3) INSTALAR CRDs DE SNAPSHOT + SNAPSHOT CONTROLLER
###############################################
echo "[INFO] Instalando CRDs de CSI Snapshot..."

sudo kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml
sudo kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml
sudo kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml

echo "[INFO] Instalando snapshot-controller..."

sudo kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml
sudo kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml

echo "[INFO] Esperando snapshot-controller Ready (hasta 120s)..."
sudo kubectl wait --for=condition=Ready pod -l app=snapshot-controller -n kube-system --timeout=120s || {
  echo "[WARN] snapshot-controller no llegó a Ready aún. Revisar con:"
  echo "       sudo kubectl get pods -n kube-system | grep snapshot"
}

echo "[INFO] Pods relacionados a snapshot en kube-system:"
sudo kubectl get pods -n kube-system | grep snapshot || echo "[INFO] No se encontraron pods con 'snapshot' (puede tardar unos segundos)."

###############################################
# 4) CREAR VolumeSnapshotClass PARA LONGHORN
###############################################
echo "[INFO] Creando VolumeSnapshotClass para Longhorn..."

cat << 'EOF' > longhorn-snapclass.yaml
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

sudo kubectl apply -f longhorn-snapclass.yaml

echo "[INFO] VolumeSnapshotClass actuales:"
sudo kubectl get volumesnapshotclass

echo "[INFO] Validando que exista longhorn-snapclass..."
sudo kubectl get volumesnapshotclass longhorn-snapclass >/dev/null 2>&1 || {
  echo "[ERROR] No se encontró VolumeSnapshotClass 'longhorn-snapclass'."
  exit 1
}

echo "[INFO] Validando anotación k10.kasten.io/is-snapshot-class=true..."
ANNOTATION_VALUE=$(sudo kubectl get volumesnapshotclass longhorn-snapclass -o jsonpath='{.metadata.annotations.k10\.kasten\.io/is-snapshot-class}' || echo "")
if [[ "$ANNOTATION_VALUE" != "true" ]]; then
  echo "[ERROR] La VolumeSnapshotClass 'longhorn-snapclass' no tiene la anotación k10.kasten.io/is-snapshot-class=true."
  exit 1
fi

###############################################
# 5) CREAR NAMESPACE PARA MySQL
###############################################
echo "[INFO] Creando namespace 'mysqlong' (si no existe)..."

if sudo kubectl get namespace mysqlong >/dev/null 2>&1; then
  echo "[INFO] Namespace 'mysqlong' ya existe, se reutiliza."
else
  sudo kubectl create namespace mysqlong
fi

###############################################
# 6) PVC PARA MySQL (LONGHORN)
###############################################
echo "[INFO] Creando PVC para MySQL en namespace 'mysqlong'..."

cat << 'EOF' > mysql-pv-long.yaml
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

sudo kubectl apply -f mysql-pv-long.yaml

echo "[INFO] Esperando que el PVC mysql-pv-claim esté Bound (hasta 120s)..."
sudo kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/mysql-pv-claim -n mysqlong --timeout=120s || {
  echo "[ERROR] El PVC 'mysql-pv-claim' no llegó a estado Bound."
  sudo kubectl get pvc -n mysqlong
  exit 1
}

###############################################
# 7) SERVICE + DEPLOYMENT DE MySQL (mysqlong)
###############################################
echo "[INFO] Creando Service + Deployment de MySQL (ClusterIP, MySQL 8.0)..."

cat << 'EOF' > mysql-deploy-long.yaml
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

sudo kubectl apply -f mysql-deploy-long.yaml

echo "[INFO] Esperando rollout completo del Deployment mysql (hasta 180s)..."
sudo kubectl rollout status deployment/mysql -n mysqlong --timeout=180s || {
  echo "[ERROR] El Deployment 'mysql' no pudo completar el rollout correctamente."
  sudo kubectl get pods -n mysqlong
  exit 1
}

###############################################
# 8) VERIFICACIONES FINALES
###############################################
echo "[INFO] Pods en el namespace 'mysqlong':"
sudo kubectl get pods -n mysqlong

echo "[INFO] Probando conexión a MySQL dentro del pod..."
sudo kubectl exec -n mysqlong deploy/mysql -- mysql -u root -ppassword -e "SHOW DATABASES;" >/dev/null 2>&1 || {
  echo "[ERROR] No se pudo ejecutar 'SHOW DATABASES;' en MySQL."
  echo "        Revisar el pod con:"
  echo "        sudo kubectl logs -n mysqlong deploy/mysql"
  exit 1
}

echo
echo "===================================================="
echo " ENTORNO LISTO Y VALIDADO:"
echo " - Longhorn instalado y con pods en ejecución (revisado)"
echo " - CRDs + snapshot-controller instalados (revisado)"
echo " - VolumeSnapshotClass: longhorn-snapclass con anotación Kasten (revisado)"
echo " - Namespace: mysqlong (revisado)"
echo " - PVC: mysql-pv-claim en estado Bound (revisado)"
echo " - Deployment + Service: mysql (ClusterIP) desplegados y con rollout OK"
echo " - MySQL responde a 'SHOW DATABASES;' dentro del pod"
echo
echo "En Kasten K10:"
echo " - Crear una Policy apuntando a la app 'mysqlong'"
echo " - Usar CSI Snapshots (VolumeSnapshotClass: longhorn-snapclass)"
echo "===================================================="

