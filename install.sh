#!/bin/zsh
# Ставит диктовку на Mac с M-чипом без прав администратора: всё в домашней папке.
# Одной командой:
#   curl -fsSL https://raw.githubusercontent.com/Tomb-Raider/dictate/main/install.sh | zsh
# Или из скачанного ZIP:  zsh ~/Downloads/dictate-main/install.sh
# Повторный запуск обновляет программу, словарь не трогает.
#
# Проверка, заработает ли, без установки: добавить --check
#   curl -fsSL https://raw.githubusercontent.com/Tomb-Raider/dictate/main/install.sh | zsh -s -- --check
#   zsh ~/Downloads/dictate-main/install.sh --check

# Папка, откуда запущен установщик. Считать здесь: внутри функции zsh подставляет в $0 её имя.
# При запуске через curl | zsh это текущая папка, программы там нет, и она скачается с GitHub
SRC_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"

RAW="https://raw.githubusercontent.com/Tomb-Raider/dictate/main"
DEST="$HOME/Диктовка"
BIN="$HOME/.local/bin"
DEPS=$'mlx-whisper>=0.4\nsounddevice\nnumpy'   # то же, что в шапке dictate.py
MODEL_DIR="${HF_HUB_CACHE:-${HF_HOME:-$HOME/.cache/huggingface}/hub}/models--mlx-community--whisper-large-v3-turbo"

# uv, который уже есть: поставленный раньше в домашнюю папку или стоящий на компьютере.
# Подходит и сборка для Intel: Python в команде dictate всё равно задан для M-чипа
find_uv() {
  if [ -x "$BIN/uv" ]; then echo "$BIN/uv"; else command -v uv; fi
}

# uv через сервер пакетов Python, настроенный на компьютере (в рабочей сети это зеркало)
pip_uv() {
  local tmp="$1" dir="$2" py whl
  for py in $(whence -ap python3 python3.12 python3.13 python3.11 python3.14 2>/dev/null); do
    # /usr/bin/python3 без инструментов разработчика открывает окно их установки, его не трогаем
    [ "$py" = /usr/bin/python3 ] && ! xcode-select -p >/dev/null 2>&1 && continue
    "$py" -m pip download uv --no-deps --only-binary=:all: --platform macosx_11_0_arm64 \
      --disable-pip-version-check -q -d "$tmp/pip" >/dev/null 2>&1 || continue
    whl="$(ls "$tmp"/pip/uv-*.whl 2>/dev/null | head -1)"
    [ -n "$whl" ] || continue
    unzip -q -o "$whl" -d "$tmp/whl" && cp "$tmp"/whl/uv-*.data/scripts/uv "$dir/uv" && chmod +x "$dir/uv" && return 0
  done
  return 1
}

# Скачивает uv в папку $1 и печатает, откуда. По очереди: astral.sh, GitHub, сервер пакетов Python.
# Рабочая сеть может закрывать часть сайтов, поэтому сбой каждого источника не останавливает
fetch_uv() {
  local dir="$1" tmp src=""
  tmp="$(mktemp -d)" || return 1
  mkdir -p "$dir"
  if curl -fsSL --connect-timeout 20 https://astral.sh/uv/install.sh -o "$tmp/i.sh" 2>/dev/null \
      && env UV_NO_MODIFY_PATH=1 UV_INSTALL_DIR="$dir" XDG_CONFIG_HOME="$tmp" sh "$tmp/i.sh" </dev/null >/dev/null 2>&1 \
      && [ -x "$dir/uv" ]; then
    src="astral.sh"
  elif curl -fsSL --connect-timeout 20 -o "$tmp/uv.tgz" 2>/dev/null \
        https://github.com/astral-sh/uv/releases/latest/download/uv-aarch64-apple-darwin.tar.gz \
      && tar -xzf "$tmp/uv.tgz" -C "$tmp" && cp "$tmp/uv-aarch64-apple-darwin/uv" "$dir/uv"; then
    src="GitHub"
  elif pip_uv "$tmp" "$dir"; then
    src="сервер пакетов Python"
  fi
  [ -d "$tmp" ] && rm -rf "$tmp"
  [ -n "$src" ] && echo "$src"
}

check() {
  local fails=0 uv tmp="" src ver major free
  ok()    { echo "✓ $*"; }
  bad()   { echo "✗ $*"; fails=$((fails + 1)); }
  maybe() { echo "? $*"; }

  echo "Проверка, заработает ли диктовка на этом Mac. Ничего не устанавливает, займёт до минуты"
  echo

  # hw.optional.arm64 честно отвечает и тогда, когда Терминал запущен через Rosetta
  if [ "$(sysctl -in hw.optional.arm64)" = "1" ]; then
    ok "Чип: $(sysctl -n machdep.cpu.brand_string)"
  else
    bad "Чип Intel, а нужен Mac с M-чипом"
  fi

  ver="$(sw_vers -productVersion)"; major="${ver%%.*}"
  if (( major >= 14 )); then ok "macOS $ver"
  elif (( major == 13 )); then maybe "macOS $ver: должно работать, но на 13 не проверялось"
  else bad "macOS $ver, а нужна 13 или новее"
  fi

  free="$(df -g "$HOME" | awk 'NR==2 {print $4}')"
  if (( free >= 3 )); then ok "Свободно на диске $free ГБ"; else bad "Свободно на диске $free ГБ, нужно 3"; fi

  uv="$(find_uv)"
  if [ -n "$uv" ]; then
    ok "uv уже есть: $uv"
  else
    tmp="$(mktemp -d)"
    if src="$(fetch_uv "$tmp")"; then
      ok "uv на компьютере нет, но скачивается ($src)"
      uv="$tmp/uv"
    else
      bad "uv на компьютере нет и не скачивается ни с astral.sh, ни с GitHub, ни с сервера пакетов"
    fi
  fi

  # Тот же подбор пакетов, что при установке, только без установки: под M-чип и эту версию macOS
  if [ -n "$uv" ]; then
    if MACOSX_DEPLOYMENT_TARGET="$major.0" "$uv" pip compile -q --no-header --python-version 3.12 \
        --python-platform aarch64-apple-darwin - <<<"$DEPS" >/dev/null 2>"${TMPDIR:-/tmp}/dictate-check.err"; then
      ok "Пакеты распознавания находятся на сервере пакетов"
    else
      bad "Пакеты распознавания не находятся:"
      grep -v '^$' "${TMPDIR:-/tmp}/dictate-check.err" | head -4 | sed 's/^/    /'
    fi
    rm -f "${TMPDIR:-/tmp}/dictate-check.err"
  fi

  if [ -d "$MODEL_DIR" ]; then
    ok "Модель уже скачана"
  elif curl -fsS --max-time 20 -o /dev/null \
      "${HF_ENDPOINT:-https://huggingface.co}/api/models/mlx-community/whisper-large-v3-turbo" 2>/dev/null; then
    ok "Hugging Face открывается, модель скачается"
  else
    bad "Hugging Face не открывается, модель не скачается"
  fi

  if curl -fsS --max-time 15 -o /dev/null "$RAW/install.sh" 2>/dev/null; then
    ok "GitHub из Терминала открывается, можно ставить одной командой"
  else
    maybe "GitHub из Терминала не открывается, ставить из ZIP"
  fi

  [ -x "$BIN/dictate" ] && ok "Диктовка уже установлена, команда dictate"
  [ -n "$tmp" ] && [ -d "$tmp" ] && rm -rf "$tmp"

  echo
  if (( fails == 0 )); then
    echo "Итог: должно заработать. Доступ к микрофону macOS спросит при первой записи"
  else
    echo "Итог: не заработает, причины отмечены ✗. Пришли этот текст тому, кто дал ссылку"
  fi
}

main() {
  set -e
  local SRC="$SRC_DIR"

  # hw.optional.arm64 честно отвечает и тогда, когда Терминал запущен через Rosetta
  if [ "$(sysctl -in hw.optional.arm64)" != "1" ]; then
    echo "Нужен Mac с M-чипом, а здесь Intel. Остановилась"; return 1
  fi

  echo "1/4 Кладу программу в $DEST"
  mkdir -p "$DEST" "$BIN"
  if [ -f "$SRC/dictate.py" ] && [ "$SRC" != "$DEST" ]; then
    cp "$SRC/dictate.py" "$DEST/"
    [ -f "$DEST/словарь.txt" ] || cp "$SRC/словарь.txt" "$DEST/"
  elif [ "$SRC" != "$DEST" ]; then
    # словарь.txt в адресе закодирован
    if ! curl -fsSL "$RAW/dictate.py" -o "$DEST/dictate.py" \
        || { [ ! -f "$DEST/словарь.txt" ] \
             && ! curl -fsSL "$RAW/%D1%81%D0%BB%D0%BE%D0%B2%D0%B0%D1%80%D1%8C.txt" -o "$DEST/словарь.txt"; }; then
      echo "Не получилось скачать программу с GitHub. Скачай ZIP и запусти install.sh из него. Остановилась"
      return 1
    fi
  fi

  echo "2/4 Ищу uv (менеджер Python, без прав администратора)"
  local UV src
  UV="$(find_uv || true)"
  if [ -z "$UV" ]; then
    echo "   uv на компьютере нет, скачиваю"
    if src="$(fetch_uv "$BIN")"; then
      echo "   скачан ($src)"
      UV="$BIN/uv"
    else
      echo "Не получилось скачать uv ни с astral.sh, ни с GitHub, ни с сервера пакетов. Остановилась"
      return 1
    fi
  fi
  echo "   uv: $UV"

  # Python строго для M-чипа: если в системе есть Python для Intel, uv иначе возьмёт его,
  # а под Intel пакетов распознавания нет. uv скачает свой Python, если подходящего нет
  echo "3/4 Делаю команду dictate"
  cat > "$BIN/dictate" <<EOF
#!/bin/zsh
exec "$UV" run --quiet --python cpython-3.12-macos-aarch64-none "$DEST/dictate.py" "\$@"
EOF
  chmod +x "$BIN/dictate"
  cat > "$DEST/Диктовка.command" <<EOF
#!/bin/zsh
exec "$BIN/dictate"
EOF
  chmod +x "$DEST/Диктовка.command"
  if ! grep -qs '.local/bin' "$HOME/.zshrc"; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zshrc"
  fi

  echo "4/4 Скачиваю Python, пакеты и модель (около 2 ГБ, один раз)"
  "$BIN/dictate" --prepare </dev/null

  echo
  echo "Готово. Открой новое окно Терминала и набери  dictate"
  echo "Или двойной клик по $DEST/Диктовка.command"
}

if [ "$1" = "--check" ]; then check; else main "$@"; fi
