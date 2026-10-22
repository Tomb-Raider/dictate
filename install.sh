#!/bin/zsh
# Ставит диктовку на Mac с M-чипом без прав администратора: всё в домашней папке.
# Одной командой:
#   curl -fsSL https://raw.githubusercontent.com/Tomb-Raider/dictate/main/install.sh | zsh
# Или из скачанного ZIP:  zsh ~/Downloads/dictate-main/install.sh
# Повторный запуск обновляет программу, словарь не трогает.

main() {
  set -e
  local RAW="https://raw.githubusercontent.com/Tomb-Raider/dictate/main"
  local SRC="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
  local DEST="$HOME/Диктовка"
  local BIN="$HOME/.local/bin"

  if [ "$(uname -m)" != "arm64" ]; then
    echo "Нужен Mac с M-чипом, а здесь Intel. Остановилась"; return 1
  fi

  echo "1/4 Кладу программу в $DEST"
  mkdir -p "$DEST" "$BIN"
  if [ -f "$SRC/dictate.py" ] && [ "$SRC" != "$DEST" ]; then
    cp "$SRC/dictate.py" "$DEST/"
    [ -f "$DEST/словарь.txt" ] || cp "$SRC/словарь.txt" "$DEST/"
  elif [ "$SRC" != "$DEST" ]; then
    curl -fsSL "$RAW/dictate.py" -o "$DEST/dictate.py"
    # словарь.txt в адресе закодирован
    [ -f "$DEST/словарь.txt" ] || curl -fsSL "$RAW/%D1%81%D0%BB%D0%BE%D0%B2%D0%B0%D1%80%D1%8C.txt" -o "$DEST/словарь.txt"
  fi

  echo "2/4 Ставлю uv (менеджер Python, без прав администратора)"
  local UV="$(command -v uv || true)"
  [ -z "$UV" ] && [ -x "$BIN/uv" ] && UV="$BIN/uv"
  if [ -z "$UV" ]; then
    curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh
    UV="$BIN/uv"
  fi

  echo "3/4 Делаю команду dictate"
  cat > "$BIN/dictate" <<EOF
#!/bin/zsh
exec "$UV" run --quiet "$DEST/dictate.py" "\$@"
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
