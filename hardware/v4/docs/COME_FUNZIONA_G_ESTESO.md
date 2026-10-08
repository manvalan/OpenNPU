# G-esteso — come gira MobileFaceNet sull'acceleratore v4

Branch `v4-conv-parallel-research`. Questo documento spiega, dall'inizio
alla fine, come la rete MobileFaceNet viene eseguita dall'hardware v4
("G-esteso"). Ogni numero è **misurato** (simulazione RTL o sintesi
Vivado) salvo dove è scritto esplicitamente *stima* o *proiezione*.
Il registro dettagliato dei passi, con test e mutazioni, è in
[`PROGRESS_LOG.md`](PROGRESS_LOG.md).

---

## 1. L'obiettivo

| | |
|---|---|
| Riferimento software | ESP32-S3, ESP-DL, modello MFN_S8_V1: **248,8 ms** per inferenza |
| Obiettivo | **100x → 2,49 ms** |
| Lavoro della rete | **221,0 M MAC** (211,0 M di convoluzioni 1x1, 10,0 M depthwise 3x3) |

Il conto che decide tutto è semplice:

```
tempo = cicli di clock misurati / frequenza di clock (Fmax)
```

I cicli li conosciamo già (simulazione RTL di tutta la rete, §6). La
Fmax arriva dal place & route (§7).

---

## 2. MobileFaceNet in una pagina

Ingresso 112x112x3, uscita un vettore di 128 valori (l'"impronta" del
volto). Quasi tutta la rete è fatta di **bottleneck**:

```
x ──► 1x1 "expand" (C → t·C, PReLU) ──► depthwise 3x3 (stride 1 o 2, PReLU) ──► 1x1 "project" (t·C → C', lineare) ──► (+ x se stride 1 e C = C')
```

| stadio | uscita | note |
|---|---|---|
| conv 3x3 s2, 3→64 | 56x56x64 | PReLU |
| depthwise 3x3, 64 | 56x56x64 | PReLU |
| 5 bottleneck (t=2, 64), il primo s2 | 28x28x64 | residui sui 4 a stride 1 |
| 1 bottleneck (t=4, 128) s2 | 14x14x128 | |
| 6 bottleneck (t=2, 128) | 14x14x128 | residui |
| 1 bottleneck (t=4, 128) s2 | 7x7x128 | |
| 2 bottleneck (t=2, 128) | 7x7x128 | residui |
| conv 1x1, 128→512 | 7x7x512 | PReLU |
| GDConv 7x7 (depthwise globale) | 1x1x512 | lineare |
| lineare 512→128 | 324 | |

Il 95 % dei MAC è nelle convoluzioni 1x1 (pointwise): è lì che va
l'hardware "grosso". Le depthwise 3x3 sono il 4,5 % e costano poco.

---

## 3. L'idea G-esteso

Tre idee del brainstorming che si sono rivelate una sola architettura:

1. **La memoria è una finestra che si sposta.** Invece di leggere
   ogni volta una patch 3x3 dalla memoria, l'hardware tiene solo **2
   righe** della mappa in un *line buffer* (BRAM) e fa scorrere una
   finestra 3x3 di registri: ogni pixel entra una volta sola e viene
   riusato 9 volte.
2. **La depthwise si calcola dentro il "mover"**, mentre la finestra
   scorre: 16 canali alla volta, con moltiplicatori in LUT (0 DSP).
3. **Depthwise e pointwise sono fuse**: il risultato depthwise di un
   pixel non va mai in memoria. Passa direttamente, già riquantizzato
   INT8, all'array 1x1.

---

## 4. I blocchi hardware

```
                 ┌──────────────── v4_core ────────────────────────────────────────────┐
 descrittori ──► │ sequencer ──► fmap_feeder ──► dwpw_engine ───────────► tile_writer  │
 (1 per passata) │     │          (padding,       │                        (+ residuo)  │
                 │     │           righe)         │                            │        │
                 │     ▼                          ▼                            ▼        │
                 │  pesi 1x1 (BRAM)       ┌─────────────────┐          fmap_mem         │
                 │  parametri dw/requant  │ line buffer BRAM│          3 banchi x 128 KB│
                 │  (RAM distribuita)     │ finestra 3x3    │                           │
                 │                        │ 16 MAC dw (LUT) │                           │
                 │                        │ requant INT8    │                           │
                 │                        │ buffer coppie   │                           │
                 │                        │ array 16x16     │ 224 DSP + 32 celle LUT    │
                 │                        │ requant INT8    │                           │
                 │                        └─────────────────┘                           │
                 └──────────────────────────────────────────────────────────────────────┘
```

| blocco | file | cosa fa |
|---|---|---|
| sequencer | `rtl/v4_core.v` | legge una lista di descrittori (1 per passata) e le esegue una dopo l'altra |
| feeder | `rtl/fmap_feeder.v` | legge la mappa di ingresso, parola per parola, e inserisce al volo il bordo di zeri |
| line buffer + depthwise | `rtl/dw_linebuf_grouped.v` | finestra mobile 3x3 su tutti i canali, 16 alla volta |
| requant | `rtl/requant_act.v` | bias, shift a potenza di 2 (come ESP-DL), saturazione INT8, ReLU/PReLU |
| array pointwise | `rtl/pw_array_packed.v` | 16x16, **2 MAC INT8 per DSP48** (stesso trucco della v3) |
| motore fuso | `rtl/dwpw_engine.v` | collega tutto: depthwise → buffer coppie → array → requant |
| writer | `rtl/tile_writer.v` | scrive le uscite e somma il residuo con saturazione |
| memoria mappe | `rtl/fmap_mem.v` | 3 banchi da 8192 parole x 128 bit |

### 4.1 Formato dei dati

Una **parola** di memoria = 128 bit = **16 canali INT8 di un pixel**.
Una mappa HxWxC è salvata riga per riga, pixel per pixel, a gruppi di
16 canali:

```
parola(riga, colonna, gruppo) = base + (riga·W + colonna)·(C/16) + gruppo
```

Lo stesso formato vale per ingresso e uscita di ogni layer: l'uscita di
una passata è direttamente l'ingresso della successiva, senza
riordinare nulla.

### 4.2 Il line buffer (la "finestra che si sposta")

Il feeder spedisce i pixel in ordine (riga, colonna, gruppo). Per ogni
colonna e gruppo, una sola BRAM tiene le **2 righe precedenti**; a ogni
pixel la BRAM viene letta una volta e riscritta una volta (1R+1W, ciò
che una BRAM offre). Le due colonne precedenti della finestra vengono
da una piccola RAM indicizzata dal gruppo. Risultato: un pixel da 16
canali per ciclo in ingresso, **4 RAMB36** invece dei 24.576 flip-flop
della prima versione.

### 4.3 L'array pointwise e il "2 MAC per DSP"

L'array fa, in un ciclo, 16 canali d'ingresso x 16 canali d'uscita per
**due pixel** (A e B) che condividono gli stessi pesi:

```
DSP:  (xB·2^16 + xA) × w  =  xB·w·2^16 + xA·w   → si separano i due prodotti
```

16x14 colonne usano i DSP48 (224), le ultime 2 colonne moltiplicatori
in LUT (il chip ha 240 DSP). Totale **512 MAC per ciclo**. Per ogni
coppia di pixel l'array fa `(Cout/16)·(Cin/16)` cicli, uno dopo l'altro
senza svuotare la pipeline.

---

## 5. Come viene eseguita la rete: le 40 passate

Una **passata** è un giro del motore su una mappa: o *depthwise+1x1
fusi*, o *solo 1x1*, o *GDConv*. MobileFaceNet diventa 40 passate:

| passate | cosa | modalità |
|---|---|---|
| 0 | conv1 3x3 s2 come 1x1 su ingresso im2col (27→32 valori per pixel) | solo 1x1 |
| 1-8 | primo blocco, **a bande** (sotto) | dw+1x1 |
| 9-16 | bottleneck 2-5 (28x28): expand, poi dw+project+residuo | alternate |
| 17-18 | bottleneck 6 (t=4, s2) | |
| 19-30 | bottleneck 7-12 (14x14) | |
| 31-32 | bottleneck 13 (t=4, s2) | |
| 33-36 | bottleneck 14-15 (7x7) | |
| 37 | conv 1x1 128→512 | solo 1x1 |
| 38 | GDConv 7x7 (unità dedicata `rtl/gdconv_unit.v`, 16 MAC in LUT) | GDConv |
| 39 | lineare 512→128 (1x1 su una mappa 1x1) | solo 1x1 |

La depthwise iniziale (dw1) è fusa con l'expand del primo bottleneck.
Ogni altra depthwise è fusa con il suo project.

### 5.1 Le bande del primo blocco

Dopo dw1+expand il tensore sarebbe 56x56x128 = **401 KB**, più dei
384 KB di memoria per le mappe. Allora il primo blocco lavora a **4
bande orizzontali**: 14-15 righe espanse (≤ 105 KB) alla volta, poi
subito la depthwise s2 + project su quella banda (7 righe di uscita).
Le bande si sovrappongono di una riga, che viene ricalcolata (+5 %
su quel blocco). Il tensore da 401 KB non esiste mai per intero.

### 5.2 Dove stanno i tensori (3 banchi)

- banco 0: sempre il tensore espanso (E) del bottleneck corrente;
- banchi 1 e 2: ingresso X e uscita Y, che si scambiano a ogni blocco
  (*ping-pong*). Il residuo legge X da un banco mentre il feeder legge
  E dall'altro e il writer scrive Y: nessun conflitto (verificato da
  un flag hardware).

---

## 6. Verifica: tutta la rete in RTL, identica bit per bit

`model/gen_mfn.c` costruisce MobileFaceNet con pesi INT8
pseudo-casuali e la calcola in C con **la stessa aritmetica
dell'hardware**. `sim/tb_v4_core_mfn.v` carica tutto tramite la porta
host del core, esegue le 40 passate in un'unica simulazione e, alla
fine di ogni passata, confronta l'intero tensore di uscita con il C.

**Risultato: dall'immagine all'impronta finale di 128 valori, 37 tensori controllati, 132.704 parole, 0 errori.**
(I tempi non dipendono dai valori dei pesi: nessuna scorciatoia
"salta gli zeri".)

Cicli misurati per passata (`docs/mfn_rtl_run.log`):

| passate | cicli | |
|---|---:|---|
| conv1 | 12.585 | |
| primo blocco (4 bande) | 83.144 | le depthwise s2 sono limitate dall'ingresso |
| bottleneck 2-5 | 102.792 | |
| bottleneck 6 | 43.294 | |
| bottleneck 7-12 | 154.620 | |
| bottleneck 13 | 34.865 | |
| bottleneck 14-15 | 13.712 | |
| conv 1x1 512 | 6.452 | |
| GDConv 7x7 | 1.631 | |
| lineare 512→128 | 324 | |
| **totale** | **453.579** | include 160 cicli del sequencer tra le passate (4 per passata) |

Utilizzo medio dell'array: 211 M MAC / (453.579 x 512) = **91 %**.

---

## 7. Da cicli a millisecondi: **200 MHz reali, 2,32 ms, 107x**

Place & route reale del core completo, **con lo streaming dei pesi dalla
DDR3 e l'im2col del conv1** (tutte le memorie, i 224 DSP, sequencer;
senza MIG/SPI), Vivado 2026.1, XC7A100T-2: **tutti i vincoli rispettati a
5,000 ns (200 MHz)** — WNS +0,004 ns, 0 percorsi falliti su 132.022
(`docs/pnr/v4_core_top_pr6_*`).

| | |
|---|---|
| cicli misurati (RTL, rete intera, immagine grezza → embedding, bit-exact) | 464.018 |
| di cui attesa pesi dalla DDR3 (modello 2,0 GB/s) | 10.231 |
| clock (P&R reale) | 200 MHz |
| **tempo di calcolo** | **2,320 ms** |
| ESP32-S3 (ESP-DL) | 248,8 ms |
| **rapporto** | **107,2x** |

Con metà della banda DDR3 (1,0 GB/s) si resta a circa 102x. Il percorso
fino a 200 MHz: 150 → 157 → 162 → 200 MHz (core con pesi on-chip), poi
185 → 200 MHz dopo aver aggiunto streaming e im2col.

Risorse dopo il routing: 45.753 LUT (72 %), 60.934 FF (48 %),
**132,5/135 BRAM (98 %)**, 224/240 DSP (93 %).

### 7.1 La scheda intera: 199,34 MHz, 2,311 ms, 107,7x

Dopo il core da solo è stata chiusa la **scheda completa** (MIG DDR3,
bridge SPI v3, porta Quad-SPI, boot, core) nello stesso place & route:
**199,34 MHz, WNS +0,003 ns** (tag `v4-board-199`; versione di riserva a
189,20 MHz, WNS +0,033 ns, tag `v4-board-189`). Con il controller DDR3
vero e i modelli Micron la rete intera prende **460.617 cicli = 2,311 ms
= 107,7x**; dall'ESP32 start→done misura 2,337 ms. L'immagine arriva
via Quad-SPI a 80 MHz in 0,94 ms. Dettagli, interfacce e comandi:
[`DOCUMENTAZIONE_V4.md`](DOCUMENTAZIONE_V4.md).

## 8. Cosa manca (onestamente)

1. ~~**Il numero sopra è il calcolo del core**~~ **fatto**: scheda
   intera nello stesso P&R e trasferimenti misurati (§7.1).
2. ~~**Pesi dalla DDR3**~~ **fatto** (`rtl/param_loader.v`, doppio
   buffer per passata; la banda DDR3 è ancora un modello). Testo
   originale: **Pesi dalla DDR3**: in simulazione tutti i pesi 1x1 (854 KB) stanno
   nella memoria del core; sul chip c'è posto per un anello da 128 KB.
   Serve un blocco che li precarichi dalla DDR3 durante il layer
   precedente: circa 0,34 ms di traffico a 2,48 GB/s, da nascondere
   dietro il calcolo. Non ancora costruito.
3. ~~**im2col del conv1**~~ **fatto** (`rtl/im2col_feeder.v`). Testo
   originale: **im2col del conv1**: in simulazione l'ingresso è già in forma
   im2col; sull'FPGA serve un piccolo feeder dedicato.
4. **Sparsità**: MobileFaceNet usa PReLU e project lineari, quindi quasi
   nessuno zero da saltare. Il margine verso 100x viene da Fmax e
   utilizzo.
5. **Ottimizzazioni note**: le tre depthwise a stride 2 sono limitate
   dall'ingresso (circa 25.000 cicli persi, 5,5 %). Portare l'ingresso a
   32 canali per ciclo in quelle passate li recupererebbe.
