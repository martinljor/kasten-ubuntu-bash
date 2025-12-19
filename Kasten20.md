### Kasten + MySQL + K3S + CSI Longhorn

La idea de esta nueva versión es poder unificar las acciones a realizar cuando ejecutas el laboratorio y que todas las acciones necesarias se puedan realizar: App Mobility + DRP + B&R

El paso a paso que se realiza en kaste20.sh es el siguiente:

1. Validaciones iniciales
2. Instalar / validar Helm
3. Instalar / validar K3s
4. Instalar Longhorn
5. Eliminar CSI local-path y dejar Longhorn como default
6. Instalar MySQL sobre Longhorn
7. Instalar Kasten (último paso)
