#!/bin/zsh
# Ставит диктовку на Mac с M-чипом без прав администратора: всё в домашней папке.
# Одной командой:
#   curl -fsSL https://raw.githubusercontent.com/Tomb-Raider/dictate/main/install.sh | zsh
# Или из скачанного ZIP:  zsh ~/Downloads/dictate-main/install.sh
# Повторный запуск обновляет программу, словарь не трогает.

# Папка, откуда запущен установщик. Считать здесь: внутри функции zsh подставляет в $0 её имя.
# При запуске через curl | zsh это текущая папка, программы там нет, и она скачается с GitHub
SRC_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"

main() {
  set -e
  local RAW="https://raw.githubusercontent.com/Tomb-Raider/dictate/main"
  local SRC="$SRC_DIR"
  local DEST="$HOME/Диктовка"
  local BIN="$HOME/.local/bin"

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

  # uv: поставленный раньше в домашнюю папку, потом уже стоящий на компьютере (подходит и сборка
  # для Intel, Python ниже всё равно задан для M-чипа), и только потом скачиваем. Рабочая сеть
  # может не пускать на astral.sh, тогда сбой надо заметить, а не идти дальше
  echo "2/4 Ищу uv (менеджер Python, без прав администратора)"
  local UV=""
  if [ -x "$BIN/uv" ]; then
    UV="$BIN/uv"
  elif command -v uv >/dev/null; then
    UV="$(command -v uv)"
  else
    echo "   uv на компьютере нет, скачиваю"
    local TMP="$(mktemp)"
    if curl -LsSf --connect-timeout 20 https://astral.sh/uv/install.sh -o "$TMP" \
        && env UV_NO_MODIFY_PATH=1 UV_INSTALL_DIR="$BIN" sh "$TMP" </dev/null; then
      [ -x "$BIN/uv" ] && UV="$BIN/uv"
    fi
    rm -f "$TMP"
  fi
  if [ -z "$UV" ]; then
    echo "Не получилось скачать uv с astral.sh, похоже, сайт закрыт в этой сети. Остановилась"
    return 1
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

main "$@"
