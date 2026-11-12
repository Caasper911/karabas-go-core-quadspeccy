# Quad Speccy для Karabas Go

FPGA-ядро для [Karabas Go](https://github.com/andykarpov/karabas-go): четыре независимых
Pentagon 128 работают параллельно на одной плате. Можно смотреть все четыре на одном экране или
выбранный на весь экран. Идея взята у Quad Speccy для ReVerSE-U16 (MVV), реализация новая.

## Статус

Один Pentagon 128 на SDRAM работает на плате. Есть общий экран на четыре машины (пока собрана
одна) и полноэкранный режим. Подробнее в [docs/PLAN.md](docs/PLAN.md).

## Что есть

- Pentagon 128: T80 3,5 МГц, 128 КБ RAM, ROM 128 / 48, порты `#FE`, `#7FFD`, Kempston, без
  contention, тайминги Pentagon (71680 T, INT 32 T)
- память каждой машины в своём банке SDRAM
- VGA 896 × 640 / 50 Гц (scan doubler), OSD-меню (Win+Esc)
- USB-клавиатура и два джойстика через MCU
- beeper, вход / выход магнитофона

## Клавиши

| Клавиши | Действие |
|---|---|
| Win + 1..4 | клавиатура к машине 1..4 |
| Win + `~ | все четыре на одном экране (после старта) / выбранная во весь экран |
| F12 | сброс выбранной машины |
| Menu + F12 | сброс всех |
| Menu + P | пауза |
| Menu + J / R | тип левого / правого джойстика |

## Сборка

Нужны ISE 14.7, GNU make и bash (Linux, или MSYS2 / Git Bash на Windows), python 3 и
[karabas-go-tools](https://github.com/andykarpov/karabas-go-tools), выписанный рядом с этим
репозиторием (`../karabas-go-tools`).

```sh
git clone --recursive <repo>      # или git submodule update --init
cd src
make go          # synthesis, implementation, bitstream, quadspeccy.kg
make go-xst      # только синтез
make go-report   # ресурсы и тайминг последней сборки
```

Пути к ISE: Linux `/opt/Xilinx/14.7/ISE_DS` (`ISE_SETTINGS=`), Windows `/c/Xilinx/14.7/ISE_DS`
(`XILINX_DIR=`).

Симуляция (ISim): `src/sim/run_sim.sh [кадров]`. Прогоняет машину с моделью SDRAM и ROM,
проверяет тайминги SDRAM и данные чтений, рисует экран в `src/sim/work/screen.png`.

## Устройство

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): клоки, расписание SDRAM, карта памяти, видео,
  клавиатура
- [docs/PLAN.md](docs/PLAN.md): этапы и открытые вопросы
- `modules/`: общие модули Karabas Go (сабмодуль karabas-go-modules)
- `src/rtl/`: ядро (`karabas_go_top.v`, `zx/`, `sdram/`, `video/`, `hid/`, `t80/`)

## ROM

`src/roms/128.rom` и `48.rom` — ROM Sinclair ZX Spectrum 128 (© Amstrad, распространение с
эмуляторами разрешено). У каждой машины свои ROM: адреса заданы в `core.json`, см.
ARCHITECTURE.md, раздел «Загрузчик ROM».
