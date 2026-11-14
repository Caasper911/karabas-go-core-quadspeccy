# QuadSpeccy для Karabas Go / Mini / Mini G

FPGA-ядро для [Karabas Go](https://github.com/andykarpov/karabas-go): четыре независимых
Pentagon 128 работают параллельно на одной плате. Можно смотреть все четыре на одном экране или
выбранный на весь экран. Идея взята у [QuadSpeccy для ReVerSE-U16](https://github.com/mvvproject/ReVerSE-U16/tree/master/u16_quadspeccy) (MVV), реализация новая.

## Статус

Четыре Pentagon 128 работают на платах Karabas Go, Mini и Mini G: общий экран на четыре машины и полноэкранный
режим выбранной, MCU link v2. Подробнее в [docs/PLAN.md](docs/PLAN.md).

## Что есть

- Pentagon 128: Z80 (tv80, один на четыре машины) 3,5 МГц, ROM 128 / 48, порты `#FE`, `#7FFD`, Kempston, без
  contention, тайминги Pentagon (71680 T, INT 32 T)
- 128 / 1024 КБ RAM на машину (OSD Memory size на странице машины, по умолчанию 128K); 1024K по стандарту Profi: порт
  `#DFFD` биты 2..0 — старшие биты страницы в `C000` (остальные биты не используются)
- память каждой машины в своём банке SDRAM
- TR-DOS 5.04T и Beta Disk с дисководом платы (только Karabas Go) у одной машины: OSD «FDD» Core 1..4, у этой
  машины должен быть выключен DivMMC
- DivMMC в каждой машине (ESXDOS 0.8.9, 512 КБ): SD-карта №2 платы или образ с карты MCU,
  выбирается в OSD на странице машины
- Z-Controller в каждой машине (порты `#57` / `#77`, всегда включён, и при выключенном DivMMC): та же SD-карта
  или образ, что у DivMMC этой машины
- VGA 31,25 кГц / 48,8 Гц (scan doubler), видимая часть 736 × 576, гашение как у 720 × 576p50; OSD-меню (Win+Esc)
- платы: Karabas Go (VGA, PCM5102, дисковод), Karabas Mini и Mini G (HDMI с тем же растром и звуком, аналоговый
  выход у Mini / PCM5102 у Mini G, без дисковода); проверено на всех трёх платах
- USB-клавиатура и два джойстика через MCU; в OSD «Keys to» Selected / All (All: в quad-режиме нажатия идут во
  все машины сразу, в полноэкранном — в выбранную)
- USB-мышь: Kempston mouse выбранной машины в полноэкранном режиме; в quad-режиме курсор, щелчок левой кнопкой
  выбирает машину, двойной щелчок — она на весь экран (курсор гаснет через 5 с без движения); средняя кнопка
  в полноэкранном режиме возвращает в quad-режим
- beeper, вход / выход магнитофона; в OSD «Tape in» Board / Core (Core: остальные машины слышат выход машины
  «Tape out», SAVE в одной — LOAD в других) и «Tape out» Core 1..4 (какая машина идёт на выход платы)
- TurboSound в каждой машине (два AY, порты `#FFFD` / `#BFFD`); слышна выбранная машина, а с OSD Sound = Always
  на странице машины — всегда; смесь ABC / ACB в OSD на странице машины

## Клавиши

| Клавиши | Действие |
|---|---|
| Win + 1..4 | клавиатура к машине 1..4 |
| Win + стрелки | соседняя машина по квадрантам 2 × 2 (без перехода через край) |
| Win + `~ | все четыре на одном экране (после старта) / выбранная во весь экран |
| F11 | NMI выбранной машины (меню ESXDOS) |
| F12 | сброс выбранной машины |
| Win + F12 | сброс всех; ОЗУ DivMMC (первые 128 КБ) очищается, как при старте ядра |
| Menu + P | пауза |
| Menu + J / R | тип левого / правого джойстика |

В OSD (Win+Esc) на страницах «Core 1..4» у каждой машины: DivMMC On/Off, SD card Real/Image и
образ SD (`.img`, `.mmc`, `.hdf`, `.vhd`, `.bin` из `/zx`), AY mix ABC / ACB. Реальной картой владеет младшая из
выбравших Real. SD card действует и при выключенном DivMMC (Z-Controller). Также в OSD задаётся цвет рамки выбранной машины в quad-режиме: 8 цветов Спектрума, по
умолчанию зелёный.

## Прошивка MCU

Ядро работает по MCU link v2 (`"link": 2` в `core.json`): нужна прошивка
[karabas-go-firmware](https://github.com/andykarpov/karabas-go-firmware) 26111315 или новее. Более старая прошивка
ядро не загрузит (не найдёт в `.kg` прошивки для своей платы).

## Сборка

Нужны ISE 14.7, GNU make и bash (Linux, или MSYS2 / Git Bash на Windows), python 3 и
[karabas-go-tools](https://github.com/andykarpov/karabas-go-tools), выписанный рядом с этим
репозиторием (`../karabas-go-tools`).

```sh
git clone --recursive https://github.com/Caasper911/karabas-go-core-quadspeccy.git   # или git submodule update --init
cd src
make             # все платы: quadspeccy.kg с прошивками Go, Mini, Mini G
make go          # одна плата (go / mini / minig): синтез, implementation, bitstream, её часть quadspeccy.kg
make go-xst      # только синтез
make go-report   # ресурсы и тайминг последней сборки
```

Весь вывод ISE во время сборки пишется ещё и в `src/karabas_<плата>_build.log`: прогресс виден через
`tail -f src/karabas_go_build.log`.

Пути к ISE: Linux `/opt/Xilinx/14.7/ISE_DS` (`ISE_SETTINGS=`), Windows `/c/Xilinx/14.7/ISE_DS`
(`XILINX_DIR=`).

Симуляция (ISim): `src/sim/run_sim.sh [кадров]`. Прогоняет машину с моделью SDRAM и ROM,
проверяет тайминги SDRAM и данные чтений, рисует экран в `src/sim/work/screen.png`.

## Устройство

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): клоки, расписание SDRAM, карта памяти, видео,
  клавиатура
- [docs/PLAN.md](docs/PLAN.md): этапы и открытые вопросы
- `modules/`: общие модули Karabas Go (сабмодуль karabas-go-modules)
- `src/rtl/`: ядро `quadspeccy.v` и обёртки плат (`karabas_go_top.v`, `karabas_mini_top.v`, `karabas_minig_top.v`),
  `zx/`, `sdram/`, `video/`, `hid/`, `tv80/`

## ROM

У каждой машины свои ROM: адреса заданы в `core.json`, см. ARCHITECTURE.md, раздел «Загрузчик ROM».
ROM не под лицензией MIT, права у их владельцев (подробно в [LICENSE](LICENSE)):

- `128.rom`, `48.rom` — ROM ZX Spectrum 128 / 48, © Amstrad (распространение с эмуляторами разрешено);
- `esxdos089.bin` — [esxDOS](https://esxdos.org) для DivMMC, Papaya Dezign: freeware без
  опубликованной лицензии, свободно скачивается с esxdos.org;
- `trdos504tprofiD.rom` — TR-DOS 5.04T, © 1986 Technology Research Ltd (проприетарная),
  изменения 5.04T © C.C. 1991.

## Лицензия

Смешанная, см. [LICENSE](LICENSE): ROM принадлежат своим владельцам; T80 и tv80 под своими лицензиями (в
заголовках файлов); генератор AY по ym2149 MikeJ / Sorgelig (BSD); модель VG93 и обвязка Beta Disk — HRDY ([FD1793_1818VG93](https://github.com/demyanenko-d/FD1793_1818VG93), без
опубликованной лицензии, пришли через karabas-go-core-tsconf); `modules/` — по условиям karabas-go-modules;
остальное (ядро, скрипты, документация, битстримы) — MIT.
