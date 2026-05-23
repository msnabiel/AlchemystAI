#!/bin/bash
set -e

# Update and install dependencies
apt-get update
apt-get install -y curl wget git

# Install iii CLI
curl -fsSL https://install.iii.dev/iii/main/install.sh | sh

# Add iii to PATH
export PATH="$HOME/.local/bin:$PATH"
echo 'export PATH="$HOME/.local/bin:$PATH"' >> /etc/profile.d/iii.sh

# Create systemd service for iii engine
cat > /etc/systemd/system/iii-engine.service <<'EOF'
[Unit]
Description=iii Engine WebSocket Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/iii
ExecStart=/root/.local/bin/iii engine start --host 0.0.0.0 --port 49134
Restart=always
RestartSec=10
Environment="PATH=/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

[Install]
WantedBy=multi-user.target
EOF

# Create working directory
mkdir -p /opt/iii

# Start and enable service
systemctl daemon-reload
systemctl enable iii-engine.service
systemctl start iii-engine.service

# Log status
systemctl status iii-engine.service --no-pager || true
echo "iii engine startup complete" >> /var/log/startup.log
