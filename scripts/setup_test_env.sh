#!/usr/bin/env bash
#
# setup_test_env.sh
#
# Configuracao inicial do ambiente de teste cliente-servidor F-Stack/DPDK
# entre este servidor (i350 + F-Stack) e o host cliente nerds01, ligados
# por cabo direto (sem switch) nas portas i350.
#
# Pre-requisito: install_fstack_dpdk.sh ja deve ter sido rodado no lado
# servidor (DPDK + F-Stack instalados, hugepages configuradas). Este script
# NAO reinstala nada — ele so leva o ambiente ja instalado para o estado
# necessario para o teste server.c <-> client.c (bind da porta certa,
# ajustes de config.ini, IP do cliente, compilacao).
#
# Tambem aplica (idempotente) a correcao do bug raiz do throughput baixo:
# tcp_ecn.c nunca esta listado em lib/Makefile's NETINET_SRCS neste fork,
# entao chamadas a tcp_ecn_syncache_add/respond resolvem contra stubs vazios
# com assinatura incompativel, corrompendo sc->sc_flags e suprimindo as
# opcoes TCP do SYN-ACK (MSS cai para 536 bytes). Ver patch_missing_tcp_ecn()
# abaixo e Tutorial.md secao 5 para detalhes completos.
#
# Topologia confirmada (cabo direto, pareamento por indice, ver Tutorial.md):
#   Servidor 0000:0a:00.1 (enp10s0f1) <-> Cliente enp2s0f1  (nerds01)
#   Servidor 0000:0a:00.2 (enp10s0f2) <-> Cliente enp2s0f2  (nerds01)
#   Servidor 0000:0a:00.3 (enp10s0f3) <-> Cliente enp2s0f3  (nerds01)
#   Servidor 0000:0a:00.0             <-> Cliente enp2s0f0  (SEM CABO, nao usar)
#
# USO:
#   sudo ./setup_test_env.sh server   # roda NO servidor (com F-Stack/DPDK)
#   sudo ./setup_test_env.sh client   # roda NO nerds01 (ou outro host cliente)
#
# Variaveis de ambiente para customizar (todas opcionais, ver defaults abaixo):
#   Lado servidor: FSTACK_DIR, SERVER_APP_DIR, CONFIG_INI, SERVER_NIC_PCI, LCORE_MASK
#   Lado cliente:  CLIENT_APP_DIR, CLIENT_IFACE, CLIENT_IP, SERVER_IP

set -euo pipefail

log()  { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
err()  { echo -e "\033[1;31m[x]\033[0m $*" >&2; }

require_root() {
    if [[ $EUID -ne 0 ]]; then
        err "Este script precisa ser executado como root (sudo)."
        exit 1
    fi
}

# Corrige o bug raiz do throughput catastroficamente baixo (~100 Kbps) e do
# SYN-ACK sem opcoes TCP visto neste F-Stack: tcp_ecn.c (a implementacao
# real de tcp_ecn_syncache_add/respond etc.) nunca esta listado em
# lib/Makefile's NETINET_SRCS neste fork, entao o linker resolve essas
# chamadas contra stubs vazios/com assinatura incompativel em
# ff_stub_14_extra.c. O chamador (tcp_syncache.c) le lixo do registrador de
# retorno esperando um int, corrompendo sc->sc_flags com bits imprevisiveis
# — as vezes incluindo SCF_NOOPT, que suprime TODAS as opcoes TCP do
# SYN-ACK (MSS cai para 536 bytes, RTO entra em backoff exponencial).
# Depois desta correcao, o mesmo link chega a ~930 Mbps (linha de Gigabit).
# Idempotente (nao duplica o patch se rodado de novo).
patch_missing_tcp_ecn() {
    local makefile="${FSTACK_DIR}/lib/Makefile"
    local stub="${FSTACK_DIR}/lib/ff_stub_14_extra.c"

    if grep -q "^	tcp_ecn.c	" "${makefile}"; then
        log "tcp_ecn.c ja esta em lib/Makefile, pulando patch de ECN."
        return
    fi

    log "Aplicando patch: adicionando tcp_ecn.c a lib/Makefile e removendo stubs conflitantes..."
    sed -i "s/^\(\s*ip_encap\.c\s*\\\\\)$/\1\n	tcp_ecn.c	\\\\/" "${makefile}"
    if ! grep -q "^	tcp_ecn.c	" "${makefile}"; then
        err "Falha ao inserir tcp_ecn.c em ${makefile} (formato do Makefile pode ter mudado)."
        exit 1
    fi

    python3 - "${stub}" <<'PYEOF'
import re, sys

path = sys.argv[1]
with open(path) as f:
    content = f.read()

marker = "tcp_do_ecn, tcp_ecn_maxretries and the tcp_ecn_* function family"
if marker in content:
    sys.exit(0)  # already patched

pattern = re.compile(
    r"int tcp_do_ecn = 2;.*?\n\nvoid \(\*tcp_hpts_softclock\)\(void\) = NULL;",
    re.DOTALL,
)
replacement = (
    "/*\n"
    " * tcp_do_ecn, tcp_ecn_maxretries and the tcp_ecn_* function family used\n"
    " * to be stubbed here with empty bodies / mismatched signatures vs.\n"
    " * tcp_ecn.h, because tcp_ecn.c was never added to NETINET_SRCS in\n"
    " * lib/Makefile. See patch_missing_tcp_ecn() in setup_test_env.sh.\n"
    " */\n\n"
    "void (*tcp_hpts_softclock)(void) = NULL;"
)
new_content, n = pattern.subn(replacement, content)
if n != 1:
    sys.exit("ERRO: bloco de stubs tcp_ecn_* nao encontrado em ff_stub_14_extra.c "
             "(o arquivo pode ter mudado de formato; aplique o patch manualmente).")

with open(path, "w") as f:
    f.write(new_content)
PYEOF
    log "Patch de ECN aplicado com sucesso."
}

build_lib() {
    log "Recompilando libfstack.a (necessario apos o patch de ECN)..."
    # shellcheck disable=SC1091
    source /etc/profile.d/dpdk-pkgconfig.sh 2>/dev/null || true
    export FF_DPDK="${FSTACK_DIR}/dpdk"
    export FF_PATH="${FSTACK_DIR}"
    make -C "${FSTACK_DIR}/lib" DPDK=y
}

# ============================================================
# LADO SERVIDOR
# ============================================================

FSTACK_DIR="${FSTACK_DIR:-/opt/f-stack}"
CONFIG_INI="${CONFIG_INI:-${FSTACK_DIR}/config/config.i350.ini}"
SERVER_APP_DIR="${SERVER_APP_DIR:-/home/nerds2/server}"
# Porta i350 com cabo fisicamente conectado ate o cliente (.0 nao tem link).
SERVER_NIC_PCI="${SERVER_NIC_PCI:-0000:0a:00.1}"
# 1 nucleo/1 fila RX — server.c so processa uma fila (thread unica). Usar
# mais de um nucleo aqui faz o RSS espalhar conexoes por filas que ninguem
# consome, derrubando SYNs de forma intermitente (ver Tutorial.md secao 4).
LCORE_MASK="${LCORE_MASK:-0x1}"

setup_server() {
    require_root

    if [[ ! -d "${FSTACK_DIR}" ]]; then
        err "${FSTACK_DIR} nao encontrado. Rode install_fstack_dpdk.sh install primeiro."
        exit 1
    fi
    if [[ ! -f "${CONFIG_INI}" ]]; then
        err "${CONFIG_INI} nao encontrado. Rode install_fstack_dpdk.sh install primeiro."
        exit 1
    fi

    log "Carregando PKG_CONFIG_PATH/LD_LIBRARY_PATH do DPDK..."
    # shellcheck disable=SC1091
    source /etc/profile.d/dpdk-pkgconfig.sh 2>/dev/null || \
        warn "/etc/profile.d/dpdk-pkgconfig.sh nao encontrado — pkg-config pode nao achar libdpdk."

    log "Parando processos 'server --conf' residuais, se houver..."
    pkill -f "server --conf" 2>/dev/null && sleep 2 || true

    log "Limpando estado IPC/hugepage residual do DPDK (/var/run/dpdk/rte/)..."
    rm -rf /var/run/dpdk/rte/* 2>/dev/null || true

    local devbind="${FSTACK_DIR}/dpdk/usertools/dpdk-devbind.py"
    if [[ ! -x "${devbind}" ]]; then
        err "dpdk-devbind.py nao encontrado em ${devbind}."
        exit 1
    fi

    log "Verificando driver atual de ${SERVER_NIC_PCI}..."
    local status
    status="$(python3 "${devbind}" --status)"
    if echo "${status}" | grep -q "^${SERVER_NIC_PCI} .*drv=vfio-pci"; then
        log "${SERVER_NIC_PCI} ja esta em vfio-pci."
    else
        # Se estiver presa num driver de kernel (igb) com IP de teste, limpa antes.
        local kiface
        kiface="$(echo "${status}" | grep "^${SERVER_NIC_PCI}" | grep -oP 'if=\K\S+' || true)"
        if [[ -n "${kiface}" ]]; then
            log "Removendo IPs de teste de ${kiface} antes do bind..."
            ip addr flush dev "${kiface}" 2>/dev/null || true
        fi
        log "Fazendo bind de ${SERVER_NIC_PCI} para vfio-pci..."
        modprobe vfio-pci
        python3 "${devbind}" --bind=vfio-pci "${SERVER_NIC_PCI}"
    fi

    log "Ajustando ${CONFIG_INI}: allow=${SERVER_NIC_PCI}, lcore_mask=${LCORE_MASK}..."
    sed -i "s/^allow=.*/allow=${SERVER_NIC_PCI}/" "${CONFIG_INI}"
    sed -i "s/^lcore_mask=.*/lcore_mask=${LCORE_MASK}/" "${CONFIG_INI}"
    grep -q "^port_list=0" "${CONFIG_INI}" || \
        warn "port_list=0 nao encontrado em ${CONFIG_INI} — confira manualmente."

    patch_missing_tcp_ecn
    if [[ ! -f "${FSTACK_DIR}/lib/tcp_ecn.o" ]]; then
        build_lib
    else
        log "libfstack.a ja foi compilada com o patch de ECN (tcp_ecn.o presente), pulando rebuild."
    fi

    if [[ ! -f "${SERVER_APP_DIR}/server.c" ]]; then
        err "server.c nao encontrado em ${SERVER_APP_DIR}."
        exit 1
    fi
    log "Compilando server (make server em ${SERVER_APP_DIR})..."
    make -C "${SERVER_APP_DIR}" server

    log "Ambiente do servidor pronto."
    echo
    echo "Resumo:"
    echo "  Porta DPDK:  ${SERVER_NIC_PCI} (vfio-pci)"
    echo "  Config:      ${CONFIG_INI} (allow=${SERVER_NIC_PCI}, lcore_mask=${LCORE_MASK})"
    echo "  Binario:     ${SERVER_APP_DIR}/server"
    echo
    echo "Proximo passo — subir o servidor:"
    echo "    sudo ${SERVER_APP_DIR}/server --conf ${CONFIG_INI}"
    echo "Confirme no log 'EAL: Auto-detected process type: PRIMARY' e 'Port 0 Link Up'."
}

# ============================================================
# LADO CLIENTE
# ============================================================

CLIENT_IFACE="${CLIENT_IFACE:-enp2s0f1}"
CLIENT_IP="${CLIENT_IP:-192.168.100.20/24}"
SERVER_IP="${SERVER_IP:-192.168.100.10}"
CLIENT_APP_DIR="${CLIENT_APP_DIR:-$(pwd)}"

setup_client() {
    require_root

    if ! ip link show "${CLIENT_IFACE}" &>/dev/null; then
        err "Interface ${CLIENT_IFACE} nao existe neste host. Rode 'ip link show' e" \
            "ajuste CLIENT_IFACE (ver tabela de pareamento no cabecalho deste script)."
        exit 1
    fi

    if command -v nmcli &>/dev/null; then
        log "Tirando ${CLIENT_IFACE} do controle do NetworkManager (evita que ele" \
            "tente DHCP nesse link ponto-a-ponto e apague o IP estatico)..."
        nmcli device set "${CLIENT_IFACE}" managed no || \
            warn "Falha ao marcar ${CLIENT_IFACE} como unmanaged — siga mesmo assim."
    else
        warn "nmcli nao encontrado, pulando (sem NetworkManager para atrapalhar)."
    fi

    if ip -4 addr show dev "${CLIENT_IFACE}" | grep -q "${CLIENT_IP%/*}"; then
        log "${CLIENT_IP} ja configurado em ${CLIENT_IFACE}."
    else
        log "Configurando ${CLIENT_IP} em ${CLIENT_IFACE}..."
        ip addr add "${CLIENT_IP}" dev "${CLIENT_IFACE}"
    fi
    ip link set "${CLIENT_IFACE}" up

    if [[ ! -f "${CLIENT_APP_DIR}/client.c" ]]; then
        err "client.c nao encontrado em ${CLIENT_APP_DIR}. Copie client.c + Makefile" \
            "para este host antes de rodar 'client'."
        exit 1
    fi
    log "Compilando client (make client em ${CLIENT_APP_DIR})..."
    make -C "${CLIENT_APP_DIR}" client

    log "Testando conectividade com o servidor (${SERVER_IP})..."
    if ping -c 3 -W 2 "${SERVER_IP}" &>/dev/null; then
        log "Ping OK — servidor alcancavel."
    else
        warn "Ping falhou. Confira se o 'server' esta rodando do outro lado e se" \
             "${CLIENT_IFACE} e mesmo a porta cabeada ate a porta DPDK em uso" \
             "(ver tabela de pareamento no cabecalho deste script)."
    fi

    log "Ambiente do cliente pronto."
    echo
    echo "Resumo:"
    echo "  Interface:  ${CLIENT_IFACE} (${CLIENT_IP}, unmanaged)"
    echo "  Binario:    ${CLIENT_APP_DIR}/client"
    echo
    echo "Proximo passo — gerar trafego de teste:"
    echo "    ${CLIENT_APP_DIR}/client ${SERVER_IP} 9999 30"
}

# ============================================================
# MAIN
# ============================================================

main() {
    local action="${1:-}"
    case "${action}" in
        server) setup_server ;;
        client) setup_client ;;
        *)
            echo "Uso: $0 {server|client}"
            echo
            echo "  server  — roda NO servidor com F-Stack/DPDK instalado"
            echo "  client  — roda NO host cliente (ex.: nerds01)"
            exit 1
            ;;
    esac
}

main "$@"
