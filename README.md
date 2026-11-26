# Electrónica Digital II — PIC16F887

Trabajos de laboratorio (TdL) y trabajo integrador de  **Electrónica Digital II**
(FCEFyN, Universidad Nacional de Córdoba), desarrollados en **assembler para el PIC16F887**
sobre una placa de desarrollo armada y soldada por el grupo.

## Hardware

- PIC16F887, fuente de 5 V
- Conversor USB-UART (FTDI) y bootloader serie AN1310
- Banco de LEDs, pulsador, displays de 7 segmentos multiplexados y teclado matricial 4x4

## Trabajos de laboratorio

| TdL | Tema |
|-----|------|
| [TdL 2](TdL2) | Antirrebote del pulsador y estructura del loop principal |
| [TdL 4](TdL4) | Cronómetro usando el Timer0 (TMR0) |
| [TdL 5](TdL5) | Lectura de teclado matricial 4x4 |

## Trabajo integrador: Pastillero inteligente

Pastillero que avisa cuándo tomar cada pastilla:

- Se cargan hasta **3 horarios de toma** desde el teclado matricial.
- **4 displays de 7 segmentos** muestran la hora.
- Al llegar cada horario suena un **buzzer** y se encienden **LEDs**.
- Un **LDR** dentro del pastillero, leído con el **ADC**, detecta cuándo se abre la tapa:
  se toma como que la pastilla fue tomada y la alarma se apaga.

El código y el informe completo están en la carpeta [TI](TI).

## Herramientas

- MPLAB X IDE (v5.35) y su simulador, para probar cada programa antes de cargarlo
- Carga a la placa mediante bootloader AN1310 por USB-serie

## Autores

Grupo **"Bit a Bit"** — Ingeniería en Computación, FCEFyN-UNC.
