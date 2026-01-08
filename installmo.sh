#!/usr/bin/env bash
set -uo pipefail

# =======================
# Paths / Flags
# =======================
MOTHER_ROOT="/srv/mother"
FILES_DIR="$MOTHER_ROOT/files"
REGISTRY_DIR="$MOTHER_ROOT/registry"
BIN_DIR="$MOTHER_ROOT/bin"
BOOTSTRAP_FLAG="$MOTHER_ROOT/.bootstrapped"

INDEX_JSON="$FILES_DIR/index.json"

# ---------------- UI ----------------
pause(){ read -rp "⏎ Enter ..."; }
header(){ clear; echo "========================================"; echo "🛡️ Mother Server Manager"; echo "========================================"; echo; }
ok(){ echo "✅ $*"; }
info(){ echo "ℹ️  $*"; }
warn(){ echo "⚠️  $*" >&2; }
err(){ echo "❌ $*" >&2; }

need_root(){
  [ "${EUID:-$(id -u)}" -eq 0 ] || { err "Run as root"; exit 1; }
}

sanitize(){ echo "$1" | tr -cd 'a-zA-Z0-9._-'; }
is_url(){ [[ "$1" =~ ^https?:// ]]; }

ensure_dirs(){
  mkdir -p "$FILES_DIR" "$REGISTRY_DIR" "$BIN_DIR"
  chown -R www-data:www-data "$FILES_DIR"
}

write_nginx(){
  cat >/etc/nginx/sites-available/mother.conf <<'EOF'
server {
  listen 80;
  server_name _;
  location /files/ {
    alias /srv/mother/files/;
    autoindex on;
  }
}
EOF
  rm -f /etc/nginx/sites-enabled/default || true
  ln -sf /etc/nginx/sites-available/mother.conf /etc/nginx/sites-enabled/mother.conf
  nginx -t
  systemctl restart nginx
}

# ---------------- Index ----------------
update_index(){
  local tmp
  tmp="$(mktemp)"
  {
    echo '{'
    echo "  \"generated_at\": \"$(date -u +%FT%TZ)\","
    echo '  "projects": ['

    local first=1
    for p in "$FILES_DIR"/*; do
      [ -d "$p" ] || continue
      local proj
      proj="$(basename "$p")"

      local versions=()
      while IFS= read -r -d '' d; do
        versions+=( "$(basename "$d")" )
      done < <(find "$p" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)

      local installer=""
      [ -f "$p/install-${proj}-offline.sh" ] && installer="/files/${proj}/install-${proj}-offline.sh"

      [ "$first" -eq 0 ] && echo '    ,'
      first=0

      echo '    {'
      echo "      \"name\": \"${proj}\","
      echo -n '      "versions": ['
      for i in "${!versions[@]}"; do
        [ "$i" -gt 0 ] && echo -n ', '
        echo -n "\"${versions[$i]}\""
      done
      echo '],'
      echo "      \"installer\": \"${installer}\""
      echo -n '    }'
    done

    echo
    echo '  ]'
    echo '}'
  } >"$tmp"

  mv "$tmp" "$INDEX_JSON"
  chown www-data:www-data "$INDEX_JSON"
}

# ---------------- Docker Setup ----------------
setup_docker(){
  header
  info "Setting up Docker & Local Registry..."

  export DEBIAN_FRONTEND=noninteractive
  apt update
  apt install -y docker.io

  systemctl enable --now docker

  if ! docker ps --format '{{.Names}}' | grep -q '^registry$'; then
    docker run -d --restart=always --name registry \
      -p 5000:5000 -v "$REGISTRY_DIR":/var/lib/registry registry:2
  fi

  for img in alpine:latest nginx:alpine busybox:latest; do
    docker pull "$img"
    docker tag "$img" "localhost:5000/$img"
    docker push "localhost:5000/$img"
  done

  ok "Docker & registry ready."
  pause
}

# ---------------- Project add/remove ----------------
add_project_menu(){
  header
  read -rp "Project name: " p
  read -rp "Version: " v
  read -rp "Direct URL: " u

  p="$(sanitize "$p")"
  v="$(sanitize "$v")"
  is_url "$u" || { err "Bad URL"; pause; return; }

  mkdir -p "$FILES_DIR/$p/$v"
  cd "$FILES_DIR/$p/$v"

  curl -L --fail -o package "$(basename "$u")" "$u"

  read -rp "Create auto-installer? [y/N]: " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    cat >"$FILES_DIR/$p/install-${p}-offline.sh" <<EOF
#!/usr/bin/env bash
set -e
curl -fsSL http://YOUR_MOTHER_IP/files/$p/$v/$(basename "$u") | bash
EOF
    chmod +x "$FILES_DIR/$p/install-${p}-offline.sh"
  fi

  update_index
  ok "Project added."
  pause
}

remove_project_menu(){
  header
  read -rp "Project name: " p
  rm -rf "$FILES_DIR/$(sanitize "$p")"
  update_index
  ok "Removed."
  pause
}

# ---------------- Timer ----------------
setup_timer(){
  header
  read -rp "Run update every how many hours? " h

  cat >/etc/systemd/system/mother-updater.timer <<EOF
[Timer]
OnBootSec=10min
OnUnitActiveSec=${h}h
EOF

  cat >/etc/systemd/system/mother-updater.service <<EOF
[Service]
Type=oneshot
ExecStart=$BIN_DIR/update-projects.sh
EOF

  systemctl daemon-reload
  systemctl enable --now mother-updater.timer
  ok "Timer enabled."
  pause
}

# ---------------- Bootstrap ----------------
bootstrap(){
  header
  export DEBIAN_FRONTEND=noninteractive
  apt update
  apt install -y nginx curl ufw ca-certificates

  ufw allow OpenSSH
  ufw allow 80
  ufw allow 5000
  ufw --force enable

  ensure_dirs
  write_nginx

  touch "$BOOTSTRAP_FLAG"
  ok "Bootstrap done."
  pause
}

# =======================
# Main
# =======================
need_root
ensure_dirs
[ -f "$BOOTSTRAP_FLAG" ] || bootstrap
update_index

while true; do
  header
  echo "1) ➕ Add project"
  echo "2) 🗑  Remove project"
  echo "3) 📦 List projects"
  echo "4) 🐳 Setup Docker & Registry"
  echo "5) ⏱  Setup auto-update timer"
  echo "6) 🚪 Exit"
  read -rp "> " c
  case "$c" in
    1) add_project_menu ;;
    2) remove_project_menu ;;
    3) ls -1 "$FILES_DIR"; pause ;;
    4) setup_docker ;;
    5) setup_timer ;;
    6) exit 0 ;;
  esac
done
