#!/bin/bash
set -e

# Get engine IP from metadata
ENGINE_IP=$(curl -s "http://metadata.google.internal/computeMetadata/v1/instance/attributes/engine-ip" -H "Metadata-Flavor: Google")

# Update and install dependencies
apt-get update
apt-get install -y curl wget git

# Install Node.js 20.x
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs

# Install iii CLI
curl -fsSL https://install.iii.dev/iii/main/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
echo 'export PATH="$HOME/.local/bin:$PATH"' >> /etc/profile.d/iii.sh

# Create working directory
mkdir -p /opt/iii-workers/caller-worker/src
cd /opt/iii-workers/caller-worker

# Create TypeScript worker code
cat > src/worker.ts <<'TSEOF'
import { registerWorker, Logger } from 'iii-sdk';

const worker = registerWorker(process.env.III_URL ?? 'ws://localhost:49134');
const logger = new Logger();

worker.registerFunction(
  'math::add_two_numbers',
  async (payload: { a: number; b: number }) => {
    logger.info('math::add_two_numbers called in TypeScript', payload);

    const result = await worker.trigger({
      function_id: 'math::add',
      payload,
    });

    return {
      ...result,
      success: "Workers are interoperating across VMs via RPC through the iii engine",
    };
  },
);

console.log('Caller worker started - listening for calls');
TSEOF

# Create package.json
cat > package.json <<'PKGEOF'
{
  "name": "caller-worker",
  "version": "0.1.0",
  "type": "module",
  "description": "Calls math::add in the Python worker and returns the result",
  "dependencies": {
    "iii-sdk": "0.11.0"
  },
  "devDependencies": {
    "@types/node": "^25.2.2",
    "tsx": "^4.0.0",
    "typescript": "^5.0.0"
  }
}
PKGEOF

# Create tsconfig.json
cat > tsconfig.json <<'TSCEOF'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ES2022",
    "moduleResolution": "node",
    "esModuleInterop": true,
    "strict": true,
    "skipLibCheck": true,
    "outDir": "./dist"
  },
  "include": ["src/**/*"]
}
TSCEOF

# Install dependencies
npm install

# Create systemd service
cat > /etc/systemd/system/caller-worker.service <<EOF
[Unit]
Description=iii Caller Worker (TypeScript)
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/iii-workers/caller-worker
Environment="III_URL=ws://${ENGINE_IP}:49134"
Environment="PATH=/usr/bin:/usr/local/bin:/root/.local/bin"
ExecStart=/usr/bin/npx tsx src/worker.ts
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Start and enable service
systemctl daemon-reload
systemctl enable caller-worker.service
systemctl start caller-worker.service

# Log status
systemctl status caller-worker.service --no-pager || true
echo "Caller worker startup complete" >> /var/log/startup.log
