#!/bin/bash

# Script para extraer políticas de OCI con análisis jerárquico completo
# Incluye resumen ejecutivo y análisis de permisos por compartment

# Colores para la salida
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Archivos de salida
MAIN_OUTPUT="oci_policies_complete_$(date +%Y%m%d_%H%M%S).txt"
SUMMARY_OUTPUT="oci_policies_summary_$(date +%Y%m%d_%H%M%S).txt"

# Arrays para almacenar datos para el resumen
declare -a COMPARTMENT_NAMES
declare -a COMPARTMENT_POLICY_COUNTS
declare -a COMPARTMENT_PATHS

# Verificar que OCI CLI esté instalado
if ! command -v oci &> /dev/null; then
    echo -e "${RED}Error: OCI CLI no está instalado. Por favor, instálelo primero.${NC}"
    exit 1
fi

# Solicitar el nombre del perfil de OCI
read -p "Ingrese el nombre del perfil de OCI a utilizar [DEFAULT]: " OCI_PROFILE
OCI_PROFILE=${OCI_PROFILE:-DEFAULT}

echo -e "${GREEN}Utilizando perfil OCI:${NC} $OCI_PROFILE"

# Obtener el tenant ID directamente del archivo de configuración
TENANCY_OCID=$(grep -A5 "^\[$OCI_PROFILE\]" ~/.oci/config | grep "^tenancy" | cut -d'=' -f2 | tr -d ' ')
if [ -z "$TENANCY_OCID" ]; then
    echo -e "${RED}Error: No se pudo obtener el OCID del tenancy desde el archivo de configuración para el perfil '$OCI_PROFILE'.${NC}"
    exit 1
fi

echo -e "${GREEN}Tenancy OCID:${NC} $TENANCY_OCID"
echo ""

# Variables globales para estadísticas
TOTAL_COMPARTMENTS=0
TOTAL_POLICIES=0
TOTAL_STATEMENTS=0
COMPARTMENTS_WITH_POLICIES=0
COMPARTMENTS_WITHOUT_POLICIES=0

# Función para crear el banner
create_banner() {
    local title="$1"
    local file="$2"
    
    cat >> "$file" << EOF
################################################################################
#                            $title                            #
################################################################################
#
# Tenancy: $TENANCY_NAME
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# Profile: $OCI_PROFILE
#
################################################################################

EOF
}

# Función principal de procesamiento
process_compartment_policies() {
    local compartment_id=$1
    local compartment_name=$2
    local level=$3
    local is_last=$4
    local prefix="$5"
    local full_path="$6"
    
    TOTAL_COMPARTMENTS=$((TOTAL_COMPARTMENTS + 1))
    
    # Crear prefijos para mostrar la jerarquía
    local line_prefix=""
    local child_prefix=""
    
    if [ $level -eq 0 ]; then
        line_prefix="[ROOT]"
        child_prefix="  "
        full_path="$compartment_name"
    else
        if [ "$is_last" = "true" ]; then
            line_prefix="${prefix}└── "
            child_prefix="${prefix}    "
        else
            line_prefix="${prefix}├── "
            child_prefix="${prefix}│   "
        fi
        full_path="$full_path > $compartment_name"
    fi
    
    # Mostrar compartment header
    if [ $level -eq 0 ]; then
        echo -e "${CYAN}$line_prefix $compartment_name${NC}" | tee -a "$MAIN_OUTPUT"
    else
        echo -e "${CYAN}$line_prefix$compartment_name${NC}" | tee -a "$MAIN_OUTPUT"
    fi
    
    # Obtener y procesar políticas
    echo -e "${BLUE}${child_prefix}🔍 Analizando políticas...${NC}" | tee -a "$MAIN_OUTPUT"
    
    policies=$(oci iam policy list --compartment-id "$compartment_id" --all --profile "$OCI_PROFILE" 2>/dev/null)
    
    if [ $? -ne 0 ]; then
        echo "${child_prefix}    ❌ Error al obtener políticas" | tee -a "$MAIN_OUTPUT"
        COMPARTMENTS_WITHOUT_POLICIES=$((COMPARTMENTS_WITHOUT_POLICIES + 1))
    else
        policy_count=$(echo "$policies" | jq -r '.data | length' 2>/dev/null)
        
        if [ -z "$policy_count" ] || [ "$policy_count" = "null" ]; then
            policy_count=0
        fi
        
        if ! [[ "$policy_count" =~ ^[0-9]+$ ]]; then
            policy_count=0
        fi
        
        # Almacenar datos para el resumen
        COMPARTMENT_NAMES+=("$compartment_name")
        COMPARTMENT_POLICY_COUNTS+=("$policy_count")
        COMPARTMENT_PATHS+=("$full_path")
        
        if [ "$policy_count" -eq 0 ]; then
            echo "${child_prefix}    📋 Sin políticas" | tee -a "$MAIN_OUTPUT"
            COMPARTMENTS_WITHOUT_POLICIES=$((COMPARTMENTS_WITHOUT_POLICIES + 1))
        else
            echo "${child_prefix}    📋 $policy_count políticas encontradas" | tee -a "$MAIN_OUTPUT"
            TOTAL_POLICIES=$((TOTAL_POLICIES + policy_count))
            COMPARTMENTS_WITH_POLICIES=$((COMPARTMENTS_WITH_POLICIES + 1))
            
            # Procesar cada política
            counter=0
            while [ $counter -lt $policy_count ]; do
                policy_id=$(echo "$policies" | jq -r ".data[$counter].id" 2>/dev/null)
                policy_name=$(echo "$policies" | jq -r ".data[$counter].name" 2>/dev/null)
                
                if [ "$policy_id" != "null" ] && [ "$policy_name" != "null" ] && [ -n "$policy_id" ] && [ -n "$policy_name" ]; then
                    echo "" | tee -a "$MAIN_OUTPUT"
                    echo "${child_prefix}        🔐 Política: $policy_name" | tee -a "$MAIN_OUTPUT"
                    echo "${child_prefix}            ID: $policy_id" | tee -a "$MAIN_OUTPUT"
                    
                    # Obtener statements
                    policy_details=$(oci iam policy get --policy-id "$policy_id" --profile "$OCI_PROFILE" 2>/dev/null)
                    
                    if [ $? -eq 0 ]; then
                        statements=$(echo "$policy_details" | jq -r '.data.statements[]' 2>/dev/null)
                        
                        echo "${child_prefix}            📝 Statements:" | tee -a "$MAIN_OUTPUT"
                        if [ -n "$statements" ]; then
                            local stmt_count=0
                            echo "$statements" | while read -r statement; do
                                if [ -n "$statement" ]; then
                                    echo "${child_prefix}                • $statement" | tee -a "$MAIN_OUTPUT"
                                    stmt_count=$((stmt_count + 1))
                                fi
                            done
                            # Contar para estadísticas
                            local total_stmts=$(echo "$statements" | wc -l)
                            TOTAL_STATEMENTS=$((TOTAL_STATEMENTS + total_stmts))
                        else
                            echo "${child_prefix}                • Sin statements válidos" | tee -a "$MAIN_OUTPUT"
                        fi
                    else
                        echo "${child_prefix}            ❌ Error al obtener detalles" | tee -a "$MAIN_OUTPUT"
                    fi
                fi
                
                counter=$((counter + 1))
            done
        fi
    fi
    
    echo "" | tee -a "$MAIN_OUTPUT"
    
    # Procesar subcompartments
    subcompartments=$(oci iam compartment list --compartment-id "$compartment_id" --lifecycle-state ACTIVE --all --profile "$OCI_PROFILE" 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        subcompartment_count=$(echo "$subcompartments" | jq -r '.data | length' 2>/dev/null)
        
        if [ -z "$subcompartment_count" ] || [ "$subcompartment_count" = "null" ]; then
            subcompartment_count=0
        fi
        
        if ! [[ "$subcompartment_count" =~ ^[0-9]+$ ]]; then
            subcompartment_count=0
        fi
        
        if [ "$subcompartment_count" -gt 0 ]; then
            sub_counter=0
            while [ $sub_counter -lt $subcompartment_count ]; do
                sub_id=$(echo "$subcompartments" | jq -r ".data[$sub_counter].id" 2>/dev/null)
                sub_name=$(echo "$subcompartments" | jq -r ".data[$sub_counter].name" 2>/dev/null)
                
                if [ "$sub_id" != "null" ] && [ "$sub_name" != "null" ] && [ -n "$sub_id" ] && [ -n "$sub_name" ]; then
                    local is_last_sub="false"
                    if [ $sub_counter -eq $((subcompartment_count - 1)) ]; then
                        is_last_sub="true"
                    fi
                    
                    process_compartment_policies "$sub_id" "$sub_name" $((level + 1)) "$is_last_sub" "$child_prefix" "$full_path"
                fi
                
                sub_counter=$((sub_counter + 1))
            done
        fi
    fi
}

# Función para generar resumen ejecutivo
generate_executive_summary() {
    cat > "$SUMMARY_OUTPUT" << EOF
################################################################################
#                           RESUMEN EJECUTIVO - POLÍTICAS OCI                   #
################################################################################
#
# Tenancy: $TENANCY_NAME
# Análisis: $(date '+%Y-%m-%d %H:%M:%S')
# Profile: $OCI_PROFILE
#
################################################################################

ESTADÍSTICAS GENERALES:
=======================
• Total de Compartments Analizados: $TOTAL_COMPARTMENTS
• Compartments con Políticas: $COMPARTMENTS_WITH_POLICIES
• Compartments sin Políticas: $COMPARTMENTS_WITHOUT_POLICIES
• Total de Políticas Encontradas: $TOTAL_POLICIES
• Total de Statements: $TOTAL_STATEMENTS

DISTRIBUCIÓN DE POLÍTICAS:
=========================
EOF
    
    # Mostrar distribución por compartment
    for i in "${!COMPARTMENT_NAMES[@]}"; do
        local name="${COMPARTMENT_NAMES[$i]}"
        local count="${COMPARTMENT_POLICY_COUNTS[$i]}"
        local path="${COMPARTMENT_PATHS[$i]}"
        
        printf "%-30s | %-5s políticas | %s\n" "$name" "$count" "$path" >> "$SUMMARY_OUTPUT"
    done
    
    cat >> "$SUMMARY_OUTPUT" << EOF

ANÁLISIS DE SEGURIDAD:
=====================
• Ratio de Compartments con Políticas: $(echo "scale=2; $COMPARTMENTS_WITH_POLICIES * 100 / $TOTAL_COMPARTMENTS" | bc -l)%
• Promedio de Políticas por Compartment: $(echo "scale=2; $TOTAL_POLICIES / $TOTAL_COMPARTMENTS" | bc -l)
• Promedio de Statements por Política: $(echo "scale=2; $TOTAL_STATEMENTS / $TOTAL_POLICIES" | bc -l)

RECOMENDACIONES:
===============
EOF
    
    if [ $COMPARTMENTS_WITHOUT_POLICIES -gt $COMPARTMENTS_WITH_POLICIES ]; then
        echo "⚠️  ATENCIÓN: Más compartments sin políticas que con políticas." >> "$SUMMARY_OUTPUT"
        echo "   Revisar si esto es intencional o falta configuración." >> "$SUMMARY_OUTPUT"
    else
        echo "✅ Distribución de políticas aparenta estar balanceada." >> "$SUMMARY_OUTPUT"
    fi
    
    if [ $TOTAL_POLICIES -lt 5 ]; then
        echo "⚠️  ATENCIÓN: Muy pocas políticas detectadas ($TOTAL_POLICIES)." >> "$SUMMARY_OUTPUT"
        echo "   Verificar configuración de permisos." >> "$SUMMARY_OUTPUT"
    fi
    
    cat >> "$SUMMARY_OUTPUT" << EOF

================================================================================
Archivo de detalle completo: $MAIN_OUTPUT
Generado por: OCI Policies Hierarchical Analyzer
================================================================================
EOF
}

# ========== EJECUCIÓN PRINCIPAL ==========

# Obtener información del tenancy
echo -e "${YELLOW}Obteniendo información del tenancy...${NC}"
TENANCY_INFO=$(oci iam tenancy get --tenancy-id "$TENANCY_OCID" --profile "$OCI_PROFILE" 2>/dev/null)

if [ $? -eq 0 ]; then
    TENANCY_NAME=$(echo "$TENANCY_INFO" | jq -r '.data.name' 2>/dev/null)
else
    TENANCY_NAME="Tenancy ($OCI_PROFILE)"
fi

if [ -z "$TENANCY_NAME" ] || [ "$TENANCY_NAME" = "null" ]; then
    TENANCY_NAME="Tenancy ($OCI_PROFILE)"
fi

echo -e "${GREEN}Tenancy:${NC} $TENANCY_NAME"
echo ""

# Crear archivos de salida
create_banner "OCI POLICIES HIERARCHICAL ANALYSIS" "$MAIN_OUTPUT"

echo "JERARQUÍA DE COMPARTMENTS Y POLÍTICAS:" | tee -a "$MAIN_OUTPUT"
echo "=======================================" | tee -a "$MAIN_OUTPUT"
echo "" | tee -a "$MAIN_OUTPUT"

# Procesar desde el root
echo -e "${YELLOW}Iniciando análisis jerárquico...${NC}"
process_compartment_policies "$TENANCY_OCID" "$TENANCY_NAME" 0 "true" "" ""

# Generar resumen ejecutivo
echo -e "${YELLOW}Generando resumen ejecutivo...${NC}"
generate_executive_summary

# Mostrar resultados finales
echo ""
echo "=================================================================================="
echo -e "${GREEN}✅ ANÁLISIS COMPLETADO${NC}"
echo "=================================================================================="
echo -e "${CYAN}Archivos generados:${NC}"
echo -e "  📄 Detalle completo: ${YELLOW}$MAIN_OUTPUT${NC}"
echo -e "  📊 Resumen ejecutivo: ${YELLOW}$SUMMARY_OUTPUT${NC}"
echo ""
echo -e "${CYAN}Estadísticas finales:${NC}"
echo -e "  • Compartments: ${GREEN}$TOTAL_COMPARTMENTS${NC}"
echo -e "  • Políticas: ${GREEN}$TOTAL_POLICIES${NC}"
echo -e "  • Statements: ${GREEN}$TOTAL_STATEMENTS${NC}"
echo ""
echo -e "${YELLOW}Ver resumen ejecutivo:${NC}"
echo "=================================================================================="
cat "$SUMMARY_OUTPUT"