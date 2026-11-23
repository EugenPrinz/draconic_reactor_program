# Сборка docs/build.html

1. Клонировать `GTNewHorizons/Draconic-Evolution` в `/tmp/de` и (sparse) `GTNewHorizons/OpenComputers` в `/tmp/oc`.
2. `python3 parse_models.py` — боксы `ModelReactorEnergyInjector`, `ModelReactorStabilizerCore`, `ModelReactorStabilizerRing` → `models.json`.
3. Скопировать текстуры в `tex/` (список — в шаге сборки в истории коммита: модели реактора, fluxGate0–3, machine_io_i/o, AdapterSide/Top, Case*, Keyboard, Cable*, PowerConverterSide, GenericTop, screen/f*, screen/b*).
4. `python3 build.py` — встраивает модели, текстуры и `docs/screen-main.png` в один HTML.

Текстуры принадлежат авторам Draconic Evolution и OpenComputers.
