#!/usr/bin/env bash
set -uo pipefail

pause(){ read -rp "⏎ Enter ..."; }
header(){ clear; echo "==============================="; echo "📡 Client Installer (Mother)"; echo "==============================="; echo; }

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "❌ Run as root: sudo -i"
  exit 1
fi

MOTHER_IP="${1:-}"
if [ -z "$MOTHER_IP" ]; then
  read -rp "Enter Mother IP (e.g. 88.127.22.33): " MOTHER_IP
fi

BASE="http://${MOTHER_IP}"
INDEX_URL="${BASE}/files/index.json"

ensure_python(){
  if command -v python3 >/dev/null 2>&1; then
    return
  fi
  header
  echo "🧰 python3 not found. Installing python3..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y python3
}

install_base(){
  header
  echo "🧰 Installing base packages..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl ca-certificates tar unzip
  echo "✅ Done."
  pause
}

# ================= Docker =================
install_docker(){
  header
  echo "🐳 Installing Docker..."

  if ! command -v docker >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y docker.io
  else
    echo "ℹ️  Docker already installed."
  fi

  # Ensure config dir exists
  mkdir -p /etc/docker

  # Force Docker to treat Mother registry as HTTP (insecure registry)
  cat >/etc/docker/daemon.json <<EOF
{
  "insecure-registries": ["${MOTHER_IP}:5000"]
}
EOF

  systemctl daemon-reload

  # Make sure docker is enabled and running
  systemctl enable --now docker >/dev/null 2>&1 || true

  # IMPORTANT: restart so daemon.json takes effect immediately
  systemctl restart docker >/dev/null 2>&1 || true

  echo
  echo "✅ Docker ready."
  echo "➡️ Registry: ${MOTHER_IP}:5000"
  echo "🧪 Test: docker pull ${MOTHER_IP}:5000/nginx:alpine"
  pause
}

# ==========================================

install_project(){
  local name="$1"
  local installer_url="${BASE}/files/${name}/install-${name}-offline.sh"

  header
  echo "🚀 Installing: $name"
  echo "From: $installer_url"
  echo

  tmp="$(mktemp -d)"
  cd "$tmp"

  curl -fsSL "$installer_url" -o installer.sh
  sed -i "s|http://YOUR_MOTHER_IP|http://${MOTHER_IP}|g" installer.sh
  chmod +x installer.sh

  echo "▶️  Running installer with interactive TTY..."
  echo

  bash installer.sh

  echo
  echo "✅ Done: $name"
  pause
}

list_all_projects(){
  curl -fsSL "$INDEX_URL" | python3 -c '
import json,sys
data=json.load(sys.stdin)
for p in data.get("projects", []):
    name = (p.get("name") or "").strip()
    installer = (p.get("installer") or "").strip()
    if not name:
        continue
    status = "auto-install" if installer else "manual"
    print(f"{name}|{status}")
'
}

menu_install(){
  header
  echo "📦 Fetching project list..."

  ensure_python

  local lines
  lines="$(list_all_projects || true)"

  if [ -z "$lines" ]; then
    echo "❌ No projects found."
    pause
    return
  fi

  echo
  echo "Available projects:"
  echo

  local names=()
  local modes=()
  local i=1

  while IFS='|' read -r name mode; do
    names+=("$name")
    modes+=("$mode")
    printf "%d) %s [%s]\n" "$i" "$name" "$mode"
    i=$((i+1))
  done <<< "$lines"

  echo
  read -rp "Select number: " pick
  if ! [[ "$pick" =~ ^[0-9]+$ ]] || [ "$pick" -lt 1 ] || [ "$pick" -gt "${#names[@]}" ]; then
    echo "⚠️ Invalid choice"
    pause
    return
  fi

  local sel_name="${names[$((pick-1))]}"
  local sel_mode="${modes[$((pick-1))]}"

  if [ "$sel_mode" = "auto-install" ]; then
    install_project "$sel_name"
  else
    header
    echo "ℹ️  Project '$sel_name' does not support auto-install."
    echo "Files are available on Mother server:"
    echo
    echo "  $BASE/files/$sel_name/"
    echo
    pause
  fi
}

while true; do
  header
  echo "Mother: $BASE"
  echo
  echo "1) 🧰 Install base packages"
  echo "2) 📦 List & install project"
  echo "3) 🐳 Install Docker"
  echo "4) 🚪 Exit"
  echo
  read -rp "Select [1-4]: " c
  case "${c:-}" in
    1) install_base ;;
    2) menu_install ;;
    3) install_docker ;;
    4) echo "✅ Bye"; exit 0 ;;
    *) echo "⚠️ Invalid"; pause ;;
  esac
done
