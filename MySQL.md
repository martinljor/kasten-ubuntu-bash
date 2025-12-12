# MySQL Deployment + Veeam Kasten Backup (CSI Driver with Longhorn).

Este documento describe cómo instalar **Longhorn**, habilitar **CSI Snapshots**, desplegar **MySQL usando Longhorn**, y preparar el entorno para **backups con Veeam Kasten**.

## 1. Pre-requisitos en Ubuntu (nodo k3s) - Lo puedes instalar con el script kasten.sh
```
sudo apt-get update
sudo apt-get install -y open-iscsi nfs-common
sudo systemctl enable iscsid
sudo systemctl start iscsid
```

## 2. Instalar Longhorn
```
sudo kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/master/deploy/longhorn.yaml
sudo kubectl -n longhorn-system get pods
sudo kubectl get storageclass
```

## 3. Instalar CRDs de CSI Snapshot
```
sudo kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml
sudo kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml
sudo kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml
sudo kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml
sudo kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml
sudo kubectl get pods -n kube-system | grep snapshot
```

## 4. Crear VolumeSnapshotClass para Longhorn
```
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
```
```
sudo kubectl apply -f longhorn-snapclass.yaml
```


## 5. Crear el namespace para MySQL
```
sudo kubectl create namespace mysqlong
```

## 6. PVC para MySQL
```
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
```

## 7. Service + Deployment de MySQL
```
cat << 'EOF' > mysql-deploy-long-svc.yaml
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
EOF
```

```
cat << 'EOF' > mysql-deploy-long.yaml
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
```
```
sudo kubectl apply -f mysql-pv-long.yaml
sudo kubectl apply -f mysql-pv-long-svc.yaml
sudo kubectl apply -f mysql-deploy-long.yaml
```

## 8. Verificar despliegue
```
sudo kubectl get pods -n mysqlong
sudo kubectl exec -it -n mysqlong deploy/mysql -- bash
```

Dentro del contenedor:
```
mysql -u root -ppassword
show databases;
exit
```


## 9. Configurar Kasten K10

En Veeam Kasten crear una política para respaldar la app mysqlong. Validar que funcione exitosamente.
Si ya tienes desplegado Minio, puedes usar el script repo.sh para autocrear el Location Profile dentro de Kasten.
