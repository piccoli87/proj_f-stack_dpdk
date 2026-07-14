# Tutorial: Compilação e Execução do `server.c` (F-Stack + DPDK)

## 0. Setup automatizado (recomendado)

O script [setup_test_env.sh](setup_test_env.sh) automatiza tudo que este tutorial descreve manualmente nas seções 1 e 3: bind da porta DPDK certa, ajustes em `config.i350.ini` (`allow=`, `lcore_mask=`), limpeza de estado residual do DPDK, `nmcli managed no` + IP estático no cliente, e a compilação dos binários.

```bash
# no servidor (com F-Stack/DPDK ja instalado via install_fstack_dpdk.sh)
sudo /home/nerds2/server/setup_test_env.sh server
sudo /home/nerds2/server/server --conf /opt/f-stack/config/config.i350.ini   # sugerido ao final do script

# no host cliente (ex.: nerds01) — copie o script + client.c + Makefile para la antes
sudo ./setup_test_env.sh client
./client 192.168.100.10 9999 30   # sugerido ao final do script
```

Todos os defaults (porta PCI, `lcore_mask`, interface/IP do cliente etc.) são os já validados nesta topologia e podem ser sobrescritos por variável de ambiente — ver comentários no cabeçalho do script. As seções abaixo explicam cada passo manualmente, para quem quiser entender o que o script faz ou precisar adaptar algo fora do previsto.

## 1. Pré-requisitos

Já validados neste servidor (ver instalação via `install_fstack_dpdk.sh`):

- F-Stack + DPDK instalados em `/opt/f-stack`
- Hugepages alocadas e montadas em `/dev/hugepages`
- NIC i350 (`0000:0a:00.1`) bindada em `vfio-pci`
- Arquivo de config em `/opt/f-stack/config/config.i350.ini`

> **Sobre qual porta i350 usar:** a placa deste servidor tem 4 portas (`0000:0a:00.0` a `.3`), cabeadas diretamente (sem switch) até o host `nerds01` (172.16.30.106). Só as portas `.1`, `.2` e `.3` têm cabo fisicamente conectado — `.0` está com `NO-CARRIER` e não deve ser usada. O pareamento confirmado por índice é:
>
> | Servidor | Cliente (nerds01) |
> |---|---|
> | `0000:0a:00.1` (`enp10s0f1`) | `enp2s0f1` |
> | `0000:0a:00.2` (`enp10s0f2`) | `enp2s0f2` |
> | `0000:0a:00.3` (`enp10s0f3`) | `enp2s0f3` |
>
> `config.i350.ini` já está configurado com `allow=0000:0a:00.1`. Se precisar trocar de porta, lembre de atualizar essa linha e usar o par correspondente na tabela acima.

> **Nota:** além dos três arquivos deste diretório (`install_fstack_dpdk.sh`, `server.c`, `client.c`), também foi necessário editar `/opt/f-stack/config/config.i350.ini` (não é um arquivo deste diretório, fica em `/opt/f-stack/config/`, fora do repositório):
> - `allow=` mudado de `0000:0a:00.0` para `0000:0a:00.1`, já que a porta `.0` não tinha cabo conectado (passo a passo na próxima seção).
> - `lcore_mask=` mudado de `0x3` (2 núcleos) para `0x1` (1 núcleo) — com 2 núcleos o DPDK cria 2 filas RX e distribui conexões entre elas via RSS, mas `server.c` só atende 1 fila (thread única), então metade das conexões novas ficava travada em `SYN-SENT` sem resposta. Ver troubleshooting na seção 4 para o procedimento completo.

### Trocando a porta DPDK usada (caso precise repetir)

Isso só é necessário se a porta em uso não tiver link, ou se você quiser mudar para outra das portas da tabela acima. Passo a passo:

1. **Pare o `server` em execução** (ele mantém a porta DPDK atual presa exclusivamente):
   ```bash
   pkill -f "server --conf"
   ```
2. **Edite `allow=` em `config.i350.ini`** para o novo endereço PCI (precisa de root, o arquivo pertence a `/opt`):
   ```bash
   sudo sed -i 's/^allow=.*/allow=0000:0a:00.1/' /opt/f-stack/config/config.i350.ini
   ```
3. **Bind a nova porta em `vfio-pci`** (se ela estiver com o driver `igb`/sem driver, primeiro remova qualquer IP que tenha sido atribuído a ela para teste):
   ```bash
   sudo ip addr flush dev enp10s0f1   # ajuste o nome da interface se necessário
   sudo python3 /opt/f-stack/dpdk/usertools/dpdk-devbind.py --bind=vfio-pci 0000:0a:00.1
   ```
4. **Reinicie o `server`** com o mesmo `--conf`:
   ```bash
   sudo /home/nerds2/server/server --conf /opt/f-stack/config/config.i350.ini
   ```
   No log de inicialização, confira a linha `Port 0 Link Up - speed 1000 Mbps - full-duplex` — se aparecer `Link Down` em loop, a porta escolhida não tem cabo conectado (volte à tabela de pareamento em "Pré-requisitos").
5. No host cliente, ajuste o IP estático para a interface pareada com a nova porta (ver tabela) e repita o teste da seção "Gerando tráfego de teste" abaixo.

Antes de compilar, exporte o `PKG_CONFIG_PATH` (necessário para o `pkg-config` localizar a `libdpdk`; se você abrir um shell novo, ele não persiste sozinho a menos que faça `source /etc/profile.d/dpdk-pkgconfig.sh`):

```bash
export PKG_CONFIG_PATH=/usr/local/lib/x86_64-linux-gnu/pkgconfig:${PKG_CONFIG_PATH:-}
```

## 2. Compilação

### Opção A — via Makefile (recomendado)

O diretório já tem um `Makefile` pronto, com alvos separados para `server` (precisa de DPDK/F-Stack) e `client` (socket TCP comum, compila em qualquer máquina Linux):

```bash
cd /home/nerds2/server

make server   # binário que roda na máquina com F-Stack + NIC bindada
make client   # binário simples, roda em qualquer outra máquina/servidor
make          # compila os dois (falha em 'server' se DPDK não estiver instalado)
```

Para limpar:

```bash
make clean
```

### Opção B — comando manual (equivalente ao que o Makefile faz)

```bash
cd /home/nerds2/server

FF_PATH=/opt/f-stack
CFLAGS="-O0 -g -gdwarf-2 -Wall $(pkg-config --cflags libdpdk)"
LIBS="$(pkg-config --static --libs libdpdk) -L${FF_PATH}/lib -Wl,--whole-archive,-lfstack,--no-whole-archive -Wl,--no-whole-archive -lrt -lm -ldl -lcrypto -lz -pthread -lnuma"

cc $CFLAGS -DINET6 -o server server.c $LIBS
```

Pontos-chave dessa linha de compilação:

| Flag | Motivo |
|---|---|
| `pkg-config --cflags libdpdk` | Injeta `-include rte_config.h`, `-march=native` e os `-I` corretos do DPDK |
| `-DINET6` | Habilita suporte IPv6 no F-Stack (mesmo padrão usado no exemplo `helloworld`) |
| `-Wl,--whole-archive,-lfstack,--no-whole-archive` | Força o linker a incluir *todos* os símbolos de `libfstack.a`, não só os referenciados diretamente — necessário porque o F-Stack registra handlers via construtores estáticos |
| `-lrt -lm -ldl -lcrypto -lz -pthread -lnuma` | Dependências da lib do F-Stack/DPDK |

## 3. Execução

O binário resultante é uma aplicação DPDK: precisa de **root**, de **hugepages configuradas** e de um **arquivo `--conf`** apontando para o `.ini` gerado na instalação.

```bash
sudo /home/nerds2/server/server --conf /opt/f-stack/config/config.i350.ini
```

O `server.c` sobe um listener TCP na porta **9999** (`ff_bind`/`ff_listen`), aceita conexões via `ff_epoll`, e soma os bytes recebidos em `total_bytes` (esse valor fica só em memória — o código não imprime nada; é um exemplo mínimo pensado para receber tráfego de teste).

### Gerando tráfego de teste

Duas opções: `netcat` ou o `client.c` deste repositório.

**Opção 1 — netcat**, de outra máquina/host na mesma rede do `config.i350.ini` (por padrão `192.168.100.10/24`):

```bash
nc 192.168.100.10 9999 < /dev/urandom
```

**Opção 2 — `client.c`** (recomendado, dá controle de duração e imprime throughput). É um client TCP padrão (BSD sockets), **sem dependência de DPDK/F-Stack** — compile e rode em qualquer outro servidor Linux que tenha rota até o IP do `config.i350.ini`.

#### Setup no host cliente (nerds01, ou equivalente)

A porta i350 usada para o teste (`enp2s0f1` no nerds01, cabeada até `0000:0a:00.1` do servidor) precisa de duas coisas antes de funcionar:

1. **IP estático na mesma sub-rede** do `[port0] addr=` do `config.i350.ini` (por padrão `192.168.100.10/24`):
   ```bash
   sudo ip addr add 192.168.100.20/24 dev enp2s0f1
   sudo ip link set enp2s0f1 up
   ```
2. **Tirar a interface do controle do NetworkManager.** Se ficar "managed", o NM tenta negociar DHCP nela (não há servidor DHCP nesse link ponto-a-ponto), falha, e a cada ciclo de retry **apaga o IP estático** que você acabou de configurar — o sintoma é o IP sumir de `ip addr` sozinho depois de ~1 minuto. Resolva com:
   ```bash
   sudo nmcli device set enp2s0f1 managed no
   ```
   (repita o `ip addr add` acima depois disso, já que o passo 1 pode ter sido desfeito nesse meio tempo)

Confirme conectividade antes do client:
```bash
ping -c 3 192.168.100.10
```

#### Compilar e rodar

```bash
cd /home/nerds/client   # ou onde tiver copiado client.c + Makefile
make client

# uso: ./client <ip_servidor> <porta> [duracao_s]
./client 192.168.100.10 9999          # roda até Ctrl+C
./client 192.168.100.10 9999 30       # roda por 30 segundos e encerra
```

O client conecta, envia continuamente um buffer de 256KB e imprime o total enviado a cada segundo — útil para gerar carga sustentada contra o `server` rodando sob F-Stack.

> **Nota sobre o handler de sinal:** `client.c` usa `sigaction()` (não `signal()`) para instalar os handlers de `SIGINT`/`SIGTERM`, explicitamente **sem** `SA_RESTART`. Isso é necessário porque o `send()` bloqueante do loop principal precisa retornar com `EINTR` quando um sinal chega — com `signal()` puro (que no glibc ativa `SA_RESTART` por padrão), o `send()` reinicia sozinho e Ctrl+C/`kill` não conseguem encerrar o processo enquanto ele estiver bloqueado esperando espaço na janela TCP.

## 4. Cuidados / troubleshooting

- **Só um processo por vez pode usar a porta DPDK.** Se o `helloworld`/`helloworld_epoll` de exemplo estiver rodando, pare-o antes (`Ctrl+C` ou `kill`) — os dois competem pela mesma NIC bindada em `vfio-pci`.
- **"No probed ethernet devices"**: confirme que a porta está mesmo em `vfio-pci`:
  ```bash
  python3 /opt/f-stack/dpdk/usertools/dpdk-devbind.py --status
  ```
- **"must config dpdk.port_list first"**: verifique se `port_list=0` está presente no `.ini` usado.
- **Erros de link/`libdpdk` não encontrada**: confira se `PKG_CONFIG_PATH` foi exportado no shell atual (seção 1).
- **Revise `addr`/`netmask`/`gateway`** em `config.i350.ini` antes de rodar — o valor gerado é só um template (`192.168.100.10/24`); ajuste ao segmento de rede real de onde o tráfego de teste vai partir.
- **`client` trava e não responde a Ctrl+C**: veja a nota sobre `sigaction`/`SA_RESTART` acima. Se acontecer com um binário antigo, mate com `pkill -9 -f ./client` (SIGTERM sozinho pode não funcionar).
- **`connect: No route to host` / `Destination Host Unreachable`**: normalmente significa que a interface de origem não está na mesma sub-rede do `addr=` do servidor, ou que a porta i350 escolhida não é a fisicamente cabeada até o servidor (ver tabela de pareamento na seção 1). Confirme com `ping` antes de rodar o `client`.
- **IP estático some sozinho de uma interface i350 depois de um tempo**: é o NetworkManager tentando (e falhando) DHCP nela — marque como unmanaged (`nmcli device set <iface> managed no`) antes de configurar o IP manualmente, tanto no servidor quanto no cliente.
- **Portas i350 cabeadas diretamente (sem switch) caem juntas ao mesmo tempo**: em cabo direto, o estado do link é uma negociação elétrica entre as duas pontas apenas. Rodar `dpdk-devbind.py --unbind` numa porta do lado servidor derruba o link do lado cliente imediatamente (e vice-versa) — isso é esperado, não é defeito de hardware. Para restaurar, basta religar o driver (`--bind=igb`) e trazer a interface `up` de novo; o link volta em poucos segundos.
- **`server` sobe como `EAL: Auto-detected process type: SECONDARY`**: significa que já existe outro processo `server` (ou qualquer app DPDK) rodando com o mesmo `--file-prefix`/hugepages — o DPDK detecta o primário existente e anexa o novo processo como secundário, que **não funciona como listener completo** (nossa `server.c` não foi escrita para o modelo multi-processo). Sintomas: `ping` pode até parar de responder (o link cai do lado do cliente, já que é cabo direto e o processo primário original pode morrer/ficar instável com o secundário anexado) e conexões TCP não fecham. Resolva:
  ```bash
  sudo pkill -9 -f "server --conf"     # mata TODOS os processos server
  sudo rm -rf /var/run/dpdk/rte/*      # limpa IPC/hugepage state residual
  sudo /home/nerds2/server/server --conf /opt/f-stack/config/config.i350.ini
  ```
  Confirme no log que aparece `EAL: Auto-detected process type: PRIMARY` (não `SECONDARY`) antes de testar.
- **Client trava em `SYN-SENT` de forma intermitente (às vezes conecta, às vezes não)**: verifique `lcore_mask` em `config.i350.ini`. Se estiver configurado para mais de 1 núcleo (ex.: `0x3` = 2 núcleos), o DPDK cria uma fila RX por núcleo e distribui conexões entre elas via hash RSS — mas `server.c` só chama `ff_run()` numa única thread (fila 0), então conexões que caem na fila 1 nunca são atendidas (o SYN não recebe nem resposta nem RST). Use `lcore_mask=0x1` (1 núcleo, 1 fila) para casar com o `server.c` de thread única:
  ```bash
  sudo pkill -f "server --conf"
  sudo sed -i 's/^lcore_mask=.*/lcore_mask=0x1/' /opt/f-stack/config/config.i350.ini
  sudo rm -rf /var/run/dpdk/rte/*
  sudo /home/nerds2/server/server --conf /opt/f-stack/config/config.i350.ini
  ```
  No log, confira `lcore: 0, port: 0, queue: 0` como única linha de fila (sem uma segunda fila sendo criada e nunca consumida).

## 5. Limitações conhecidas (e corrigidas)

### Sockets não-bloqueantes (corrigido)

`server.c` não configurava os sockets como não-bloqueantes. Em F-Stack (como em BSD sockets), isso é obrigatório para uso com `epoll`: sem isso, `ff_read()` podia bloquear a única thread de polling esperando mais dados — travando também o recebimento de novos pacotes da NIC (a mesma thread que faria o polling da NIC fica presa dentro do `read()`). Corrigido adicionando `ff_ioctl(fd, FIONBIO, &on)` (precisa de `#include <sys/ioctl.h>`) tanto no socket de escuta quanto em cada conexão aceita.

### Throughput baixo / SYN-ACK sem opções TCP (corrigido — bug de build do F-Stack)

Mesmo depois da correção acima, transferências sustentadas (ex.: `client 192.168.100.10 9999 30`) ficavam lentas (dezenas/centenas de **Kbits/s** em vez da faixa esperada para Gigabit) e travavam por dezenas de segundos antes de retomar.

**Sintoma:** capturando os pacotes byte a byte, o SYN-ACK gerado pelo F-Stack **não incluía nenhuma opção TCP** (nem MSS, nem window scaling, nem SACK). Isso forçava o lado cliente a cair no MSS mínimo do RFC (536 bytes em vez de ~1460) e coincidia com uma janela de perdas que disparava backoff de retransmissão TCP (`rto` chegando a 51-103 **segundos** em `ss -tin`).

**Causa raiz encontrada** (via instrumentação com `printf` e `gdb` — breakpoints e watchpoints de hardware — dentro de `freebsd/netinet/tcp_syncache.c` e `tcp_ecn.c`, compilando a lib com `DEBUG="-O0 -g -gdwarf-2"` para obter informação de linha): o arquivo-fonte `/opt/f-stack/lib/../freebsd/netinet/tcp_ecn.c` **nunca era compilado** — faltava na lista `NETINET_SRCS` de `/opt/f-stack/lib/Makefile`. Como o linker ainda precisava resolver os símbolos `tcp_ecn_syncache_add()`, `tcp_ecn_syncache_respond()` etc., ele usava stubs "vazios" definidos em `/opt/f-stack/lib/ff_stub_14_extra.c` — só que as *assinaturas* desses stubs não batiam com as assinaturas reais declaradas em `tcp_ecn.h` (ex.: o stub declarava `void tcp_ecn_syncache_add(struct syncache *, int, uint16_t)`, mas o código chamador esperava `int tcp_ecn_syncache_add(uint16_t, int)`). Esse descasamento de ABI fazia o valor de retorno lido pelo chamador ser lixo de registrador, corrompendo `sc->sc_flags` (a flag `SCF_NOOPT` acabava setada por acidente, entre outras variações não determinísticas entre execuções).

**Correção aplicada** (nos fontes do F-Stack em `/opt/f-stack`, fora deste repositório):
1. Adicionado `tcp_ecn.c` à lista `NETINET_SRCS` em `/opt/f-stack/lib/Makefile`, para que o arquivo real seja compilado.
2. Removidos os 8 stubs de função `tcp_ecn_*` (com assinatura errada) e as 2 variáveis globais duplicadas (`tcp_do_ecn`, `tcp_ecn_maxretries`) de `/opt/f-stack/lib/ff_stub_14_extra.c`, já que `tcp_ecn.c` agora fornece as implementações reais.
3. Recompilada `libfstack.a` (`make -C /opt/f-stack/lib`).

**Verificação:** `tcpdump` confirmou o SYN-ACK passando a incluir `options [mss 1460, nop, wscale 8, sackOK, TS val ...]`; um teste `iperf3` real (seção 6) foi de **~82-100 Kbits/s para 900-933 Mbits/s** — ganho de ordem de ~10.000x.

**Automação:** como esse fix vive fora deste diretório (em `/opt/f-stack`, que é recriado do zero por `install_fstack_dpdk.sh`), tanto [setup_test_env.sh](setup_test_env.sh) quanto [setup_iperf3_fstack.sh](setup_iperf3_fstack.sh) aplicam esse patch automaticamente (função `patch_missing_tcp_ecn`) antes de compilar a lib/servidor, de forma idempotente — detectam se o patch já foi aplicado e pulam o rebuild se `tcp_ecn.o` já existir. Não é necessário reaplicar manualmente, mesmo após reinstalar o F-Stack.

## 6. Medindo throughput real com `iperf3` (via `LD_PRELOAD`)

O `iperf3` não fala a API nativa do F-Stack (`ff_socket`, `ff_epoll`, etc.), mas este fork do F-Stack traz um adaptador `LD_PRELOAD` pronto em `/opt/f-stack/adapter/syscall/` (`libff_syscall.so`) que "sequestra" as chamadas de socket do Linux e as redireciona para a API do F-Stack — permite rodar `iperf3` (ou outros binários não modificados) sem recompilar nada. Documentação completa: `/opt/f-stack/adapter/syscall/README.md`.

### Script automatizado (recomendado)

[setup_iperf3_fstack.sh](setup_iperf3_fstack.sh) automatiza tudo desta seção — compila o adaptador com as flags certas, aplica os dois patches de compatibilidade (idempotente, não duplica se já aplicado), sobe a instância `fstack` + `iperf3 -s`, e do lado cliente configura a interface e já roda o teste:

```bash
# no servidor (com F-Stack/DPDK ja instalado)
sudo /home/nerds2/server/setup_iperf3_fstack.sh server

# no host cliente (ex.: nerds01) — copie o script para la antes
sudo ./setup_iperf3_fstack.sh client
```

O modo `client` já roda `iperf3 -c` no final e imprime o resultado. Variáveis de ambiente (`SERVER_NIC_PCI`, `CLIENT_IFACE`, `CLIENT_IP`, `SERVER_IP`, `IPERF3_PORT` etc.) permitem customizar sem editar o script — ver comentários no cabeçalho. As subseções abaixo detalham o que o script faz, para quem quiser entender ou adaptar manualmente.

#### Parâmetros extras do `iperf3` (variáveis de ambiente, todos opcionais)

| Variável | Flag do iperf3 | Efeito |
|---|---|---|
| `IPERF3_DURATION` | `-t` | Duração do teste em segundos (default `10`) |
| `IPERF3_LENGTH` | `-l` | Tamanho do bloco/buffer de leitura-escrita (ex.: `1448`, `64K`) |
| `IPERF3_WINDOW` | `-w` | Tamanho da janela/buffer de socket (ex.: `128K`) |
| `IPERF3_CONGESTION` | `-C` | Algoritmo de controle de congestionamento (ex.: `cubic`, `reno`) — **ver nota abaixo** |
| `IPERF3_PARALLEL` | `-P` | Número de streams paralelos |
| `IPERF3_MSS` | `-M` | MSS forçado do lado cliente |
| `IPERF3_BITRATE` | `-b` | Limite de taxa alvo (ex.: `100M`); vazio = sem limite |
| `IPERF3_REVERSE=true` | `-R` | Modo reverso (servidor envia, cliente recebe) |
| `IPERF3_JSON=true` | `-J` | Saída em JSON |
| `IPERF3_LOGFILE` | `--logfile` | Grava a saída (JSON ou texto) neste arquivo em vez do terminal |
| `IPERF3_EXTRA_ARGS` | — | Passthrough livre para qualquer outra flag (ex.: `"-O 2 -N"`) |

Exemplo — 30s, blocos de 64K, 4 streams paralelos, saída JSON em arquivo:

```bash
sudo IPERF3_DURATION=30 IPERF3_LENGTH=64K IPERF3_PARALLEL=4 IPERF3_JSON=true \
    IPERF3_LOGFILE=/tmp/resultado.json ./setup_iperf3_fstack.sh client
```

> **Nota sobre `IPERF3_CONGESTION`/`-C`:** o patch de compatibilidade aplicado por este script (ver "Bugs encontrados" abaixo) faz o adaptador do F-Stack **ignorar silenciosamente** qualquer tentativa de setar `TCP_CONGESTION` no lado servidor. Ou seja, `-C` só tem efeito real no lado cliente (kernel Linux padrão) — o F-Stack sempre usa seu próprio congestion control padrão (FreeBSD), independente do valor pedido. Isso não é uma limitação do script; é do próprio adaptador `LD_PRELOAD`.
>
> Antes da correção do bug de ECN (ver seção 5), o próprio JSON de saída do `iperf3` expunha o sintoma: o campo `"tcp_mss_default": 536` confirmava, em formato máquina, a queda de MSS causada pelo SYN-ACK do F-Stack sem opções TCP. Com o patch aplicado, esse campo passa a refletir o MSS real (~1448-1460).

### Compilação do adaptador (manual)

Duas flags de compilação são **obrigatórias** para uso com `iperf3` (ver "Bugs encontrados" abaixo para o motivo):

```bash
export FF_PATH=/opt/f-stack
export PKG_CONFIG_PATH=/usr/local/lib/x86_64-linux-gnu/pkgconfig:${PKG_CONFIG_PATH:-}
cd /opt/f-stack/adapter/syscall
export FF_PRELOAD_SUPPORT_SELECT=1
export FF_KERNEL_MAX_FD_SELECT=128
make clean && make all
```

Gera `fstack` (o processo backend DPDK, equivalente ao nosso `server`) e `libff_syscall.so` (a lib `LD_PRELOAD`).

### Rodando o servidor iperf3

```bash
# 1) Pare o server.c/helloworld que estiver usando a porta DPDK, e limpe estado residual
sudo pkill -9 -f "server --conf"; sudo pkill -9 -f "adapter/syscall/fstack"
sudo rm -rf /var/run/dpdk/rte/*

# 2) Suba o processo backend fstack (usa o mesmo config.i350.ini)
sudo /opt/f-stack/adapter/syscall/fstack --conf /opt/f-stack/config/config.i350.ini --proc-type=primary --proc-id=0 &

# 3) Rode o iperf3 -s com LD_PRELOAD
sudo env LD_PRELOAD=/opt/f-stack/adapter/syscall/libff_syscall.so FF_NB_FSTACK_INSTANCE=1 iperf3 -s -4 -p 9999
```

### Rodando o cliente (máquina Linux comum, ex.: nerds01)

Nenhuma configuração especial — `iperf3` cliente padrão, sem `LD_PRELOAD`:

```bash
iperf3 -c 192.168.100.10 -p 9999 -t 10
```

### Bugs encontrados e corrigidos no adaptador (`ff_hook_syscall.c`)

Ao tentar rodar `iperf3` sem ajustes, dois bugs reais do adaptador impediam qualquer conexão:

1. **Crash `*** buffer overflow detected ***` logo ao subir o servidor.** Causa: o F-Stack numera seus fds a partir de 128/1024+ para diferenciá-los de fds reais do kernel; `iperf_server_listen()` (dentro de `libiperf.so`) usa `select()`/`FD_SET` internamente, e `fd_set` tem tamanho fixo (`FD_SETSIZE`) — um fd ≥ 1024 estoura esse limite e o `_FORTIFY_SOURCE` do glibc aborta o processo. **Corrigido** compilando com `FF_PRELOAD_SUPPORT_SELECT=1` e `FF_KERNEL_MAX_FD_SELECT=128` (flag documentada no próprio `Makefile` do adaptador, porém comentada/desligada por padrão).
2. **`iperf3: error - unable to set TCP_CONGESTION: Supplied congestion control algorithm not supported on this host`.** Causa: `TCP_CONGESTION` (optname 13 no Linux) não tem tradução numérica para o equivalente do FreeBSD dentro do adaptador (diferente do `ioctl`, que tem `linux2freebsd_ioctl()` fazendo essa tradução) — `iperf3` sempre consulta/tenta essa opção, mesmo sem `-C`. **Corrigido** com um patch pontual em `ff_hook_setsockopt`/`ff_hook_getsockopt` (`adapter/syscall/ff_hook_syscall.c`) que intercepta especificamente `level=IPPROTO_TCP, optname=13` e responde com sucesso (devolvendo `"newreno"` no caso do `getsockopt`) sem repassar ao F-Stack — não precisamos controlar o algoritmo de congestionamento para medir throughput.

Esses patches **não estão em nenhum arquivo deste diretório** — vivem em `/opt/f-stack/adapter/syscall/ff_hook_syscall.c`, fora do repositório. Se o F-Stack for reinstalado do zero (`install_fstack_dpdk.sh`), [setup_iperf3_fstack.sh](setup_iperf3_fstack.sh) recompila o adaptador com as duas flags acima e reaplica os dois patches de `setsockopt`/`getsockopt` **automaticamente** (função `patch_adapter_tcp_congestion`, idempotente — procure por `optname == 13` no arquivo se quiser conferir manualmente se já foram aplicados). Não é necessário reaplicar à mão.

### Resultado obtido

Com os dois bugs do adaptador corrigidos **e** com o patch de ECN da seção 5 aplicado (ambos automáticos via [setup_iperf3_fstack.sh](setup_iperf3_fstack.sh)), um teste real de 8-10s completa (`iperf Done.`, sem crash) e confirma **de forma independente** (ferramenta padrão da indústria, não nosso `client.c`/`server.c`) throughput na faixa esperada para Gigabit: **900-933 Mbits/sec** sustentados, contra os ~80-100 Kbits/sec observados antes da correção — um ganho de ordem de ~10.000x.

**Conclusão:** o teto de throughput não era uma característica inerente deste build/branch do F-Stack nem do driver DPDK/i350, e sim um bug de build real (`tcp_ecn.c` fora da lista de fontes compilados, ver seção 5), já corrigido e automatizado nos scripts deste diretório.
