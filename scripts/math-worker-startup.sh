#!/bin/bash
set -e

# Get engine IP from metadata
ENGINE_IP=$(curl -s "http://metadata.google.internal/computeMetadata/v1/instance/attributes/engine-ip" -H "Metadata-Flavor: Google")

# Update and install dependencies
apt-get update
apt-get install -y python3 python3-pip python3-venv git curl

# Install iii CLI
curl -fsSL https://install.iii.dev/iii/main/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
echo 'export PATH="$HOME/.local/bin:$PATH"' >> /etc/profile.d/iii.sh

# Create working directory
mkdir -p /opt/iii-workers/math-worker
cd /opt/iii-workers/math-worker

# Create Python worker code
cat > math_worker.py <<'PYEOF'
import os
from iii import register_worker, InitOptions, Logger

worker = register_worker(
    os.environ.get("III_URL", "ws://localhost:49134"),
    InitOptions(worker_name="math-worker"),
)
logger = Logger()

def add_handler(payload: dict) -> dict:
    a = payload.get("a", 0)
    b = payload.get("b", 0)
    logger.info(f"math::add called in Python with a={a}, b={b}")
    result = {"c": a + b}
    return result

worker.register_function("math::add", add_handler)

print("Math worker started - listening for calls")
PYEOF

# Create requirements.txt
cat > requirements.txt <<'REQEOF'
iii-sdk==0.11.0
REQEOF

# Create virtual environment and install dependencies
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

# Create systemd service
cat > /etc/systemd/system/math-worker.service <<EOF
[Unit]
Description=iii Math Worker (Python)
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/iii-workers/math-worker
Environment="III_URL=ws://${ENGINE_IP}:49134"
Environment="PATH=/opt/iii-workers/math-worker/venv/bin:/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=/opt/iii-workers/math-worker/venv/bin/python3 math_worker.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Start and enable service
systemctl daemon-reload
systemctl enable math-worker.service
systemctl start math-worker.service

# Log status
systemctl status math-worker.service --no-pager || true
echo "Math worker startup complete" >> /var/log/startup.log
