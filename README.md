# F-Stack + DPDK line-rate fix & throughput testkit (Intel i350)

Este diretório reúne, para publicação em um repositório GitHub, o resultado de
uma investigação de ponta a ponta sobre um bug real do
[F-Stack](https://github.com/F-Stack/f-stack) que limitava o throughput TCP a
~80-100 Kbits/s (em vez da faixa de Gigabit esperada) rodando sobre DPDK numa
NIC Intel i350 — mais os scripts de instalação/configuração e o código de
exemplo usados para reproduzir, diagnosticar e validar a correção.

**Resultado da correção:** ~80-100 Kbits/s → **900-933 Mbits/s** sustentados
(ganho de ordem de ~10.000x), confirmado com `iperf3` real via adaptador
`LD_PRELOAD` do próprio F-Stack. Detalhes completos da causa raiz em
[`docs/Tutorial.md`](docs/Tutorial.md#5-limitações-conhecidas-e-corrigidas).

## O bug, resumido

`freebsd/netinet/tcp_ecn.c` nunca estava listado em `NETINET_SRCS` do
`lib/Makefile` do F-Stack — ou seja, **nunca era compilado**. O linker
resolvia `tcp_ecn_syncache_add()`/`tcp_ecn_syncache_respond()` (chamadas de
dentro de `tcp_syncache.c` ao montar o SYN-ACK) contra stubs vazios em
`lib/ff_stub_14_extra.c`, mas as **assinaturas desses stubs não batiam** com
as reais declaradas em `tcp_ecn.h`. Esse descasamento de ABI fazia o valor de
retorno lido pelo chamador ser lixo de registrador, corrompendo
`sc->sc_flags` — na prática, o SYN-ACK saía **sem nenhuma opção TCP** (sem
MSS, window scaling, SACK), derrubando o MSS efetivo para 536 bytes (mínimo
do RFC) e empurrando o RTO de retransmissão para dezenas de segundos.

A correção (dois arquivos, ver [`patches/`](patches/) e
[`f-stack-fork/`](f-stack-fork/)) foi: (1) adicionar `tcp_ecn.c` a
`NETINET_SRCS`, (2) remover os stubs conflitantes de `ff_stub_14_extra.c`.
Um terceiro patch, no adaptador `LD_PRELOAD` (`adapter/syscall/`), corrige
dois bugs de compatibilidade que impediam o `iperf3` real de rodar sobre
F-Stack (usado para validar a correção acima de forma independente do
código de exemplo deste projeto). Escrita e investigação completas —
incluindo a jornada de debugging com `gdb`/watchpoints de hardware que levou
à causa raiz — estão documentadas em [`docs/Tutorial.md`](docs/Tutorial.md).

## Estrutura deste diretório

```
proj_fstack_dpdk/
├── f-stack-fork/     — fork completo do F-Stack (clone git com histórico),
│                       branch fix/tcp-ecn-linerate-throughput contendo os
│                       dois commits de correção prontos para uso
├── patches/          — os mesmos dois commits como .patch autônomos
│                       (git am / git apply), para quem preferir aplicar
│                       sobre um checkout próprio do F-Stack em vez de usar
│                       o fork inteiro
├── scripts/
│   ├── install_fstack_dpdk.sh   — instala DPDK+F-Stack do zero num servidor
│   │                               Ubuntu com i350 (por padrão, clona o
│   │                               fork já corrigido — ver FSTACK_REPO_URL)
│   ├── setup_test_env.sh        — configura o ambiente de teste client/server
│   │                               simples (server.c/client.c deste repo)
│   └── setup_iperf3_fstack.sh   — configura e roda teste de vazão real com
│                                   iperf3 via adaptador LD_PRELOAD
├── examples/
│   ├── server.c, client.c, Makefile  — client/server TCP mínimos de teste
└── docs/
    └── Tutorial.md    — tutorial completo: pré-requisitos, compilação,
                          execução, troubleshooting, a causa raiz do bug e
                          sua correção, e o guia de medição com iperf3
```

`f-stack-fork/` é um clone git de verdade (não uma cópia estática) — tem o
histórico completo do F-Stack oficial (`origin` aponta para
`https://github.com/F-Stack/f-stack.git`) mais dois commits próprios na
branch `fix/tcp-ecn-linerate-throughput`. Isso é o que deve virar o seu
fork real no GitHub (via `git push` para um remote novo — ver "Publicando no
GitHub" abaixo).

## Ambiente onde isso foi validado

- Servidor Ubuntu, kernel 6.x, NIC Intel i350 quad-port (PCI ID `8086:1521`)
- DPDK 24.11.6 (embutido no F-Stack, compilado via `meson`/`ninja`)
- F-Stack branch `dev` (commit `91ffc63d` no momento da correção)
- Porta i350 bindada em `vfio-pci`, cabeamento direto (sem switch) até um
  host cliente Linux comum
- Correção testada de forma independente com `iperf3` real via adaptador
  `LD_PRELOAD` do F-Stack (não depende do `server.c`/`client.c` deste repo)

## Quick start

```bash
# 1) Editar scripts/install_fstack_dpdk.sh e trocar FSTACK_REPO_URL pelo
#    seu fork no GitHub (depois de publicá-lo — ver seção abaixo), ou manter
#    o padrão local (INSTALL_ROOT=/opt) e apontar para f-stack-fork/ local:
sudo FSTACK_REPO_URL="$(pwd)/f-stack-fork" FSTACK_BRANCH=fix/tcp-ecn-linerate-throughput \
    ./scripts/install_fstack_dpdk.sh install

# 2) Bind da porta i350 e configuração básica de teste
sudo ./scripts/install_fstack_dpdk.sh bind <iface>
sudo ./scripts/setup_test_env.sh server

# 3) (opcional) medir vazão real com iperf3
sudo ./scripts/setup_iperf3_fstack.sh server
```

Consulte [`docs/Tutorial.md`](docs/Tutorial.md) para o passo a passo
completo, incluindo o lado cliente e troubleshooting.

> **Nota:** mesmo usando o F-Stack oficial (não o fork) como base, todos os
> três scripts em `scripts/` reaplicam os patches automaticamente e de forma
> idempotente (funções `patch_missing_tcp_ecn`/`patch_adapter_tcp_congestion`)
> antes de compilar — então a correção não se perde mesmo que
> `FSTACK_REPO_URL` aponte para o repositório oficial.

## Publicado no GitHub

Este repositório está publicado em
https://github.com/piccoli87/proj_f-stack_dpdk e inclui `f-stack-fork/` como
subdiretório comum (não como submódulo nem repositório separado) — o
histórico de commits original do fork não foi preservado, apenas o snapshot
dos arquivos.

## Créditos

Correção e investigação realizadas em cima do F-Stack oficial
(https://github.com/F-Stack/f-stack, BSD 2-Clause,
Copyright (C) 2017-2022 THL A29 Limited, a Tencent company). Ver
[`LICENSE`](LICENSE).
