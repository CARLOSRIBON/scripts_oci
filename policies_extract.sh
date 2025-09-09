#!/bin/bash

# Script para extraer políticas de OCI con análisis jerárquico completo
# Versión corregida: Primero descubre el árbol, después busca políticas
# Compatible con bash estándar

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
TEMP_TREE_FILE="/tmp/oci_tree_$$"

# Variables globales para estadísticas
TOTAL_COMPARTMENTS=0
TOTAL_POLICIES=0
TOTAL_STATEMENTS=0
COMPARTMENTS_WITH_POLICIES=0
COMPARTMENTS_WITHOUT_POLICIES=0

# Verificar que OCI CLI esté instalado
if ! command -v oci &> /dev/null; then
    echo -e "${RED}Error: OCI CLI no está instalado. Por favor, instálelo primero.${NC}"
    exit 1
fi

# Verificar que jq esté instalado
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq no está instalado. Por favor, instálelo primero.${NC}"
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

# FASE 1: Descubrir el árbol de compartments de forma recursiva
discover_compartment_tree() {
    local compartment_id=$1
    local compartment_name=$2
    local level=$3
    local parent_path="$4"
    
    echo -e "${CYAN}[FASE 1] Descubriendo: $compartment_name (Nivel $level)${NC}"
    
    # Construir path completo
    local full_path
    if [ $level -eq 0 ]; then
        full_path="$compartment_name"
    else
        full_path="$parent_path > $compartment_name"
    fi
    
    # Guardar información en archivo temporal
    echo "$compartment_id|$compartment_name|$level|$full_path" >> "$TEMP_TREE_FILE"
    
    TOTAL_COMPARTMENTS=$((TOTAL_COMPARTMENTS + 1))
    
    # Buscar subcompartments
    echo -e "${BLUE}    └── Buscando subcompartments...${NC}"
    local subcompartments=$(oci iam compartment list \
        --compartment-id "$compartment_id" \
        --lifecycle-state ACTIVE \
        --all \
        --profile "$OCI_PROFILE" 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        local subcompartment_count=$(echo "$subcompartments" | jq -r '.data | length' 2>/dev/null)
        
        if [ -z "$subcompartment_count" ] || [ "$subcompartment_count" = "null" ]; then
            subcompartment_count=0
        fi
        
        echo -e "${BLUE}    └── Encontrados: $subcompartment_count subcompartments${NC}"
        
        if [ "$subcompartment_count" -gt 0 ]; then
            local sub_counter=0
            
            while [ $sub_counter -lt $subcompartment_count ]; do
                local sub_id=$(echo "$subcompartments" | jq -r ".data[$sub_counter].id" 2>/dev/null)
                local sub_name=$(echo "$subcompartments" | jq -r ".data[$sub_counter].name" 2>/dev/null)
                
                if [ "$sub_id" != "null" ] && [ "$sub_name" != "null" ] && [ -n "$sub_id" ] && [ -n "$sub_name" ]; then
                    # Recursivamente descubrir subcompartments
                    discover_compartment_tree "$sub_id" "$sub_name" $((level + 1)) "$full_path"
                fi
                
                sub_counter=$((sub_counter + 1))
            done
        fi
    else
        echo -e "${RED}    └── Error al obtener subcompartments${NC}"
    fi
}

# FASE 2: Buscar políticas en cada compartment
search_all_policies() {
    echo -e "${YELLOW}[FASE 2] Analizando políticas en todos los compartments...${NC}"
    
    while IFS='|' read -r compartment_id compartment_name level full_path; do
        if [ -n "$compartment_id" ]; then
            echo -e "${YELLOW}Analizando políticas en: $compartment_name${NC}"
            
            # Buscar políticas
            local policies=$(oci iam policy list \
                --compartment-id "$compartment_id" \
                --all \
                --profile "$OCI_PROFILE" 2>/dev/null)
            
            local policy_count=0
            local statement_count=0
            
            if [ $? -eq 0 ]; then
                policy_count=$(echo "$policies" | jq -r '.data | length' 2>/dev/null)
                
                if [ -z "$policy_count" ] || [ "$policy_count" = "null" ]; then
                    policy_count=0
                fi
                
                echo -e "${GREEN}    └── Políticas encontradas: $policy_count${NC}"
                
                if [ "$policy_count" -gt 0 ]; then
                    COMPARTMENTS_WITH_POLICIES=$((COMPARTMENTS_WITH_POLICIES + 1))
                    TOTAL_POLICIES=$((TOTAL_POLICIES + policy_count))
                    
                    # Contar statements en todas las políticas
                    local counter=0
                    while [ $counter -lt $policy_count ]; do
                        local policy_id=$(echo "$policies" | jq -r ".data[$counter].id" 2>/dev/null)
                        
                        if [ "$policy_id" != "null" ] && [ -n "$policy_id" ]; then
                            local policy_details=$(oci iam policy get \
                                --policy-id "$policy_id" \
                                --profile "$OCI_PROFILE" 2>/dev/null)
                            
                            if [ $? -eq 0 ]; then
                                local statements=$(echo "$policy_details" | jq -r '.data.statements | length' 2>/dev/null)
                                if [ -n "$statements" ] && [ "$statements" != "null" ]; then
                                    statement_count=$((statement_count + statements))
                                fi
                            fi
                        fi
                        
                        counter=$((counter + 1))
                    done
                    
                    TOTAL_STATEMENTS=$((TOTAL_STATEMENTS + statement_count))
                else
                    COMPARTMENTS_WITHOUT_POLICIES=$((COMPARTMENTS_WITHOUT_POLICIES + 1))
                fi
            else
                echo -e "${RED}    └── Error al obtener políticas${NC}"
                COMPARTMENTS_WITHOUT_POLICIES=$((COMPARTMENTS_WITHOUT_POLICIES + 1))
            fi
            
            # Actualizar archivo temporal con estadísticas
            echo "$compartment_id|$compartment_name|$level|$full_path|$policy_count|$statement_count" >> "${TEMP_TREE_FILE}.stats"
        fi
    done < "$TEMP_TREE_FILE"
}

# FASE 3: Generar reporte detallado con estructura jerárquica
generate_detailed_report() {
    echo -e "${CYAN}[FASE 3] Generando reporte detallado...${NC}"
    
    # Función interna para mostrar compartment con indentación
    show_compartment_details() {
        local compartment_id=$1
        local compartment_name=$2
        local level=$3
        local full_path=$4
        local policy_count=$5
        local statement_count=$6
        
        # Crear indentación basada en el nivel
        local indent=""
        local prefix=""
        
        if [ $level -eq 0 ]; then
            prefix="[ROOT] "
        else
            local i=0
            while [ $i -lt $level ]; do
                if [ $i -eq $((level - 1)) ]; then
                    indent="${indent}└── "
                else
                    indent="${indent}    "
                fi
                i=$((i + 1))
            done
            prefix="$indent"
        fi
        
        # Escribir información del compartment
        echo "${prefix}${compartment_name}" >> "$MAIN_OUTPUT"
        echo "    ${indent}Path: $full_path" >> "$MAIN_OUTPUT"
        echo "    ${indent}Políticas: $policy_count | Statements: $statement_count" >> "$MAIN_OUTPUT"
        
        # Si hay políticas, mostrar detalles
        if [ "$policy_count" -gt 0 ]; then
            local policies=$(oci iam policy list \
                --compartment-id "$compartment_id" \
                --all \
                --profile "$OCI_PROFILE" 2>/dev/null)
            
            if [ $? -eq 0 ]; then
                local counter=0
                while [ $counter -lt $policy_count ]; do
                    local policy_id=$(echo "$policies" | jq -r ".data[$counter].id" 2>/dev/null)
                    local policy_name=$(echo "$policies" | jq -r ".data[$counter].name" 2>/dev/null)
                    
                    if [ "$policy_id" != "null" ] && [ "$policy_name" != "null" ] && [ -n "$policy_id" ] && [ -n "$policy_name" ]; then
                        echo "" >> "$MAIN_OUTPUT"
                        echo "        ${indent}🔐 Política: $policy_name" >> "$MAIN_OUTPUT"
                        echo "        ${indent}    ID: $policy_id" >> "$MAIN_OUTPUT"
                        
                        # Obtener statements
                        local policy_details=$(oci iam policy get \
                            --policy-id "$policy_id" \
                            --profile "$OCI_PROFILE" 2>/dev/null)
                        
                        if [ $? -eq 0 ]; then
                            echo "        ${indent}    📝 Statements:" >> "$MAIN_OUTPUT"
                            echo "$policy_details" | jq -r '.data.statements[]' 2>/dev/null | while read -r statement; do
                                if [ -n "$statement" ]; then
                                    echo "        ${indent}        • $statement" >> "$MAIN_OUTPUT"
                                fi
                            done
                        else
                            echo "        ${indent}    ❌ Error al obtener detalles" >> "$MAIN_OUTPUT"
                        fi
                    fi
                    
                    counter=$((counter + 1))
                done
            fi
        fi
        
        echo "" >> "$MAIN_OUTPUT"
    }
    
    # Procesar archivo de estadísticas ordenado por nivel
    sort -t'|' -k3n "${TEMP_TREE_FILE}.stats" | while IFS='|' read -r compartment_id compartment_name level full_path policy_count statement_count; do
        if [ -n "$compartment_id" ]; then
            show_compartment_details "$compartment_id" "$compartment_name" "$level" "$full_path" "$policy_count" "$statement_count"
        fi
    done
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

DISTRIBUCIÓN DE POLÍTICAS POR COMPARTMENT:
==========================================
EOF
    
    # Mostrar distribución por compartment usando el archivo de estadísticas
    while IFS='|' read -r compartment_id compartment_name level full_path policy_count statement_count; do
        if [ -n "$compartment_id" ]; then
            printf "%-30s | %-5s políticas | %s\n" "$compartment_name" "$policy_count" "$full_path" >> "$SUMMARY_OUTPUT"
        fi
    done < "${TEMP_TREE_FILE}.stats"
    
    cat >> "$SUMMARY_OUTPUT" << EOF

ANÁLISIS DE SEGURIDAD:
=====================
EOF
    
    if [ $TOTAL_COMPARTMENTS -gt 0 ]; then
        local coverage_percentage=$((COMPARTMENTS_WITH_POLICIES * 100 / TOTAL_COMPARTMENTS))
        echo "• Ratio de Compartments con Políticas: ${coverage_percentage}%" >> "$SUMMARY_OUTPUT"
        
        local avg_policies=$((TOTAL_POLICIES * 100 / TOTAL_COMPARTMENTS))
        echo "• Promedio de Políticas por Compartment: $((avg_policies / 100)).$((avg_policies % 100))" >> "$SUMMARY_OUTPUT"
    fi
    
    if [ $TOTAL_POLICIES -gt 0 ]; then
        local avg_statements=$((TOTAL_STATEMENTS * 100 / TOTAL_POLICIES))
        echo "• Promedio de Statements por Política: $((avg_statements / 100)).$((avg_statements % 100))" >> "$SUMMARY_OUTPUT"
    fi
    
    cat >> "$SUMMARY_OUTPUT" << EOF

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
Generado por: OCI Policies Hierarchical Analyzer v2.0
================================================================================
EOF
}

# Función de limpieza
cleanup() {
    if [ -f "$TEMP_TREE_FILE" ]; then
        rm -f "$TEMP_TREE_FILE"
    fi
    if [ -f "${TEMP_TREE_FILE}.stats" ]; then
        rm -f "${TEMP_TREE_FILE}.stats"
    fi
}

# Capturar señales para limpieza
trap cleanup EXIT INT TERM

# ========== EJECUCIÓN PRINCIPAL ==========

echo "=================================================================================="
echo -e "${GREEN}🚀 INICIANDO ANÁLISIS JERÁRQUICO DE POLÍTICAS OCI${NC}"
echo "=================================================================================="
echo ""

# FASE 1: Descubrir árbol completo de compartments
echo -e "${CYAN}FASE 1: DESCUBRIMIENTO DEL ÁRBOL DE COMPARTMENTS${NC}"
echo "=================================================================================="
discover_compartment_tree "$TENANCY_OCID" "$TENANCY_NAME" 0 ""
echo ""
echo -e "${GREEN}✅ Árbol de compartments descubierto: $TOTAL_COMPARTMENTS compartments encontrados${NC}"
echo ""

# FASE 2: Buscar políticas en cada compartment
echo -e "${CYAN}FASE 2: BÚSQUEDA DE POLÍTICAS${NC}"
echo "=================================================================================="
search_all_policies
echo ""
echo -e "${GREEN}✅ Búsqueda de políticas completada${NC}"
echo ""

# FASE 3: Generar reportes
echo -e "${CYAN}FASE 3: GENERACIÓN DE REPORTES${NC}"
echo "=================================================================================="

# Crear archivo de detalle
create_banner "OCI POLICIES HIERARCHICAL ANALYSIS" "$MAIN_OUTPUT"
echo "JERARQUÍA DE COMPARTMENTS Y POLÍTICAS:" >> "$MAIN_OUTPUT"
echo "=======================================" >> "$MAIN_OUTPUT"
echo "" >> "$MAIN_OUTPUT"

generate_detailed_report

# Generar resumen ejecutivo
generate_executive_summary

echo -e "${GREEN}✅ Reportes generados${NC}"
echo ""

# Mostrar resultados finales
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
echo -e "  • Cobertura: ${GREEN}$COMPARTMENTS_WITH_POLICIES${NC}/${GREEN}$TOTAL_COMPARTMENTS${NC} compartments con políticas"
echo ""
echo -e "${YELLOW}Ver resumen ejecutivo:${NC}"
echo "=================================================================================="
cat "$SUMMARY_OUTPUT"