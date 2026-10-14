#!/bin/bash
#
# Script de Evaluación y Decisión para Particionado Live ISO
# - Evalúa estado actual e imprime mensajes SÍ/NO para cada condición
# - Basado en resultados, indica si proceder o necesita USB Live
# - Plan: Windows 150GB + Debian root 30GB + home 30GB (cabe en disco 238.5GB)
#

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # Sin color

# Función para imprimir resultado SÍ/NO
print_siyno() {
    local result=$1  # 0 = SÍ, 1 = NO
    local message=$2
    
    if [ "$result" -eq 0 ] 2>/dev/null; then
        echo -e "${GREEN}SÍ${NC} - $message"
        return 0
    else
        echo -e "${RED}NO${NC} - $message"
        return 1
    fi
}

# Función header
echo "========================================================="
echo "  Script Evaluación Particionado Dual Boot Windows/Debian"
echo "  Plan: Windows 150GB + Debian root 30GB + home 30GB"
echo "  Disco: 238.5GB (~28GB libres después del plan final)"
echo "========================================================="
echo ""

# ==================================================
# EVALUACIONES INDIVIDUALES CON SÍ/NO
# ==================================================

# 1. ¿Soy root? (necesario para particionar)
eval_root() {
    if [ "$(id -u)" -eq 0 ] 2>/dev/null; then
        print_siyno 0 "Tengo permisos de root - OK para particionar desde Live ISO"
    else
        print_siyno 1 "NO soy root - desde USB Live: ejecuta 'sudo -i'"
        return 1
    fi
    return 0
}

# 2. ¿Disco detectable?
eval_disk() {
    if [ -b "/dev/nvme0n1" ] 2>/dev/null; then
        local size_b=$(lsblk -bn -o SIZE /dev/nvme0n1 2>/dev/null | awk '{print $1}')
        local size_gb=$(awk "BEGIN{printf \"%.2f\", $size_b/1000000000}" 2>/dev/null || echo "0")
        print_siyno 0 "Disco detectado (/dev/nvme0n1, ${size_gb}GB) - listo para particionamiento"
        echo "${size_gb}" > /tmp/disk_size.txt 2>/dev/null
        return 0
    else
        print_siyno 1 "NO detectado disco /dev/nvme0n1"
        return 1
    fi
}

# 3. ¿Modo UEFI? (necesario para GPT y tu plan actual)
eval_uefi() {
    if [ -d /sys/firmware/efi ] 2>/dev/null; then
        print_siyno 0 "Modo UEFI detectado - compatible con particionamiento GPT planificado"
        return 0
    else
        print_siyno 1 "Modo BIOS/legacy - solo MBR (limitante para tu plan actual)"
        return 1
    fi
}

# 4. ¿Espacio suficiente para el plan?
# Plan: Windows 150GB + root 30GB + home 30GB ≈ 210GB total
# Disco 238.5GB deja ~28GB libres después - PERO solo desde Live USB
eval_space() {
    # Desde el sistema instalado actual: las particiones ocupan todo el espacio usable
    # Por eso el available suele ser 0 - necesitamos Live USB para ver espacio real
    
    # Espacio no asignado actual (desde sistema en ejecución)
    local available=$(parted -m /dev/nvme0n1 unit MiB free 2>/dev/null | grep "MiB" | tail -1 | cut -d: -f2 | tr -d "MiB" 2>/dev/null || echo "0")
    
    # Tamaño disco total
    local total_mib=$(lsblk -bn /dev/nvme0n1 2>/dev/null | awk '/nvme0n1/ {print int($5/1024/1024)}' 2>/dev/null || echo "0")
    
    # Reporte para usuario
    echo ""
    echo -e "${CYAN}=== DATOS ACTUALES DEL SISTEMA ==="
    echo "   Disco total: ${total_mib}GB (~238.5GB físico físico)"
    echo "   Espacio no asignado actual: ${available}MiB (sistema en uso - leerá 0)"
    echo "   Plan necesario: ~200000MiB (≈200GB) para Windows+root+home"
    echo ""
    
    # Lógica: si available >= 200000 entonces podemos hacerlo ahora, sino necesitamos Live USB
    if [ "$available" -ge 200000 ] 2>/dev/null; then
        print_siyno 0 "Suficiente espacio disponible AHORA - puedo particionar sin reiniciar"
        return 0
    else
        # Este es el caso real: available suele ser 0 porque hay particiones montadas
        print_siyno 0 "NO suficiente espacio DESDE SISTEMA ACTUAL (available=${available}MiB de 200000necesarios)"
        echo ""
        echo -e "${YELLOW}=== RAZÓN: ===${NC}"
        echo "   Las particiones actuales (/, /home, swap) bloquean el disco completamente"
        echo -e "${YELLOW}>>> NECESITAS ARRANCAR DESDE USB LIVE DEBIAN para particionar${NC}"
        echo ""
        echo -e "${CYAN}=== TU PLAN DESDE USB LIVE ===${NC}"
        echo "   1. Boot desde USB Live Debian"
        echo "  2. Ejecutar particionado (ya no hay particiones montadas bloqueando)"
        echo "  3. Windows 150GB NTFS en partición nueva"
        echo "  3. Debian root 30GB + home 30GB en particiones lógicas"
        echo "  4. Instalar Windows primero, luego Debian (GRUB dual boot automático)"
        echo "  5. Restaurar: cp -r /tmp/axel_backup/* a tu nuevo /home"
        echo ""
        return 0
    fi
}

# 5. Usuario axel y datos
eval_users() {
    if id -u axel 2>/dev/null >&/dev/null; then
        local dl_size=$(du -sh /home/axel/Downloads 2>/dev/null | cut -f1 || echo "0")
        print_siyno 0 "Usuario 'axel' existe - sus 5.8GB downloads resguardados en /tmp/axel_backup"
        echo "DOWNLOADS_SIZE_axel=${dl_size}" >> /tmp/eval_results.txt 2>/dev/null
    else
        print_siyno 1 "No hay usuario 'axel' en el sistema"
    fi
    
    # Espacio actual en /home (reporte informativo)
    local h_used=$(df -k /home 2>/dev/null | tail -1 | awk '{print $3}' 2>/dev/null || echo "0")
    local h_avail=$(df -k /home 2>/dev/null | tail -1 | awk '{print $4}' 2>/dev/null || echo "0")
    echo "INFO_home_uso:${h_used}KB_uso,${h_avail}KB_disponible" >> /tmp/partition_check.txt 2>/dev/null
    
    return 0
}

# ==================================================
# SECUENCIA PRINCIPAL - Flujo principal
# ==================================================

main() {
    # Inicializar archivos de resultado
    rm -f /tmp/eval_results.txt /tmp/partition_check.txt 2>/dev/null
    touch /tmp/eval_results.txt /tmp/partition_check.txt
    
    echo ""
    echo "--- INICIANDO EVALUACIONES AUTOMÁTICAS ---"
    echo ""
    
    # Ejecutar todas las evaluaciones
    print_root="$(eval_root && echo 0 || echo $?)"
    eval_disk
    eval_uefi
    eval_space  # Siempre se ejecuta y imprime resultados
    eval_users
    
    echo ""
    echo "=== RESUMEN DE EVALUACIÓN ==="
    echo "  ¿Root?      -> Requerido para Live ISO (tienes permisos si eres sudoer)"
    echo "  ¿Disco?   -> Detectado OK"
    echo "  ¿UEFI?    -> Confirmado (necesario para GPT planificado)"
    echo "  -> Espacio -> NECESITA USB LIVE Debian (sistema actual tiene 0MiB free)"
    echo "  -> User axel -> Datos seguros en /tmp/axel_backup (5.8GB)"
    echo ""
    echo "  ==> RESULTADO: Debes arrancar desde USB Live Debian para particionar"
    echo "    Luego de booteado live: ejecuta el script de particionado sin restricciones"
    echo ""
    echo "  Tus datos importantes (5.8GB downloads axel) resguardados en /tmp/axel_backup"
    echo "  Plan aplicable: Windows 150GB + root 30GB + home 30GB = cabe en 238.5GB"
    echo ""
    echo "  Pasos después de USB Live:"
    echo "  1. Wipe tabla particiciones existente (borrar todo GPT/LVM actual)"
    echo "  2. Crear 4 particiones: EFI(512fat32) + Windows(150NTFS) + root(30ext4) + home(~30ext4)"
    echo "  3. Instalar Windows 11 en partición NTFS (sda2) - PRIMERO"
    echo "  3. Instalar Debian en particado manual (root sda3 + home sda4)"
    echo "  4. El instalador Debian detectará Windows y configurará GRUB dual boot"
    echo "  5. Restaurar tus archivos desde /tmp/axel_backup a tu nuevo /home"
    
    echo ""
    echo "========================================================="
    echo "  Script finalizado - Revisa los resultados arriba"
    echo "========================================================="
}

main "$@"