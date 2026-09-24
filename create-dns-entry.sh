#!/bin/bash

# ==============================================================================
# Script para aplicar o Helm Chart Anubis Gateway
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# O chart fica na mesma pasta deste script.
CHART_DIR="${SCRIPT_DIR}"
VALUES_FILE="${CHART_DIR}/values.yaml"
NAMESPACE="${1:-global-gateway}"

if [ ! -f "${VALUES_FILE}" ]; then
    echo "❌ Erro: Arquivo '${VALUES_FILE}' não encontrado!"
    exit 1
fi

echo "======================================================================"
echo "📦 Aplicando Helm Chart Anubis Gateway..."
echo "• Chart: ${CHART_DIR}"
echo "• Values: ${VALUES_FILE}"
echo "• Namespace: ${NAMESPACE}"
echo "======================================================================"

helm upgrade --install anubis-gateway "${CHART_DIR}" \
  -n "${NAMESPACE}" \
  --create-namespace \
  -f "${VALUES_FILE}"

echo "----------------------------------------------------------------------"
echo "✅ Helm upgrade aplicado com sucesso!"
echo ""
echo "🔍 Status dos Pods:"
kubectl get pods -n "${NAMESPACE}" -l "app.kubernetes.io/instance=anubis-gateway" || true
echo ""
echo "🔍 Status das Rotas (HTTPRoute):"
kubectl get httproute -n "${NAMESPACE}" || true
echo "======================================================================"