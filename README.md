# Emit_Kimberlite_AR

  copy my entire file setup/hud.sh 
  open Linux or termux and paste.

then ⤵️

cat << 'EOF' > fix_build.sh
pkg install -y clang make python sqlite
pip install --upgrade setuptools --break-system-packages
rm -rf node_modules package-lock.json ~/.cache/node-gyp
npm install express ws --no-audit --no-fund
npm install sqlite3 --no-audit --no-fund --build-from-source
EOF

~/emit_cockpit $ cat << 'EOF' > deploy_emit.sh
#!/usr/bin/env bash
set -e




