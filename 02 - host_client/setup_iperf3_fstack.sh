#!/usr/bin/env bash
#
# setup_iperf3_fstack.sh
#
# Configura e roda um teste real de vazao TCP entre duas maquinas usando
# iperf3 sobre F-Stack + DPDK, via o adaptador LD_PRELOAD (libff_syscall.so)
# que ja vem com este fork do F-Stack em adapter/syscall/. Isso permite usar
# o iperf3 (binario padrao, sem modificacao) como cliente/servidor de teste
# de vazao sobre a pilha TCP do F-Stack, em vez de escrever um gerador de
# trafego proprio.
#
# Pre-requisito: F-Stack/DPDK ja instalado (install_fstack_dpdk.sh) e a
# topologia de rede ja validada (ver Tutorial.md) — porta i350 com link
# fisico ate o host cliente, cabo direto sem switch.
#
# O adaptador LD_PRELOAD deste fork tem dois bugs conhecidos com iperf3
# (ver Tutorial.md secao 6 para detalhes completos):
#   1. Crash "buffer overflow detected" — corrigido compilando com
#      FF_PRELOAD_SUPPORT_SELECT=1 (flag documentada no Makefile do
#      adaptador, mas desligada por padrao).
#   2. "unable to set TCP_CONGESTION" — optname 13 do Linux nao tem
#      traducao para o equivalente FreeBSD neste adaptador; corrigido
#      com um patch pontual em ff_hook_syscall.c que intercepta essa
#      opcao e responde com sucesso sem repassar ao F-Stack.
# Este script aplica os dois automaticamente (idempotente — nao duplica
# o patch se rodado de novo).
#
# USO:
#   sudo ./setup_iperf3_fstack.sh server   # roda NO servidor com F-Stack/DPDK
#   sudo ./setup_iperf3_fstack.sh client   # roda NO host cliente, mede vazao
#
# Exemplo com parametros extras do iperf3 (JSON, 30s, blocos de 64K, 4 streams):
#   sudo IPERF3_DURATION=30 IPERF3_LENGTH=64K IPERF3_PARALLEL=4 IPERF3_JSON=true \
#       IPERF3_LOGFILE=/tmp/resultado.json ./setup_iperf3_fstack.sh client
#
# Variaveis de ambiente (todas opcionais, ver defaults abaixo):
#   Lado servidor: FSTACK_DIR, CONFIG_INI, SERVER_NIC_PCI, LCORE_MASK,
#                  IPERF3_PORT
#   Lado cliente:  CLIENT_IFACE, CLIENT_IP, SERVER_IP, IPERF3_PORT,
#                  IPERF3_DURATION (-t), IPERF3_LENGTH (-l), IPERF3_WINDOW (-w),
#                  IPERF3_CONGESTION (-C, so afeta o lado cliente — ver nota
#                  na secao "LADO CLIENTE" abaixo), IPERF3_PARALLEL (-P),
#                  IPERF3_MSS (-M), IPERF3_BITRATE (-b), IPERF3_REVERSE=true (-R),
#                  IPERF3_JSON=true (-J), IPERF3_LOGFILE (--logfile),
#                  IPERF3_EXTRA_ARGS (passthrough livre, ex.: "-O 2 -N")

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

# ============================================================
# COMUM
# ============================================================

FSTACK_DIR="${FSTACK_DIR:-/opt/f-stack}"
CONFIG_INI="${CONFIG_INI:-${FSTACK_DIR}/config/config.i350.ini}"
ADAPTER_DIR="${FSTACK_DIR}/adapter/syscall"
IPERF3_PORT="${IPERF3_PORT:-9999}"

# ============================================================
# LADO SERVIDOR
# ============================================================

SERVER_NIC_PCI="${SERVER_NIC_PCI:-0000:0a:00.1}"
LCORE_MASK="${LCORE_MASK:-0x1}"

# Aplica os dois patches de compatibilidade em ff_hook_syscall.c (TCP_CONGESTION
# nao traduzido entre Linux e FreeBSD). Idempotente: sai sem fazer nada se o
# marcador de patch ja estiver presente.
patch_adapter_tcp_congestion() {
    local src="${ADAPTER_DIR}/ff_hook_syscall.c"

    if grep -q "IPPROTO_TCP, TCP_CONGESTION" "${src}"; then
        log "Patch de TCP_CONGESTION ja aplicado em ff_hook_syscall.c, pulando."
        return
    fi

    log "Aplicando patch de compatibilidade TCP_CONGESTION em ff_hook_syscall.c..."
    python3 - "${src}" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path) as f:
    content = f.read()

getsockopt_anchor = """    CHECK_FD_OWNERSHIP(getsockopt, (fd, level, optname,
        optval, optlen));

    DEFINE_REQ_ARGS(getsockopt);"""

getsockopt_replacement = """    CHECK_FD_OWNERSHIP(getsockopt, (fd, level, optname,
        optval, optlen));

    /*
     * TCP_CONGESTION (Linux optname 13) has no numeric translation to
     * FreeBSD's own TCP_CONGESTION in this adapter (unlike ioctl, which has
     * linux2freebsd_ioctl()), so forwarding it verbatim would hit an
     * unrelated FreeBSD sockopt. Report a plausible built-in algorithm name
     * so callers like iperf3 (which reads this before/instead of setting
     * it) don't abort the connection.
     */
    if (level == 6 && optname == 13) {  /* IPPROTO_TCP, TCP_CONGESTION */
        static const char cc_name[] = "newreno";
        socklen_t cc_len = sizeof(cc_name);
        if (optval != NULL && *optlen > 0) {
            socklen_t copy_len = *optlen < cc_len ? *optlen : cc_len;
            rte_memcpy(optval, cc_name, copy_len);
            *optlen = copy_len;
        } else {
            *optlen = cc_len;
        }
        return 0;
    }

    DEFINE_REQ_ARGS(getsockopt);"""

setsockopt_anchor = """    CHECK_FD_OWNERSHIP(setsockopt, (fd, level, optname,
        optval, optlen));

    DEFINE_REQ_ARGS_STATIC(setsockopt);"""

setsockopt_replacement = """    CHECK_FD_OWNERSHIP(setsockopt, (fd, level, optname,
        optval, optlen));

    /*
     * TCP_CONGESTION (Linux optname 13) has no numeric translation to
     * FreeBSD's own TCP_CONGESTION in this adapter (unlike ioctl, which has
     * linux2freebsd_ioctl()), so forwarding it verbatim hits an unrelated
     * FreeBSD sockopt and fails. F-Stack fds only reach here, so this is
     * safe to no-op: apps like iperf3 (v3.9+) unconditionally try to set
     * it and abort the connection on failure, even without -C. We don't
     * need to steer the cc algorithm for a throughput test.
     */
    if (level == 6 && optname == 13) {  /* IPPROTO_TCP, TCP_CONGESTION */
        return 0;
    }

    DEFINE_REQ_ARGS_STATIC(setsockopt);"""

if getsockopt_anchor not in content:
    sys.exit("ERRO: ancora de getsockopt nao encontrada em ff_hook_syscall.c "
             "(o arquivo pode ter mudado de formato; aplique o patch manualmente).")
if setsockopt_anchor not in content:
    sys.exit("ERRO: ancora de setsockopt nao encontrada em ff_hook_syscall.c "
             "(o arquivo pode ter mudado de formato; aplique o patch manualmente).")

content = content.replace(getsockopt_anchor, getsockopt_replacement, 1)
content = content.replace(setsockopt_anchor, setsockopt_replacement, 1)

with open(path, "w") as f:
    f.write(content)
PYEOF
    log "Patch aplicado com sucesso."
}

build_adapter() {
    log "Compilando adaptador LD_PRELOAD (fstack + libff_syscall.so)..."
    # shellcheck disable=SC1091
    source /etc/profile.d/dpdk-pkgconfig.sh 2>/dev/null || \
        warn "/etc/profile.d/dpdk-pkgconfig.sh nao encontrado — pkg-config pode nao achar libdpdk."

    export FF_PATH="${FSTACK_DIR}"
    export FF_PRELOAD_SUPPORT_SELECT=1
    export FF_KERNEL_MAX_FD_SELECT=128

    make -C "${ADAPTER_DIR}" clean >/dev/null 2>&1 || true
    make -C "${ADAPTER_DIR}" all
}

stop_stale_processes() {
    log "Parando processos residuais (server/fstack/iperf3) e limpando estado DPDK..."
    pkill -9 -f "server --conf" 2>/dev/null || true
    pkill -9 -f "adapter/syscall/fstack" 2>/dev/null || true
    pkill -9 -f "iperf3 -s" 2>/dev/null || true
    sleep 2
    rm -rf /var/run/dpdk/rte/* 2>/dev/null || true
}

bind_nic() {
    local devbind="${FSTACK_DIR}/dpdk/usertools/dpdk-devbind.py"
    local status
    status="$(python3 "${devbind}" --status)"
    if echo "${status}" | grep -q "^${SERVER_NIC_PCI} .*drv=vfio-pci"; then
        log "${SERVER_NIC_PCI} ja esta em vfio-pci."
        return
    fi

    local kiface
    kiface="$(echo "${status}" | grep "^${SERVER_NIC_PCI}" | grep -oP 'if=\K\S+' || true)"
    if [[ -n "${kiface}" ]]; then
        ip addr flush dev "${kiface}" 2>/dev/null || true
    fi
    log "Fazendo bind de ${SERVER_NIC_PCI} para vfio-pci..."
    modprobe vfio-pci
    python3 "${devbind}" --bind=vfio-pci "${SERVER_NIC_PCI}"
}

setup_server() {
    require_root

    if [[ ! -d "${FSTACK_DIR}" ]] || [[ ! -f "${CONFIG_INI}" ]]; then
        err "${FSTACK_DIR}/${CONFIG_INI} nao encontrado. Rode install_fstack_dpdk.sh install primeiro."
        exit 1
    fi
    if [[ ! -d "${ADAPTER_DIR}" ]]; then
        err "${ADAPTER_DIR} nao encontrado. Este F-Stack nao tem o adaptador LD_PRELOAD (adapter/syscall)."
        exit 1
    fi

    stop_stale_processes
    bind_nic

    log "Ajustando ${CONFIG_INI}: allow=${SERVER_NIC_PCI}, lcore_mask=${LCORE_MASK}..."
    sed -i "s/^allow=.*/allow=${SERVER_NIC_PCI}/" "${CONFIG_INI}"
    sed -i "s/^lcore_mask=.*/lcore_mask=${LCORE_MASK}/" "${CONFIG_INI}"

    patch_adapter_tcp_congestion
    build_adapter

    log "Subindo instancia fstack (backend DPDK)..."
    local fstack_log="/tmp/fstack_instance.log"
    setsid nohup "${ADAPTER_DIR}/fstack" --conf "${CONFIG_INI}" \
        --proc-type=primary --proc-id=0 </dev/null > "${fstack_log}" 2>&1 &
    disown

    local waited=0
    while ! grep -q "Link Up" "${fstack_log}" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
        if [[ ${waited} -ge 20 ]]; then
            err "fstack nao subiu (sem 'Link Up' apos 20s). Confira ${fstack_log}:"
            tail -30 "${fstack_log}"
            exit 1
        fi
    done
    log "fstack rodando, link ativo."

    log "Subindo iperf3 -s com LD_PRELOAD (porta ${IPERF3_PORT})..."
    local iperf3_log="/tmp/iperf3_server.log"
    setsid nohup env LD_PRELOAD="${ADAPTER_DIR}/libff_syscall.so" FF_NB_FSTACK_INSTANCE=1 \
        iperf3 -s -4 -p "${IPERF3_PORT}" </dev/null > "${iperf3_log}" 2>&1 &
    disown

    sleep 3
    if ! pgrep -f "iperf3 -s -4 -p ${IPERF3_PORT}" >/dev/null; then
        err "iperf3 -s nao ficou de pe. Confira ${iperf3_log}:"
        tail -30 "${iperf3_log}"
        exit 1
    fi

    log "Ambiente do servidor pronto."
    echo
    echo "Resumo:"
    echo "  Porta DPDK:      ${SERVER_NIC_PCI} (vfio-pci)"
    echo "  fstack instance: rodando (log em ${fstack_log})"
    echo "  iperf3 -s:       rodando na porta ${IPERF3_PORT} (log em ${iperf3_log})"
    echo
    echo "No host cliente, rode:"
    echo "    sudo ./setup_iperf3_fstack.sh client"
}

# ============================================================
# LADO CLIENTE
# ============================================================

CLIENT_IFACE="${CLIENT_IFACE:-enp2s0f1}"
CLIENT_IP="${CLIENT_IP:-192.168.100.20/24}"
SERVER_IP="${SERVER_IP:-192.168.100.10}"

# Parametros de teste do iperf3 (todos opcionais). Cada um so entra na linha
# de comando se a variavel correspondente estiver definida — deixe em branco
# para usar o default do proprio iperf3.
IPERF3_DURATION="${IPERF3_DURATION:-10}"      # -t: duracao do teste em segundos
IPERF3_LENGTH="${IPERF3_LENGTH:-}"            # -l: tamanho do bloco/buffer de leitura-escrita (ex.: 1448, 64K)
IPERF3_WINDOW="${IPERF3_WINDOW:-}"            # -w: tamanho da janela/buffer de socket (ex.: 128K)
IPERF3_CONGESTION="${IPERF3_CONGESTION:-}"    # -C: algoritmo de controle de congestionamento (ex.: cubic, reno)
IPERF3_PARALLEL="${IPERF3_PARALLEL:-}"        # -P: numero de streams paralelos
IPERF3_MSS="${IPERF3_MSS:-}"                  # -M: MSS do lado cliente
IPERF3_BITRATE="${IPERF3_BITRATE:-}"          # -b: limite de taxa alvo (ex.: 100M); vazio = sem limite (TCP)
IPERF3_REVERSE="${IPERF3_REVERSE:-false}"     # -R: modo reverso (servidor envia, cliente recebe)
IPERF3_JSON="${IPERF3_JSON:-false}"           # -J: saida em JSON
IPERF3_LOGFILE="${IPERF3_LOGFILE:-}"          # --logfile: grava a saida (JSON ou texto) neste arquivo
IPERF3_EXTRA_ARGS="${IPERF3_EXTRA_ARGS:-}"    # passthrough livre para qualquer outra flag do iperf3

# Nota sobre IPERF3_CONGESTION: o adaptador LD_PRELOAD deste F-Stack nao
# traduz TCP_CONGESTION para o FreeBSD (ver Tutorial.md secao 6) — o patch
# aplicado por este script faz o lado servidor (F-Stack) ignorar silenciosamente
# qualquer tentativa de setar o algoritmo. Ou seja, -C so tem efeito real do
# lado cliente (kernel Linux); o servidor sempre usa o congestion control
# padrao do FreeBSD, independente do valor pedido aqui.
build_iperf3_client_args() {
    local -n _args_ref=$1
    _args_ref=(-c "${SERVER_IP}" -p "${IPERF3_PORT}" -t "${IPERF3_DURATION}")

    [[ -n "${IPERF3_LENGTH}" ]] && _args_ref+=(-l "${IPERF3_LENGTH}")
    [[ -n "${IPERF3_WINDOW}" ]] && _args_ref+=(-w "${IPERF3_WINDOW}")
    [[ -n "${IPERF3_CONGESTION}" ]] && _args_ref+=(-C "${IPERF3_CONGESTION}")
    [[ -n "${IPERF3_PARALLEL}" ]] && _args_ref+=(-P "${IPERF3_PARALLEL}")
    [[ -n "${IPERF3_MSS}" ]] && _args_ref+=(-M "${IPERF3_MSS}")
    [[ -n "${IPERF3_BITRATE}" ]] && _args_ref+=(-b "${IPERF3_BITRATE}")
    [[ "${IPERF3_REVERSE}" == "true" ]] && _args_ref+=(-R)
    [[ "${IPERF3_JSON}" == "true" ]] && _args_ref+=(-J)
    [[ -n "${IPERF3_LOGFILE}" ]] && _args_ref+=(--logfile "${IPERF3_LOGFILE}")
    if [[ -n "${IPERF3_EXTRA_ARGS}" ]]; then
        # shellcheck disable=SC2206
        local extra=(${IPERF3_EXTRA_ARGS})
        _args_ref+=("${extra[@]}")
    fi
}

setup_client() {
    require_root

    if ! ip link show "${CLIENT_IFACE}" &>/dev/null; then
        err "Interface ${CLIENT_IFACE} nao existe neste host. Ajuste CLIENT_IFACE" \
            "(ver tabela de pareamento no Tutorial.md)."
        exit 1
    fi

    if command -v nmcli &>/dev/null; then
        log "Tirando ${CLIENT_IFACE} do controle do NetworkManager..."
        nmcli device set "${CLIENT_IFACE}" managed no || \
            warn "Falha ao marcar ${CLIENT_IFACE} como unmanaged — siga mesmo assim."
    fi

    if ip -4 addr show dev "${CLIENT_IFACE}" | grep -q "${CLIENT_IP%/*}"; then
        log "${CLIENT_IP} ja configurado em ${CLIENT_IFACE}."
    else
        log "Configurando ${CLIENT_IP} em ${CLIENT_IFACE}..."
        ip addr add "${CLIENT_IP}" dev "${CLIENT_IFACE}"
    fi
    ip link set "${CLIENT_IFACE}" up

    if ! command -v iperf3 &>/dev/null; then
        err "iperf3 nao encontrado neste host. Instale com 'apt-get install iperf3'."
        exit 1
    fi

    log "Testando conectividade com o servidor (${SERVER_IP})..."
    if ! ping -c 3 -W 2 "${SERVER_IP}" &>/dev/null; then
        err "Ping falhou. Confira se 'sudo ./setup_iperf3_fstack.sh server' rodou do outro" \
            "lado e se ${CLIENT_IFACE} e mesmo a porta cabeada ate a porta DPDK em uso."
        exit 1
    fi
    log "Ping OK — servidor alcancavel."

    local iperf3_args
    build_iperf3_client_args iperf3_args
    log "Rodando: iperf3 ${iperf3_args[*]}"
    echo
    iperf3 "${iperf3_args[@]}"
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
            echo "  server  — roda NO servidor com F-Stack/DPDK: compila o adaptador"
            echo "            LD_PRELOAD, aplica os patches de compatibilidade,"
            echo "            sobe a instancia fstack e o iperf3 -s"
            echo "  client  — roda NO host cliente: configura a interface, testa"
            echo "            conectividade e roda o iperf3 -c medindo vazao"
            exit 1
            ;;
    esac
}

main "$@"
