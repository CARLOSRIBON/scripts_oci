#!/bin/bash

# Script para extraer los statements de todas las políticas en todos los compartments de OCI
# Requisitos: OCI CLI instalado y configurado correctamente

# Colores para la salida
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Archivo de salida
OUTPUT_FILE="oci_policies_$(date +%Y%m%d_%H%M%S).txt"

echo "=== Iniciando extracción de políticas de OCI ===" | tee -a "$OUTPUT_FILE"
echo "Fecha de ejecución: $(date)" | tee -a "$OUTPUT_FILE"
echo "" | tee -a "$OUTPUT_FILE"

# Verificar que OCI CLI esté instalado
if ! command -v oci &> /dev/null; then
    echo -e "${RED}Error: OCI CLI no está instalado. Por favor, instálelo primero.${NC}"
    exit 1
fi

# Solicitar el nombre del perfil de OCI
read -p "Ingrese el nombre del perfil de OCI a utilizar [DEFAULT]: " OCI_PROFILE
OCI_PROFILE=${OCI_PROFILE:-DEFAULT}

echo -e "${GREEN}Utilizando perfil OCI:${NC} $OCI_PROFILE" | tee -a "$OUTPUT_FILE"

# Obtener el tenant ID directamente del archivo de configuración
TENANCY_OCID=$(grep -A5 "^\[$OCI_PROFILE\]" ~/.oci/config | grep "^tenancy" | cut -d'=' -f2 | tr -d ' ')
if [ -z "$TENANCY_OCID" ]; then
    echo -e "${RED}Error: No se pudo obtener el OCID del tenancy desde el archivo de configuración para el perfil '$OCI_PROFILE'.${NC}"
    exit 1
fi

echo -e "${GREEN}Tenancy OCID:${NC} $TENANCY_OCID" | tee -a "$OUTPUT_FILE"
echo "" | tee -a "$OUTPUT_FILE"

# Función para procesar un compartment
process_compartment() {
    local compartment_id=$1
    local compartment_name=$2
    local compartment_path=$3
    
    echo -e "${YELLOW}Procesando compartment:${NC} $compartment_path" | tee -a "$OUTPUT_FILE"
    
    # Obtener todas las políticas en el compartment actual
    policies=$(oci iam policy list --compartment-id "$compartment_id" --all --profile "$OCI_PROFILE")
    
    # Verificar si hay políticas
    policy_count=$(echo "$policies" | jq -r '.data | length')
    
    if [ "$policy_count" -eq 0 ]; then
        echo "  No se encontraron políticas en este compartment." | tee -a "$OUTPUT_FILE"
    else
        echo "  Encontradas $policy_count políticas." | tee -a "$OUTPUT_FILE"
        
        # Iterar a través de cada política
        for ((i=0; i<policy_count; i++)); do
            policy_id=$(echo "$policies" | jq -r ".data[$i].id")
            policy_name=$(echo "$policies" | jq -r ".data[$i].name")
            
            echo "" | tee -a "$OUTPUT_FILE"
            echo "  Política: $policy_name" | tee -a "$OUTPUT_FILE"
            echo "  ID: $policy_id" | tee -a "$OUTPUT_FILE"
            
            # Obtener detalles de la política (para obtener los statements)
            policy_details=$(oci iam policy get --policy-id "$policy_id" --profile "$OCI_PROFILE")
            statements=$(echo "$policy_details" | jq -r '.data.statements[]')
            
            echo "  Statements:" | tee -a "$OUTPUT_FILE"
            echo "$statements" | while read -r statement; do
                echo "    - $statement" | tee -a "$OUTPUT_FILE"
            done
        done
    fi
    
    echo "" | tee -a "$OUTPUT_FILE"
    
    # Obtener los subcompartments y procesarlos recursivamente
    subcompartments=$(oci iam compartment list --compartment-id "$compartment_id" --lifecycle-state ACTIVE --all --profile "$OCI_PROFILE")
    subcompartment_count=$(echo "$subcompartments" | jq -r '.data | length')
    
    if [ "$subcompartment_count" -gt 0 ]; then
        for ((j=0; j<subcompartment_count; j++)); do
            sub_id=$(echo "$subcompartments" | jq -r ".data[$j].id")
            sub_name=$(echo "$subcompartments" | jq -r ".data[$j].name")
            sub_path="$compartment_path > $sub_name"
            
            process_compartment "$sub_id" "$sub_name" "$sub_path"
        done
    fi
}

# Intentar obtener el nombre del tenancy o usar un valor predeterminado
TENANCY_NAME=$(oci iam tenancy get --tenancy-id "$TENANCY_OCID" --profile "$OCI_PROFILE" 2>/dev/null | jq -r '.data.name')
if [ -z "$TENANCY_NAME" ]; then
    # Si no podemos obtener el nombre, usamos el perfil como nombre del tenancy
    TENANCY_NAME="Tenancy ($OCI_PROFILE)"
fi
process_compartment "$TENANCY_OCID" "$TENANCY_NAME" "$TENANCY_NAME (Root)"

echo -e "${GREEN}Procesamiento completado.${NC}" | tee -a "$OUTPUT_FILE"
echo -e "Los resultados se han guardado en: ${YELLOW}$OUTPUT_FILE${NC}"
