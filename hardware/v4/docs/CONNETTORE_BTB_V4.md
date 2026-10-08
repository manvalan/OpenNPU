# Connettore modulo ↔ scheda base: BTB 0,8 mm 2×20 (40 pin)

Sostituisce il pettine PCIe x1 e la prima proposta a 30 pin (2026-10-06).
Il modulo è prodotto da PCBWay: per ogni parte MPN del produttore e codice LCSC come fonte.
La piedinatura dell'FPGA viene da `hardware/v4/constr/v4_board_top.xdc`
e dal datasheet §6. La mappa qui sotto vale per qualsiasi connettore BTB
da 40 pin a passo 0,8 mm con la numerazione "dispari su una fila, pari
sull'altra" (confermata per la coppia hanxia, sotto).

## Parti (verificate sui disegni dei produttori, LCSC, 2026-10-06)

**Coppia scelta (Michele, 2026-10-06): hanxia HX-BTB, accoppiamento a 4,0 mm.**

| Lato | MPN | LCSC | Ruolo | Altezza | Giacenza LCSC |
|---|---|---|---|---|---|
| modulo FPGA (bottom) | HX-BTB **M0810-2x20P** | C47018699 | maschio | 1,0 mm | 929 |
| scheda base | HX-BTB **F0830-2x20P** | C47018694 | femmina | 3,0 mm | 980 |

- Dal disegno hanxia (rev. 1.0, 2021-07-08): femmina 3,0 mm + maschio
  1,0 mm = **altezza accoppiata 4,0 mm**, inserzione 1,9 mm (riga
  evidenziata in entrambi i disegni). Passo 0,8 mm, 40 contatti,
  contatti C5191 dorati.
- Footprint (uguale per i due): pad 0,30 × 2,00 mm a passo 0,80, file a
  6,00 mm tra i centri, 2 fori di centraggio Ø 0,65 mm; per 40 contatti
  A = 17,90 mm, C = 17,00 mm.
- Corrente: 0,5 A per contatto (scheda LCSC; il disegno non la riporta).
- Il disegno meccanico non numera i pin; numerazione dispari su una fila (1, 3, … 39) e pari sull'altra (2, 4, … 40), pin 1 accanto al pin 2: confermata da Michele sul simbolo dello schema LCSC di C47018699 (2026-10-06).
- Lo stesso disegno, con la stessa tabella delle altezze, è quello della
  serie Hong Cheng HC-BTB 0,8 mm.

**Scartata: STWXE BA42-40AT-1-LHB (C508687) + BA42-40BT-1-LHB (C7498460).**
Sono **entrambe femmine** (serie BA42 = "Receptacle", disegno
"0.80 Pitch BTB Receptacle SMT"): A e B sono due altezze del receptacle
(A = 3,75 mm, B = 7,75 mm), con footprint diversi (6,40 e 7,20 mm tra le
file); 3,75 mm è l'altezza del pezzo A, non quella accoppiata.
Di C7498460 c'erano 8 pezzi.

**Scartata: Hong Cheng HC-BTB-0.8-2x15P-GH40-W (C54556723, 30 pin).**
Il compagno a catalogo è HC-BTB-0.8-2x15P-MH45-W (C54556739), accoppiato
a 8,5 mm; a 30 pin i contatti di 5 V e GND non bastano (sotto).

## Corrente sui 5 V e numero di contatti

Dal capitolo consumi del datasheet (§7.1): carico del modulo 5,8 W
medio, 6,4 W di picco (FPGA da `report_power`, DDR3 da IDD Micron), con
regolatori all'85 % (*stima*) **1,35 A medi, 1,5 A di picco a 5 V**: si
progetta per 2 A. Con 0,5 A per contatto: **6 contatti di +5 V (3 A)** e
15 di GND (ritorno della corrente e schermatura del Quad-SPI).

## Piedinatura (40 pin)

Numerazione: numerazione dispari su una fila (1, 3, … 39) e pari sull'altra (2, 4, … 40), pin 1 accanto al pin 2: confermata da Michele sul simbolo dello schema LCSC di C47018699 (2026-10-06).

**Nota di layout.** Il maschio M0810 sta sul **bottom** del modulo: in CAD
il footprint va messo sul lato bottom (specchiato dal CAD) **senza
rinumerare i pin**. Prima di produrre, verificare con una sovrapposizione
delle due schede (modulo visto dal basso sopra la base) che il pin 1 del
modulo cada sul pin 1 della base; la femmina F0830 sta sul top della base
con la stessa numerazione.

| Pin | Segnale | Pin FPGA | ESP32-S3 | | Pin | Segnale | Pin FPGA | ESP32-S3 |
|---|---|---|---|---|---|---|---|---|
| 1 | **+5V** | | | | 2 | **+5V** | | |
| 3 | **+5V** | | | | 4 | **+5V** | | |
| 5 | **+5V** | | | | 6 | **+5V** | | |
| 7 | GND | | | | 8 | GND | | |
| 9 | **qsclk** | D15 | GPIO12 (fisso) | | 10 | GND | | |
| 11 | GND | | | | 12 | qio0 | A13 | GPIO11 (fisso) |
| 13 | qio1 | A14 | GPIO13 (fisso) | | 14 | GND | | |
| 15 | GND | | | | 16 | qio2 | B18 | GPIO14 (fisso) |
| 17 | qio3 | A18 | GPIO9 (fisso) | | 18 | GND | | |
| 19 | GND | | | | 20 | qcs_n | C15 | GPIO10 (fisso) |
| 21 | sclk | A15 | GPIO4 | | 22 | GND | | |
| 23 | mosi | B16 | GPIO5 | | 24 | miso | B17 | GPIO6 |
| 25 | cs_n | A16 | GPIO7 | | 26 | GND | | |
| 27 | data_ready_n | D14 | GPIO16 | | 28 | sys_rst (att. basso) | G13 | GPIO15 |
| 29 | GND | | | | 30 | PROGRAM_B | P9 | GPIO21 |
| 31 | INIT_B | P7 | GPIO47 | | 32 | DONE | P10 | GPIO48 |
| 33 | GND | | | | 34 | TCK | E10 | GPIO1 |
| 35 | TMS | E12 | GPIO2 | | 36 | TDI | E11 | GPIO17 |
| 37 | TDO | E13 | GPIO18 | | 38 | GND | | |
| 39 | GND | | | | 40 | GND | | |

19 segnali (LVCMOS 3,3 V), 6 × +5 V, 15 × GND.

- **+5 V raggruppati** (1–6) con due masse subito dopo (7, 8).
- **Quad-SPI (80 MHz)**: ogni segnale ha una massa accanto nella stessa
  fila e di fronte nell'altra; qsclk (9) è tra 7 e 11, con 8 e 10
  dall'altra parte. Tracce corte e di lunghezza simile, serie 22–33 Ω su
  qsclk vicino all'ESP32 (§6.1).
- **SPI di gestione**, IRQ e reset dopo la massa 22, poi
  **configurazione e JTAG** verso il fondo: vanno ai GPIO dell'ESP32
  (driver di configurazione, datasheet §11.8). GPIO dell'ESP32: quelli
  Quad-SPI sono fissi (IO_MUX di SPI2), gli altri sono i default di
  `v4_bringup` (menuconfig). GPIO47/48 sono a 3,3 V solo sui moduli
  ESP32-S3 a 3,3 V.
- Pull-up sul modulo, non sulla base: qcs_n 10 kΩ, sys_rst 10 kΩ,
  PROGRAM_B 4,7 kΩ, INIT_B 4,7 kΩ, DONE 330 Ω (UG470).

## Meccanica e termica

- Modulo orizzontale, parallelo alla base, a **4,0 mm** (altezza
  accoppiata): sul **bottom** del modulo solo componenti bassi
  (passivi 0402/0603, niente induttori alti), tenendo conto anche di
  quelli della base sotto il modulo.
- FPGA e DDR3 sul **top**; il **dissipatore va sul top** (paragrafo
  termico del datasheet §7.2). Un connettore solo regge il modulo:
  aggiungere almeno due distanziali da 4,0 mm sul lato opposto.
