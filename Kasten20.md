### Kasten + MySQL + K3S + CSI Longhorn

La idea de esta nueva versión es poder unificar las acciones a realizar cuando ejecutas el laboratorio y que todas las acciones necesarias se puedan realizar: App Mobility + DRP + B&R

El paso a paso que se realiza en kaste20.sh es el siguiente:

1. Validaciones (OS, root, usuario, IP)
2. Instalar / validar Helm
3. Instalar / validar K3s
4. Configurar kubeconfig
5. Instalar Longhorn 
6. Configurar CSI Snapshot + VolumeSnapshotClass
7. Eliminar local-path CSI
8. Instalar MySQL 
9. Instalar Kasten
10. Exponer gateway y mostrar URL

Happy to help - MJ
