# Kasten Ubuntu Bash Installer
Automated Bash script to deploy **Veeam Kasten K10** on **Ubuntu Server** using **K3s + Helm**. 
Este repositorio contiene un script que simplifica todo el proceso de instalación, validación y despliegue de Kasten en un entorno Ubuntu limpio.

## 🚀 Requisitos / Requirements
- Ubuntu 22.04 o superior. (testeado para 22.04)
- Acceso a sudo
- Conexión a Internet

## 📥 Pasos de instalación / Installation Steps
### 1️⃣ Crear la VM con Ubuntu / Create the Ubuntu VM
Luego de instalar la VM, actualizar los paquetes: `sudo apt update && sudo apt upgrade -y`
### 2️⃣ Descargar el archivo `kasten.sh` / Download `kasten.sh`
`wget https://raw.githubusercontent.com/martinljor/kasten-ubuntu-bash/main/kasten.sh`
### 3️⃣ Convertir en ejecutable / Make executable
`sudo chmod +x kasten.sh`
### 4️⃣ Ejecutar el script / Run the script
`sudo ./kasten.sh`

## 🎉 Enjoy Veeam Kasten!
Si te resultó útil, dejá una ⭐ en el repositorio.
If you like this script, give me a ⭐ to the repo.

Happy to help - MJ
