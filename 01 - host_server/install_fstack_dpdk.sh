#!/usr/bin/env bash
#
# install_fstack_dpdk.sh
#
# Instala e configura DPDK + F-Stack em um servidor Ubuntu com NIC física
# Intel i350 (driver kernel: igb / PMD DPDK: net_e1000_igb).
#
# Testado para funcionar em Ubuntu 22.04/24.04 com kernel 6.x. Detecta a
# versão do kernel em tempo de execução (uname -r), então também deve
# funcionar em uma eventual série 7.x sem alterações.
#
# USO:
#   sudo ./install_fstack_dpdk.sh install      # instala tudo (DPDK + F-Stack)
#   sudo ./install_fstack_dpdk.sh bind IFACE   # faz bind da interface p/ vfio-pci
#   sudo ./install_fstack_dpdk.sh unbind IFACE # devolve a interface pro driver igb
#   sudo ./install_fstack_dpdk.sh hugepages    # (re)configura hugepages
#
# ATENÇÃO: script idempotente na medida do possível, mas revise as
# variáveis abaixo (interface, PCI, hugepages) antes de rodar em produção.


# sudo sed -i 's/^allow=.*/allow=0000:02:00.0/' /opt/f-stack/config/config.i350.ini
# sudo /opt/f-stack/example/helloworld --conf /opt/f-stack/config/config.i350.ini


set -euo pipefail

# ============================================================
# VARIÁVEIS DE CONFIGURAÇÃO — ajuste conforme seu servidor
# ============================================================

FSTACK_BRANCH="${FSTACK_BRANCH:-dev}"            # branch do F-Stack a clonar
INSTALL_ROOT="${INSTALL_ROOT:-/opt}"
FSTACK_DIR="${INSTALL_ROOT}/f-stack"
# O F-Stack embute sua própria cópia (com patches próprios) do DPDK em
# ${FSTACK_DIR}/dpdk — precisa ser compilada dali, não de um tarball DPDK
# baixado separadamente, pois o F-Stack referencia símbolos que só existem
# nessa cópia patcheada (ver doc/F-Stack_Build_Guide.md do próprio projeto).
DPDK_SRC_DIR="${FSTACK_DIR}/dpdk"
DPDK_BUILD_DIR="${DPDK_SRC_DIR}/build"

# NIC alvo (i350). O endereço PCI da i350 varia de servidor para servidor
# (depende do slot físico onde a placa está encaixada) — por isso NIC_PCI e
# NIC_IFACE são auto-detectados via lspci (ver detect_nic_pci/detect_nic_iface
# abaixo) em vez de usar um valor fixo. Defina as variáveis de ambiente
# NIC_PCI/NIC_IFACE explicitamente para pular a auto-detecção (útil se houver
# mais de uma i350 no mesmo servidor, ou se a auto-detecção escolher a porta
# errada). Ex.: NIC_PCI=0000:0a:00.1 sudo -E ./install_fstack_dpdk.sh bind ethX
NIC_IFACE="${NIC_IFACE:-}"
NIC_PCI="${NIC_PCI:-}"

# PCI vendor:device ID da Intel I350 Gigabit Network Connection (constante,
# igual em qualquer slot/servidor — ao contrário do endereço PCI em si).
I350_VENDOR_DEVICE="8086:1521"

# Hugepages: i350 não exige muito, 1024 páginas de 2MB (2GB) é suficiente
# para a maioria dos casos de teste/dev. Ajuste para produção.
HUGEPAGE_SIZE_KB=2048
HUGEPAGE_COUNT="${HUGEPAGE_COUNT:-1024}"

# Core(s) DPDK vai usar (lcores). Ajuste ao seu processador.
DPDK_LCORES="${DPDK_LCORES:-0-1}"

# ============================================================
# FUNÇÕES AUXILIARES
# ============================================================

log()  { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
err()  { echo -e "\033[1;31m[x]\033[0m $*" >&2; }

# Reexecuta um comando com backoff exponencial. Útil para tolerar falhas
# transitórias de rede/DNS (ex.: VPN instável, mirror fora do ar).
# Uso: retry <tentativas> <delay_inicial_s> comando args...
retry() {
    local max_attempts="$1"; shift
    local delay="$1"; shift
    local attempt=1

    until "$@"; do
        if (( attempt >= max_attempts )); then
            err "Comando falhou após ${max_attempts} tentativas: $*"
            return 1
        fi
        warn "Tentativa ${attempt}/${max_attempts} falhou (\"$*\"). Nova tentativa em ${delay}s..."
        sleep "${delay}"
        attempt=$((attempt + 1))
        delay=$((delay * 2))
    done
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        err "Este script precisa ser executado como root (sudo)."
        exit 1
    fi
}

detect_kernel() {
    KERNEL_VERSION="$(uname -r)"
    log "Kernel detectado: ${KERNEL_VERSION}"
    # Extrai major.minor para eventuais checagens condicionais no futuro.
    KERNEL_MAJOR="$(echo "${KERNEL_VERSION}" | cut -d. -f1)"
    KERNEL_MINOR="$(echo "${KERNEL_VERSION}" | cut -d. -f2)"
}

# Descobre o(s) endereço(s) PCI da i350 via lspci (ID fixo 8086:1521), já
# que o slot varia por servidor. Respeita NIC_PCI se já tiver sido definida
# explicitamente (env var ou -e no sudo).
detect_nic_pci() {
    if [[ -n "${NIC_PCI}" ]]; then
        log "Usando NIC_PCI definida explicitamente: ${NIC_PCI}"
        return
    fi

    local found
    found="$(lspci -Dnn 2>/dev/null | grep -i "\[${I350_VENDOR_DEVICE}\]" | awk '{print $1}')"

    if [[ -z "${found}" ]]; then
        err "Não foi possível auto-detectar uma NIC Intel i350 (PCI ID ${I350_VENDOR_DEVICE})" \
            "via lspci. Rode 'lspci -Dnn | grep -i ethernet' para conferir os PCIs" \
            "disponíveis e defina manualmente, ex.:" \
            "  sudo NIC_PCI=0000:0a:00.0 -E $0 ${1:-install}"
        exit 1
    fi

    NIC_PCI="$(echo "${found}" | head -1)"
    local count
    count="$(echo "${found}" | wc -l)"
    if [[ "${count}" -gt 1 ]]; then
        warn "Múltiplas portas i350 detectadas neste servidor:"
        while IFS= read -r pci; do warn "    - ${pci}"; done <<< "${found}"
        warn "Usando a primeira automaticamente (${NIC_PCI})." \
             "Para escolher outra porta, defina NIC_PCI explicitamente:" \
             "  sudo NIC_PCI=0000:xx:00.x -E $0 ${1:-install}"
    else
        log "NIC i350 detectada automaticamente em ${NIC_PCI}."
    fi
}

# Descobre a interface Linux correspondente a NIC_PCI (só existe se a porta
# ainda estiver num driver de kernel como igb — some quando já está em
# vfio-pci, o que é normal). Respeita NIC_IFACE se já definida.
detect_nic_iface() {
    if [[ -n "${NIC_IFACE}" ]]; then
        return
    fi

    local netdir="/sys/bus/pci/devices/${NIC_PCI}/net"
    if [[ -d "${netdir}" ]]; then
        NIC_IFACE="$(ls "${netdir}" | head -1)"
        log "Interface Linux correspondente a ${NIC_PCI}: ${NIC_IFACE}"
    else
        warn "Nenhuma interface de rede associada a ${NIC_PCI} no momento" \
             "(provavelmente já está em vfio-pci, sem ifname de kernel — normal" \
             "se essa porta já foi bindada antes). Informe a interface manualmente" \
             "se for usar 'bind'/'unbind' sem argumento."
    fi
}

# ============================================================
# 1. PACOTES DE SISTEMA
# ============================================================

install_system_deps() {
    log "Atualizando índices de pacotes..."
    # apt-get update retorna erro se QUALQUER repositório configurado falhar
    # (ex.: PPA de terceiros fora do ar/404), mesmo que os repositórios
    # oficiais do Ubuntu — de onde vêm todas as dependências abaixo — tenham
    # sido atualizados com sucesso. Por isso não tratamos isso como fatal:
    # avisamos e seguimos, pois os pacotes que instalamos aqui não dependem
    # de PPAs de terceiros.
    if ! retry 5 5 apt-get update -y; then
        warn "apt-get update falhou mesmo após retries — possivelmente algum" \
             "repositório de terceiros (PPA) está quebrado ou indisponível." \
             "Prosseguindo mesmo assim, já que os pacotes necessários vêm dos" \
             "repositórios oficiais do Ubuntu. Se 'apt-get install' abaixo" \
             "falhar por pacote não encontrado, revise 'apt-get update' manualmente."
    fi

    log "Instalando dependências de build (kernel headers para ${KERNEL_VERSION})..."
    retry 5 5 apt-get install -y \
        build-essential \
        git \
        wget \
        curl \
        python3 \
        python3-pip \
        python3-pyelftools \
        meson \
        ninja-build \
        pkg-config \
        libnuma-dev \
        libpcap-dev \
        libssl-dev \
        libarchive-dev \
        nettle-dev \
        libacl1-dev \
        libzstd-dev \
        liblz4-dev \
        libbz2-dev \
        linux-headers-"${KERNEL_VERSION}" \
        pciutils \
        net-tools \
        ethtool \
        kmod

    # pip para dependências python usadas pelo dpdk-devbind e utilidades.
    # --break-system-packages só existe em pip >= 23.0.1 (PEP 668); versões
    # mais antigas (ex.: Ubuntu 22.04) não reconhecem a flag.
    if pip3 install --help 2>&1 | grep -q -- --break-system-packages; then
        retry 3 5 pip3 install --break-system-packages --upgrade pyelftools || true
    else
        retry 3 5 pip3 install --upgrade pyelftools || true
    fi

    if [[ ! -e /lib/modules/${KERNEL_VERSION}/build ]]; then
        warn "linux-headers-${KERNEL_VERSION} pode não ter instalado corretamente." \
             "Verifique 'apt list --installed | grep linux-headers'."
    fi
}

# ============================================================
# 2. HUGEPAGES
# ============================================================

setup_hugepages() {
    log "Configurando ${HUGEPAGE_COUNT} hugepages de ${HUGEPAGE_SIZE_KB}kB..."

    local hp_path="/sys/kernel/mm/hugepages/hugepages-${HUGEPAGE_SIZE_KB}kB/nr_hugepages"
    if [[ ! -e "${hp_path}" ]]; then
        err "Path de hugepages não encontrado: ${hp_path}. O kernel suporta esse tamanho de página?"
        exit 1
    fi

    echo "${HUGEPAGE_COUNT}" > "${hp_path}"

    local allocated
    allocated="$(cat "${hp_path}")"
    if [[ "${allocated}" -lt "${HUGEPAGE_COUNT}" ]]; then
        warn "Só foi possível alocar ${allocated}/${HUGEPAGE_COUNT} hugepages." \
             "Memória insuficiente disponível — considere reduzir HUGEPAGE_COUNT" \
             "ou reservar via parâmetro de boot (hugepagesz=2M hugepages=${HUGEPAGE_COUNT})."
    fi

    mkdir -p /dev/hugepages
    if ! mountpoint -q /dev/hugepages; then
        mount -t hugetlbfs nodev /dev/hugepages
        log "hugetlbfs montado em /dev/hugepages"
    else
        log "/dev/hugepages já está montado."
    fi

    # Persistência entre reboots via sysctl + fstab
    if ! grep -q "vm.nr_hugepages" /etc/sysctl.conf 2>/dev/null; then
        echo "vm.nr_hugepages=${HUGEPAGE_COUNT}" >> /etc/sysctl.conf
        log "vm.nr_hugepages adicionado a /etc/sysctl.conf (persistente)"
    fi

    if ! grep -q "hugetlbfs" /etc/fstab 2>/dev/null; then
        echo "nodev /dev/hugepages hugetlbfs defaults 0 0" >> /etc/fstab
        log "Entrada hugetlbfs adicionada a /etc/fstab (persistente)"
    fi
}

# ============================================================
# 3. BUILD DO DPDK
# ============================================================

build_dpdk() {
    if [[ ! -d "${DPDK_SRC_DIR}" ]]; then
        err "DPDK embutido não encontrado em ${DPDK_SRC_DIR}. Rode a clonagem do F-Stack primeiro."
        exit 1
    fi

    log "Compilando DPDK embutido do F-Stack (${DPDK_SRC_DIR})..."
    cd "${DPDK_SRC_DIR}"

    log "Configurando build com meson (PMD igb habilitado por padrão)..."
    if [[ ! -d "${DPDK_BUILD_DIR}" ]]; then
        meson setup build \
            -Dexamples=l2fwd,l3fwd \
            -Dplatform=native
    fi

    log "Compilando DPDK (ninja)..."
    ninja -C build

    log "Instalando DPDK no sistema (ninja install + ldconfig)..."
    ninja -C build install
    ldconfig

    # Exporta variáveis de ambiente do pkg-config para builds subsequentes
    # (F-Stack precisa localizar libdpdk via pkg-config)
    echo "export PKG_CONFIG_PATH=/usr/local/lib/x86_64-linux-gnu/pkgconfig:\${PKG_CONFIG_PATH:-}" \
        > /etc/profile.d/dpdk-pkgconfig.sh
    echo "export LD_LIBRARY_PATH=/usr/local/lib/x86_64-linux-gnu:\${LD_LIBRARY_PATH:-}" \
        >> /etc/profile.d/dpdk-pkgconfig.sh
    chmod +x /etc/profile.d/dpdk-pkgconfig.sh
    # shellcheck disable=SC1091
    source /etc/profile.d/dpdk-pkgconfig.sh

    log "Verificando se o PMD igb foi habilitado:"
    if pkg-config --list-all 2>/dev/null | grep -q libdpdk; then
        log "libdpdk registrada no pkg-config: $(pkg-config --modversion libdpdk)"
    else
        err "pkg-config não encontrou libdpdk. Verifique o install acima."
        exit 1
    fi

    # vfio-pci é o método recomendado (não exige módulo out-of-tree como igb_uio)
    log "Carregando módulo vfio-pci..."
    modprobe vfio-pci

    # Necessário para vfio funcionar sem IOMMU de hardware (comum em VMs/labs).
    # Em servidor físico com IOMMU habilitado na BIOS/VT-d, isso não é necessário,
    # mas não tem efeito colateral deixá-lo configurado.
    if [[ -e /sys/module/vfio/parameters/enable_unsafe_noiommu_mode ]]; then
        echo 1 > /sys/module/vfio/parameters/enable_unsafe_noiommu_mode || true
    fi
}

# ============================================================
# 4. BUILD DO F-STACK
# ============================================================

clone_fstack() {
    log "Clonando F-Stack (branch ${FSTACK_BRANCH})..."
    mkdir -p "${INSTALL_ROOT}"
    cd "${INSTALL_ROOT}"

    if [[ ! -d "${FSTACK_DIR}" ]]; then
        retry 5 5 git clone --branch "${FSTACK_BRANCH}" --depth 1 \
            https://github.com/F-Stack/f-stack.git "${FSTACK_DIR}"
    else
        log "Diretório ${FSTACK_DIR} já existe, pulando clone."
    fi

    # O Makefile do F-Stack só desliga -Werror=array-bounds a partir do GCC 12,
    # mas o falso positivo em freebsd/kern/sys_generic.c (kern_specialfd) já
    # ocorre no GCC 11 (padrão do Ubuntu 22.04). Baixa o gate de versão para 11.
    local fstack_makefile="${FSTACK_DIR}/lib/Makefile"
    if ! grep -q '^GCCVERGE12 = .*>= 11)$' "${fstack_makefile}"; then
        log "Aplicando patch: -Wno-error=array-bounds também para GCC 11 (workaround p/ GCC 11.4 do Ubuntu 22.04)."
        # Sem comentário na mesma linha: um "# ..." colado após o $(shell ...)
        # deixa um espaço residual no valor da variável (ex.: "1 " em vez de
        # "1"), o que quebra o ifeq de comparação mais abaixo no Makefile.
        sed -i \
            -E 's/^GCCVERGE12 = (.*)>= (12\)|11\) # .*)$/GCCVERGE12 = \1>= 11)/' \
            "${fstack_makefile}"
    fi
}

build_fstack() {
    export FF_DPDK="${DPDK_SRC_DIR}"
    export FF_PATH="${FSTACK_DIR}"
    # shellcheck disable=SC1091
    source /etc/profile.d/dpdk-pkgconfig.sh

    log "Compilando lib do F-Stack..."
    cd "${FSTACK_DIR}/lib"
    make clean >/dev/null 2>&1 || true
    make -j"$(nproc)" DPDK=y

    log "Instalando headers do F-Stack (ff_config.h etc.) em /usr/local/include..."
    make install

    log "Compilando exemplo helloworld para validar a build..."
    cd "${FSTACK_DIR}/example"
    make -j"$(nproc)"

    log "F-Stack compilado em ${FSTACK_DIR}. Binários de exemplo em ${FSTACK_DIR}/example."
}

# ============================================================
# 5. CONFIG.INI DE REFERÊNCIA PARA A i350
# ============================================================

write_config_ini() {
    local cfg_dir="${FSTACK_DIR}/config"
    mkdir -p "${cfg_dir}"
    local cfg_file="${cfg_dir}/config.i350.ini"

    log "Gerando config.ini de referência em ${cfg_file}..."

    cat > "${cfg_file}" <<EOF
[dpdk]
# lcores usados pela pilha F-Stack; alinhe com DPDK_LCORES no script
lcore_mask=$(printf '0x%x' $(( (1 << $(echo ${DPDK_LCORES} | cut -d- -f1)) | (1 << $(echo ${DPDK_LCORES} | cut -d- -f2)) )))
channel=4
promiscuous=1
numa_on=0
tso=0
vlan_strip=1
# Obrigatório: sem port_list o F-Stack falha ao iniciar com
# "port_cfg_handler: must config dpdk.port_list first". 0 = índice da
# primeira (e única, neste template) porta DPDK, correspondente a
# allow abaixo.
port_list=0

# Endereço PCI da i350 obtido via dpdk-devbind.py -s (após bind em vfio-pci).
# A chave é "allow" (nome atual do EAL); "pci_whitelist" NÃO é reconhecida
# pelo parser de ini do F-Stack e seria silenciosamente ignorada.
allow=${NIC_PCI}

# Diretório de sockets Unix usados pelo processo mestre / freebsd stack
[freebsd.boot]
hz=100

[freebsd.sysctl]
kern.ipc.maxsockets=262144
net.inet.tcp.syncache.hashsize=4096
net.inet.tcp.syncache.bucketlimit=100
net.inet.tcp.tcbhashsize=65536
net.inet.tcp.fast_finwait2_recycle=1

[port0]
# Ajuste addr/netmask/gateway ao seu segmento de rede real
addr=192.168.100.10
netmask=255.255.255.0
broadcast=192.168.100.255
gateway=192.168.100.1

# Se for usar múltiplas filas RSS na i350:
#nb_vdev=0
#lcore_list=${DPDK_LCORES}
EOF

    log "Revise manualmente addr/netmask/gateway em ${cfg_file} antes de rodar a aplicação."
}

# ============================================================
# 6. BIND / UNBIND DE INTERFACE
# ============================================================

bind_iface() {
    local iface="${1:?Uso: $0 bind <iface>}"
    local devbind="${DPDK_SRC_DIR}/usertools/dpdk-devbind.py"

    if [[ ! -x "${devbind}" ]]; then
        err "dpdk-devbind.py não encontrado em ${devbind}. Rode '$0 install' primeiro."
        exit 1
    fi

    local pci
    pci="$(python3 "${devbind}" --status | awk -v ifc="${iface}" '$0 ~ ifc {print $1}')"

    if [[ -z "${pci}" ]]; then
        warn "Não encontrei PCI automaticamente para ${iface}; usando NIC_PCI=${NIC_PCI} do script."
        pci="${NIC_PCI}"
    fi

    log "Fazendo down da interface ${iface}..."
    ip link set "${iface}" down || true

    log "Fazendo bind de ${pci} (${iface}) para vfio-pci..."
    modprobe vfio-pci
    python3 "${devbind}" --bind=vfio-pci "${pci}"

    log "Status atual:"
    local status_out
    status_out="$(python3 "${devbind}" --status)"
    echo "${status_out}"

    # O --bind pode retornar exit code 0 sem o driver ter mudado de fato
    # (já aconteceu na prática). Confirma explicitamente antes de seguir.
    if ! echo "${status_out}" | grep -q "^${pci} .*drv=vfio-pci"; then
        err "${pci} não aparece com drv=vfio-pci após o bind, mesmo com exit" \
            "code 0. O DPDK não vai encontrar a NIC nesse estado" \
            "(\"No probed ethernet devices\"). Diagnóstico sugerido:"
        echo "    sudo dmesg | grep -i iommu | tail -20"
        echo "    for d in /sys/bus/pci/devices/${pci%.*}.*; do echo \"\$d -> \$(readlink -f \$d/iommu_group)\"; done"
        echo "    cat /sys/module/vfio/parameters/enable_unsafe_noiommu_mode"
        exit 1
    fi
    log "Bind confirmado: ${pci} está em vfio-pci."
}

unbind_iface() {
    local iface="${1:?Uso: $0 unbind <iface>}"
    local devbind="${DPDK_SRC_DIR}/usertools/dpdk-devbind.py"
    local pci="${NIC_PCI}"

    log "Devolvendo ${pci} para o driver igb..."
    python3 "${devbind}" --bind=igb "${pci}"

    log "Subindo a interface novamente..."
    ip link set "${iface}" up || true

    python3 "${devbind}" --status
}

# ============================================================
# MAIN
# ============================================================

main() {
    require_root
    detect_kernel

    local action="${1:-}"

    case "${action}" in
        install)
            detect_nic_pci "${action}"
            detect_nic_iface
            install_system_deps
            setup_hugepages
            clone_fstack
            build_dpdk
            build_fstack
            write_config_ini
            log "Instalação concluída."
            log "Próximos passos:"
            echo "    1) sudo $0 bind ${NIC_IFACE:-<interface>}"
            echo "    2) Revise ${FSTACK_DIR}/config/config.i350.ini"
            echo "    3) Rode o exemplo: sudo ${FSTACK_DIR}/example/helloworld --conf ${FSTACK_DIR}/config/config.i350.ini"
            ;;
        bind)
            detect_nic_pci "${action}"
            detect_nic_iface
            bind_iface "${2:-${NIC_IFACE:?Informe a interface: $0 bind <iface>}}"
            ;;
        unbind)
            detect_nic_pci "${action}"
            detect_nic_iface
            unbind_iface "${2:-${NIC_IFACE:?Informe a interface: $0 unbind <iface>}}"
            ;;
        hugepages)
            setup_hugepages
            ;;
        *)
            echo "Uso: $0 {install|bind <iface>|unbind <iface>|hugepages}"
            exit 1
            ;;
    esac
}

main "$@"
