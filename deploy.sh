#!/bin/bash
set -e

echo "🚀 PSQ API Deployment Script"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (use sudo)"
    exit 1
fi

# Update system
echo "📦 Updating system packages..."
apt-get update && apt-get upgrade -y

# Install Node.js and npm
echo "📦 Installing Node.js and npm..."
curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
apt-get install -y nodejs

# Install dependencies
echo "📦 Installing system dependencies..."
apt-get install -y git nginx

# Install Google Cloud SDK
echo "☁️ Installing Google Cloud SDK..."
echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | tee -a /etc/apt/sources.list.d/google-cloud-sdk.list
curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key --keyring /usr/share/keyrings/cloud.google.gpg add -
apt-get update && apt-get install -y google-cloud-cli

echo ""
echo "⚠️  MANUAL STEP REQUIRED: Install pocketd CLI"
echo "Please follow the instructions for your system to install pocketd:"
echo "- Visit: https://dev.poktroll.com/explore/account_management/create_new_account_cli"
echo "- Or build from source: https://github.com/pokt-network/poktroll"
echo ""
read -p "Press Enter when you have installed pocketd and can run 'pocketd version'..."

# Verify pocketd installation
if ! command -v pocketd &> /dev/null; then
    echo "❌ pocketd command not found. Please install it first."
    exit 1
fi

echo "✅ pocketd found: $(pocketd version)"

# Create application user
echo "👤 Creating application user..."
useradd -r -m -s /bin/bash psqapi || echo "User psqapi already exists"

# Create application directory
echo "📁 Setting up application directory..."
mkdir -p /opt/psq-api
cd /opt/psq-api

# Clone or update repository
echo "📥 Setting up repository..."
if [ -d ".git" ]; then
    echo "Repository exists, updating..."
    git fetch origin
    git reset --hard origin/main
else
    echo "Cloning repository..."
    git clone https://github.com/buildwithgrove/psq-api.git .
fi

# Set ownership
chown -R psqapi:psqapi /opt/psq-api

# Install Node.js dependencies
echo "📦 Installing Node.js dependencies..."
sudo -u psqapi npm ci --only=production

# Build the application
echo "🏗️ Building application..."
sudo -u psqapi npm run build

# Create environment file
echo "⚙️ Creating environment configuration..."
cat > .env << EOF
CHAIN_ENV=BETA
NODE_ENV=production
PORT=3000
EOF

chown psqapi:psqapi .env

# Set up Google Cloud credentials
echo "🔑 Setting up Google Cloud credentials..."
echo "Please place your Google Cloud service account JSON file at /opt/psq-api/credentials.json"
echo "You can do this by running: sudo nano /opt/psq-api/credentials.json"
read -p "Press Enter when you've added the credentials file..."

if [ -f "credentials.json" ]; then
    chown psqapi:psqapi credentials.json
    chmod 600 credentials.json
    echo "GOOGLE_APPLICATION_CREDENTIALS=/opt/psq-api/credentials.json" >> .env
else
    echo "⚠️ Warning: credentials.json not found. BigQuery queries may fail."
fi

# Install systemd service
echo "🔧 Installing systemd service..."
cp psq-api.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable psq-api

# Configure nginx
echo "🌐 Configuring nginx..."
cat > /etc/nginx/sites-available/psq-api << 'EOF'
server {
    listen 80;
    server_name psq-api.grove.city;

    location /api/ {
        proxy_pass http://localhost:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # Timeouts for long-running requests
        proxy_connect_timeout 60s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
    }

    location /health {
        proxy_pass http://localhost:3000/api/health;
        access_log off;
    }

    location / {
        return 404;
    }
}
EOF

# Enable nginx site
ln -sf /etc/nginx/sites-available/psq-api /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

# Set up firewall
echo "🔥 Configuring firewall..."
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# Start services
echo "🚀 Starting services..."
systemctl start psq-api
systemctl start nginx

# Create log rotation
echo "📝 Setting up log rotation..."
cat > /etc/logrotate.d/psq-api << EOF
/var/log/syslog {
    daily
    missingok
    rotate 14
    compress
    notifempty
    postrotate
        systemctl restart psq-api
    endscript
}
EOF

echo "✅ Deployment complete!"
echo ""
echo "🌐 Your API should be running at:"
echo "   Health check: http://$(curl -s ifconfig.me)/health"
echo "   API endpoint: http://$(curl -s ifconfig.me)/api"
echo ""
echo "📋 Next steps:"
echo "1. Point your domain (psq-api.grove.city) to this server's IP"
echo "2. Set up SSL certificate (Let's Encrypt recommended)"
echo "3. Monitor logs: journalctl -u psq-api -f"
echo "4. Test the API with the provided curl commands"
echo ""
echo "🔧 Management commands:"
echo "   Start:   systemctl start psq-api"
echo "   Stop:    systemctl stop psq-api"
echo "   Restart: systemctl restart psq-api"
echo "   Status:  systemctl status psq-api"
echo "   Logs:    journalctl -u psq-api -f"