# DiagPC

Diagnóstico e teste de estresse de hardware para Windows 10/11, num programa só.
Você deixa rodando por 10 a 30 minutos e no final ele gera um relatório com os problemas encontrados:
superaquecimento, erro de memória, SSD/HD com defeito, placa de vídeo travando, desligamentos
inesperados, telas azuis e mais.

Feito por **Danilo Américo**.

## Como rodar

Abra o PowerShell e cole:

```powershell
irm https://raw.githubusercontent.com/theamerico-hub/Diagpc/main/iniciar.ps1 | iex
```

O comando baixa o DiagPC para `C:\DiagPC`, mostra a versão carregada e abre a interface gráfica como
administrador. Os relatórios ficam em `C:\DiagPC\Relatorios`.

A interface mostra as leituras de CPU, GPU e memória ao vivo, a etapa atual com o tempo restante e o log dos
resultados, com botões para pular etapa, parar e abrir o relatório. Para usar no console (texto), rode
`DiagPC.ps1 -Console`.

Para usar no pendrive, baixe o repositório (Code > Download ZIP) e clique duas vezes em `Iniciar-DiagPC.bat`.

## Modos

| Modo | Tempo | Uso |
|---|---|---|
| Rápido | ~10 min | triagem |
| Completo | ~30 min | "desliga sozinho", "trava" |
| Personalizado | você escolhe | testes longos ou só alguns testes |
| Só diagnóstico | ~2 min | logs, SMART e inventário, sem estresse |

Na interface: botões **Pular etapa** e **Parar** (gera relatório parcial). No console: tecla **P** pula a etapa e **Ctrl+C** interrompe.

## O que é testado

- **Temperaturas** de CPU, GPU e disco em repouso e sob carga, e queda de clock (throttling)
- **Processador:** estresse em todos os núcleos com conferência dos cálculos (detecta instabilidade)
- **Memória RAM:** padrões de bits em ~75% da memória livre
- **SSD/HD:** gravação e leitura sem cache, com conferência dos dados e da velocidade
- **Placa de vídeo:** estresse WebGL em tela cheia; detecta travamento do driver
- **CPU + GPU juntos:** testa a fonte
- **Saúde dos discos em %** (estilo HD Sentinel), com o motivo da redução
- **Logs do Windows:** desligamentos inesperados, tela azul (com o código e a provável causa),
  erros de hardware WHEA, erros de disco, driver de vídeo reiniciando, programas travando
- Bateria, drivers com erro, pouca RAM, disco cheio, Windows em HD mecânico

**Se o PC desligar no meio do teste**, ligue e rode o DiagPC de novo: ele mostra em qual etapa e com
qual temperatura o PC desligou (ajuda a separar superaquecimento de problema de fonte).

## Saúde do disco (%)

| Disco | Como é calculado |
|---|---|
| SSD NVMe | 100% − desgaste informado pelo SSD, limitado pela área reserva; erros de mídia descontam |
| SSD SATA | estatística padrão de desgaste ou atributo de vida útil do fabricante (231, 202, 169, 233, 177…) |
| HD | parte de 100% e desconta setores realocados (5), pendentes (197), incorrigíveis (198) e erros reportados (187) |

90–100% Excelente · 80–89% Boa · 50–79% Atenção · abaixo de 50% Ruim.
Erros de CRC (cabo SATA) são avisados à parte e não reduzem a saúde.
É uma estimativa própria, não o algoritmo do HD Sentinel, então os números podem diferir um pouco.

## Componentes de terceiros

- [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor) v0.9.4 (MPL-2.0),
  baixado do GitHub oficial na primeira execução, para ler as temperaturas.
- [smartmontools](https://www.smartmontools.org/) 7.4 – `ferramentas/smartctl.exe` (GPL-2.0, licença em
  `ferramentas/smartmontools-COPYING.txt`; código-fonte em https://github.com/smartmontools/smartmontools).

## Limitações

- O teste de RAM cobre a memória livre do Windows, não 100% dos endereços. Para confirmar um pente com
  defeito, use o MemTest86.
- O estresse de CPU esquenta menos que o Prime95 com AVX.
- O Windows Defender às vezes bloqueia o driver do LibreHardwareMonitor. Nesse caso a temperatura da CPU
  pode não aparecer; o resto funciona.
