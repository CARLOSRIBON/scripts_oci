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
    policies=$(oci iam policy list --compartment-id "$compartment_id" --all --profile "$OCI_PROFILE" 2>/dev/null)
    
    # Verificar si el comando fue exitoso
    if [ $? -ne 0 ]; then
        echo "  Error al obtener políticas para este compartment." | tee -a "$OUTPUT_FILE"
        echo "" | tee -a "$OUTPUT_FILE"
        return
    fi
    
    # Verificar si la respuesta es JSON válido y obtener el número de políticas
    policy_count=$(echo "$policies" | jq -r '.data | length' 2>/dev/null)
    
    # Si policy_count está vacío o es null, establecer a 0
    if [ -z "$policy_count" ] || [ "$policy_count" = "null" ]; then
        policy_count=0
    fi
    
    # Validar que policy_count sea un número entero
    if ! [[ "$policy_count" =~ ^[0-9]+$ ]]; then
        echo "  Error: Respuesta inválida del API de OCI. Asumiendo 0 políticas." | tee -a "$OUTPUT_FILE"
        policy_count=0
    fi
    
    if [ "$policy_count" -eq 0 ]; then
        echo "  No se encontraron políticas en este compartment." | tee -a "$OUTPUT_FILE"
    else
        echo "  Encontradas $policy_count políticas." | tee -a "$OUTPUT_FILE"
        
        # Iterar a través de cada política usando while con contador
        counter=0
        while [ $counter -lt $policy_count ]; do
            policy_id=$(echo "$policies" | jq -r ".data[$counter].id" 2>/dev/null)
            policy_name=$(echo "$policies" | jq -r ".data[$counter].name" 2>/dev/null)
            
            # Verificar que se obtuvieron valores válidos
            if [ "$policy_id" = "null" ] || [ "$policy_name" = "null" ] || [ -z "$policy_id" ] || [ -z "$policy_name" ]; then
                echo "  Error al procesar política en índice $counter" | tee -a "$OUTPUT_FILE"
                counter=$((counter + 1))
                continue
            fi
            
            echo "" | tee -a "$OUTPUT_FILE"
            echo "  Política: $policy_name" | tee -a "$OUTPUT_FILE"
            echo "  ID: $policy_id" | tee -a "$OUTPUT_FILE"
            
            # Obtener detalles de la política (para obtener los statements)
            policy_details=$(oci iam policy get --policy-id "$policy_id" --profile "$OCI_PROFILE" 2>/dev/null)
            
            if [ $? -eq 0 ]; then
                statements=$(echo "$policy_details" | jq -r '.data.statements[]' 2>/dev/null)
                
                echo "  Statements:" | tee -a "$OUTPUT_FILE"
                if [ -n "$statements" ]; then
                    echo "$statements" | while read -r statement; do
                        if [ -n "$statement" ]; then
                            echo "    - $statement" | tee -a "$OUTPUT_FILE"
                        fi
                    done
                else
                    echo "    - No se encontraron statements válidos" | tee -a "$OUTPUT_FILE"
                fi
            else
                echo "  Error al obtener detalles de la política" | tee -a "$OUTPUT_FILE"
            fi
            
            counter=$((counter + 1))
        done
    fi
    
    echo "" | tee -a "$OUTPUT_FILE"
    
    # Obtener los subcompartments y procesarlos recursivamente
    subcompartments=$(oci iam compartment list --compartment-id "$compartment_id" --lifecycle-state ACTIVE --all --profile "$OCI_PROFILE" 2>/dev/null)
    
    # Verificar si el comando fue exitoso
    if [ $? -ne 0 ]; then
        echo "  Error al obtener subcompartments." | tee -a "$OUTPUT_FILE"
        return
    fi
    
    subcompartment_count=$(echo "$subcompartments" | jq -r '.data | length' 2>/dev/null)
    
    # Si subcompartment_count está vacío o es null, establecer a 0
    if [ -z "$subcompartment_count" ] || [ "$subcompartment_count" = "null" ]; then
        subcompartment_count=0
    fi
    
    # Validar que subcompartment_count sea un número entero
    if ! [[ "$subcompartment_count" =~ ^[0-9]+$ ]]; then
        echo "  Error: Respuesta inválida del API de OCI para subcompartments. Asumiendo 0." | tee -a "$OUTPUT_FILE"
        subcompartment_count=0
    fi
    
    if [ "$subcompartment_count" -gt 0 ]; then
        # Usar while loop en lugar de for aritmético para mayor robustez
        sub_counter=0
        while [ $sub_counter -lt $subcompartment_count ]; do
            sub_id=$(echo "$subcompartments" | jq -r ".data[$sub_counter].id" 2>/dev/null)
            sub_name=$(echo "$subcompartments" | jq -r ".data[$sub_counter].name" 2>/dev/null)
            
            # Verificar que se obtuvieron valores válidos
            if [ "$sub_id" != "null" ] && [ "$sub_name" != "null" ] && [ -n "$sub_id" ] && [ -n "$sub_name" ]; then
                sub_path="$compartment_path > $sub_name"
                process_compartment "$sub_id" "$sub_name" "$sub_path"
            else
                echo "  Error al procesar subcompartment en índice $sub_counter" | tee -a "$OUTPUT_FILE"
            fi
            
            sub_counter=$((sub_counter + 1))
        done
    fi
}

# Intentar obtener el nombre del tenancy o usar un valor predeterminado
TENANCY_NAME=$(oci iam tenancy get --tenancy-id "$TENANCY_OCID" --profile "$OCI_PROFILE" 2>/dev/null | jq -r '.data.name' 2>/dev/null)
if [ -z "$TENANCY_NAME" ] || [ "$TENANCY_NAME" = "null" ]; then
    # Si no podemos obtener el nombre, usamos el perfil como nombre del tenancy
    TENANCY_NAME="Tenancy ($OCI_PROFILE)"
fi

# Iniciar el procesamiento desde el tenancy raíz
process_compartment "$TENANCY_OCID" "$TENANCY_NAME" "$TENANCY_NAME (Root)"

echo -e "${GREEN}Procesamiento completado.${NC}" | tee -a "$OUTPUT_FILE"
echo -e "Los resultados se han guardado en: ${YELLOW}$OUTPUT_FILE${NC}"