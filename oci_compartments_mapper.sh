#!/bin/bash

# Script para crear un mapa simple de compartments de OCI estilo banner MOTD
# Requisitos: OCI CLI instalado y configurado correctamente

# Archivo de salida
OUTPUT_FILE="oci_compartments_motd_$(date +%Y%m%d_%H%M%S).txt"

# Función para crear el banner superior
create_banner() {
    local tenancy_name="$1"
    local width=80
    
    echo "################################################################################"
    echo "#                          OCI COMPARTMENTS MAP                               #"
    echo "################################################################################"
    echo "#"
    printf "# %-74s #\n" "Tenancy: $tenancy_name"
    printf "# %-74s #\n" "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "#"
    echo "################################################################################"
    echo ""
}

# Función para crear línea separadora
create_separator() {
    echo "--------------------------------------------------------------------------------"
}

# Verificar que OCI CLI esté instalado
if ! command -v oci &> /dev/null; then
    echo "Error: OCI CLI no está instalado. Por favor, instálelo primero."
    exit 1
fi

# Solicitar el nombre del perfil de OCI
read -p "Ingrese el nombre del perfil de OCI a utilizar [DEFAULT]: " OCI_PROFILE
OCI_PROFILE=${OCI_PROFILE:-DEFAULT}

echo "Utilizando perfil OCI: $OCI_PROFILE"

# Obtener el tenant ID directamente del archivo de configuración
TENANCY_OCID=$(grep -A5 "^\[$OCI_PROFILE\]" ~/.oci/config | grep "^tenancy" | cut -d'=' -f2 | tr -d ' ')
if [ -z "$TENANCY_OCID" ]; then
    echo "Error: No se pudo obtener el OCID del tenancy desde el archivo de configuración para el perfil '$OCI_PROFILE'."
    exit 1
fi

echo "Tenancy OCID: $TENANCY_OCID"
echo ""

# Función para procesar un compartment y sus hijos
process_compartment() {
    local compartment_id=$1
    local compartment_name=$2
    local level=$3
    local is_last=$4
    local prefix="$5"
    
    # Crear el prefijo de línea según el nivel y posición
    local line_prefix=""
    local child_prefix=""
    
    if [ $level -eq 0 ]; then
        line_prefix="[ROOT]"
        child_prefix="  "
    else
        if [ "$is_last" = "true" ]; then
            line_prefix="${prefix}└── "
            child_prefix="${prefix}    "
        else
            line_prefix="${prefix}├── "
            child_prefix="${prefix}│   "
        fi
    fi
    
    # Obtener información del compartment
    local comp_info=$(oci iam compartment get --compartment-id "$compartment_id" --profile "$OCI_PROFILE" 2>/dev/null)
    local state="UNKNOWN"
    local description=""
    
    if [ $? -eq 0 ]; then
        state=$(echo "$comp_info" | jq -r '.data."lifecycle-state"' 2>/dev/null)
        description=$(echo "$comp_info" | jq -r '.data.description' 2>/dev/null)
    fi
    
    # Mostrar el compartment
    local status_symbol=""
    case "$state" in
        "ACTIVE")
            status_symbol="[✓]"
            ;;
        "INACTIVE"|"DELETED")
            status_symbol="[✗]"
            ;;
        *)
            status_symbol="[?]"
            ;;
    esac
    
    if [ $level -eq 0 ]; then
        printf "%-70s %s\n" "$line_prefix $compartment_name" "$status_symbol" >> "$OUTPUT_FILE"
    else
        printf "%-70s %s\n" "$line_prefix$compartment_name" "$status_symbol" >> "$OUTPUT_FILE"
    fi
    
    # Mostrar descripción si existe y es corta
    if [ "$description" != "null" ] && [ "$description" != "" ] && [ ${#description} -lt 60 ]; then
        if [ $level -eq 0 ]; then
            printf "%s    Description: %s\n" "$child_prefix" "$description" >> "$OUTPUT_FILE"
        else
            printf "%s    %s\n" "$child_prefix" "$description" >> "$OUTPUT_FILE"
        fi
    fi
    
    # Obtener los subcompartments
    local subcompartments=$(oci iam compartment list --compartment-id "$compartment_id" --lifecycle-state ACTIVE --all --profile "$OCI_PROFILE" 2>/dev/null)
    
    # Verificar si el comando fue exitoso
    if [ $? -ne 0 ]; then
        printf "%s    [Error: No se pudieron obtener subcompartments]\n" "$child_prefix" >> "$OUTPUT_FILE"
        return
    fi
    
    local subcompartment_count=$(echo "$subcompartments" | jq -r '.data | length' 2>/dev/null)
    
    # Validar que subcompartment_count sea un número entero
    if ! [[ "$subcompartment_count" =~ ^[0-9]+$ ]]; then
        printf "%s    [Error: Datos de subcompartments inválidos]\n" "$child_prefix" >> "$OUTPUT_FILE"
        return
    fi
    
    if [ "$subcompartment_count" -gt 0 ]; then
        # Procesar cada subcompartment
        local sub_counter=0
        while [ $sub_counter -lt $subcompartment_count ]; do
            local sub_id=$(echo "$subcompartments" | jq -r ".data[$sub_counter].id" 2>/dev/null)
            local sub_name=$(echo "$subcompartments" | jq -r ".data[$sub_counter].name" 2>/dev/null)
            
            # Verificar que se obtuvieron valores válidos
            if [ "$sub_id" != "null" ] && [ "$sub_name" != "null" ] && [ -n "$sub_id" ] && [ -n "$sub_name" ]; then
                # Determinar si es el último subcompartment
                local is_last_sub="false"
                if [ $sub_counter -eq $((subcompartment_count - 1)) ]; then
                    is_last_sub="true"
                fi
                
                process_compartment "$sub_id" "$sub_name" $((level + 1)) "$is_last_sub" "$child_prefix"
            else
                printf "%s    [Error: Subcompartment #%d inválido]\n" "$child_prefix" "$sub_counter" >> "$OUTPUT_FILE"
            fi
            
            sub_counter=$((sub_counter + 1))
        done
    fi
}

# Obtener información del tenancy
echo "Obteniendo información del tenancy..."
TENANCY_INFO=$(oci iam tenancy get --tenancy-id "$TENANCY_OCID" --profile "$OCI_PROFILE" 2>/dev/null)

if [ $? -eq 0 ]; then
    TENANCY_NAME=$(echo "$TENANCY_INFO" | jq -r '.data.name' 2>/dev/null)
    TENANCY_DESC=$(echo "$TENANCY_INFO" | jq -r '.data.description' 2>/dev/null)
else
    TENANCY_NAME="Tenancy ($OCI_PROFILE)"
    TENANCY_DESC=""
fi

if [ -z "$TENANCY_NAME" ] || [ "$TENANCY_NAME" = "null" ]; then
    TENANCY_NAME="Tenancy ($OCI_PROFILE)"
fi

echo "Nombre del Tenancy: $TENANCY_NAME"
echo ""
echo "Generando mapa de compartments..."

# Crear el banner en el archivo
create_banner "$TENANCY_NAME" > "$OUTPUT_FILE"

# Agregar estadísticas rápidas
echo "COMPARTMENT HIERARCHY:" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"
echo "Legend: [✓] Active  [✗] Inactive/Deleted  [?] Unknown" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

# Iniciar el procesamiento desde el tenancy raíz
process_compartment "$TENANCY_OCID" "$TENANCY_NAME" 0 "true" ""

# Agregar footer
echo "" >> "$OUTPUT_FILE"
create_separator >> "$OUTPUT_FILE"
echo "Total compartments processed at: $(date)" >> "$OUTPUT_FILE"
echo "Profile used: $OCI_PROFILE" >> "$OUTPUT_FILE"
echo "Tenancy OCID: $TENANCY_OCID" >> "$OUTPUT_FILE"
create_separator >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

# Agregar instrucciones de uso
cat >> "$OUTPUT_FILE" << 'EOF'
USAGE INSTRUCTIONS:
- Copy this file to /etc/motd to display on login
- Or use: cat this_file.txt > /etc/motd (requires root)
- For SSH banner: add to /etc/ssh/sshd_config: Banner /path/to/this/file.txt

COMPARTMENT STATUS:
- [✓] ACTIVE     - Compartment is active and operational
- [✗] INACTIVE   - Compartment is inactive or deleted  
- [?] UNKNOWN    - Status could not be determined

Generated by OCI Compartments MOTD Mapper
EOF

echo "Procesamiento completado."
echo ""
echo "=== ARCHIVO GENERADO ==="
echo "Banner MOTD: $OUTPUT_FILE"
echo ""
echo "Para usar como MOTD:"
echo "  sudo cp $OUTPUT_FILE /etc/motd"
echo ""
echo "Para usar como banner SSH:"
echo "  sudo cp $OUTPUT_FILE /etc/ssh/banner"
echo "  sudo echo 'Banner /etc/ssh/banner' >> /etc/ssh/sshd_config"
echo "  sudo systemctl reload sshd"
echo ""
echo "Vista previa del archivo:"
echo "========================"
head -20 "$OUTPUT_FILE"
echo "..."
echo "(archivo completo: $OUTPUT_FILE)"