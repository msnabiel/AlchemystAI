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
mkdir -p /opt/api-gateway/src
cd /opt/api-gateway

# Create API Gateway code
cat > src/server.ts <<'SERVEREOF'
import http from 'http';
import { registerWorker, Logger } from 'iii-sdk';

const ENGINE_URL = process.env.III_URL ?? 'ws://localhost:49134';
const PORT = parseInt(process.env.PORT ?? '8080');

const worker = registerWorker(ENGINE_URL);
const logger = new Logger();

const server = http.createServer(async (req, res) => {
  // CORS headers
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') {
    res.writeHead(200);
    res.end();
    return;
  }

  // Health check endpoint
  if (req.url === '/health' && req.method === 'GET') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'healthy', engine: ENGINE_URL }));
    return;
  }

  // Math add endpoint
  if (req.url === '/math/add' && req.method === 'POST') {
    let body = '';

    req.on('data', chunk => {
      body += chunk.toString();
    });

    req.on('end', async () => {
      try {
        const payload = JSON.parse(body);

        // Validate input
        if (typeof payload.a !== 'number' || typeof payload.b !== 'number') {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'Invalid input: a and b must be numbers' }));
          return;
        }

        logger.info('API Gateway received request', { payload });

        // Trigger the caller worker function via iii engine
        const result = await worker.trigger({
          function_id: 'math::add_two_numbers',
          payload,
        });

        logger.info('API Gateway received result', { result });

        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(result));
      } catch (error: any) {
        logger.error('API Gateway error', { error: error.message });
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Internal server error', message: error.message }));
      }
    });

    return;
  }

  // 404 for all other routes
  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'Not found' }));
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`API Gateway listening on http://0.0.0.0:${PORT}`);
  console.log(`Connected to iii engine at ${ENGINE_URL}`);
  console.log('Available endpoints:');
  console.log('  POST /math/add - Add two numbers');
  console.log('  GET  /health   - Health check');
});
SERVEREOF

# Create package.json
cat > package.json <<'PKGEOF'
{
  "name": "api-gateway",
  "version": "0.1.0",
  "type": "module",
  "description": "HTTP JSON API gateway for iii quickstart",
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
cat > /etc/systemd/system/api-gateway.service <<EOF
[Unit]
Description=iii API Gateway (HTTP JSON)
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/api-gateway
Environment="III_URL=ws://${ENGINE_IP}:49134"
Environment="PORT=8080"
Environment="PATH=/usr/bin:/usr/local/bin:/root/.local/bin"
ExecStart=/usr/bin/npx tsx src/server.ts
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Start and enable service
systemctl daemon-reload
systemctl enable api-gateway.service
systemctl start api-gateway.service

# Log status
systemctl status api-gateway.service --no-pager || true
echo "API Gateway startup complete" >> /var/log/startup.log
